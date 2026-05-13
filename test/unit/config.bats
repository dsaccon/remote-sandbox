#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib"
    cp "$REPO_ROOT/lib/log.sh" "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/lib/config.sh" "$SANDBOX_REPO_ROOT/lib/"
}

teardown() {
    rm -rf "$SANDBOX_REPO_ROOT"
}

write_config() {
    cat > "$SANDBOX_REPO_ROOT/config"
}

@test "defaults apply when config has empty values" {
    write_config <<'EOF'
AWS_REGION=""
INSTANCE_TYPE=""
USE_SPOT=""
EOF
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$AWS_REGION" = "us-west-2" ]
    [ "$INSTANCE_TYPE" = "m7i-flex.xlarge" ]
    [ "$USE_SPOT" = "true" ]
}

@test "config file values override defaults" {
    write_config <<'EOF'
AWS_REGION="eu-west-1"
INSTANCE_TYPE="t3.large"
EOF
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$AWS_REGION" = "eu-west-1" ]
    [ "$INSTANCE_TYPE" = "t3.large" ]
}

@test "SANDBOX_ env vars override config file" {
    write_config <<'EOF'
AWS_REGION="eu-west-1"
INSTANCE_TYPE="t3.large"
EOF
    export SANDBOX_INSTANCE_TYPE="m7i-flex.2xlarge"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$INSTANCE_TYPE" = "m7i-flex.2xlarge" ]
    [ "$AWS_REGION" = "eu-west-1" ]  # not overridden
}

@test "config_set_from_flag overrides env and file" {
    write_config <<'EOF'
INSTANCE_TYPE="t3.large"
EOF
    export SANDBOX_INSTANCE_TYPE="m7i-flex.2xlarge"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    config_set_from_flag INSTANCE_TYPE "c7i.xlarge"
    [ "$INSTANCE_TYPE" = "c7i.xlarge" ]
}

@test "config_load errors if config file missing" {
    rm -f "$SANDBOX_REPO_ROOT/config"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    run config_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"no config file"* ]]
}
