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

# provider_terminate_ids HANDLE... — terminate instances by id. No-op on
# empty args (bash 3.2: "$@" with zero args is safe, an empty array literal
# is not).
provider_terminate_ids() {
    [[ $# -eq 0 ]] && return 0
    aws_terminate_instances "$@" >/dev/null
}

# provider_cleanup_net NAME... — best-effort delete of each <NAME>-sg.
# Per-sandbox SGs are named this way by `up`. Failures are silent and
# expected: legacy sandboxes share the old SG (no -sg variant exists) and
# freshly-terminated instances still hold the SG via their ENI for ~60s.
provider_cleanup_net() {
    local n
    for n in "$@"; do
        _aws ec2 delete-security-group --group-name "${n}-sg" 2>/dev/null \
            && log_info "deleted SG ${n}-sg" || true
    done
}

# Returns the display STATE for a sandbox combining AWS state + status checks.
# Values: pending | initializing | ready | impaired | running | stopping |
#         stopped | shutting-down | terminated
compute_display_state() {
    local state="$1" inst_status="$2" sys_status="$3"
    if [[ "$state" != "running" ]]; then
        printf '%s' "$state"
        return
    fi
    if [[ "$inst_status" == "ok" && "$sys_status" == "ok" ]]; then
        printf '%s' "ready"
    elif [[ "$inst_status" == "impaired" || "$sys_status" == "impaired" ]]; then
        printf '%s' "impaired"
    elif [[ "$inst_status" == "initializing" || "$sys_status" == "initializing" || -z "$inst_status" || -z "$sys_status" ]]; then
        printf '%s' "initializing"
    else
        # All checks present and neither ok nor initializing nor impaired
        # (e.g. insufficient-data, not-applicable) — fall back to plain "running".
        printf '%s' "running"
    fi
}

# provider_list — emit one normalized TSV row per Project=claude-sandbox
# instance (any state), 9 tab-separated fields in this exact order:
#   handle  name  state  type  market  launch_epoch  ip  allowed_cidr  ash_hours
# "-" for any absent field. `state` is resolved via compute_display_state;
# `launch_epoch` is a unix timestamp converted from AWS's LaunchTime.
#
# Include shutting-down + terminated so users can watch the full lifecycle
# after `sandbox down`. AWS purges terminated instances after ~1 hour, so
# they don't accumulate forever.
provider_list() {
    local json
    json="$(aws_describe_instances_by_tag Project claude-sandbox \
        'pending,running,stopping,stopped,shutting-down,terminated')"
    local count
    count="$(printf '%s' "$json" | jq '[.Reservations[].Instances[]] | length')"
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    # Get instance-status for every running instance in one batch call.
    local running_ids=()
    while IFS= read -r rid; do
        [[ -z "$rid" ]] && continue
        running_ids+=("$rid")
    done < <(printf '%s' "$json" | jq -r '.Reservations[].Instances[] | select(.State.Name=="running") | .InstanceId')

    local status_json
    if [[ ${#running_ids[@]} -gt 0 ]]; then
        status_json="$(aws_describe_instance_status_for "${running_ids[@]}")"
    else
        status_json='{"InstanceStatuses":[]}'
    fi

    # Collect every SG ID across all instances so we can batch-fetch ingress
    # rules in one call and look them up per-instance in jq below.
    local sg_ids=()
    while IFS= read -r sg; do
        [[ -z "$sg" ]] && continue
        sg_ids+=("$sg")
    done < <(printf '%s' "$json" | jq -r '[.Reservations[].Instances[].SecurityGroups[]?.GroupId] | unique[]')

    local sg_json
    if [[ ${#sg_ids[@]} -gt 0 ]]; then
        sg_json="$(aws_describe_sgs_by_ids "${sg_ids[@]}")"
    else
        sg_json='{"SecurityGroups":[]}'
    fi

    local now_epoch; now_epoch="$(date -u +%s)"
    # Join instance data with status data + SG ingress in jq. allowed_cidr
    # shows the first :22 CIDR found across the instance's SGs; "-" if none
    # configured.
    printf '%s' "$json" | jq -r --argjson statuses "$status_json" --argjson sgs "$sg_json" '
        ($statuses.InstanceStatuses // [] | INDEX(.InstanceId)) as $sm |
        ($sgs.SecurityGroups // [] | INDEX(.GroupId)) as $sgm |
        .Reservations[].Instances[] |
        [
            .InstanceId,
            ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // .InstanceId),
            .State.Name,
            .InstanceType,
            .LaunchTime,
            (.PublicIpAddress // "-"),
            ($sm[.InstanceId].InstanceStatus.Status // "-"),
            ($sm[.InstanceId].SystemStatus.Status // "-"),
            ([
                .SecurityGroups[]?.GroupId
                | $sgm[.]?
                | (.IpPermissions[]? | select(.IpProtocol=="tcp" and .FromPort==22) | .IpRanges[]?.CidrIp)
            ] | .[0] // "-"),
            ((.Tags // []) | map(select(.Key=="AutoShutdownHours")) | .[0].Value // "-"),
            (if .InstanceLifecycle=="spot" then "spot" else "on-demand" end)
        ] | @tsv
    ' | while IFS=$'\t' read -r handle name state type launch ip inst_status sys_status cidr shutdown_hours market; do
        # `read -r` with IFS=$'\t' treats runs of tabs as one separator (tab is
        # an IFS-whitespace char), so when both status fields are empty the
        # cidr column gets eaten. jq emits "-" placeholders to keep field
        # positions stable; translate back to "" here for compute_display_state.
        [[ "$inst_status" == "-" ]] && inst_status=""
        [[ "$sys_status" == "-" ]] && sys_status=""
        local launch_epoch
        launch_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${launch%.*}" "+%s" 2>/dev/null \
            || date -u -d "$launch" "+%s" 2>/dev/null || echo "$now_epoch")"
        local display_state
        display_state="$(compute_display_state "$state" "$inst_status" "$sys_status")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$handle" "$name" "$display_state" "$type" "$market" "$launch_epoch" "$ip" "$cidr" "$shutdown_hours"
    done
}
