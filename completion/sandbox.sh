#!/usr/bin/env bash
# completion/sandbox.sh — tab completion for ./bin/sandbox in bash + zsh.
#
# Normally sourced indirectly via ../init.sh. Source directly only if you
# want completion without loading .env:
#     source ./completion/sandbox.sh
#
# Requires:
#   - aws CLI on PATH (it already is if you got this far)
#   - AWS credentials loaded into the environment for the live-name suggestions
#     to work (source ./init.sh). If creds aren't loaded, completion still
#     works for the static parts — it just won't enumerate sandbox names.

# Enable bash-style completion in zsh.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz +X compinit && compinit -u 2>/dev/null
    autoload -Uz +X bashcompinit && bashcompinit
fi

_sandbox_list_names() {
    # Query EC2 for sandbox names. Emit two columns (Name, BakeRole) per
    # instance and filter out bake VMs in awk — JMESPath's `!Tags[?...]`
    # negation is unreliable. Silent failure → empty output so completion
    # just doesn't enumerate, rather than erroring.
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-west-2}}"
    aws ec2 describe-instances --region "$region" \
        --filters \
            'Name=tag:Project,Values=claude-sandbox' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value | [0], Tags[?Key==`BakeRole`].Value | [0]]' \
        --output text 2>/dev/null \
        | awk '$2 == "None" { print $1 }'
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

_sandbox_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local subcmd="${COMP_WORDS[1]:-}"

    # Word 1: top-level subcommand or top-level help flag.
    if [[ $COMP_CWORD -eq 1 ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "up down list ssh build-ami list-amis delete-ami --help -h help" -- "$cur") )
        return
    fi

    case "$subcmd" in
        up)
            # Static flag list. Value-taking flags (--instance-type / --repo /
            # --name / --ssh-cidr) aren't enumerated.
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--repo --name --instance-type --no-spot --ssh-cidr --help" -- "$cur") )
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

        list|list-amis)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--active --help" -- "$cur") )
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

# Register the completion function for every common way the user might invoke
# the dispatcher. Bash completion keys off the first word verbatim, so each
# spelling needs its own registration.
complete -F _sandbox_complete sandbox      2>/dev/null || true
complete -F _sandbox_complete ./bin/sandbox 2>/dev/null || true
complete -F _sandbox_complete bin/sandbox   2>/dev/null || true
