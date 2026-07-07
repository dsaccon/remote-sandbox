#!/usr/bin/env bash
# completion/sandbox.sh — tab completion for ./bin/sandbox.
#
# Normally sourced indirectly via ../init.sh. Source directly only if you want
# completion without loading .env:
#     source ./completion/sandbox.sh
#
# Two implementations, picked by shell:
#   - zsh  → a native compsys completion in ./sandbox.zsh (sourced below). It
#            uses _files / _message, so <src> file completion gets ~ expansion,
#            directory slashes, tab-to-descend, and the dest-path hint.
#   - bash → the readline completion defined here (_sandbox_complete).
# The native-zsh syntax can't live in this file because bash must still parse
# it, hence the separate ./sandbox.zsh that only zsh ever reads.
#
# Requires:
#   - aws CLI on PATH (it already is if you got this far)
#   - AWS credentials loaded into the environment for the live-name suggestions
#     to work (source ./init.sh). If creds aren't loaded, completion still
#     works for the static parts — it just won't enumerate sandbox names.

# --- Shared between both shells: live name / AMI lookups via the aws CLI. -----

# _sandbox_cfg KEY — best-effort read of KEY's value from ./config (surrounding
# quotes and any trailing comment/space stripped). Empty if unreadable/absent.
# Done with sed, NOT shell parameter expansion: a `${v%%#*}` breaks under zsh
# EXTENDED_GLOB, which reads a leading `#` in a pattern as a glob operator.
_sandbox_cfg() {
    [[ -r "$_sandbox_config" ]] || return 0
    sed -n "s/^[[:space:]]*$1=[\"']\{0,1\}\([^\"'[:space:]#]*\).*/\1/p" \
        "$_sandbox_config" 2>/dev/null | head -1
}

# Seconds to reuse the completion cache. The first Tab in a while queries the
# clouds; repeat Tabs within this window return instantly (no round-trip). Kept
# short enough that a box you just up'd/down'd — or an image you just baked —
# reappears quickly. (No spinner: drawing to the terminal mid-completion fights
# readline's own redraw and garbles the prompt, so we just make it fast.)
_SANDBOX_CACHE_TTL=15

# _sandbox_mtime FILE — file mtime as a unix epoch (macOS then GNU stat).
_sandbox_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# _sandbox_cached TAG FRESH_FN — print FRESH_FN's output, cached per config for
# _SANDBOX_CACHE_TTL seconds so repeated Tab presses don't re-hit the cloud APIs.
# Cold/stale → run FRESH_FN and refresh via a temp file + atomic rename (so a
# concurrent Tab never reads a half-written cache); warm → just cat the file.
_sandbox_cached() {
    local tag="$1" fresh="$2" key cache now m
    key="$(printf '%s' "${_sandbox_config:-}" | cksum | cut -d' ' -f1)"
    cache="${TMPDIR:-/tmp}/sandbox-${tag}-$(id -u)-${key}"
    now="$(date +%s)"; m="$(_sandbox_mtime "$cache")"
    if [[ -z "$m" ]] || (( now - m >= _SANDBOX_CACHE_TTL )); then
        if "$fresh" > "$cache.$$" 2>/dev/null; then
            mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null
        else
            rm -f "$cache.$$" 2>/dev/null
        fi
    fi
    cat "$cache" 2>/dev/null
}

# _sandbox_list_names — sandbox names across BOTH clouds (ssh/scp/down are
# cross-cloud, so completion offers everything reachable), cached.
_sandbox_list_names() { _sandbox_cached names _sandbox_list_names_fresh; }

# _sandbox_list_names_fresh — query both clouds CONCURRENTLY. Process
# substitution starts both at once and merges them (parallel in bash AND zsh,
# with no background-job notices), so latency is the slower query, not the sum.
_sandbox_list_names_fresh() {
    sort -u <(_sandbox_names_aws 2>/dev/null) <(_sandbox_names_gcp 2>/dev/null)
}
_sandbox_names_aws() {
    # Emit (Name, BakeRole) and drop bake VMs in awk — JMESPath negation is
    # unreliable.
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-west-2}}"
    aws ec2 describe-instances --region "$region" \
        --filters \
            'Name=tag:Project,Values=claude-sandbox' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value | [0], Tags[?Key==`BakeRole`].Value | [0]]' \
        --output text 2>/dev/null \
        | awk '$2 == "None" { print $1 }'
}
_sandbox_names_gcp() {
    local proj; proj="$(_sandbox_cfg GCP_PROJECT)"
    [[ -z "$proj" ]] && return 0
    gcloud compute instances list --project "$proj" \
        --filter="labels.project=claude-sandbox" --format="value(name)" 2>/dev/null
}

# _sandbox_list_images — delete-image identifiers across BOTH clouds (AWS AMI
# ids + GCP image names), cached like the names lookup so `delete-image <Tab>`
# only pays the cloud round-trip on the first press.
_sandbox_list_images() { _sandbox_cached images _sandbox_list_images_fresh; }
_sandbox_list_images_fresh() {
    sort -u <(_sandbox_images_aws 2>/dev/null) <(_sandbox_images_gcp 2>/dev/null)
}
_sandbox_images_aws() {
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-west-2}}"
    aws ec2 describe-images --region "$region" --owners self \
        --filters 'Name=name,Values=claude-sandbox-*' \
        --query 'Images[].ImageId' --output text 2>/dev/null \
        | tr '\t' '\n'
}
_sandbox_images_gcp() {
    local proj; proj="$(_sandbox_cfg GCP_PROJECT)"
    [[ -z "$proj" ]] && return 0
    gcloud compute images list --project "$proj" \
        --filter="family=claude-sandbox" --format="value(name)" 2>/dev/null
}

# Directory of THIS file, so the zsh branch can find sandbox.zsh. Resolves in
# both shells: bash via BASH_SOURCE, zsh via $0 of the sourced file.
_sandbox_comp_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# Path to ./config, resolved at source time and kept (NOT unset like
# _sandbox_comp_dir below) so _sandbox_cfg can read it when completion runs.
_sandbox_config="${_sandbox_comp_dir%/*}/config"

if [[ -n "${ZSH_VERSION:-}" ]]; then
    # --- zsh: native compsys completion (see sandbox.zsh) --------------------
    autoload -Uz +X compinit && compinit -u 2>/dev/null
    if [[ -f "$_sandbox_comp_dir/sandbox.zsh" ]]; then
        # shellcheck source=/dev/null
        source "$_sandbox_comp_dir/sandbox.zsh"
    fi
else
    # --- bash: readline completion -------------------------------------------

    # _sandbox_complete_path CUR — local file/dir completion for CUR into
    # COMPREPLY. We glob ourselves rather than use `compgen -f` so a leading
    # `~/` expands (readline passes it through literally) while keeping `~/` in
    # the suggestion. We do NOT append a trailing "/" to directories — readline
    # (-o filenames, below) adds it, tilde-expanding to stat the path.
    _sandbox_complete_path() {
        local cur="$1"
        local prefix="" expanded="$cur"
        case "$cur" in
            '~/'*) prefix="~/"; expanded="$HOME/${cur#\~/}" ;;
            '~')   prefix="~/"; expanded="$HOME/" ;;
        esac

        local _ng; _ng="$(shopt -p nullglob)"; shopt -s nullglob
        COMPREPLY=()
        local g
        for g in "$expanded"*; do
            if [[ -n "$prefix" ]]; then
                COMPREPLY+=( "${prefix}${g#"$HOME"/}" )   # /Users/you/x -> ~/x
            else
                COMPREPLY+=( "$g" )
            fi
        done
        eval "$_ng"   # restore nullglob state
    }

    _sandbox_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local prev="${COMP_WORDS[COMP_CWORD-1]}"
        local subcmd="${COMP_WORDS[1]:-}"

        # Word 1: top-level subcommand or top-level help flag.
        if [[ $COMP_CWORD -eq 1 ]]; then
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "up down list ssh scp spot build-ami list-images delete-image list-amis delete-ami --help -h help" -- "$cur") )
            return
        fi

        case "$subcmd" in
            up)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                elif [[ "$prev" == "--disk-size" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "32 64 100 200 500" -- "$cur") )
                else
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "--cloud --repo --name --instance-type --disk-size --spot --no-spot --ssh-cidr --help" -- "$cur") )
                fi
                ;;

            down)
                if [[ "$prev" == "--stale" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "30m 1h 4h 12h 24h 48h 7d" -- "$cur") )
                    return
                fi
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                    return
                fi
                local names
                names="$(_sandbox_list_names)"
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$names --all --stale --cloud --yes --help" -- "$cur") )
                ;;

            ssh)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                elif [[ "$prev" == "--ports" ]]; then
                    COMPREPLY=()   # freeform port numbers
                elif [[ "$cur" == -* ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "--cloud --ports --help" -- "$cur") )
                else
                    local names
                    names="$(_sandbox_list_names)"
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "$names --cloud --ports --help" -- "$cur") )
                fi
                ;;

            scp)
                # upload:    scp <name> <src-path> [dest-path]
                # download:  scp <name> -d [remote-src] [local-dest|-o local-dest]
                if [[ "${COMP_WORDS[COMP_CWORD-1]}" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                elif [[ "${COMP_WORDS[COMP_CWORD-1]}" == "-o" || "${COMP_WORDS[COMP_CWORD-1]}" == "--output" ]]; then
                    # The value of `-o <path>` / `--output <path>` is a LOCAL path.
                    _sandbox_complete_path "$cur"
                elif [[ "$cur" == --output=* ]]; then
                    # The `--output=<path>` form: complete the path, re-add prefix.
                    _sandbox_complete_path "${cur#--output=}"
                    local _i
                    for _i in "${!COMPREPLY[@]}"; do COMPREPLY[$_i]="--output=${COMPREPLY[$_i]}"; done
                else
                    # Detect download mode and which positional the current word
                    # is, counting only non-flag words (skipping the -o value)
                    # so the flags may sit anywhere.
                    local dl=0 filled=0 i skip=0 names flags
                    for (( i=2; i < ${#COMP_WORDS[@]}; i++ )); do
                        [[ "${COMP_WORDS[i]}" == "-d" || "${COMP_WORDS[i]}" == "--download" ]] && dl=1
                    done
                    for (( i=2; i < COMP_CWORD; i++ )); do
                        if (( skip )); then skip=0; continue; fi
                        case "${COMP_WORDS[i]}" in
                            -o|--output) skip=1 ;;
                            -*) ;;
                            *) (( filled++ )) ;;
                        esac
                    done

                    if [[ "$cur" == -* ]]; then
                        flags="-d --download --cloud --help"
                        (( dl )) && flags="$flags -o --output"
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
                    elif (( dl )); then
                        case $(( filled + 1 )) in
                            1) names="$(_sandbox_list_names)"
                               # shellcheck disable=SC2207
                               COMPREPLY=( $(compgen -W "$names" -- "$cur") ) ;;
                            2) COMPREPLY=() ;;                       # remote-src: remote, nothing local
                            3) _sandbox_complete_path "$cur" ;;      # local-dest
                            *) COMPREPLY=() ;;
                        esac
                    else
                        case $(( filled + 1 )) in
                            1) names="$(_sandbox_list_names)"
                               # shellcheck disable=SC2207
                               COMPREPLY=( $(compgen -W "$names --help" -- "$cur") ) ;;
                            2) _sandbox_complete_path "$cur" ;;      # local <src>
                            *) COMPREPLY=() ;;                       # remote dest: nothing local
                        esac
                    fi
                fi
                ;;

            list)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                else
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "--active --cloud --help" -- "$cur") )
                fi
                ;;

            list-amis|list-images)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                else
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "--active --cloud --help" -- "$cur") )
                fi
                ;;

            spot)
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "on off status --help" -- "$cur") )
                ;;

            build-ami)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                else
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "--cloud --help" -- "$cur") )
                fi
                ;;

            delete-ami|delete-image)
                if [[ "$prev" == "--cloud" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "aws gcp" -- "$cur") )
                else
                    local imgs
                    imgs="$(_sandbox_list_images)"
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "$imgs --cloud --force --help" -- "$cur") )
                fi
                ;;
        esac
    }

    # -o filenames: treat results as filenames so readline adds a trailing slash
    # to directories and drops the trailing space after them (for the
    # `scp <name> <src>` path completion). On non-path positions the results
    # aren't real files, so it's a no-op beyond a trailing space.
    complete -o filenames -F _sandbox_complete sandbox       2>/dev/null || true
    complete -o filenames -F _sandbox_complete ./bin/sandbox 2>/dev/null || true
    complete -o filenames -F _sandbox_complete bin/sandbox   2>/dev/null || true
fi

unset _sandbox_comp_dir
