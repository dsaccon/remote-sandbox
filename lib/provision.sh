#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers. Other tasks add to this file.

if [[ -n "${_SANDBOX_PROVISION_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVISION_SH_LOADED=1

_provision_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_provision_repo_root="$(cd "$_provision_sh_dir/.." && pwd)"

# shellcheck source=log.sh
source "$_provision_sh_dir/log.sh"

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
