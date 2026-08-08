#!/usr/bin/env bats
# test/unit/gcp.bats — GCP driver skeleton: seam, preflight, name validation.

# The fixture account, and the GCP label sandbox_owner_label derives from it.
TEST_OWNER_EMAIL="tester@example.com"
TEST_OWNER_LABEL="tester-example-com"

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    # Deterministic identity for every test: sandboxes are owner-scoped, so the
    # driver resolves the active gcloud account. Point it at a fixture, never at
    # the developer's real ~/.config/gcloud — and never at the gcloud stub,
    # whose canned response is instance JSON, not an email.
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
    printf '[core]\naccount = %s\n' "$TEST_OWNER_EMAIL" \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    source "$REPO_ROOT/lib/providers/gcp.sh"
    GCP_PROJECT="proj"; GCP_ZONE="us-west1-b"; GCP_MACHINE_TYPE="e2-standard-4"; SSH_USER="ubuntu"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "gcp_validate_name accepts RFC1035 names" {
    run gcp_validate_name sandbox-26bdd2af
    [ "$status" -eq 0 ]
}
@test "gcp_validate_name rejects uppercase/underscore" {
    run gcp_validate_name My_Box
    [ "$status" -ne 0 ]
    [[ "$output" == *"RFC1035"* ]]
}
@test "provider_preflight dies when GCP_PROJECT empty" {
    GCP_PROJECT=""
    run provider_preflight
    [ "$status" -ne 0 ]
    [[ "$output" == *"GCP_PROJECT"* ]]
}
@test "provider_build_image delegates to the gcp baker" {
    run provider_build_image
    # setup() leaves SSH_KEY_FILE unset, so _gcp_build_image must fail loudly on
    # the missing prerequisite rather than silently proceeding.
    [ "$status" -ne 0 ]
    [[ "$output" == *"build-ami"* ]]
}

# Regression: gcp_render_startup must return 0 even with an empty repo. A
# trailing `[[ -n "$repo" ]] && printf` made it return 1, which under the
# caller's `set -e` aborted provider_launch right after the firewall create.
@test "gcp_render_startup returns 0 with an empty repo" {
    run gcp_render_startup sandbox-abc ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"hostnamectl set-hostname sandbox-abc"* ]]
}

# Regression (end-to-end): under `set -e` (as bin/sandbox-up runs), a repo-less
# launch must still reach the instance-create, not die after the firewall.
@test "provider_launch under set -e reaches instance-create with an empty repo" {
    set_response 0 ''
    echo "ssh-ed25519 AAAA test" > "$BATS_TEST_TMPDIR/id.pub"
    run env REPO_ROOT="$REPO_ROOT" \
            GCLOUD_CMD="$GCLOUD_CMD" GCLOUD_STUB_LOG="$GCLOUD_STUB_LOG" \
            GCLOUD_STUB_RESPONSE="$GCLOUD_STUB_RESPONSE" \
            CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" \
            GCP_PROJECT=proj GCP_ZONE=us-west1-b GCP_MACHINE_TYPE=e2-standard-4 \
            SSH_USER=ubuntu \
            GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub" AUTO_SHUTDOWN_HOURS=0 \
        bash -c '
            set -euo pipefail
            source "$REPO_ROOT/lib/providers/gcp.sh"
            provider_launch sandbox-abc "" false "1.2.3.4/32"
        '
    [ "$status" -eq 0 ]
    grep -q -- "compute instances create sandbox-abc" "$GCLOUD_STUB_LOG"
}

# Regression: a failed instance-create must roll back the firewall it created,
# not leave an orphaned <name>-fw rule.
@test "provider_launch rolls back the firewall when the instance create fails" {
    local stub="$BATS_TEST_TMPDIR/gcloud-failcreate"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
: "${GCLOUD_STUB_LOG:?}"
printf '%s\n' "$*" >> "$GCLOUD_STUB_LOG"
case "$*" in
    *"instances create"*) exit 1 ;;   # simulate a failed create
    *)                    exit 0 ;;
esac
STUB
    chmod +x "$stub"
    GCLOUD_CMD="$stub"
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=0
    run provider_launch sb-rb "" false "1.2.3.4/32"
    [ "$status" -ne 0 ]
    grep -q -- "firewall-rules create sb-rb-fw" "$GCLOUD_STUB_LOG"
    grep -q -- "firewall-rules delete sb-rb-fw" "$GCLOUD_STUB_LOG"
}

@test "provider_launch creates a per-sandbox firewall rule and an instance" {
    set_response 0 ''    # gcloud calls succeed, empty output
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=0
    run provider_launch sandbox-abc "" false "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'compute firewall-rules create sandbox-abc-fw' "$GCLOUD_STUB_LOG"
    grep -q -- 'source-ranges=1.2.3.4/32' "$GCLOUD_STUB_LOG"
    grep -q -- 'target-tags=sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances create sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'labels=project=claude-sandbox,name=sandbox-abc' "$GCLOUD_STUB_LOG"
}

@test "provider_launch adds spot + max-run-duration flags when requested" {
    set_response 0 ''
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=8
    run provider_launch sandbox-abc "" true "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'provisioning-model=SPOT' "$GCLOUD_STUB_LOG"
    grep -q -- 'max-run-duration=8h' "$GCLOUD_STUB_LOG"
    grep -q -- 'instance-termination-action=DELETE' "$GCLOUD_STUB_LOG"
}

@test "provider_list emits a normalized row" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-abc","status":"RUNNING","machineType":"https://.../machineTypes/e2-standard-4",
  "creationTimestamp":"2026-07-03T10:00:00.000-07:00",
  "scheduling":{"provisioningModel":"SPOT"},
  "networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}],
  "metadata":{"items":[{"key":"auto-shutdown-hours","value":"8"}]},
  "tags":{"items":["sandbox-abc"]}}]
EOF
    run provider_list
    [ "$status" -eq 0 ]
    # handle name state type market ... ip ... ash
    [[ "$output" == *"sandbox-abc"*"ready"*"e2-standard-4"*"spot"*"5.6.7.8"*"8"* ]]
}

@test "provider_list fetches instances and firewall rules concurrently" {
    # Two independent gcloud calls; each sleeps 3s (stub below). Serial querying
    # is ~6s, concurrent ~3s. Assert under 5s — guards against serial regression.
    set_response 0 '[{"name":"sandbox-abc","status":"RUNNING","machineType":"https://x/machineTypes/e2-standard-4","creationTimestamp":"2026-07-03T10:00:00.000-07:00","scheduling":{"provisioningModel":"SPOT"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}],"metadata":{"items":[{"key":"auto-shutdown-hours","value":"8"}]},"tags":{"items":["sandbox-abc"]}}]'
    local slow="$BATS_TEST_TMPDIR/slow-gcloud"
    printf '#!/usr/bin/env bash\nsleep 3\nexec "%s" "$@"\n' "$REPO_ROOT/test/unit/stubs/gcloud-empty" > "$slow"
    chmod +x "$slow"; GCLOUD_CMD="$slow"

    local start end
    start="$(date +%s)"
    run provider_list
    end="$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sandbox-abc"* ]]
    (( end - start < 5 ))
}

@test "provider_resolve_ip returns the natIP for a RUNNING box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<EOF
0
{"status":"RUNNING","labels":{"owner":"$TEST_OWNER_LABEL"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -eq 0 ]
    [ "$output" = "5.6.7.8" ]
}
@test "provider_resolve_ip dies for a booting box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<EOF
0
{"status":"PROVISIONING","labels":{"owner":"$TEST_OWNER_LABEL"},"networkInterfaces":[{"accessConfigs":[{}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"booting"* ]]
}
@test "provider_terminate_ids deletes by name+zone" {
    set_response 0 ''
    run provider_terminate_ids sandbox-abc
    [ "$status" -eq 0 ]
    grep -q -- 'compute instances delete sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'zone=us-west1-b' "$GCLOUD_STUB_LOG"
}


# --- Multi-user: sandboxes are scoped to the gcloud account that made them. ---
# Identity comes from the CLOUDSDK_CONFIG fixture written in setup(), so these
# assert against $TEST_OWNER_LABEL rather than hardcoding an address.

@test "provider_launch labels the instance with the owner" {
    set_response 0 ''
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=0
    run provider_launch sandbox-abc "" false "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- "labels=project=claude-sandbox,name=sandbox-abc,owner=$TEST_OWNER_LABEL" \
        "$GCLOUD_STUB_LOG"
    # Metadata carries the unmodified address for audit, not the label form.
    grep -q -- "owner=$TEST_OWNER_EMAIL" "$GCLOUD_STUB_LOG"
}

@test "provider_list filters instances by owner label" {
    set_response 0 '[]'
    run provider_list
    [ "$status" -eq 0 ]
    grep -q -- "labels.owner=$TEST_OWNER_LABEL" "$GCLOUD_STUB_LOG"
    grep -q -- "labels.project=claude-sandbox" "$GCLOUD_STUB_LOG"
}

@test "provider_resolve_ip rejects a box owned by someone else" {
    cat > "$GCLOUD_STUB_RESPONSE" <<RESP
0
{"status":"RUNNING","labels":{"owner":"someone-else-corp-com"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}
RESP
    run provider_resolve_ip sandbox-theirs
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named sandbox-theirs"* ]]
}

@test "provider_resolve_ip rejects a box with no owner label" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'RESP'
0
{"status":"RUNNING","labels":{"project":"claude-sandbox"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}
RESP
    run provider_resolve_ip sandbox-legacy
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named sandbox-legacy"* ]]
}
