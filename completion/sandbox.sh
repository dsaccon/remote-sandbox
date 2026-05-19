#!/usr/bin/env bash
# completion/sandbox.sh — tab completion for ./bin/sandbox in bash + zsh.
#
# Enable in your current shell:
#     source ./completion/sandbox.sh
#
# Or add to ~/.bashrc / ~/.zshrc once:
#     source /path/to/remote-sandbox/completion/sandbox.sh
#
# Requires:
#   - aws CLI on PATH (it already is if you got this far)
#   - AWS credentials loaded into the environment for the live-name suggestions
#     to work (source ./load-env.sh). If creds aren't loaded, completion still
#     works for the static parts — it just won't enumerate sandbox names.

# Enable bash-style completion in zsh.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz +X compinit && compinit -u 2>/dev/null
    autoload -Uz +X bashcompinit && bashcompinit
fi

_sandbox_list_names() {
    # Query EC2 for sandbox names, excluding bake VMs (tagged BakeRole=bake).
    # Silent failure → empty output so completion just doesn't enumerate,
    # rather than erroring.
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-west-2}}"
    aws ec2 describe-instances --region "$region" \
        --filters \
            'Name=tag:Project,Values=claude-sandbox' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
        --query "Reservations[].Instances[?!Tags[?Key=='BakeRole']].Tags[?Key=='Name'].Value" \
        --output text 2>/dev/null | tr '\t' '\n'
}

_sandbox_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local subcmd="${COMP_WORDS[1]:-}"

    # Word 1: top-level subcommand or top-level help flag.
    if [[ $COMP_CWORD -eq 1 ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "up down list ssh build-ami --help -h help" -- "$cur") )
        return
    fi

    case "$subcmd" in
        up)
            # Static flag list. --instance-type / --repo / --name take values,
            # but we don't try to enumerate those.
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--repo --name --instance-type --no-spot --help" -- "$cur") )
            ;;

        down)
            if [[ "$prev" == "--stale" ]]; then
                # Suggest a few sensible durations.
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "30m 1h 4h 12h 24h 48h 7d" -- "$cur") )
                return
            fi
            local names
            names="$(_sandbox_list_names)"
            # Combine static flags + live names. compgen handles prefix filter.
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "$names --all --stale --help" -- "$cur") )
            ;;

        ssh)
            local names
            names="$(_sandbox_list_names)"
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "$names --help" -- "$cur") )
            ;;

        list|build-ami)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--help" -- "$cur") )
            ;;
    esac
}

# Register the completion function for every common way the user might invoke
# the dispatcher. Bash completion keys off the first word verbatim, so each
# spelling needs its own registration.
complete -F _sandbox_complete sandbox      2>/dev/null || true
complete -F _sandbox_complete ./bin/sandbox 2>/dev/null || true
complete -F _sandbox_complete bin/sandbox   2>/dev/null || true
