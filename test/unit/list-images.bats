#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,identity,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-list-images" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
AMI_ID="ami-current"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
GCP_IMAGE="claude-sandbox-cur"
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

    # Two AMIs (one current) and two gcp images (one current).
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Images":[
  {"ImageId":"ami-current","Name":"claude-sandbox-A","CreationDate":"2026-06-30T15:59:07.000Z",
   "BlockDeviceMappings":[{"Ebs":{"VolumeSize":30,"SnapshotId":"snap-a"}}]},
  {"ImageId":"ami-old","Name":"claude-sandbox-B","CreationDate":"2026-06-29T23:08:11.000Z",
   "BlockDeviceMappings":[{"Ebs":{"VolumeSize":30,"SnapshotId":"snap-b"}}]}
]}
EOF
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"claude-sandbox-cur","creationTimestamp":"2026-06-01T12:00:00.000-07:00","diskSizeGb":"10","family":"claude-sandbox"},
 {"name":"claude-sandbox-prev","creationTimestamp":"2026-05-20T12:00:00.000-07:00","diskSizeGb":"10","family":"claude-sandbox"}]
EOF
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

# slow_stub NAME MARKER REAL SECS — a CLI stub that sleeps SECS on its FIRST call
# (guarded by MARKER), then execs the real stub. One sleep per cloud regardless
# of how many times the driver calls the CLI. Prints the stub path.
slow_stub() {
    local path="$BATS_TEST_TMPDIR/$1" marker="$BATS_TEST_TMPDIR/$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
if [ ! -e "$marker" ]; then : > "$marker"; sleep $4; fi
exec "$3" "\$@"
EOF
    chmod +x "$path"
    printf '%s' "$path"
}

@test "list-images shows AMIs and gcp images with PROVIDER + CURRENT" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list-images"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROVIDER"* ]]
    echo "$output" | grep ami-current   | grep -q -w aws
    echo "$output" | grep claude-sandbox-cur | grep -q -w gcp
    # CURRENT marker on the two config images, not on the others.
    echo "$output" | grep ami-current   | grep -q -w yes
    echo "$output" | grep claude-sandbox-cur | grep -q -w yes
    ! ( echo "$output" | grep ami-old | grep -q -w yes )
}

@test "list-images --cloud gcp shows only gcp images" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list-images" --cloud gcp
    [ "$status" -eq 0 ]
    echo "$output" | grep -q claude-sandbox-cur
    ! ( echo "$output" | grep -q ami-current )
}

@test "list-images --active shows only in-use images" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list-images" --active
    [ "$status" -eq 0 ]
    # in use = the current config images (no running instances in the stub)
    echo "$output" | grep -q ami-current
    echo "$output" | grep -q claude-sandbox-cur
    ! ( echo "$output" | grep -q ami-old )
    ! ( echo "$output" | grep -q claude-sandbox-prev )
}

@test "list-images prints an empty message when nothing found" {
    printf '0\n{"Images":[]}\n' > "$AWS_STUB_RESPONSE"
    printf '0\n[]\n' > "$GCLOUD_STUB_RESPONSE"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list-images"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no claude-sandbox images"* ]]
}

@test "both clouds are queried concurrently for images, not one after another" {
    # Each cloud's CLI sleeps 3s once. Sequential querying costs ~6s; launching
    # both at once costs ~3s. Assert under 5s — above one sleep plus overhead,
    # below the sequential sum. Guards against regressing to serial querying.
    AWS_CMD="$(slow_stub slow-aws aws-slept "$REPO_ROOT/test/unit/stubs/aws-empty" 3)"
    GCLOUD_CMD="$(slow_stub slow-gcloud gcloud-slept "$REPO_ROOT/test/unit/stubs/gcloud-empty" 3)"
    export AWS_CMD GCLOUD_CMD

    local start end
    start="$(date +%s)"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list-images"
    end="$(date +%s)"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q ami-current
    echo "$output" | grep -q claude-sandbox-cur
    (( end - start < 5 ))
}
