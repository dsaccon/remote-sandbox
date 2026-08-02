#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers" "$SANDBOX_REPO_ROOT/ami/systemd" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,identity,config,common,provider,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT"/lib/providers/{aws,gcp}.sh "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/ami/bootstrap.sh" "$SANDBOX_REPO_ROOT/ami/"
    cp "$REPO_ROOT"/ami/systemd/*.{service,timer} "$SANDBOX_REPO_ROOT/ami/systemd/"
    cp "$REPO_ROOT/bin/sandbox-build-ami" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
AMI_ID=""
DOTFILES_REPO=""
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
    # ssh / scp stubs that succeed silently.
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-ok"
    export SCP_CMD="$BATS_TEST_TMPDIR/scp-ok"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_CMD"; chmod +x "$SSH_CMD"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SCP_CMD"; chmod +x "$SCP_CMD"
    # curl stub for ssh-readiness check (we test against the netcat path differently)
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-ok"
    printf '#!/usr/bin/env bash\necho 1.2.3.4\n' > "$CURL_CMD"; chmod +x "$CURL_CMD"
    # build-ami requires a readable SSH key file (it scps bootstrap to the VM).
    # Provide a dummy one so the readability guard passes; SSH/SCP are stubbed.
    export SANDBOX_SSH_KEY_FILE="$BATS_TEST_TMPDIR/key.pem"
    printf 'dummy-key\n' > "$SANDBOX_SSH_KEY_FILE"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "build-ami writes new AMI_ID to config on success" {
    # Walk through the calls:
    #   1: aws_caller_identity (sts get-caller-identity)
    #   2: describe-key-pairs
    #   3: describe-security-groups (ensure_sg)
    #   4: describe-security-groups (set ingress: list rules)
    #   5: authorize-security-group-ingress (no existing rule to revoke)
    #   6: describe-images (find base Ubuntu AMI)        → ami-base
    #   7: run-instances (bake VM)                       → i-bake
    #   8: wait instance-status-ok
    #   9: describe-instances (get IP)                   → 1.2.3.4
    #  10: create-image                                  → ami-new123
    #  11: wait image-available
    #  12: terminate-instances
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
ami-new123
EOF
    # Default stub returns the same output for every call. That's fine for
    # asserting on overall orchestration — we check the call log below.
    run "$SANDBOX_REPO_ROOT/bin/sandbox-build-ami"
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 describe-images.*099720109477' "$AWS_STUB_LOG"
    grep -q -- 'ec2 run-instances' "$AWS_STUB_LOG"
    grep -q -- 'ec2 create-image' "$AWS_STUB_LOG"
    grep -q -- 'ec2 wait image-available' "$AWS_STUB_LOG"
    grep -q -- 'ec2 terminate-instances' "$AWS_STUB_LOG"
    grep -q '^AMI_ID="ami-new123"' "$SANDBOX_REPO_ROOT/config"
}

@test "build-ami --cloud gcp bakes a custom image and writes GCP_IMAGE" {
    cat > "$SANDBOX_REPO_ROOT/config" <<EOF
CLOUD="aws"
GCP_PROJECT="proj"
GCP_ZONE="us-west1-b"
SSH_USER="ubuntu"
SSH_INGRESS_CIDR="1.2.3.4/32"
GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"
EOF
    echo "ssh-ed25519 AAAA test" > "$BATS_TEST_TMPDIR/id.pub"
    # gcloud stub returns an IP for the `instances describe … natIP` call.
    printf '0\n5.6.7.8\n' > "$GCLOUD_STUB_RESPONSE"

    # --cloud gcp overrides the config CLOUD=aws → the gcp bake runs.
    run "$SANDBOX_REPO_ROOT/bin/sandbox-build-ami" --cloud gcp
    [ "$status" -eq 0 ]
    grep -q -- 'compute firewall-rules create sandbox-bake-' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances create sandbox-bake-' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances stop sandbox-bake-' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute images create claude-sandbox-' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances delete sandbox-bake-' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute firewall-rules delete sandbox-bake-' "$GCLOUD_STUB_LOG"
    # No AWS calls happened — this baked gcp, not aws.
    [ ! -s "$AWS_STUB_LOG" ]
    grep -q '^GCP_IMAGE="claude-sandbox-' "$SANDBOX_REPO_ROOT/config"
}
