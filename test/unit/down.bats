#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-down" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

fixture_two_boxes() {
    local now_iso="$1"
    local old_iso="$2"
    cat > "$AWS_STUB_RESPONSE" <<EOF
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-new","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"$now_iso",
   "Tags":[{"Key":"Name","Value":"sandbox-new"},{"Key":"Project","Value":"claude-sandbox"},
           {"Key":"CreatedAt","Value":"$now_iso"}]},
  {"InstanceId":"i-old","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"$old_iso",
   "Tags":[{"Key":"Name","Value":"sandbox-old"},{"Key":"Project","Value":"claude-sandbox"},
           {"Key":"CreatedAt","Value":"$old_iso"}]}
]}]}
EOF
}

@test "down by name terminates matching instance" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" sandbox-new
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-new' "$AWS_STUB_LOG"
    ! grep -q -- 'terminate-instances --instance-ids i-old' "$AWS_STUB_LOG"
}

@test "down unknown name exits non-zero" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" sandbox-missing
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named sandbox-missing"* ]]
}

@test "down --all terminates every Project=claude-sandbox instance" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --all --yes
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-new i-old' "$AWS_STUB_LOG" \
        || grep -q -- 'terminate-instances --instance-ids i-old i-new' "$AWS_STUB_LOG"
}

@test "down --all without --yes and a declined prompt terminates nothing" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run bash -c "printf 'n\n' | '$SANDBOX_REPO_ROOT/bin/sandbox-down' --all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be TERMINATED"* ]]
    ! grep -q -- 'terminate-instances' "$AWS_STUB_LOG"
}

@test "down --stale 24h terminates only old ones" {
    # Compare against now; pick a comfortably-old time so the test is stable.
    fixture_two_boxes "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "2020-01-01T00:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --stale 24h --yes
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-old' "$AWS_STUB_LOG"
    ! grep -q -- 'i-new' "$AWS_STUB_LOG" | grep -q terminate
}

@test "down --all --yes terminates across BOTH clouds" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
EOF
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-gcp","status":"RUNNING","machineType":"z/e2","creationTimestamp":"2026-05-12T10:00:00.000-07:00","scheduling":{"provisioningModel":"STANDARD"},"networkInterfaces":[{"accessConfigs":[{"natIP":"9.9.9.9"}]}],"metadata":{"items":[]},"tags":{"items":["sandbox-gcp"]}}]
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --all --yes
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances' "$AWS_STUB_LOG"
    grep -q -- 'instances delete sandbox-gcp' "$GCLOUD_STUB_LOG"
}
