#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-delete-image" "$SANDBOX_REPO_ROOT/bin/"
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

@test "delete-image refuses the current image without --force" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-delete-image" ami-current
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to delete"* ]]
    ! grep -q -- 'deregister-image' "$AWS_STUB_LOG"
}

@test "delete-image on an unknown id exits non-zero" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-delete-image" ami-nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no image 'ami-nope'"* ]]
}

@test "delete-image deregisters an aws AMI (and touches no gcp)" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-delete-image" ami-old
    [ "$status" -eq 0 ]
    grep -q -- 'deregister-image --image-id ami-old' "$AWS_STUB_LOG"
    ! grep -q -- 'images delete' "$GCLOUD_STUB_LOG"
}

@test "delete-image deletes a gcp image by name" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-delete-image" claude-sandbox-prev
    [ "$status" -eq 0 ]
    grep -q -- 'images delete claude-sandbox-prev' "$GCLOUD_STUB_LOG"
    ! grep -q -- 'deregister-image' "$AWS_STUB_LOG"
}

@test "delete-image --force deletes the current image" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-delete-image" ami-current --force
    [ "$status" -eq 0 ]
    grep -q -- 'deregister-image --image-id ami-current' "$AWS_STUB_LOG"
}
