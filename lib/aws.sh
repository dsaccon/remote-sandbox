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
    local json out rc
    json="$(cat)"
    if ! out="$(printf '%s' "$json" | _aws ec2 run-instances --cli-input-json file:///dev/stdin --output json 2>&1)"; then
        rc=$?
        printf '%s\n' "$out" >&2
        return "$rc"
    fi
    printf '%s' "$out" | jq -r '.Instances[0].InstanceId'
}

aws_wait_running() {
    local instance_id="$1"
    _aws ec2 wait instance-status-ok --instance-ids "$instance_id"
}

aws_describe_instances_by_tag() {
    local key="$1"
    local val="$2"
    _aws ec2 describe-instances \
        --filters "Name=tag:$key,Values=$val" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
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
    _aws ec2 create-image --instance-id "$instance_id" --name "$name" \
        --no-reboot --query ImageId --output text
}

aws_wait_image_available() {
    local ami_id="$1"
    _aws ec2 wait image-available --image-ids "$ami_id"
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
