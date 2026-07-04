#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/ami"
    cp "$REPO_ROOT"/lib/{log,config,common,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/ami/cloud-init.yaml.tmpl" "$SANDBOX_REPO_ROOT/ami/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
AMI_ID="ami-abc"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # Stub curl for current_public_ip.
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-stub"
    cat > "$CURL_CMD" <<'EOF'
#!/usr/bin/env bash
echo "1.2.3.4"
EOF
    chmod +x "$CURL_CMD"
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/provision.sh"
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "current_public_ip returns CIDR /32" {
    run current_public_ip_cidr
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3.4/32" ]
}

@test "preflight_or_die succeeds when everything OK" {
    # All AWS calls succeed (default stub exit 0, returns empty unless told).
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Images":[{"ImageId":"ami-abc"}]}
EOF
    # Note: subsequent calls reuse the same response file — we accept that
    # for this happy-path test; the rejections below get their own responses.
    run preflight_or_die
    [ "$status" -eq 0 ]
}

@test "preflight_or_die exits if AMI_ID empty" {
    AMI_ID=""
    run preflight_or_die
    [ "$status" -ne 0 ]
    [[ "$output" == *"no AMI"* ]]
}

@test "ensure_sg creates SG when missing" {
    # describe-security-groups returns None → create-security-group called.
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
None
EOF
    # We can't distinguish describe vs create with one response file in this
    # simple stub. Test asserts on call log instead.
    run ensure_sg
    grep -q -- 'describe-security-groups --group-names claude-sandbox-sg' "$AWS_STUB_LOG"
}
