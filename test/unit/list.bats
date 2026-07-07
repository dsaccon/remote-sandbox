#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,common,provider,multicloud,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-list" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # GCP stub — hermetic. The default config leaves GCP_PROJECT unset, so the
    # cross-cloud lister skips gcp; tests that want a gcp row set GCP_PROJECT +
    # GCLOUD_STUB_RESPONSE themselves.
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "list prints header and one row per instance" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","PublicIpAddress":"1.2.3.4",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"sandbox-abc"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"sandbox-abc"* ]]
    # State.Name is "running" but the stub returns no instance-status data, so
    # compute_display_state reports "initializing" (status checks not yet seen).
    [[ "$output" == *"initializing"* ]]
    [[ "$output" == *"m7i-flex.xlarge"* ]]
    [[ "$output" == *"1.2.3.4"* ]]
}

@test "list prints empty message when nothing found" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no sandboxes"* ]]
}

@test "list shows spot vs on-demand in a MARKET column" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-spot","InstanceType":"m7i-flex.xlarge","InstanceLifecycle":"spot",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"alpha-box"},{"Key":"Project","Value":"claude-sandbox"}]},
  {"InstanceId":"i-od","InstanceType":"m7i-flex.xlarge",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"beta-box"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKET"* ]]
    echo "$output" | grep alpha-box | grep -q -w spot
    echo "$output" | grep beta-box  | grep -q on-demand
}

@test "list shows sandboxes from both aws and gcp with a PROVIDER column" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
EOF
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","PublicIpAddress":"1.2.3.4",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"sandbox-aws"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-gcp","status":"RUNNING","machineType":"https://www.googleapis.com/compute/v1/projects/proj/zones/us-west1-b/machineTypes/e2-standard-4","creationTimestamp":"2026-05-12T10:00:00.000-07:00","scheduling":{"provisioningModel":"STANDARD"},"networkInterfaces":[{"accessConfigs":[{"natIP":"9.9.9.9"}]}],"metadata":{"items":[]},"tags":{"items":["sandbox-gcp"]}}]
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROVIDER"* ]]
    # each box tagged with its cloud
    echo "$output" | grep sandbox-aws | grep -q -w aws
    echo "$output" | grep sandbox-gcp | grep -q -w gcp
    [[ "$output" == *"1.2.3.4"* ]]
    [[ "$output" == *"9.9.9.9"* ]]
}

@test "list shows a DISK column with each box's root disk size" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
EOF
    # Hybrid AWS response: describe-instances/-status/-security-groups/-volumes
    # each read their own key from the one stub reply.
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-a","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"2026-07-05T00:00:00Z","RootDeviceName":"/dev/sda1",
   "BlockDeviceMappings":[{"DeviceName":"/dev/sda1","Ebs":{"VolumeId":"vol-1"}}],
   "Tags":[{"Key":"Name","Value":"sandbox-aws"},{"Key":"Project","Value":"claude-sandbox"}]}
]}],"InstanceStatuses":[],"SecurityGroups":[],"Volumes":[{"VolumeId":"vol-1","Size":64}]}
EOF
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-gcp","status":"RUNNING","machineType":"z/e2-standard-4","creationTimestamp":"2026-07-05T00:00:00.000-07:00","scheduling":{"provisioningModel":"STANDARD"},"networkInterfaces":[{"accessConfigs":[{"natIP":"9.9.9.9"}]}],"metadata":{"items":[]},"tags":{"items":["sandbox-gcp"]},"disks":[{"diskSizeGb":"128"}]}]
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISK"* ]]
    echo "$output" | grep sandbox-aws | grep -q -w 64G
    echo "$output" | grep sandbox-gcp | grep -q -w 128G
}

@test "list skips gcp silently when GCP_PROJECT is unset (no error, no gcp row)" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","PublicIpAddress":"1.2.3.4",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"sandbox-aws"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    echo "$output" | grep sandbox-aws | grep -q -w aws
    # gcp had no creds → skipped, so it must not appear as a provider row
    ! ( echo "$output" | grep -q -w gcp )
}
