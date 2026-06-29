#!/usr/bin/env bash
# lib/config.sh — load ./config with precedence: flag > env > file > default.
# Source, don't execute. Requires SANDBOX_REPO_ROOT set by caller.

if [[ -n "${_SANDBOX_CONFIG_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_CONFIG_SH_LOADED=1

# Resolve log.sh relative to this file so it works regardless of caller cwd.
_config_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_config_sh_dir/log.sh"

# Keys we manage. Each gets a default; env-var lookup is SANDBOX_<KEY>.
_CONFIG_KEYS=(
    CLOUD
    AWS_REGION
    INSTANCE_TYPE
    USE_SPOT
    SPOT_FALLBACK_ON_DEMAND
    SSH_KEY_NAME
    SSH_KEY_FILE
    SSH_USER
    AMI_ID
    AUTO_SHUTDOWN_HOURS
    DOTFILES_REPO
    CLAUDE_HARDENING_REPO
    SSH_INGRESS_CIDR
)

# Defaults.
_config_default() {
    case "$1" in
        CLOUD)                    echo "aws" ;;
        AWS_REGION)               echo "us-west-2" ;;
        INSTANCE_TYPE)            echo "m7i-flex.xlarge" ;;
        USE_SPOT)                 echo "true" ;;
        SPOT_FALLBACK_ON_DEMAND)  echo "true" ;;
        SSH_KEY_NAME)             echo "claude-sandbox" ;;
        SSH_KEY_FILE)             echo "${HOME}/.ssh/${SSH_KEY_NAME:-claude-sandbox}.pem" ;;
        SSH_USER)                 echo "ubuntu" ;;
        AMI_ID)                   echo "" ;;
        AUTO_SHUTDOWN_HOURS)      echo "0" ;;
        DOTFILES_REPO)            echo "" ;;
        CLAUDE_HARDENING_REPO)    echo "" ;;
        SSH_INGRESS_CIDR)         echo "" ;;
        *)                        echo "" ;;
    esac
}

config_load() {
    : "${SANDBOX_REPO_ROOT:?config_load: SANDBOX_REPO_ROOT not set}"
    local cfg="$SANDBOX_REPO_ROOT/config"
    if [[ ! -f "$cfg" ]]; then
        die "no config file at $cfg — copy config.example to config and edit"
    fi
    # shellcheck source=/dev/null
    source "$cfg"

    # For each key: env override → file value (already set) → default.
    local key env_name env_val cur
    for key in "${_CONFIG_KEYS[@]}"; do
        env_name="SANDBOX_$key"
        env_val="${!env_name:-}"
        if [[ -n "$env_val" ]]; then
            printf -v "$key" '%s' "$env_val"
            continue
        fi
        cur="${!key:-}"
        if [[ -z "$cur" ]]; then
            printf -v "$key" '%s' "$(_config_default "$key")"
        fi
    done

    # Export everything for child processes.
    export "${_CONFIG_KEYS[@]}"
}

# config_set_from_flag KEY VALUE — highest precedence; subcommands call this
# while parsing argv.
config_set_from_flag() {
    local key="$1"; local val="$2"
    printf -v "$key" '%s' "$val"
    # Dynamic export: export the variable named by $key, not a literal "key".
    # shellcheck disable=SC2163
    export "$key"
}

# config_write_key KEY VALUE — rewrite the `KEY="..."` line in ./config in
# place, or append it if absent. VALUE is written quoted. Used to persist
# settings changed from the CLI (AMI_ID after a bake, USE_SPOT toggle, ...).
config_write_key() {
    : "${SANDBOX_REPO_ROOT:?config_write_key: SANDBOX_REPO_ROOT not set}"
    local key="$1" val="$2"
    local cfg="$SANDBOX_REPO_ROOT/config"
    [[ -f "$cfg" ]] || die "no config at $cfg"
    local tmp; tmp="$(mktemp)"
    if grep -q "^${key}=" "$cfg"; then
        sed -E "s|^${key}=.*|${key}=\"${val}\"|" "$cfg" > "$tmp"
    else
        cp "$cfg" "$tmp"
        printf '\n%s="%s"\n' "$key" "$val" >> "$tmp"
    fi
    mv "$tmp" "$cfg"
}

# config_write_ami_id NEW_ID — convenience wrapper over config_write_key.
config_write_ami_id() {
    config_write_key AMI_ID "$1"
}
