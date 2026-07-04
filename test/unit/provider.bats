#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$REPO_ROOT/lib/provider.sh"
}
@test "provider_load dies on unknown CLOUD" {
    CLOUD="azure"
    run provider_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown CLOUD"* ]]
}
@test "provider_load sources the aws driver and defines the contract" {
    CLOUD="aws"
    provider_load
    declare -F provider_preflight >/dev/null
    declare -F provider_launch >/dev/null
    declare -F provider_resolve_ip >/dev/null
}
