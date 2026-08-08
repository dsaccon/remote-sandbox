#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-response"
    : > "$AWS_STUB_LOG"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/aws.sh"
    AWS_REGION="us-west-2"
}

set_response() {
    local rc="$1"; shift
    { echo "$rc"; printf '%s' "$*"; } > "$AWS_STUB_RESPONSE"
}

@test "aws_caller_identity passes through region and exits 0 on success" {
    set_response 0 '{"Arn":"arn:aws:iam::1:user/me"}'
    run aws_caller_identity
    [ "$status" -eq 0 ]
    grep -q -- '--region us-west-2' "$AWS_STUB_LOG"
    grep -q -- 'sts get-caller-identity' "$AWS_STUB_LOG"
}

@test "aws_caller_identity dies with friendly message on failure" {
    set_response 1 ''
    run aws_caller_identity
    [ "$status" -ne 0 ]
    [[ "$output" == *"aws configure"* ]]
}

@test "aws_describe_image returns 0 when image exists" {
    set_response 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    run aws_describe_image ami-abc
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 describe-images --image-ids ami-abc' "$AWS_STUB_LOG"
}

@test "aws_describe_image fails with helpful message when missing" {
    set_response 0 '{"Images":[]}'
    run aws_describe_image ami-bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"AMI ami-bad not found"* ]]
}

@test "aws_set_sg_ingress_to revokes existing then authorizes new CIDR" {
    # First call: describe to find existing rules. Second: revoke. Third: authorize.
    # aws_set_sg_ingress_to calls describe-security-groups with
    # --query 'SecurityGroups[0].IpPermissions', so the real CLI returns just
    # the IpPermissions array. The stub ignores --query and returns this
    # verbatim, so the fixture must be the projected array, not the full object.
    set_response 0 '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"5.6.7.8/32"}]}]'
    run aws_set_sg_ingress_to sg-123 "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 revoke-security-group-ingress' "$AWS_STUB_LOG"
    grep -q -- 'ec2 authorize-security-group-ingress' "$AWS_STUB_LOG"
    grep -q -- '1.2.3.4/32' "$AWS_STUB_LOG"
}

# Regression: the normalized record is consumed with `read -r` under
# IFS=$'\t', and tab is an IFS-whitespace character, so a run of tabs collapses
# into ONE separator. Every field in the jq array therefore emits a "-"
# placeholder rather than an empty string — except .InstanceType and
# .LaunchTime, which didn't. An instance missing both produced two adjacent
# empty fields, collapsing the row and shifting every later column left by two:
# `type` received the IP, `cidr` received the market, and `ip` received "-".
# That is why `ssh <name>` resolved to `ubuntu@on-demand`.
@test "provider_list keeps columns aligned when InstanceType/LaunchTime are absent" {
    source "$REPO_ROOT/lib/providers/aws.sh"
    set_response 0 '{"Reservations":[{"Instances":[
      {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
       "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
    ]}]}'
    run provider_list
    [ "$status" -eq 0 ]
    row="$(printf '%s' "$output" | head -1)"
    # handle name state type market epoch ip cidr ash disk
    [ "$(printf '%s' "$row" | awk -F'\t' '{print NF}')" -eq 10 ]
    [ "$(printf '%s' "$row" | awk -F'\t' '{print $7}')" = "5.6.7.8" ]
    [ "$(printf '%s' "$row" | awk -F'\t' '{print $5}')" = "on-demand" ]
}

@test "provider_list fetches status/SG/volumes concurrently, not serially" {
    source "$REPO_ROOT/lib/providers/aws.sh"
    # A running instance with a security group and a root volume fires all three
    # secondary lookups. Each aws call sleeps 2s (stub below), so serial querying
    # is ~8s (describe-instances + 3) and concurrent ~4s (describe-instances +
    # max of 3). Assert under 6s — guards against regressing to serial calls.
    set_response 0 '{"Reservations":[{"Instances":[
      {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
       "PublicIpAddress":"5.6.7.8","RootDeviceName":"/dev/xvda",
       "SecurityGroups":[{"GroupId":"sg-1"}],
       "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeId":"vol-1"}}],
       "Tags":[{"Key":"Name","Value":"aws-box"},{"Key":"Project","Value":"claude-sandbox"}]}
    ]}]}'
    local slow="$BATS_TEST_TMPDIR/slow-aws"
    printf '#!/usr/bin/env bash\nsleep 2\nexec "%s" "$@"\n' "$REPO_ROOT/test/unit/stubs/aws-empty" > "$slow"
    chmod +x "$slow"; AWS_CMD="$slow"

    local start end
    start="$(date +%s)"
    run provider_list
    end="$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aws-box"* && "$output" == *"5.6.7.8"* ]]
    (( end - start < 6 ))
}

# provider_cleanup_net used to run `delete-security-group ... 2>/dev/null` and
# log only on success. That silently swallowed UnauthorizedOperation, so a
# too-narrow IAM policy leaked a security group on every `down` — invisibly,
# until the orphan blocked `up --name <same>` with InvalidGroup.Duplicate.
_fake_aws() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$AWS_CMD_FAKE"; chmod +x "$AWS_CMD_FAKE"; AWS_CMD="$AWS_CMD_FAKE"; }

@test "provider_cleanup_net warns when the SG delete is unauthorized" {
    source "$REPO_ROOT/lib/providers/aws.sh"
    AWS_CMD_FAKE="$BATS_TEST_TMPDIR/aws-fake"
    _fake_aws 'echo "An error occurred (UnauthorizedOperation) when calling the DeleteSecurityGroup operation" >&2; exit 255'
    run provider_cleanup_net box
    [[ "$output" == *"could not delete SG box-sg"* ]]
    [[ "$output" == *"UnauthorizedOperation"* ]]
}

@test "provider_cleanup_net stays quiet when the SG simply doesn't exist" {
    source "$REPO_ROOT/lib/providers/aws.sh"
    AWS_CMD_FAKE="$BATS_TEST_TMPDIR/aws-fake"
    _fake_aws 'echo "An error occurred (InvalidGroup.NotFound) ..." >&2; exit 255'
    run provider_cleanup_net box
    [ -z "$output" ]
}

@test "provider_cleanup_net explains a DependencyViolation instead of hiding it" {
    source "$REPO_ROOT/lib/providers/aws.sh"
    AWS_CMD_FAKE="$BATS_TEST_TMPDIR/aws-fake"
    _fake_aws 'echo "An error occurred (DependencyViolation) ..." >&2; exit 255'
    run provider_cleanup_net box
    [[ "$output" == *"still attached"* ]]
    [[ "$output" == *"delete-security-group --group-name box-sg"* ]]
}
