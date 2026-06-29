#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-list" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "list prints header and one row per instance" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","PublicIpAddress":"1.2.3.4",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"sandbox-abc"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"sandbox-abc"* ]]
    # State.Name is "running" but the stub returns no instance-status data, so
    # compute_display_state reports "initializing" (status checks not yet seen).
    [[ "$output" == *"initializing"* ]]
    [[ "$output" == *"m7i-flex.xlarge"* ]]
    [[ "$output" == *"1.2.3.4"* ]]
}

@test "list prints empty message when nothing found" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no sandboxes"* ]]
}

@test "list shows spot vs on-demand in a MARKET column" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-spot","InstanceType":"m7i-flex.xlarge","InstanceLifecycle":"spot",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"alpha-box"},{"Key":"Project","Value":"claude-sandbox"}]},
  {"InstanceId":"i-od","InstanceType":"m7i-flex.xlarge",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"beta-box"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKET"* ]]
    echo "$output" | grep alpha-box | grep -q -w spot
    echo "$output" | grep beta-box  | grep -q on-demand
}
