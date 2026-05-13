#!/usr/bin/env bash
# lib/log.sh — consistent stderr logging.
# Source, don't execute. Idempotent.

if [[ -n "${_SANDBOX_LOG_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_LOG_SH_LOADED=1

_log() {
    local level="$1"; shift
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%SZ)" "$level" "$*" >&2
}

log_info() { _log INFO  "$@"; }
log_warn() { _log WARN  "$@"; }
log_err()  { _log ERROR "$@"; }

die() {
    log_err "$@"
    exit 1
}
