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

@test "provider_launch creates a per-sandbox firewall rule and an instance" {
    set_response 0 ''    # gcloud calls succeed, empty output
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=0
    run provider_launch sandbox-abc "" false "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'compute firewall-rules create sandbox-abc-fw' "$GCLOUD_STUB_LOG"
    grep -q -- 'source-ranges=1.2.3.4/32' "$GCLOUD_STUB_LOG"
    grep -q -- 'target-tags=sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances create sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'labels=project=claude-sandbox,name=sandbox-abc' "$GCLOUD_STUB_LOG"
}

@test "provider_launch adds spot + max-run-duration flags when requested" {
    set_response 0 ''
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=8
    run provider_launch sandbox-abc "" true "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'provisioning-model=SPOT' "$GCLOUD_STUB_LOG"
    grep -q -- 'max-run-duration=8h' "$GCLOUD_STUB_LOG"
    grep -q -- 'instance-termination-action=DELETE' "$GCLOUD_STUB_LOG"
}

@test "provider_list emits a normalized row" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-abc","status":"RUNNING","machineType":"https://.../machineTypes/e2-standard-4",
  "creationTimestamp":"2026-07-03T10:00:00.000-07:00",
  "scheduling":{"provisioningModel":"SPOT"},
  "networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}],
  "metadata":{"items":[{"key":"auto-shutdown-hours","value":"8"}]},
  "tags":{"items":["sandbox-abc"]}}]
EOF
    run provider_list
    [ "$status" -eq 0 ]
    # handle name state type market ... ip ... ash
    [[ "$output" == *"sandbox-abc"*"ready"*"e2-standard-4"*"spot"*"5.6.7.8"*"8"* ]]
}

@test "provider_resolve_ip returns the natIP for a RUNNING box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
{"status":"RUNNING","networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -eq 0 ]
    [ "$output" = "5.6.7.8" ]
}
@test "provider_resolve_ip dies for a booting box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
{"status":"PROVISIONING","networkInterfaces":[{"accessConfigs":[{}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"booting"* ]]
}
@test "provider_terminate_ids deletes by name+zone" {
    set_response 0 ''
    run provider_terminate_ids sandbox-abc
    [ "$status" -eq 0 ]
    grep -q -- 'compute instances delete sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'zone=us-west1-b' "$GCLOUD_STUB_LOG"
}
