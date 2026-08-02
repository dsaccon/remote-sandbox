#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,identity,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-ssh" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_USER="ubuntu"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    # Deterministic owner identity: the gcp driver scopes sandboxes to the
    # active gcloud account. Point it at a fixture, never the real
    # ~/.config/gcloud, and never the gcloud stub (its canned response is
    # instance JSON, which would sanitize to a >63-char label and die).
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = tester@example.com\n' > "$CLOUDSDK_CONFIG/configurations/config_default"
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

@test "ssh finds a box in gcp across clouds (no CLOUD needed)" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
SSH_USER="ubuntu"
EOF
    printf '0\n{"Reservations":[]}\n' > "$AWS_STUB_RESPONSE"
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-gcp","status":"RUNNING","machineType":"z/e2","creationTimestamp":"2026-07-05T00:00:00.000-07:00","scheduling":{"provisioningModel":"STANDARD"},"networkInterfaces":[{"accessConfigs":[{"natIP":"9.9.9.9"}]}],"metadata":{"items":[]},"tags":{"items":["sandbox-gcp"]}}]
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-gcp
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH_CMD: ubuntu@9.9.9.9"* ]]
}

@test "ssh --ports forwards each port with -L" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x --ports 16006 18000 13100
    [ "$status" -eq 0 ]
    [[ "$output" == *"-L 16006:localhost:16006"* ]]
    [[ "$output" == *"-L 18000:localhost:18000"* ]]
    [[ "$output" == *"-L 13100:localhost:13100"* ]]
    [[ "$output" == *"SSH_CMD: "*"ubuntu@5.6.7.8"* ]]
}

@test "ssh --ports rejects an out-of-range port before connecting" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x --ports 70000
    [ "$status" -ne 0 ]
    [[ "$output" == *"1-65535"* ]]
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
