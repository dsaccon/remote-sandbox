#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-ssh" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_USER="ubuntu"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-stub"
    cat > "$SSH_CMD" <<'EOF'
#!/usr/bin/env bash
echo "SSH_CMD: $*"
EOF
    chmod +x "$SSH_CMD"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "ssh resolves name → IP and execs ssh user@ip" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH_CMD: ubuntu@5.6.7.8"* ]]
}

@test "ssh unknown name exits non-zero" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named nope"* ]]
}
