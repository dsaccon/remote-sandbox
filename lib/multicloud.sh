#!/usr/bin/env bash
# lib/multicloud.sh — cross-cloud orchestration. Query, resolve, and terminate
# sandboxes across every configured cloud (aws + gcp). `list`, `ssh`, `scp`, and
# `down` operate on whatever exists, regardless of the config CLOUD (which is
# just the default launch target for `up`). A per-command `--cloud <c>` narrows
# any of these to one cloud.
#
# Source AFTER lib/config.sh (config_load) — each cloud is loaded in its own
# subshell (the drivers share provider_* names, so they can't coexist).

if [[ -n "${_SANDBOX_MULTICLOUD_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_MULTICLOUD_SH_LOADED=1

_mc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_mc_dir/log.sh"
# shellcheck source=provider.sh
source "$_mc_dir/provider.sh"

# Supported clouds, in display order.
_MC_CLOUDS="aws gcp"

# mc_valid_cloud C — die unless C is a supported cloud. Call while parsing a
# --cloud flag so bad values fail fast with a clear message.
mc_valid_cloud() {
    case "$1" in
        aws|gcp) return 0 ;;
        *) die "unknown --cloud '$1' (supported: aws, gcp)" ;;
    esac
}

# provider_list_all [SCOPE] — normalized records across the in-scope clouds
# (SCOPE = aws|gcp to restrict; empty = all), one tab-separated row per box,
# prefixed with its provider (10 fields):
#   provider handle name state type market launch_epoch ip allowed_cidr ash_hours
# A cloud whose CLI/credentials aren't usable is skipped silently.
# Seconds a single cloud may take before it is abandoned. A stalled cloud used
# to hang every command indefinitely — a broken IPv6 route once made gcloud sit
# for 76s per call with no output at all. Override with SANDBOX_CLOUD_TIMEOUT.
: "${SANDBOX_CLOUD_TIMEOUT:=25}"

# _mc_wait_bounded PID SECS — wait for PID, killing it if it outlives SECS.
# Returns the child's status, or 124 (GNU timeout's convention) if it was killed.
#
# A watchdog subshell rather than a polling loop, so `wait` blocks until the
# child is genuinely done and a healthy cloud adds no latency. macOS ships no
# timeout(1), and its /bin/bash is 3.2 — no `wait -n`.
_mc_wait_bounded() {
    local pid="$1" secs="$2" watchdog rc
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    # 143 = 128 + SIGTERM, i.e. the watchdog fired.
    [ "$rc" -eq 143 ] && rc=124
    return "$rc"
}

# _mc_report_skip PROV RC ERRFILE — say why a cloud produced no rows.
# rc 0 = fine; rc 3 = not configured, silent by design (an AWS-only user should
# never see gcp noise); rc 124 = timed out; anything else = configured but
# failing, so pass along what the cloud's own CLI reported.
_mc_report_skip() {
    local prov="$1" rc="$2" errfile="$3" msg
    # Explicit `if`s, not `[ ... ] && return`: the latter evaluates to the test's
    # status when it is false, which is a footgun under `set -e`
    # (see lib/providers/gcp.sh:200).
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
        return 0
    fi
    if [ "$rc" -eq 124 ]; then
        log_warn "$prov skipped — no response within ${SANDBOX_CLOUD_TIMEOUT}s"
        return 0
    fi
    # Strip log.sh's own "[HH:MM:SSZ] ERROR: " prefix from the captured text:
    # the driver died via die(), and log_warn is about to add a prefix of its
    # own, so keeping both nests two timestamps in one line.
    msg="$(tr '\n' ' ' < "$errfile" 2>/dev/null \
        | sed -e 's/\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\] ERROR: //g' \
              -e 's/  */ /g; s/^ *//; s/ *$//')"
    log_warn "$prov skipped — ${msg:-no error output}"
    return 0
}

provider_list_all() {
    local scope="${1:-}" prov out err pid rc
    for prov in $_MC_CLOUDS; do
        [[ -n "$scope" && "$scope" != "$prov" ]] && continue
        out="$(mktemp "${TMPDIR:-/tmp}/sandbox-mc-out.XXXXXX")" || continue
        err="$(mktemp "${TMPDIR:-/tmp}/sandbox-mc-err.XXXXXX")" || { rm -f "$out"; continue; }
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            provider_configured || exit 3
            provider_check_creds >/dev/null || exit 1
            provider_list 2>/dev/null | while IFS= read -r row; do
                [ -n "$row" ] && printf '%s\t%s\n' "$prov" "$row"
            done
            exit 0
        ) >"$out" 2>"$err" &
        pid=$!
        # `|| rc=$?` rather than a bare call: a failing cloud returns non-zero,
        # which under the callers' `set -e` would abort the whole listing —
        # including the healthy cloud's rows that are already on disk.
        rc=0
        _mc_wait_bounded "$pid" "$SANDBOX_CLOUD_TIMEOUT" || rc=$?
        cat "$out" 2>/dev/null
        _mc_report_skip "$prov" "$rc" "$err"
        rm -f "$out" "$err"
    done
    return 0
}

# mc_find NAME [SCOPE] — print the single matching record (11-field row) for the
# box whose name OR handle == NAME across the in-scope clouds. die on no match,
# or on an ambiguous one. Used by ssh/scp/down.
mc_find() {
    local name="$1" scope="${2:-}" rows match live count clouds ncloud
    rows="$(provider_list_all "$scope")"
    match="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$3==n || $2==n')"
    if [[ -z "$match" ]]; then
        die "no sandbox named $name in ${scope:-aws or gcp} (try ./bin/sandbox list)"
    fi
    # A terminated box keeps its name resolvable for as long as the cloud goes on
    # listing it (~1h on AWS), so reusing a name would otherwise make every
    # lookup ambiguous — you couldn't even `down` the new box by name. Prefer
    # boxes that still exist; fall back to the dead ones only when that's all
    # there is, which is the case `down` cleans up after.
    live="$(printf '%s\n' "$match" | awk -F'\t' '$4 != "terminated" && $4 != "shutting-down"')"
    [[ -n "$live" ]] && match="$live"
    count="$(printf '%s\n' "$match" | grep -c .)"
    if [[ "$count" -gt 1 ]]; then
        clouds="$(printf '%s\n' "$match" | awk -F'\t' '{print $1}' | sort -u | tr '\n' ' ')"
        ncloud="$(printf '%s\n' "$match" | awk -F'\t' '{print $1}' | sort -u | grep -c .)"
        if [[ "$ncloud" -gt 1 ]]; then
            die "sandbox $name exists in more than one cloud (${clouds% }) — pick one with --cloud"
        fi
        die "$count live sandboxes are named $name in ${clouds% } — address one by its instance id instead"
    fi
    printf '%s' "$match"
}

# mc_resolve_ip NAME [SCOPE] — resolve a running box NAME to its public IP across
# clouds, with the same state-aware errors ssh/scp had per-cloud.
mc_resolve_ip() {
    local match provider handle name state type market epoch ip cidr ash disk
    match="$(mc_find "$1" "${2:-}")" || return 1
    # provider/handle/type/... are positional placeholders; this function only
    # acts on `state`, `name` and `ip`, but the field order is fixed.
    # shellcheck disable=SC2034
    IFS=$'\t' read -r provider handle name state type market epoch ip cidr ash disk <<< "$match"
    # Refuse only states that clearly aren't reachable; a box that's up (ready /
    # running / still-initializing / impaired) is connectable as long as it has
    # a public IP — matching the old per-cloud resolve, which keyed off "running".
    case "$state" in
        pending)
            die "sandbox $name is still booting (state: pending) — no IP yet. Check './bin/sandbox list'." ;;
        stopping|stopped)
            die "sandbox $name is $state. Up a new one with './bin/sandbox up'." ;;
        shutting-down|terminated)
            die "sandbox $name is $state — gone. Up a fresh one with './bin/sandbox up'." ;;
        *) : ;;
    esac
    if [[ -z "$ip" || "$ip" == "-" ]]; then
        die "sandbox $name is up but has no public IP yet — check './bin/sandbox list'"
    fi
    printf '%s' "$ip"
}

# mc_terminate — read "provider<TAB>handle<TAB>name" rows on stdin; group by
# provider and terminate + clean up per cloud (each in a subshell with that
# driver loaded). Logs a one-line summary per cloud.
# mc_cleanup_net — read "provider<TAB>name" rows on stdin and delete each box's
# per-sandbox network resources (AWS SG / GCP firewall rule) via its cloud's
# driver, without touching instances. Used by `down` on a box that is already
# gone: the instance is terminated, but AWS keeps its security group, and an
# orphaned one blocks `up --name <same>` with InvalidGroup.Duplicate forever.
mc_cleanup_net() {
    local input; input="$(cat)"
    [[ -z "$input" ]] && return 0
    local prov
    for prov in $_MC_CLOUDS; do
        local names=() p n
        while IFS=$'\t' read -r p n; do
            [[ "$p" == "$prov" ]] || continue
            [[ -z "$n" ]] && continue
            names+=("$n")
        done <<< "$input"
        [[ ${#names[@]} -eq 0 ]] && continue
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            provider_cleanup_net "${names[@]}"
            exit 0
        )
    done
}

mc_terminate() {
    local input; input="$(cat)"
    [[ -z "$input" ]] && return 0
    local prov
    for prov in $_MC_CLOUDS; do
        local ids=() names=() p h n
        while IFS=$'\t' read -r p h n; do
            [[ "$p" == "$prov" ]] || continue
            [[ -z "$h" ]] && continue
            ids+=("$h"); [[ -n "$n" ]] && names+=("$n")
        done <<< "$input"
        [[ ${#ids[@]} -eq 0 ]] && continue
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            provider_terminate_ids "${ids[@]}"
            [[ ${#names[@]} -gt 0 ]] && provider_cleanup_net "${names[@]}"
            exit 0
        )
        log_info "$prov: terminated ${ids[*]}"
    done
}

# provider_images_all [SCOPE] — normalized image records across the in-scope
# clouds (SCOPE = aws|gcp to restrict; empty = all), one tab-separated row per
# image, prefixed with its provider (7 fields):
#   provider id name created_epoch size_gb current in_use
# A cloud whose CLI/credentials aren't usable is skipped silently.
provider_images_all() {
    local scope="${1:-}" prov
    for prov in $_MC_CLOUDS; do
        [[ -n "$scope" && "$scope" != "$prov" ]] && continue
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            ( provider_check_creds ) >/dev/null 2>&1 || exit 0
            provider_list_images 2>/dev/null | while IFS= read -r row; do
                [ -n "$row" ] && printf '%s\t%s\n' "$prov" "$row"
            done
            exit 0
        )
    done
    return 0
}

# mc_find_image ID_OR_NAME [SCOPE] — the single image record (7 fields) whose id
# OR name == the query across in-scope clouds. die on no match or on ambiguity
# (same identifier in >1 cloud). Used by delete-image.
mc_find_image() {
    local q="$1" scope="${2:-}" rows match count provs
    rows="$(provider_images_all "$scope")"
    match="$(printf '%s\n' "$rows" | awk -F'\t' -v q="$q" '$2==q || $3==q')"
    if [[ -z "$match" ]]; then
        die "no image '$q' in ${scope:-aws or gcp} (try ./bin/sandbox list-images)"
    fi
    count="$(printf '%s\n' "$match" | grep -c .)"
    if [[ "$count" -gt 1 ]]; then
        provs="$(printf '%s\n' "$match" | awk -F'\t' '{print $1}' | tr '\n' ' ')"
        die "image '$q' exists in more than one cloud (${provs% }) — pick one with --cloud"
    fi
    printf '%s' "$match"
}

# mc_delete_image — read "provider<TAB>id" rows on stdin; delete each image via
# its cloud's driver (per-provider subshell). Logs a one-line summary per cloud.
mc_delete_image() {
    local input; input="$(cat)"
    [[ -z "$input" ]] && return 0
    local prov
    for prov in $_MC_CLOUDS; do
        local ids=() p i
        while IFS=$'\t' read -r p i; do
            [[ "$p" == "$prov" ]] || continue
            [[ -z "$i" ]] && continue
            ids+=("$i")
        done <<< "$input"
        [[ ${#ids[@]} -eq 0 ]] && continue
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            local one
            for one in "${ids[@]}"; do
                provider_delete_image "$one"
            done
            exit 0
        )
    done
}
