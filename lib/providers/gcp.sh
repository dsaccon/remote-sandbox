#!/usr/bin/env bash
# lib/providers/gcp.sh — GCP (GCE) driver. All gcloud calls go through
# $GCLOUD_CMD so tests can stub it.
if [[ -n "${_SANDBOX_GCP_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_GCP_SH_LOADED=1
_gcp_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../log.sh
source "$_gcp_sh_dir/../log.sh"

: "${GCLOUD_CMD:=gcloud}"
_gcloud() {
    : "${GCP_PROJECT:?_gcloud: GCP_PROJECT not set}"
    "$GCLOUD_CMD" --project "$GCP_PROJECT" "$@"
}

# gcp_validate_name NAME — enforce RFC1035 (GCE instance/firewall names).
gcp_validate_name() {
    local n="$1"
    [[ "$n" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
        || die "invalid --name '$n' for gcp: must be RFC1035 (lowercase, digits, hyphens; start with a letter; <=63 chars)"
}

provider_check_creds() {
    command -v "$GCLOUD_CMD" >/dev/null 2>&1 || die "gcloud not on PATH — install the Google Cloud SDK"
    [[ -n "${GCP_PROJECT:-}" ]] || die "GCP_PROJECT not set in ./config"
    if ! _gcloud compute images list --filter="name=nonexistent" >/dev/null 2>&1; then
        die "gcloud auth/project check failed — set GOOGLE_APPLICATION_CREDENTIALS and GCP_PROJECT"
    fi
}

provider_preflight() {
    provider_check_creds
    local pub="${GCP_SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
    [[ -r "$pub" ]] || die "SSH public key not readable: $pub (set GCP_SSH_PUBKEY)"
    if [[ -n "${GCP_IMAGE:-}" ]]; then
        _gcloud compute images describe "$GCP_IMAGE" >/dev/null 2>&1 \
            || die "GCP_IMAGE '$GCP_IMAGE' not found in project $GCP_PROJECT"
    fi
}

provider_build_image() {
    die "image baking not yet supported on gcp — bake out-of-band and set GCP_IMAGE (see docs)"
}
