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

@test "ssh routes through 'cmux ssh' when cmux is installed and reachable" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    unset SSH_CMD
    export CMUX_CMD="$BATS_TEST_TMPDIR/cmux-stub"
    cat > "$CMUX_CMD" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ping" ]] && exit 0
echo "CMUX_CMD: $*"
EOF
    chmod +x "$CMUX_CMD"

    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"CMUX_CMD: ssh ubuntu@5.6.7.8"* ]]
}

@test "ssh falls back to plain ssh when cmux is installed but its app isn't reachable" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    unset SSH_CMD
    stub_dir="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/ssh" <<'EOF'
#!/usr/bin/env bash
echo "SSH_CMD: $*"
EOF
    chmod +x "$stub_dir/ssh"
    export PATH="$stub_dir:$PATH"

    export CMUX_CMD="$BATS_TEST_TMPDIR/cmux-stub"
    cat > "$CMUX_CMD" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$CMUX_CMD"

    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH_CMD: ubuntu@5.6.7.8"* ]]
}

@test "ssh skips cmux entirely when SSH_USE_CMUX=false, even if cmux is reachable" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    echo 'SSH_USE_CMUX="false"' >> "$SANDBOX_REPO_ROOT/config"
    unset SSH_CMD
    stub_dir="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/ssh" <<'EOF'
#!/usr/bin/env bash
echo "SSH_CMD: $*"
EOF
    chmod +x "$stub_dir/ssh"
    export PATH="$stub_dir:$PATH"

    export CMUX_CMD="$BATS_TEST_TMPDIR/cmux-stub"
    cat > "$CMUX_CMD" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ping" ]] && exit 0
echo "CMUX_CMD: $*"
EOF
    chmod +x "$CMUX_CMD"

    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH_CMD: ubuntu@5.6.7.8"* ]]
    [[ "$output" != *"CMUX_CMD:"* ]]
}
