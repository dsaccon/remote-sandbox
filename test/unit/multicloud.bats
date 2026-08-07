#!/usr/bin/env bats
#
# provider_list_all's skip reporting: a cloud you never set up stays silent, a
# cloud that is set up but failing says why, and neither can stall the command
# forever. Exercised through bin/sandbox-list, which is the visible surface.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,identity,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-list" "$SANDBOX_REPO_ROOT/bin/"

    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = tester@example.com\n' > "$CLOUDSDK_CONFIG/configurations/config_default"

    # One healthy AWS box, so every test can assert the good cloud survives
    # whatever the other one is doing.
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"2026-08-01T00:00:00Z",
   "Tags":[{"Key":"Name","Value":"aws-box"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

with_gcp() {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
EOF
}

# fake_gcloud NAME BODY — an executable stub on $GCLOUD_CMD.
fake_gcloud() {
    local path="$BATS_TEST_TMPDIR/$1"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$path"
    chmod +x "$path"
    printf '%s' "$path"
}

@test "a cloud that was never configured is skipped silently" {
    printf 'AWS_REGION="us-west-2"\n' > "$SANDBOX_REPO_ROOT/config"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aws-box"* ]]
    # No GCP_PROJECT means nothing to query — warning here would nag an
    # AWS-only user on every single command.
    ! ( echo "$output" | grep -qi "warn.*gcp" )
}

@test "a configured but broken cloud reports the CLI's own error" {
    with_gcp
    GCLOUD_CMD="$(fake_gcloud gcloud-fail 'echo "Reauthentication required." >&2; exit 1')"
    export GCLOUD_CMD
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    # The real cause, not a guess. This exact string was being discarded.
    [[ "$output" == *"Reauthentication required."* ]]
    [[ "$output" == *"gcp skipped"* ]]
}

@test "a broken cloud does not suppress the healthy one's rows" {
    with_gcp
    GCLOUD_CMD="$(fake_gcloud gcloud-fail2 'echo "boom" >&2; exit 1')"
    export GCLOUD_CMD
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aws-box"* ]]
}

@test "a stalled cloud is abandoned at SANDBOX_CLOUD_TIMEOUT" {
    with_gcp
    GCLOUD_CMD="$(fake_gcloud gcloud-hang 'sleep 60')"
    export GCLOUD_CMD SANDBOX_CLOUD_TIMEOUT=2
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no response within 2s"* ]]
    [[ "$output" == *"aws-box"* ]]
}

@test "a healthy cloud produces no warning" {
    with_gcp
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[]
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aws-box"* ]]
    ! ( echo "$output" | grep -qi "warn" )
}
