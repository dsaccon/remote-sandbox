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
provider_list_all() {
    local scope="${1:-}" prov
    for prov in $_MC_CLOUDS; do
        [[ -n "$scope" && "$scope" != "$prov" ]] && continue
        (
            set +e
            CLOUD="$prov"
            provider_load 2>/dev/null || exit 0
            ( provider_check_creds ) >/dev/null 2>&1 || exit 0
            provider_list 2>/dev/null | while IFS= read -r row; do
                [ -n "$row" ] && printf '%s\t%s\n' "$prov" "$row"
            done
            exit 0
        )
    done
    return 0
}

# mc_find NAME [SCOPE] — print the single matching record (10-field row) for the
# box whose name OR handle == NAME across the in-scope clouds. die on no match or
# on an ambiguous match (same name in >1 cloud). Used by ssh/scp/down.
mc_find() {
    local name="$1" scope="${2:-}" rows match count provs
    rows="$(provider_list_all "$scope")"
    match="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$3==n || $2==n')"
    if [[ -z "$match" ]]; then
        die "no sandbox named $name in ${scope:-aws or gcp} (try ./bin/sandbox list)"
    fi
    count="$(printf '%s\n' "$match" | grep -c .)"
    if [[ "$count" -gt 1 ]]; then
        provs="$(printf '%s\n' "$match" | awk -F'\t' '{print $1}' | tr '\n' ' ')"
        die "sandbox $name exists in more than one cloud (${provs% }) — pick one with --cloud"
    fi
    printf '%s' "$match"
}

# mc_resolve_ip NAME [SCOPE] — resolve a running box NAME to its public IP across
# clouds, with the same state-aware errors ssh/scp had per-cloud.
mc_resolve_ip() {
    local match provider handle name state type market epoch ip cidr ash
    match="$(mc_find "$1" "${2:-}")" || return 1
    IFS=$'\t' read -r provider handle name state type market epoch ip cidr ash <<< "$match"
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
