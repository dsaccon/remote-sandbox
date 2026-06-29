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
