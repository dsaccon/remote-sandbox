#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/provision.sh"
}

@test "render_cloud_init substitutes hostname when no repo" {
    out="$(render_cloud_init sandbox-abc "" 8)"
    [[ "$out" == *"hostname: sandbox-abc"* ]]
    [[ "$out" != *"git clone"* ]]
    [[ "$out" == *"AUTO_SHUTDOWN_HOURS=8"* ]]
}

@test "render_cloud_init injects git clone when repo provided" {
    out="$(render_cloud_init sandbox-abc "https://github.com/x/y.git" 8)"
    [[ "$out" == *"hostname: sandbox-abc"* ]]
    [[ "$out" == *"git clone https://github.com/x/y.git"* ]]
}

@test "render_cloud_init omits clone block when repo empty string" {
    out="$(render_cloud_init sandbox-abc "" 0)"
    [[ "$out" != *"git clone"* ]]
    [[ "$out" == *"AUTO_SHUTDOWN_HOURS=0"* ]]
}
