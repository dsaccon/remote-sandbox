#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-scp" "$SANDBOX_REPO_ROOT/bin/"
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

    # scp stub: record argv so tests can assert on the upload command.
    export SCP_CMD="$BATS_TEST_TMPDIR/scp-stub"
    cat > "$SCP_CMD" <<'EOF'
#!/usr/bin/env bash
echo "SCP_CMD: $*"
EOF
    chmod +x "$SCP_CMD"

    # ssh stub: emulate the remote listing (`pwd` then `ls -1Ap`) used by the
    # interactive directory browser. Args are ignored.
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-stub"
    cat > "$SSH_CMD" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "/home/ubuntu" "projects/" "notes.txt"
EOF
    chmod +x "$SSH_CMD"

    # A real local source file to upload.
    SRC="$BATS_TEST_TMPDIR/payload.txt"
    echo "hello" > "$SRC"

    RUNNING_JSON='0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"1.2.3.4","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"box"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}'
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "scp with explicit dest resolves name → IP and execs scp src user@ip:dest" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box "$SRC" /home/ubuntu/code
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"$SRC ubuntu@1.2.3.4:/home/ubuntu/code"* ]]
}

@test "scp on a directory adds -r" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    mkdir "$BATS_TEST_TMPDIR/adir"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box "$BATS_TEST_TMPDIR/adir" /tmp
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"-r "*"adir ubuntu@1.2.3.4:/tmp"* ]]
}

@test "scp unknown name exits non-zero" {
    printf '%s\n' '0' '{"Reservations":[]}' > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" nope "$SRC" /tmp
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named nope"* ]]
}

@test "scp with missing local source errors before touching AWS" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box /no/such/file /tmp
    [ "$status" -ne 0 ]
    [[ "$output" == *"source path not found"* ]]
}

@test "scp missing args prints usage" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"sandbox scp <name>"* ]]
}

@test "scp --help describes the interactive arrow-key browser" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"arrow-key browser"* ]]
}

@test "scp <name> --help shows help (not 'source path not found')" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" != *"source path not found"* ]]
}

# The interactive browser reads single keypresses; tests pipe the raw bytes.
# The ssh stub always lists pwd=/home/ubuntu + one subdir, so the chosen dir
# resolves to /home/ubuntu regardless of how we navigate.

@test "scp no dest: Enter on '[ upload here ]' uploads into the current dir" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf '\r' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box '$SRC'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"$SRC ubuntu@1.2.3.4:/home/ubuntu"* ]]
}

@test "scp no dest: 'u' shortcut uploads into the current dir" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf 'u' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box '$SRC'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"$SRC ubuntu@1.2.3.4:/home/ubuntu"* ]]
}

@test "scp no dest: down-arrow then Enter descends, then 'u' uploads" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    # down (highlight the subdir) -> Enter (descend) -> u (upload here)
    run bash -c "printf '\033[B\ru' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box '$SRC'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/home/ubuntu"* ]]
}

@test "scp no dest: 'q' cancels" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf 'q' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box '$SRC'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"upload cancelled"* ]]
}

@test "scp no dest: unrecognised keys are ignored, then 'u' uploads" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf 'xZu' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box '$SRC'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/home/ubuntu"* ]]
}

# ---- download mode (-d / --download): sandbox -> local ----

@test "scp -d with explicit remote-src downloads into the cwd by default" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box -d /home/ubuntu/notes.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"ubuntu@1.2.3.4:/home/ubuntu/notes.txt ."* ]]
}

@test "scp --download with explicit remote-src and local-dest" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box --download /remote/f.txt /tmp/out
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/remote/f.txt /tmp/out"* ]]
}

@test "scp -d no remote-src: arrow-browse and pick a file (down, Enter)" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    # ssh stub lists projects/ (dir) then notes.txt (file); down selects the
    # file, Enter picks it. The remote path is passed verbatim (SFTP-literal).
    # No reply follows for the local-dest prompt, so stdin hits EOF there and
    # the default (cwd) holds.
    run bash -c "printf '\033[B\r' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"ubuntu@1.2.3.4:/home/ubuntu/notes.txt ."* ]]
}

@test "scp -d no remote-src: typing a local dest at the prompt overrides the default" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    # Same navigation as above (down, Enter picks notes.txt), then the
    # leftover "/tmp/custom\n" on stdin is read as the local-dest reply.
    run bash -c "printf '\033[B\r/tmp/custom\n' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"ubuntu@1.2.3.4:/home/ubuntu/notes.txt /tmp/custom"* ]]
}

@test "scp -d no remote-src: '~/path' typed at the prompt expands to \$HOME/path" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    # read (unlike a typed command line) does not expand ~, so the script must
    # expand it itself before handing the path to scp.
    run bash -c "printf '\033[B\r~/Downloads\n' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"ubuntu@1.2.3.4:/home/ubuntu/notes.txt $HOME/Downloads"* ]]
}

@test "scp -d no remote-src: bare '~' typed at the prompt expands to \$HOME" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf '\033[B\r~\n' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCP_CMD: "*"ubuntu@1.2.3.4:/home/ubuntu/notes.txt $HOME"* ]]
}

@test "scp -d: Enter on a directory descends rather than picking it" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    # Enter on row 0 (projects/, a dir) descends; the stub re-lists the same
    # entries, so a second down+Enter then picks the file.
    run bash -c "printf '\r\033[B\r' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/home/ubuntu/notes.txt"* ]]
}

@test "scp -d: 'q' cancels the download" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf 'q' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d"
    [ "$status" -ne 0 ]
    [[ "$output" == *"download cancelled"* ]]
}

@test "scp -d with no name prints usage" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" -d
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "scp --help documents download mode" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"download"* ]]
}

@test "scp -d -o sets the local destination in interactive mode" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run bash -c "printf '\033[B\r' | '$SANDBOX_REPO_ROOT/bin/sandbox-scp' box -d -o /tmp/dl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/home/ubuntu/notes.txt /tmp/dl"* ]]
}

@test "scp -d --output= form sets the local destination" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box -d /remote/f.png --output=/tmp/out
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu@1.2.3.4:/remote/f.png /tmp/out"* ]]
}

@test "scp -o without -d is rejected" {
    printf '%s\n' "$RUNNING_JSON" > "$AWS_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box "$SRC" -o /tmp
    [ "$status" -ne 0 ]
    [[ "$output" == *"only valid with -d"* ]]
}

@test "scp -d -o with no value errors" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-scp" box -d -o
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a directory"* ]]
}
