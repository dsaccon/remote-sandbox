#!/usr/bin/env bash
# load-env.sh — source (do NOT execute) to load .env into the current shell.
#
# Usage:
#     source ./load-env.sh         # loads ./.env from repo root
#     source ./load-env.sh path    # loads custom path
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
    echo "ERROR: load-env.sh must be SOURCED, not executed." >&2
    echo "    source ./load-env.sh" >&2
    exit 1
fi

_env_file="${1:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/.env}"

if [[ ! -f "$_env_file" ]]; then
    echo "load-env: $_env_file not found" >&2
    unset _env_file
    return 1 2>/dev/null || exit 1
fi

# Warn if .env permissions are looser than 600. macOS stat takes -f, GNU -c.
_env_perms="$(stat -f '%Lp' "$_env_file" 2>/dev/null || stat -c '%a' "$_env_file" 2>/dev/null)"
if [[ -n "$_env_perms" && "$_env_perms" != "600" ]]; then
    echo "load-env: WARN $_env_file has permissions $_env_perms (recommend 600). Fix:" >&2
    echo "    chmod 600 $_env_file" >&2
fi

# Export every assignment in the file.
set -a
# shellcheck source=/dev/null
source "$_env_file"
set +a

# Report what got loaded — names only, never values.
_env_loaded="$(awk -F'=' '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$_env_file" | tr '\n' ' ')"
echo "load-env: exported [$_env_loaded] from $_env_file"

unset _env_file _env_perms _env_loaded
