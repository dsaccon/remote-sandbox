#!/usr/bin/env bash
# lib/providers/aws.sh — AWS driver. Adapts the existing aws.sh/provision.sh
# helpers to the provider_* contract. Additive: sources them, adds wrappers.
if [[ -n "${_SANDBOX_PROVIDER_AWS_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVIDER_AWS_LOADED=1
_paws_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# provision.sh transitively sources log.sh, common.sh (Task 2), and aws.sh.
# shellcheck source=../provision.sh
source "$_paws_dir/../provision.sh"

# ---- provider contract (AWS) ----
provider_check_creds() { aws_caller_identity; }
provider_preflight()   { preflight_or_die; }
provider_launch()      { provision_launch "$1" "$2" "$3" "$4"; }   # -> instance id
provider_resolve_ip()  { aws_resolve_running_sandbox_ip "$1"; }
provider_build_image() { die "provider_build_image wired in Task 6"; }  # real impl in Task 6
