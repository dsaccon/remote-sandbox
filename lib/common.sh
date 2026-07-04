#!/usr/bin/env bash
# lib/common.sh — cloud-agnostic helpers shared by all provider drivers.
if [[ -n "${_SANDBOX_COMMON_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_COMMON_SH_LOADED=1
_common_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_common_repo_root="$(cd "$_common_sh_dir/.." && pwd)"
# shellcheck source=log.sh
source "$_common_sh_dir/log.sh"

: "${CURL_CMD:=curl}"

# render_cloud_init NAME REPO_URL AUTO_SHUTDOWN_HOURS
# Prints rendered YAML to stdout.
render_cloud_init() {
    local name="$1"
    local repo="$2"
    local hours="$3"
    local tmpl="$_common_repo_root/ami/cloud-init.yaml.tmpl"
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

current_public_ip_cidr() {
    local ip
    ip="$("$CURL_CMD" -fsS https://checkip.amazonaws.com)" || die "could not fetch public IP"
    ip="${ip//[$'\t\r\n ']}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected public IP: $ip"
    printf '%s/32' "$ip"
}

# resolve_ssh_cidr [override] — pick the SG :22 ingress CIDR for a new sandbox.
# Precedence:  $1 (--ssh-cidr flag value) > $SSH_INGRESS_CIDR config > auto-detect.
# Auto-detect uses current_public_ip_cidr which fetches over HTTPS — that egress
# IP is wrong for users whose SSH traffic exits via a different path (split
# tunnel, VPN, etc.); they should set SSH_INGRESS_CIDR explicitly.
# Intentionally callable with no args (build-ami does so); silence SC2119/SC2120.
# shellcheck disable=SC2120
resolve_ssh_cidr() {
    local override="${1:-}"
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
    elif [[ -n "${SSH_INGRESS_CIDR:-}" ]]; then
        printf '%s' "$SSH_INGRESS_CIDR"
    else
        current_public_ip_cidr
    fi
}
