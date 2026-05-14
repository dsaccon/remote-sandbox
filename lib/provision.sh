#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers. Other tasks add to this file.

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
