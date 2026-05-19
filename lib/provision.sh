#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers.

if [[ -n "${_SANDBOX_PROVISION_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVISION_SH_LOADED=1

_provision_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_provision_repo_root="$(cd "$_provision_sh_dir/.." && pwd)"

# shellcheck source=log.sh
source "$_provision_sh_dir/log.sh"
# Functions below depend on aws.sh helpers (aws_caller_identity, etc.). Source
# it eagerly here so callers can source provision.sh alone and get everything
# they need; source guards make this idempotent.
# shellcheck source=aws.sh
source "$_provision_sh_dir/aws.sh"

# render_cloud_init NAME REPO_URL AUTO_SHUTDOWN_HOURS
# Prints rendered YAML to stdout.
render_cloud_init() {
    local name="$1"
    local repo="$2"
    local hours="$3"
    local tmpl="$_provision_repo_root/ami/cloud-init.yaml.tmpl"
    [[ -f "$tmpl" ]] || die "missing template: $tmpl"

    local clone_block=""
    if [[ -n "$repo" ]]; then
        clone_block="  - [ sudo, -u, ubuntu, -i, bash, -c, \"git clone $repo\" ]"
    fi

    # Newlines in clone_block could break sed; use awk for safety.
    awk \
        -v name="$name" \
        -v clone="$clone_block" \
        -v hours="$hours" \
        '{
            gsub(/\{\{NAME\}\}/, name)
            gsub(/\{\{CLONE_BLOCK\}\}/, clone)
            gsub(/\{\{AUTO_SHUTDOWN_HOURS\}\}/, hours)
            print
        }' "$tmpl"
}

: "${CURL_CMD:=curl}"

current_public_ip_cidr() {
    local ip
    ip="$("$CURL_CMD" -fsS https://checkip.amazonaws.com)" || die "could not fetch public IP"
    ip="${ip//[$'\t\r\n ']}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected public IP: $ip"
    printf '%s/32' "$ip"
}

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
    {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}
  ],
  "UserData": "$user_data_b64",
  "TagSpecifications": [
    {"ResourceType":"instance","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"},
      {"Key":"CreatedAt","Value":"$iso"},
      {"Key":"Owner","Value":"$owner_tag"}
    ]},
    {"ResourceType":"volume","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"}
    ]}
  ]$spot_block
}
EOF
}

# provision_launch NAME REPO USE_SPOT — prints "<instance-id> <ip>" on success.
provision_launch() {
    local name="$1"
    local repo="$2"
    local use_spot="$3"

    local cidr; cidr="$(current_public_ip_cidr)"
    local sg_id; sg_id="$(ensure_sg)"
    log_info "security group: $sg_id; SSH ingress = $cidr"
    aws_set_sg_ingress_to "$sg_id" "$cidr"

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
            id="$(_run_instances "$name" false "$sg_id" "$user_data_b64")"
        else
            local err; err="$(cat "$err_log")"
            rm -f "$err_log"
            die "run-instances (spot) failed: $err"
        fi
    else
        log_info "requesting on-demand instance ($INSTANCE_TYPE)..."
        id="$(_run_instances "$name" false "$sg_id" "$user_data_b64")"
    fi
    rm -f "$err_log"

    wait_with_progress "instance $id launched; waiting for status checks (60-90s)" \
        aws_wait_running "$id"

    local ip; ip="$(aws_get_instance_ip "$id")"
    [[ "$ip" == "None" || -z "$ip" ]] && die "instance $id has no public IP"

    # Verify SSH actually comes up. On failure, show last 50 lines of EC2
    # console output to help diagnose AMI/sshd issues per the spec.
    : "${SSH_CMD:=ssh}"
    : "${SSH_KEY_FILE:?provision_launch: SSH_KEY_FILE not set (should default in config_load)}"
    [[ -r "$SSH_KEY_FILE" ]] || die "SSH key file not readable: $SSH_KEY_FILE"
    local ssh_opts=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
                    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR -o ConnectTimeout=10)
    local i ok=0
    for i in {1..18}; do  # ~90s total
        if "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER}@${ip}" true 2>/dev/null; then
            ok=1; break
        fi
        sleep 5
    done
    if [[ "$ok" -ne 1 ]]; then
        log_err "SSH never came up on $ip; last 50 lines of console output:"
        aws_get_console_output "$id" | tail -n 50 >&2
        die "instance $id reachable on network but SSH not responding"
    fi

    printf '%s %s\n' "$id" "$ip"
}

# Internal: actually invoke run-instances; returns the instance id or
# prints the AWS error message and exits non-zero.
_run_instances() {
    local name="$1" use_spot="$2" sg_id="$3" user_data_b64="$4"
    local json; json="$(build_run_instances_json "$name" "$use_spot" "$sg_id" "$user_data_b64")"
    printf '%s' "$json" | aws_run_instances_json
}
