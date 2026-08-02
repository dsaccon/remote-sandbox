#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers.

if [[ -n "${_SANDBOX_PROVISION_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVISION_SH_LOADED=1

_provision_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=log.sh
source "$_provision_sh_dir/log.sh"
# shellcheck source=common.sh
source "$_provision_sh_dir/common.sh"
# Functions below depend on aws.sh helpers (aws_caller_identity, etc.). Source
# it eagerly here so callers can source provision.sh alone and get everything
# they need; source guards make this idempotent.
# shellcheck source=aws.sh
source "$_provision_sh_dir/aws.sh"

preflight_or_die() {
    : "${AWS_REGION:?preflight: AWS_REGION not set}"
    : "${SSH_KEY_NAME:?preflight: SSH_KEY_NAME not set}"
    [[ -z "${AMI_ID:-}" ]] && die "no AMI configured — run './bin/sandbox build-ami' (and check ./config)"

    aws_caller_identity
    aws_describe_image "$AMI_ID"
    aws_describe_key_pair "$SSH_KEY_NAME"
}

ensure_sg() {
    local name="claude-sandbox-sg"
    local id
    if id="$(aws_describe_sg_id "$name")"; then
        printf '%s' "$id"
    else
        log_info "creating security group $name"
        aws_create_sg "$name"
    fi
}

# build_run_instances_json NAME USE_SPOT — emits JSON to stdout.
build_run_instances_json() {
    local name="$1"
    local use_spot="$2"
    local sg_id="$3"
    local user_data_b64="$4"
    local iso owner_tag

    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    owner_tag="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"

    local spot_block=""
    if [[ "$use_spot" == "true" ]]; then
        spot_block=',"InstanceMarketOptions":{"MarketType":"spot","SpotOptions":{"InstanceInterruptionBehavior":"terminate"}}'
    fi

    cat <<EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$SSH_KEY_NAME",
  "MaxCount": 1,
  "MinCount": 1,
  "SecurityGroupIds": ["$sg_id"],
  "InstanceInitiatedShutdownBehavior": "terminate",
  "BlockDeviceMappings": [
    {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":${DISK_SIZE_GB:-64},"VolumeType":"gp3","DeleteOnTermination":true}}
  ],
  "UserData": "$user_data_b64",
  "TagSpecifications": [
    {"ResourceType":"instance","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"},
      {"Key":"CreatedAt","Value":"$iso"},
      {"Key":"Owner","Value":"$owner_tag"},
      {"Key":"AutoShutdownHours","Value":"${AUTO_SHUTDOWN_HOURS:-0}"}
    ]},
    {"ResourceType":"volume","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"}
    ]}
  ]$spot_block
}
EOF
}

# provision_launch NAME REPO USE_SPOT CIDR — issues run-instances and prints
# the new instance id on stdout. Non-blocking: does NOT wait for status
# checks or SSH readiness. Use `sandbox list` to track state.
#
# CIDR is the :22 ingress for the per-sandbox SG that gets created here.
provision_launch() {
    local name="$1"
    local repo="$2"
    local use_spot="$3"
    local cidr="$4"

    local sg_id; sg_id="$(aws_create_per_sandbox_sg "$name" "$cidr")"
    log_info "security group: $sg_id ($name-sg); SSH ingress = $cidr"

    local user_data; user_data="$(render_cloud_init "$name" "$repo" "${AUTO_SHUTDOWN_HOURS:-0}")"
    local user_data_b64; user_data_b64="$(printf '%s' "$user_data" | base64 | tr -d '\n')"

    local id err_log
    err_log="$(mktemp)"
    if [[ "$use_spot" == "true" ]]; then
        log_info "requesting spot instance ($INSTANCE_TYPE)..."
        if id="$(_run_instances "$name" true "$sg_id" "$user_data_b64" 2>"$err_log")"; then
            : # spot succeeded
        elif grep -q "InsufficientInstanceCapacity" "$err_log" && [[ "${SPOT_FALLBACK_ON_DEMAND:-false}" == "true" ]]; then
            log_warn "spot unavailable, falling back to on-demand"
            if ! id="$(_run_instances "$name" false "$sg_id" "$user_data_b64" 2>"$err_log")"; then
                local err; err="$(cat "$err_log")"
                rm -f "$err_log"
                die "run-instances (on-demand fallback) failed: $err"
            fi
        else
            local err; err="$(cat "$err_log")"
            rm -f "$err_log"
            die "run-instances (spot) failed: $err"
        fi
    else
        log_info "requesting on-demand instance ($INSTANCE_TYPE)..."
        if ! id="$(_run_instances "$name" false "$sg_id" "$user_data_b64" 2>"$err_log")"; then
            local err; err="$(cat "$err_log")"
            rm -f "$err_log"
            die "run-instances (on-demand) failed: $err"
        fi
    fi
    rm -f "$err_log"

    printf '%s\n' "$id"
}

# Internal: actually invoke run-instances; returns the instance id or
# prints the AWS error message and exits non-zero.
_run_instances() {
    local name="$1" use_spot="$2" sg_id="$3" user_data_b64="$4"
    local json; json="$(build_run_instances_json "$name" "$use_spot" "$sg_id" "$user_data_b64")"
    printf '%s' "$json" | aws_run_instances_json
}
