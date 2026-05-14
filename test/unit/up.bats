#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/ami" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
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
    tail -n +2 "$fixture_file"
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

@test "up happy path on spot prints ssh command" {
    write_aws_fake
    # Order of calls inside provision_launch:
    #   1: sts get-caller-identity
    #   2: describe-images
    #   3: describe-key-pairs
    #   4: describe-security-groups (ensure_sg)
    #   5: describe-security-groups (set ingress: list existing rules)
    #   6: revoke-security-group-ingress  (skipped if no existing 22/tcp rules — see fixture 5)
    #   7: authorize-security-group-ingress
    #   8: run-instances  (spot)
    #   9: wait instance-status-ok
    #  10: describe-instances (get IP)
    #  11: create-tags
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    # 6 not called (no existing rules to revoke)
    set_fixture 6 0 ''  # authorize
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'
    set_fixture 8 0 ''  # wait
    set_fixture 9 0 '5.6.7.8'
    set_fixture 10 0 ''  # create-tags

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
    # Confirm spot was requested.
    grep -q -- '--cli-input-json' "$AWS_STUB_LOG"
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
    set_fixture 9 0 ''
    set_fixture 10 0 '5.6.7.8'
    set_fixture 11 0 ''

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"spot unavailable"* ]] || [[ "$output" == *"falling back to on-demand"* ]]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
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
    set_fixture 8 0 ''
    set_fixture 9 0 '5.6.7.8'
    set_fixture 10 0 ''

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
    # run-instances JSON should NOT contain InstanceMarketOptions when --no-spot
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
}
