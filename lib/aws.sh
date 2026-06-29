#!/usr/bin/env bash
# lib/aws.sh — thin wrappers over `aws` CLI. Every external call goes through
# $AWS_CMD so tests can stub it. Functions print to stdout, log to stderr,
# and use `die` on unrecoverable errors.

if [[ -n "${_SANDBOX_AWS_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_AWS_SH_LOADED=1

_aws_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_aws_sh_dir/log.sh"

: "${AWS_CMD:=aws}"

_aws() {
    : "${AWS_REGION:?_aws: AWS_REGION not set}"
    "$AWS_CMD" --region "$AWS_REGION" "$@"
}

aws_caller_identity() {
    if ! _aws sts get-caller-identity >/dev/null 2>&1; then
        die "AWS credentials not configured or invalid — run 'aws configure'"
    fi
}

aws_describe_image() {
    local ami_id="$1"
    local out
    if ! out="$(_aws ec2 describe-images --image-ids "$ami_id" --output json 2>&1)"; then
        die "AMI $ami_id not found in $AWS_REGION (api error: $out)"
    fi
    local count
    count="$(printf '%s' "$out" | jq '.Images | length')"
    if [[ "$count" -eq 0 ]]; then
        die "AMI $ami_id not found in $AWS_REGION"
    fi
}

aws_describe_key_pair() {
    local name="$1"
    if ! _aws ec2 describe-key-pairs --key-names "$name" >/dev/null 2>&1; then
        die "EC2 key pair '$name' not found in $AWS_REGION. Create one:
  aws ec2 create-key-pair --region $AWS_REGION --key-name $name --query KeyMaterial --output text > ~/.ssh/${name}.pem
  chmod 600 ~/.ssh/${name}.pem"
    fi
}

aws_describe_sg_id() {
    local name="$1"
    local out
    out="$(_aws ec2 describe-security-groups --group-names "$name" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    if [[ -z "$out" || "$out" == "None" ]]; then
        return 1
    fi
    printf '%s' "$out"
}

aws_create_sg() {
    local name="$1"
    local vpc_id
    vpc_id="$(_aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)"
    [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && die "no default VPC in $AWS_REGION"
    _aws ec2 create-security-group --group-name "$name" \
        --description "claude-sandbox SSH ingress (managed by remote-sandbox)" \
        --vpc-id "$vpc_id" --query GroupId --output text
}

# aws_create_per_sandbox_sg NAME CIDR — create a per-sandbox SG with :22 ingress
# from CIDR, tagged Project=claude-sandbox + SandboxName=NAME so it can be
# found and cleaned up later. Returns the new SG ID on stdout.
aws_create_per_sandbox_sg() {
    local sb_name="$1" cidr="$2"
    local sg_name="${sb_name}-sg"
    local vpc_id
    vpc_id="$(_aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)"
    [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && die "no default VPC in $AWS_REGION"
    local sg_id
    sg_id="$(_aws ec2 create-security-group --group-name "$sg_name" \
        --description "claude-sandbox $sb_name SSH ingress (managed by remote-sandbox)" \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=claude-sandbox},{Key=SandboxName,Value=$sb_name}]" \
        --query GroupId --output text)"
    _aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr "$cidr" >/dev/null
    printf '%s' "$sg_id"
}

# aws_delete_sg SG_ID — try to delete an SG. Returns 0 on success, non-zero
# on failure (most commonly because the SG is still in use by an ENI that
# hasn't fully detached yet). Silent on success; the caller decides how to
# log failures.
aws_delete_sg() {
    local sg_id="$1"
    _aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null
}

# aws_describe_sgs_by_ids ID [ID ...] — batch fetch SGs by ID, return JSON.
# Empty arg list → empty SecurityGroups array (so callers can pipe to jq
# unconditionally).
aws_describe_sgs_by_ids() {
    if [[ $# -eq 0 ]]; then
        printf '%s' '{"SecurityGroups":[]}'
        return 0
    fi
    _aws ec2 describe-security-groups --group-ids "$@" --output json
}

aws_set_sg_ingress_to() {
    local sg_id="$1"
    local cidr="$2"
    # Revoke every existing :22/tcp rule.
    local existing
    existing="$(_aws ec2 describe-security-groups --group-ids "$sg_id" \
        --query 'SecurityGroups[0].IpPermissions' --output json)"
    local existing_cidrs
    existing_cidrs="$(printf '%s' "$existing" \
        | jq -r '.[] | select(.IpProtocol=="tcp" and .FromPort==22) | .IpRanges[].CidrIp' || true)"
    if [[ -n "$existing_cidrs" ]]; then
        while IFS= read -r old_cidr; do
            [[ -z "$old_cidr" ]] && continue
            _aws ec2 revoke-security-group-ingress --group-id "$sg_id" \
                --protocol tcp --port 22 --cidr "$old_cidr" >/dev/null
        done <<< "$existing_cidrs"
    fi
    _aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr "$cidr" >/dev/null
}

aws_run_instances_json() {
    # Read JSON from stdin, invoke run-instances, print resulting instance id
    # to stdout. On failure, emit the AWS error to stderr and return non-zero
    # so the caller can pattern-match (e.g. for InsufficientInstanceCapacity).
    #
    # We write the JSON to a tempfile instead of using `file:///dev/stdin`
    # because aws CLI v2 rejects /dev/stdin with "Invalid JSON received"
    # (it appears to mmap/seek the file). Tempfile is bulletproof.
    local out err_log rc tmpf id
    tmpf="$(mktemp -t aws-run-instances.XXXXXX)"
    err_log="$(mktemp -t aws-run-instances-err.XXXXXX)"
    trap 'rm -f "$tmpf" "$err_log"' RETURN
    cat > "$tmpf"

    # NB: capture rc via `|| rc=$?`, not `if ! out=$(...); then rc=$?`. After
    # `! `, $? is the negation's status (0), so the old form returned 0 on
    # failure — silently breaking the spot→on-demand fallback in provision.sh.
    rc=0
    out="$(_aws ec2 run-instances --cli-input-json "file://$tmpf" --output json 2>"$err_log")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        cat "$err_log" >&2
        return "$rc"
    fi

    id="$(printf '%s' "$out" | jq -r '.Instances[0].InstanceId // ""')"
    if [[ -z "$id" || "$id" == "null" ]]; then
        printf 'aws_run_instances_json: success exit but no InstanceId in response\n' >&2
        printf 'stdout was: %s\n' "$out" >&2
        printf 'stderr was: %s\n' "$(cat "$err_log")" >&2
        return 1
    fi
    printf '%s' "$id"
}

aws_wait_running() {
    local instance_id="$1"
    _aws ec2 wait instance-status-ok --instance-ids "$instance_id"
}

aws_describe_instances_by_tag() {
    # Default state filter excludes only the implicit-default terminator state
    # that AWS purges after ~1 hour ("terminated"), keeping callers from being
    # surprised by long-dead instances. Pass a custom filter as the 3rd arg
    # if you also want terminated instances (e.g. for `list` to show the
    # full shutdown lifecycle).
    local key="$1"
    local val="$2"
    local states="${3:-pending,running,stopping,stopped,shutting-down}"
    _aws ec2 describe-instances \
        --filters "Name=tag:$key,Values=$val" "Name=instance-state-name,Values=$states" \
        --output json
}

aws_terminate_instances() {
    [[ $# -eq 0 ]] && return 0
    _aws ec2 terminate-instances --instance-ids "$@" --output json
}

aws_get_console_output() {
    local id="$1"
    _aws ec2 get-console-output --instance-id "$id" --output text 2>/dev/null || true
}

aws_get_instance_ip() {
    local id="$1"
    _aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

# aws_describe_instance_status_for ID [ID ...] — describe-instance-status for
# the given instance IDs. Use to get InstanceStatus.Status / SystemStatus.Status
# (ok / impaired / initializing / insufficient-data). Returns JSON.
# Empty arg list → empty JSON envelope so callers can pipe to jq unconditionally.
aws_describe_instance_status_for() {
    if [[ $# -eq 0 ]]; then
        printf '%s' '{"InstanceStatuses":[]}'
        return 0
    fi
    _aws ec2 describe-instance-status --instance-ids "$@" --output json
}

# Latest Canonical Ubuntu 24.04 LTS amd64 AMI in current region.
aws_describe_ubuntu_2404_ami() {
    _aws ec2 describe-images \
        --owners 099720109477 \
        --filters \
            'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
            'Name=state,Values=available' \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text
}

aws_create_image() {
    local instance_id="$1"
    local name="$2"
    # NOTE: DO NOT pass --no-reboot. With --no-reboot the snapshot is taken
    # against a live filesystem whose page cache hasn't been flushed —
    # recently-written files (like the dotfiles clone, the nvim tarball,
    # the npm-installed claude binary) end up on the AMI as ZERO-BYTE
    # files. Letting AWS reboot the instance triggers a clean sync first,
    # which guarantees consistency. Costs ~30-60s extra per bake.
    _aws ec2 create-image --instance-id "$instance_id" --name "$name" \
        --query ImageId --output text
}

aws_wait_image_available() {
    local ami_id="$1"
    _aws ec2 wait image-available --image-ids "$ami_id"
}

# aws_describe_self_amis — all claude-sandbox-* AMIs owned by the caller.
# Returns describe-images JSON.
aws_describe_self_amis() {
    _aws ec2 describe-images --owners self \
        --filters 'Name=name,Values=claude-sandbox-*' \
        --output json
}

aws_deregister_image() {
    local ami="$1"
    _aws ec2 deregister-image --image-id "$ami" >/dev/null
}

aws_delete_snapshot() {
    local snap="$1"
    _aws ec2 delete-snapshot --snapshot-id "$snap" >/dev/null
}

# aws_image_snapshot_ids AMI_ID — print whitespace-separated snapshot IDs
# attached to the given AMI's EBS block device mappings. Must be called
# BEFORE deregistering the AMI (after, the image is gone).
aws_image_snapshot_ids() {
    local ami="$1"
    _aws ec2 describe-images --image-ids "$ami" \
        --query 'Images[0].BlockDeviceMappings[?Ebs].Ebs.SnapshotId' \
        --output text
}

aws_run_simple() {
    # Minimal launch for the bake VM: ami, type, key, sg, tag.
    local ami="$1" itype="$2" key="$3" sg="$4" name="$5"
    _aws ec2 run-instances \
        --image-id "$ami" --instance-type "$itype" --key-name "$key" \
        --security-group-ids "$sg" --count 1 \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=claude-sandbox},{Key=Name,Value=$name},{Key=BakeRole,Value=bake}]" \
        --query 'Instances[0].InstanceId' --output text
}
