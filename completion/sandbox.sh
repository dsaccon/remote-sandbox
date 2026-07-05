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

# _sandbox_cfg KEY — best-effort read of KEY's value from ./config (quotes,
# trailing comment, and spaces stripped). Empty if unreadable/absent. Works in
# both bash and zsh (plain parameter expansion, no shell-specific syntax).
_sandbox_cfg() {
    [[ -r "$_sandbox_config" ]] || return 0
    local v
    v="$(grep -E "^[[:space:]]*$1=" "$_sandbox_config" 2>/dev/null | head -1)"
    v="${v#*=}"      # value after KEY=
    v="${v%%#*}"     # strip trailing comment
    v="${v//\"/}"    # strip double quotes
    v="${v// /}"     # strip spaces
    printf '%s' "$v"
}

# _sandbox_list_names — live sandbox names for the ACTIVE cloud (ssh/scp/down
# all operate on CLOUD, so completion matches what they can reach). Silent
# failure → empty output, so completion just doesn't enumerate.
_sandbox_list_names() {
    local cloud; cloud="$(_sandbox_cfg CLOUD)"; cloud="${cloud:-aws}"
    if [[ "$cloud" == "gcp" ]]; then
        local proj; proj="$(_sandbox_cfg GCP_PROJECT)"
        [[ -z "$proj" ]] && return 0
        gcloud compute instances list --project "$proj" \
            --filter="labels.project=claude-sandbox" \
            --format="value(name)" 2>/dev/null
    else
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
    fi
}

_sandbox_list_amis() {
    # AMI IDs for claude-sandbox-* AMIs the caller owns. Silent failure
    # → empty output (same UX as _sandbox_list_names).
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-west-2}}"
    aws ec2 describe-images --region "$region" --owners self \
        --filters 'Name=name,Values=claude-sandbox-*' \
        --query 'Images[].ImageId' --output text 2>/dev/null \
        | tr '\t' '\n'
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
            COMPREPLY=( $(compgen -W "up down list ssh scp spot build-ami list-amis delete-ami --help -h help" -- "$cur") )
            return
        fi

        case "$subcmd" in
            up)
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "--repo --name --instance-type --spot --no-spot --ssh-cidr --help" -- "$cur") )
                ;;

            down)
                if [[ "$prev" == "--stale" ]]; then
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "30m 1h 4h 12h 24h 48h 7d" -- "$cur") )
                    return
                fi
                local names
                names="$(_sandbox_list_names)"
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$names --all --stale --help" -- "$cur") )
                ;;

            ssh)
                if [[ $COMP_CWORD -eq 2 ]]; then
                    local names
                    names="$(_sandbox_list_names)"
                    # shellcheck disable=SC2207
                    COMPREPLY=( $(compgen -W "$names --help" -- "$cur") )
                else
                    COMPREPLY=()   # ssh takes a single <name>
                fi
                ;;

            scp)
                # upload:    scp <name> <src-path> [dest-path]
                # download:  scp <name> -d [remote-src] [local-dest|-o local-dest]
                if [[ "${COMP_WORDS[COMP_CWORD-1]}" == "-o" || "${COMP_WORDS[COMP_CWORD-1]}" == "--output" ]]; then
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
                        flags="-d --download --help"
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

            list|list-amis)
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "--active --help" -- "$cur") )
                ;;

            spot)
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "on off status --help" -- "$cur") )
                ;;

            build-ami)
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "--help" -- "$cur") )
                ;;

            delete-ami)
                local amis
                amis="$(_sandbox_list_amis)"
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$amis --help" -- "$cur") )
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
