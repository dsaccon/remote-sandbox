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

# wait_with_progress LABEL CMD [ARGS...]
#
# Runs CMD in the background, prints an elapsed-time progress line on stderr
# until it finishes (overwriting in place on a TTY, or one dot per tick if
# stderr is redirected). Returns CMD's exit status.
wait_with_progress() {
    local label="$1"; shift
    log_info "$label"
    "$@" &
    local pid=$!
    local start
    start="$(date +%s)"
    if [[ -t 2 ]]; then
        # Interactive: overwrite the same line with elapsed seconds.
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  ... %ds elapsed   ' "$(( $(date +%s) - start ))" >&2
            sleep 2
        done
        printf '\r  ... done in %ds        \n' "$(( $(date +%s) - start ))" >&2
    else
        # Non-TTY (piped/captured): one dot per tick, plus elapsed at the end.
        while kill -0 "$pid" 2>/dev/null; do
            printf '.' >&2
            sleep 5
        done
        printf ' done in %ds\n' "$(( $(date +%s) - start ))" >&2
    fi
    wait "$pid"
}
