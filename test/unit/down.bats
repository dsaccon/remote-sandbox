#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-down" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
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
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --all
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-new i-old' "$AWS_STUB_LOG" \
        || grep -q -- 'terminate-instances --instance-ids i-old i-new' "$AWS_STUB_LOG"
}

@test "down --stale 24h terminates only old ones" {
    # Compare against now; pick a comfortably-old time so the test is stable.
    fixture_two_boxes "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "2020-01-01T00:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --stale 24h
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-old' "$AWS_STUB_LOG"
    ! grep -q -- 'i-new' "$AWS_STUB_LOG" | grep -q terminate
}
