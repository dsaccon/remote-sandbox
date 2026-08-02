#!/usr/bin/env bash
# init.sh — source (do NOT execute) to set up a shell for this repo:
#   - exports AWS creds from .env into the environment
#   - registers tab completion for ./bin/sandbox
#
# Usage:
#     source ./init.sh              # loads ./.env from repo root
#     source ./init.sh path/to/env  # loads custom env file path
#
# Every KEY=value line in .env becomes an exported environment variable. AWS
# CLI and ./bin/sandbox both pick up AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# and AWS_DEFAULT_REGION automatically from the environment.
#
# This file must be SOURCED. Executing it would set vars only in the
# subshell, which dies immediately — useless.

# Trip an error if executed instead of sourced. The trick: $0 is the script
# path when executed but the shell name (bash / zsh / -bash) when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" && "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
    echo "ERROR: init.sh must be SOURCED, not executed." >&2
    echo "    source ./init.sh" >&2
    exit 1
fi

_init_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_env_file="${1:-$_init_dir/.env}"

if [[ ! -f "$_env_file" ]]; then
    echo "init: $_env_file not found" >&2
    unset _env_file _init_dir
    return 1 2>/dev/null || exit 1
fi

# Warn if .env permissions are looser than 600. macOS stat takes -f, GNU -c.
_env_perms="$(stat -f '%Lp' "$_env_file" 2>/dev/null || stat -c '%a' "$_env_file" 2>/dev/null)"
if [[ -n "$_env_perms" && "$_env_perms" != "600" ]]; then
    echo "init: WARN $_env_file has permissions $_env_perms (recommend 600). Fix:" >&2
    echo "    chmod 600 $_env_file" >&2
fi

# Export every assignment in the file.
set -a
# shellcheck source=/dev/null
source "$_env_file"
set +a

# GOOGLE_APPLICATION_CREDENTIALS drives Application Default Credentials, which
# CLIENT LIBRARIES use. The gcloud CLI — and therefore ./bin/sandbox — does NOT
# read it; gcloud authenticates from its own credential store (`gcloud auth
# login`). Nothing in this repo consumes the variable. It is re-exported here
# only for other tooling in the same shell that may genuinely want ADC; setting
# it does nothing for the sandbox CLI.
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS
    echo "init: GOOGLE_APPLICATION_CREDENTIALS exported (for client libraries; gcloud does not use it)"
fi

# Report what got loaded — names only, never values.
_env_loaded="$(awk -F'=' '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$_env_file" | tr '\n' ' ')"
echo "init: exported [$_env_loaded] from $_env_file"

# Tab completion. Best-effort: if the completion file is missing or fails,
# .env loading above still counts as a successful init.
if [[ -f "$_init_dir/completion/sandbox.sh" ]]; then
    # shellcheck source=completion/sandbox.sh
    source "$_init_dir/completion/sandbox.sh" \
        && echo "init: tab completion registered for ./bin/sandbox" \
        || echo "init: WARN tab completion failed to load" >&2
fi

unset _env_file _env_perms _env_loaded _init_dir
