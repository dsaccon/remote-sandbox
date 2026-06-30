# completion/sandbox.zsh — native zsh (compsys) completion for ./bin/sandbox.
#
# Sourced ONLY under zsh, by completion/sandbox.sh — which first runs compinit
# and which also defines the shared _sandbox_list_names / _sandbox_list_amis
# helpers this file calls. Bash never reads this file, so it is free to use
# native zsh/compsys syntax (${(f)...}, _files, _message, _describe).
#
# Why native rather than the bash-style completion under bashcompinit: only the
# real completion harness can drive _files (so <src> paths get ~ expansion, a
# trailing "/" on directories, and tab-to-descend) and _message (the dest-path
# hint). bashcompinit runs completion functions inside a `$(...)` subshell under
# `emulate sh`, where _files errors and message builtins are discarded.
#
# Dispatch is by explicit word index rather than `_arguments` state machine:
#   words[1] = ./bin/sandbox   words[2] = subcommand   words[3..] = its args
#   CURRENT  = 1-based index of the word currently being completed
# This keeps the position handling unambiguous.

# _sandbox_names — complete a live sandbox name (queried from EC2).
_sandbox_names() {
    local out; out="$(_sandbox_list_names)"
    local -a names; names=( ${(f)out} )
    (( ${#names} )) && _describe -t sandboxes 'sandbox' names
}

# _sandbox_amis — complete a claude-sandbox-* AMI id you own.
_sandbox_amis() {
    local out; out="$(_sandbox_list_amis)"
    local -a amis; amis=( ${(f)out} )
    (( ${#amis} )) && _describe -t amis 'AMI' amis
}

_sandbox() {
    local cmd=$words[2]

    # Completing the subcommand itself.
    if (( CURRENT == 2 )); then
        local -a commands
        commands=(
            'up:provision a fresh ephemeral sandbox'
            'down:terminate sandbox(es)'
            'list:list sandboxes'
            'ssh:SSH into a sandbox'
            'scp:upload a local file/dir to a sandbox'
            'spot:show or set the standing spot default'
            'build-ami:bake a fresh AMI'
            'list-amis:list AMIs you own'
            'delete-ami:deregister AMIs and delete their snapshots'
            '--help:show help'
        )
        _describe -t commands 'sandbox command' commands
        return
    fi

    case $cmd in
        up)
            local -a opts
            opts=(
                '--repo:clone a git repo into the box'
                '--name:sandbox name'
                '--instance-type:EC2 instance type'
                '--spot:force spot for this launch'
                '--no-spot:force on-demand for this launch'
                '--ssh-cidr:SSH ingress CIDR'
                '--help:show help'
            )
            _describe -t options 'option' opts
            ;;

        down)
            if [[ $words[CURRENT-1] == --stale ]]; then
                local -a durs; durs=(30m 1h 4h 12h 24h 48h 7d)
                _describe -t durations 'duration' durs
            else
                _sandbox_names
                local -a opts
                opts=(
                    '--all:terminate every sandbox'
                    '--stale:terminate boxes older than a duration'
                    '--help:show help'
                )
                _describe -t options 'option' opts
            fi
            ;;

        ssh)
            # ssh takes a single <name>.
            if (( CURRENT == 3 )); then
                _sandbox_names
                local -a opts; opts=('--help:show help')
                _describe -t options 'option' opts
            fi
            ;;

        scp)
            # upload:    scp <name> <src-path> [dest-path]
            # download:  scp <name> -d [remote-src] [local-dest|-o local-dest]
            if [[ $words[CURRENT-1] == -o || $words[CURRENT-1] == --output ]]; then
                # The value of `-o <path>` / `--output <path>` is a LOCAL path.
                _files
            elif [[ $words[CURRENT] == --output=* ]]; then
                # The `--output=<path>` form: strip the prefix, then complete.
                compset -P '--output='
                _files
            else
                # Detect download mode and which positional the current word is,
                # counting only non-flag words (and skipping the -o value) so the
                # flags may sit anywhere on the line.
                local dl=0 filled=0 i skip=0
                for (( i = 3; i <= ${#words}; i++ )); do
                    [[ $words[i] == -d || $words[i] == --download ]] && dl=1
                done
                for (( i = 3; i < CURRENT; i++ )); do
                    if (( skip )); then skip=0; continue; fi
                    case $words[i] in
                        -o|--output) skip=1 ;;        # its value isn't a positional
                        -*) ;;                         # other flag
                        *) (( filled++ )) ;;           # a positional
                    esac
                done

                if [[ $words[CURRENT] == -* ]]; then
                    local -a opts
                    opts=(
                        '-d:download mode (sandbox -> local)'
                        '--download:download mode (sandbox -> local)'
                        '--help:show help'
                    )
                    (( dl )) && opts+=(
                        '-o:local destination directory/path'
                        '--output:local destination directory/path'
                    )
                    _describe -t options 'option' opts
                elif (( dl )); then
                    case $(( filled + 1 )) in
                        1) _sandbox_names ;;                                                                # <name>
                        2) _message -r 'remote file — omit to browse the sandbox interactively (press Enter)' ;;  # remote-src
                        3) _files ;;                                                                        # local-dest
                    esac
                else
                    case $(( filled + 1 )) in
                        1) _sandbox_names ;;                                                                # <name>
                        2) _files ;;                                                                        # local <src>
                        3) _message -r 'omit to browse the sandbox filesystem interactively — just press Enter' ;;  # remote dest
                    esac
                fi
            fi
            ;;

        list|list-amis)
            local -a opts; opts=('--active:only the ready ones' '--help:show help')
            _describe -t options 'option' opts
            ;;

        spot)
            if (( CURRENT == 3 )); then
                local -a acts
                acts=(
                    'on:make spot the standing default'
                    'off:make on-demand the standing default'
                    'status:show the current default'
                )
                _describe -t actions 'action' acts
            fi
            ;;

        build-ami)
            local -a opts; opts=('--help:show help')
            _describe -t options 'option' opts
            ;;

        delete-ami)
            _sandbox_amis
            ;;
    esac
}

compdef _sandbox sandbox ./bin/sandbox bin/sandbox
