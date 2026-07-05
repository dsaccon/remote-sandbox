#!/usr/bin/env bash
# lib/provider.sh — select and load the cloud driver named by $CLOUD, and
# expose the provider_* contract. Call provider_load AFTER config_load.
if [[ -n "${_SANDBOX_PROVIDER_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVIDER_SH_LOADED=1
_provider_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_provider_sh_dir/log.sh"
# shellcheck source=common.sh
source "$_provider_sh_dir/common.sh"

# provider_load — source the driver for $CLOUD. Call after config_load.
provider_load() {
    local cloud="${CLOUD:-aws}"
    case "$cloud" in
        aws) # shellcheck source=providers/aws.sh
             source "$_provider_sh_dir/providers/aws.sh" ;;
        gcp) # shellcheck source=providers/gcp.sh
             source "$_provider_sh_dir/providers/gcp.sh" ;;
        *)   die "unknown CLOUD '$cloud' (supported: aws, gcp)" ;;
    esac
}
