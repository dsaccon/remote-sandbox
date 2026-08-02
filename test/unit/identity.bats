#!/usr/bin/env bats
# test/unit/identity.bats — owner identity from gcloud's active account.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    source "$REPO_ROOT/lib/identity.sh"
}

write_cfg() {   # CONFIG_NAME EMAIL
    printf '[core]\naccount = %s\nproject = proj\n' "$2" \
        > "$CLOUDSDK_CONFIG/configurations/config_$1"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "reads the account from the default config" {
    write_cfg default david@synesis.one
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "david@synesis.one" ]
}

@test "honours the config named by active_config" {
    write_cfg work jane@corp.com
    printf 'work\n' > "$CLOUDSDK_CONFIG/active_config"
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "jane@corp.com" ]
}

@test "CLOUDSDK_ACTIVE_CONFIG_NAME overrides active_config" {
    write_cfg work jane@corp.com
    write_cfg other bob@corp.com
    printf 'work\n' > "$CLOUDSDK_CONFIG/active_config"
    CLOUDSDK_ACTIVE_CONFIG_NAME=other run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "bob@corp.com" ]
}

@test "falls back to gcloud when the config file is absent" {
    set_response 0 'fallback@corp.com'
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "fallback@corp.com" ]
    grep -q "config get-value account" "$GCLOUD_STUB_LOG"
}

@test "dies when the file is absent and gcloud yields nothing" {
    set_response 0 ''
    run sandbox_owner_email
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud auth login"* ]]
}

@test "dies when gcloud reports the account unset" {
    set_response 0 '(unset)'
    run sandbox_owner_email
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud auth login"* ]]
}

@test "ignores an account key belonging to another section" {
    printf '[core]\nproject = proj\n[auth]\naccount = wrong@corp.com\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    set_response 0 'right@corp.com'
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "right@corp.com" ]
}

@test "label replaces @ and . with dashes" {
    write_cfg default david@synesis.one
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "david-synesis-one" ]
}

@test "label uses the full email so local parts cannot collide" {
    write_cfg default first.last@corp.com
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "first-last-corp-com" ]
}

@test "label lowercases" {
    write_cfg default David@Synesis.One
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "david-synesis-one" ]
}

@test "label dies when it would exceed 63 chars" {
    write_cfg default "$(printf 'a%.0s' $(seq 1 60))@synesis.one"
    run sandbox_owner_label
    [ "$status" -ne 0 ]
    [[ "$output" == *"63"* ]]
}

@test "label propagates a failure to resolve the email" {
    set_response 0 ''
    run sandbox_owner_label
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud auth login"* ]]
}
