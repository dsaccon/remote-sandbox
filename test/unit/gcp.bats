#!/usr/bin/env bats
# test/unit/gcp.bats — GCP driver skeleton: seam, preflight, name validation.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    source "$REPO_ROOT/lib/providers/gcp.sh"
    GCP_PROJECT="proj"; GCP_ZONE="us-west1-b"; SSH_USER="ubuntu"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "gcp_validate_name accepts RFC1035 names" {
    run gcp_validate_name sandbox-26bdd2af
    [ "$status" -eq 0 ]
}
@test "gcp_validate_name rejects uppercase/underscore" {
    run gcp_validate_name My_Box
    [ "$status" -ne 0 ]
    [[ "$output" == *"RFC1035"* ]]
}
@test "provider_preflight dies when GCP_PROJECT empty" {
    GCP_PROJECT=""
    run provider_preflight
    [ "$status" -ne 0 ]
    [[ "$output" == *"GCP_PROJECT"* ]]
}
@test "provider_build_image is unsupported on gcp" {
    run provider_build_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"not yet supported"* ]]
}
