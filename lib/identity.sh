#!/usr/bin/env bash
# lib/identity.sh — who is running this command, for owner-scoping GCP
# resources. Identity is gcloud's ACTIVE ACCOUNT, read from gcloud's own config
# files so the hot path (tab completion) never spawns gcloud.
#
# NB: these functions die() on failure, and die() calls exit. Callers that must
# not exit — anything running in the user's interactive shell, i.e. tab
# completion — have to invoke them inside a subshell. See completion/sandbox.sh.
#
# Source, don't execute. Idempotent.

if [[ -n "${_SANDBOX_IDENTITY_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_IDENTITY_SH_LOADED=1

_identity_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_identity_sh_dir/log.sh"

: "${GCLOUD_CMD:=gcloud}"

# sandbox_owner_email — gcloud's active account, e.g. david@synesis.one.
#
# Fast path reads gcloud's config files directly (two small reads, no process
# spawn). Falls back to `gcloud config get-value account` if that layout ever
# changes — correct but ~1-2s, which is why it isn't the default.
sandbox_owner_email() {
    local root name file email=""

    root="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
    name="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}"
    if [[ -z "$name" && -r "$root/active_config" ]]; then
        name="$(tr -d '[:space:]' < "$root/active_config")"
    fi
    [[ -z "$name" ]] && name="default"

    file="$root/configurations/config_$name"
    if [[ -r "$file" ]]; then
        # INI-style. Only [core].account counts — track the current section
        # rather than grabbing any line that happens to say "account =".
        email="$(awk '
            /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section); next }
            section == "core" && /^[[:space:]]*account[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, "");
                print; exit
            }' "$file")"
    fi

    if [[ -z "$email" ]]; then
        email="$("$GCLOUD_CMD" config get-value account 2>/dev/null | tr -d '[:space:]')"
    fi

    [[ -n "$email" && "$email" != "(unset)" ]] \
        || die "cannot determine your gcloud account — run 'gcloud auth login'"

    printf '%s' "$email"
}

# sandbox_owner_label — GCP-label-safe form of the full email, e.g.
# david-synesis-one. Label values allow only [a-z0-9_-], max 63 chars.
#
# Uses the FULL email, not the local part: first.last@corp.com and
# first-last@corp.com both reduce to first-last, and a label collision would
# silently show two people each other's boxes.
sandbox_owner_label() {
    local email label
    email="$(sandbox_owner_email)" || return 1
    label="$(printf '%s' "$email" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9_-]/-/g')"
    [[ "${#label}" -le 63 ]] \
        || die "owner label for '$email' exceeds the 63-char GCP label limit"
    printf '%s' "$label"
}
