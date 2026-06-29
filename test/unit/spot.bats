#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-spot" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
USE_SPOT="true"
EOF
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "spot status prints the current default" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-spot" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"spot: on"* ]]
}

@test "spot with no arg defaults to status" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-spot"
    [ "$status" -eq 0 ]
    [[ "$output" == *"spot: on"* ]]
}

@test "spot off writes USE_SPOT=false in place" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-spot" off
    [ "$status" -eq 0 ]
    grep -q '^USE_SPOT="false"' "$SANDBOX_REPO_ROOT/config"
    [ "$(grep -c '^USE_SPOT=' "$SANDBOX_REPO_ROOT/config")" -eq 1 ]
}

@test "spot on writes USE_SPOT=true" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
USE_SPOT="false"
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-spot" on
    [ "$status" -eq 0 ]
    grep -q '^USE_SPOT="true"' "$SANDBOX_REPO_ROOT/config"
}

@test "spot with a bad arg errors" {
    run "$SANDBOX_REPO_ROOT/bin/sandbox-spot" bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown arg"* ]]
}
