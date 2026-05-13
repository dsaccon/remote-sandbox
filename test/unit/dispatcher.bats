#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PATH="$REPO_ROOT/bin:$PATH"
}

@test "sandbox with no args prints usage and exits non-zero" {
    run sandbox
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "sandbox unknown-cmd errors clearly" {
    run sandbox bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command: bogus"* ]]
}

@test "sandbox config-missing message points at config.example" {
    tmpdir="$(mktemp -d)"
    cp "$REPO_ROOT/bin/sandbox" "$tmpdir/sandbox"
    mkdir -p "$tmpdir/bin" "$tmpdir/lib"
    cp "$REPO_ROOT/bin/sandbox" "$tmpdir/bin/"
    cp "$REPO_ROOT/lib/log.sh" "$tmpdir/lib/"
    touch "$tmpdir/config.example"
    # No `config` file present.
    cd "$tmpdir"
    run ./bin/sandbox list
    [ "$status" -ne 0 ]
    [[ "$output" == *"copy config.example to config"* ]]
}
