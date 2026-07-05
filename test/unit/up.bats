#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/ami" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,common,provider,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/lib/providers/aws.sh" "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/ami/cloud-init.yaml.tmpl" "$SANDBOX_REPO_ROOT/ami/"
    cp "$REPO_ROOT/bin/sandbox-up" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
INSTANCE_TYPE="m7i-flex.xlarge"
USE_SPOT="true"
SPOT_FALLBACK_ON_DEMAND="true"
AMI_ID="ami-abc"
AUTO_SHUTDOWN_HOURS="8"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_CMD="$BATS_TEST_TMPDIR/aws-fake"
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-stub"
    cat > "$CURL_CMD" <<'EOF'
#!/usr/bin/env bash
echo "1.2.3.4"
EOF
    chmod +x "$CURL_CMD"
    # Stub ssh so provision_launch's SSH-readiness check succeeds immediately.
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-ok"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_CMD"
    chmod +x "$SSH_CMD"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

# write_aws_fake takes a sequence of fixture stanzas — one per AWS call,
# each "rc::stdout". The stub uses a counter to pick which one.
write_aws_fake() {
    cat > "$AWS_CMD" <<'OUTER'
#!/usr/bin/env bash
set -e
counter_file="$AWS_FAKE_COUNTER"
n="$(cat "$counter_file" 2>/dev/null || echo 0)"
echo "$((n+1))" > "$counter_file"
echo "CALL[$((n+1))]: $*" >> "$AWS_STUB_LOG"
fixture_file="$AWS_FAKE_FIXTURES/$((n+1))"
if [[ -f "$fixture_file" ]]; then
    rc="$(head -n1 "$fixture_file")"
    # Real `aws` writes API errors to stderr, not stdout. The fallback path in
    # provision.sh greps the captured stderr for "InsufficientInstanceCapacity",
    # so error fixtures (rc != 0) must go to stderr to be seen.
    if [[ "$rc" -eq 0 ]]; then
        tail -n +2 "$fixture_file"
    else
        tail -n +2 "$fixture_file" >&2
    fi
    exit "$rc"
fi
exit 0
OUTER
    chmod +x "$AWS_CMD"
    export AWS_FAKE_COUNTER="$BATS_TEST_TMPDIR/counter"
    : > "$AWS_FAKE_COUNTER"
    export AWS_FAKE_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$AWS_FAKE_FIXTURES"
}

set_fixture() {
    local n="$1" rc="$2"
    shift 2
    { echo "$rc"; printf '%s' "$*"; } > "$AWS_FAKE_FIXTURES/$n"
}

@test "up happy path on spot prints instance id and is non-blocking" {
    write_aws_fake
    # With up now non-blocking, calls stop after run-instances:
    #   1: sts get-caller-identity
    #   2: describe-images
    #   3: describe-key-pairs
    #   4: describe-security-groups (ensure_sg)
    #   5: describe-security-groups (set ingress: list existing rules)
    #   6: authorize-security-group-ingress (no existing rules to revoke)
    #   7: run-instances (spot) → InstanceId
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''  # authorize
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"i-xyz"* ]]
    [[ "$output" == *"launching"* ]]
    # No more SSH command in the output — that comes via sandbox list/ssh.
    [[ "$output" != *"ssh ubuntu@"* ]]
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
    grep -q -- '--cli-input-json' "$AWS_STUB_LOG"
    # No wait-status-ok or describe-instances for IP should have been made.
    ! grep -q -- 'ec2 wait instance-status-ok' "$AWS_STUB_LOG"
}

@test "up falls back to on-demand on InsufficientInstanceCapacity" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    # 7: spot run-instances fails with capacity error
    set_fixture 7 255 'An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation'
    # 8: on-demand retry succeeds
    set_fixture 8 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"spot unavailable"* ]] || [[ "$output" == *"falling back to on-demand"* ]]
    [[ "$output" == *"i-xyz"* ]]
}

@test "up with --no-spot skips spot, goes straight to on-demand" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot
    [ "$status" -eq 0 ]
    [[ "$output" == *"i-xyz"* ]]
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
}

@test "up --spot forces spot even when config USE_SPOT=false" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
INSTANCE_TYPE="m7i-flex.xlarge"
USE_SPOT="false"
SPOT_FALLBACK_ON_DEMAND="true"
AMI_ID="ami-abc"
AUTO_SHUTDOWN_HOURS="0"
EOF
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --spot
    [ "$status" -eq 0 ]
    [[ "$output" == *"requesting spot instance"* ]]
    [[ "$output" == *"i-xyz"* ]]
}

@test "up --no-spot forces on-demand even when config USE_SPOT=true" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot
    [ "$status" -eq 0 ]
    [[ "$output" == *"requesting on-demand instance"* ]]
    [[ "$output" == *"i-xyz"* ]]
}

@test "up with both --spot and --no-spot errors" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --spot --no-spot
    [ "$status" -ne 0 ]
    [[ "$output" == *"conflicting --spot/--no-spot"* ]]
}

@test "up --help lists both --spot and --no-spot" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--spot"* ]]
    [[ "$output" == *"--no-spot"* ]]
}

@test "up with both --no-spot and --spot (reverse order) errors" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot --spot
    [ "$status" -ne 0 ]
    [[ "$output" == *"conflicting --spot/--no-spot"* ]]
}

@test "up under CLOUD=gcp rejects a non-RFC1035 --name before any launch" {
    cp "$REPO_ROOT/lib/providers/gcp.sh" "$SANDBOX_REPO_ROOT/lib/providers/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
CLOUD="gcp"
GCP_PROJECT="p"
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
INSTANCE_TYPE="m7i-flex.xlarge"
USE_SPOT="true"
SPOT_FALLBACK_ON_DEMAND="true"
AMI_ID="ami-abc"
AUTO_SHUTDOWN_HOURS="0"
EOF
    write_aws_fake

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --name Bad_Name
    [ "$status" -ne 0 ]
    [[ "$output" == *"RFC1035"* ]]
    # Rejected before any preflight/launch call — the aws stub's log (used as
    # a stand-in for "any provider call happened") stays empty.
    [ ! -s "$AWS_STUB_LOG" ]
}

@test "up --cloud overrides the config CLOUD launch target" {
    cp "$REPO_ROOT/lib/providers/gcp.sh" "$SANDBOX_REPO_ROOT/lib/providers/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
CLOUD="gcp"
GCP_PROJECT="p"
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
INSTANCE_TYPE="m7i-flex.xlarge"
USE_SPOT="true"
SPOT_FALLBACK_ON_DEMAND="true"
AMI_ID="ami-abc"
AUTO_SHUTDOWN_HOURS="0"
EOF
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'

    # config says gcp, but --cloud aws wins → the AWS launch path runs.
    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --cloud aws
    [ "$status" -eq 0 ]
    [[ "$output" == *"i-xyz"* ]]
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
}

# A launch that fails must surface an error and non-zero exit, not silently
# die (the old `read -r id < <(provider_launch)` swallowed failures as EOF).
@test "up surfaces a launch failure instead of exiting silently" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    # 7: on-demand run-instances fails with a non-capacity error (no fallback).
    set_fixture 7 255 'An error occurred (UnauthorizedOperation) when calling RunInstances'

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" != *"launching"* ]]
}
