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
provider_build_image() { _aws_build_image; }

# provider_list_images — normalized image records for the caller's
# claude-sandbox-* AMIs, newest first, one tab-separated row each (6 fields):
#   id  name  created_epoch  size_gb  current  in_use
# current = the AMI_ID in ./config; in_use = current OR an AMI a non-terminated
# sandbox booted from (so --active never hides an AMI a live box depends on).
provider_list_images() {
    local json inst_json current="${AMI_ID:-}" in_use=" ${AMI_ID:-} " ami
    json="$(aws_describe_self_amis)"
    inst_json="$(aws_describe_instances_by_tag Project claude-sandbox \
        'pending,running,stopping,stopped,shutting-down' 2>/dev/null || echo '{}')"
    while IFS= read -r ami; do
        [[ -z "$ami" || "$ami" == "null" ]] && continue
        [[ "$in_use" == *" $ami "* ]] && continue
        in_use+="$ami "
    done < <(printf '%s' "$inst_json" | jq -r '.Reservations[]?.Instances[]?.ImageId' 2>/dev/null)

    printf '%s' "$json" | jq -r '
        .Images | sort_by(.CreationDate) | reverse | .[] |
        [ .ImageId, (.Name // "-"), .CreationDate,
          (((.BlockDeviceMappings // []) | map(select(.Ebs) | .Ebs.VolumeSize) | add) // 0)
        ] | @tsv' \
    | while IFS=$'\t' read -r id name created size; do
        local epoch cur used
        epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${created%.*}" "+%s" 2>/dev/null \
            || date -u -d "$created" "+%s" 2>/dev/null || echo 0)"
        cur=0; [[ -n "$current" && "$id" == "$current" ]] && cur=1
        used=0; [[ "$in_use" == *" $id "* ]] && used=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$epoch" "$size" "$cur" "$used"
    done
}

# provider_delete_image AMI_ID — deregister an AMI and delete its EBS snapshots.
# Capture snapshot IDs BEFORE deregister (after, the block-device info is gone).
provider_delete_image() {
    local ami="$1" snaps snap
    snaps="$(aws_image_snapshot_ids "$ami" 2>/dev/null || true)"
    if [[ -z "$snaps" || "$snaps" == "None" ]]; then
        log_warn "$ami: no snapshot found (already deleted, or AMI doesn't exist)"
    fi
    log_info "deregistering $ami"
    aws_deregister_image "$ami"
    for snap in $snaps; do
        [[ -z "$snap" || "$snap" == "None" ]] && continue
        log_info "deleting snapshot $snap"
        aws_delete_snapshot "$snap"
    done
}

# _aws_build_image — bake a fresh AMI (formerly bin/sandbox-build-ami's body,
# moved here verbatim in Task 6; AWS-specific end to end). Relies on
# REPO_ROOT, config_load's exports, and helpers from aws.sh/provision.sh/
# common.sh, all already in scope by the time provider_load has run.
_aws_build_image() {
    : "${SSH_CMD:=ssh}"
    : "${SCP_CMD:=scp}"

    BAKE_INSTANCE_TYPE="t3.medium"

    aws_caller_identity
    aws_describe_key_pair "$SSH_KEY_NAME"

    # Ensure SG and SSH ingress to current IP. Bake VMs share the legacy
    # `claude-sandbox-sg`; only the per-sandbox `up` path creates dedicated SGs.
    sg_id="$(ensure_sg)"
    cidr="$(resolve_ssh_cidr)"
    log_info "security group: $sg_id; SSH ingress = $cidr"
    aws_set_sg_ingress_to "$sg_id" "$cidr"

    log_info "finding latest Ubuntu 24.04 amd64 AMI..."
    base_ami="$(aws_describe_ubuntu_2404_ami)"
    [[ "$base_ami" == ami-* ]] || die "could not find Ubuntu base AMI"
    log_info "base AMI: $base_ami"

    bake_name="sandbox-bake-$(date -u +%Y%m%dT%H%M%SZ)"
    log_info "launching bake VM ($BAKE_INSTANCE_TYPE) as $bake_name..."
    instance_id="$(aws_run_simple "$base_ami" "$BAKE_INSTANCE_TYPE" "$SSH_KEY_NAME" "$sg_id" "$bake_name")"
    log_info "bake VM: $instance_id"

    # Cleanup-on-failure trap leaves the instance up so the user can debug.
    cleanup_on_failure=1
    trap '
        if [[ $cleanup_on_failure -eq 1 ]]; then
            log_warn "bake failed; leaving $instance_id running for debugging."
            ip="$(aws_get_instance_ip "$instance_id" 2>/dev/null || echo "?")"
            echo "  Debug:  ssh ${SSH_USER}@${ip}"
            echo "  Tear down when done:  ./bin/sandbox down $instance_id"
        fi' EXIT

    wait_with_progress "bake VM $instance_id launched; waiting for status checks (60-90s)" \
        aws_wait_running "$instance_id"
    ip="$(aws_get_instance_ip "$instance_id")"
    log_info "bake VM IP: $ip"

    : "${SSH_KEY_FILE:?build-ami: SSH_KEY_FILE not set (should default in config_load)}"
    [[ -r "$SSH_KEY_FILE" ]] || die "SSH key file not readable: $SSH_KEY_FILE"
    ssh_opts=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
              -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR -o ConnectTimeout=10)

    # Public IP can change between the early SG setup and now (2-3 min on cell
    # tether / VPN / IP-rotating ISPs). Re-check and refresh ingress so SSH
    # doesn't silently time out for the next 7 minutes. If SSH_INGRESS_CIDR is
    # pinned in config, resolve_ssh_cidr just returns it both times — no-op.
    new_cidr="$(resolve_ssh_cidr)"
    if [[ "$new_cidr" != "$cidr" ]]; then
        log_warn "public IP changed during launch ($cidr → $new_cidr); refreshing SG"
        aws_set_sg_ingress_to "$sg_id" "$new_cidr"
        cidr="$new_cidr"
    fi

    log_info "waiting for SSH..."
    for i in {1..30}; do
        if "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER}@${ip}" true 2>/dev/null; then
            break
        fi
        sleep 5
        [[ $i -eq 30 ]] && die "SSH never came up on $ip"
    done

    log_info "uploading bootstrap files..."
    "$SCP_CMD" "${ssh_opts[@]}" \
        "$REPO_ROOT/ami/bootstrap.sh" \
        "$REPO_ROOT/ami/systemd/auto-shutdown.service" \
        "$REPO_ROOT/ami/systemd/auto-shutdown.timer" \
        "$REPO_ROOT/ami/xterm-ghostty.src" \
        "${SSH_USER}@${ip}:/tmp/"

    log_info "running bootstrap (this can take 5-10 minutes)..."
    "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER}@${ip}" \
        "DOTFILES_REPO='${DOTFILES_REPO:-}' CLAUDE_HARDENING_REPO='${CLAUDE_HARDENING_REPO:-}' bash /tmp/bootstrap.sh"

    ami_name="claude-sandbox-$(date -u +%Y%m%dT%H%M%SZ)"
    log_info "creating image $ami_name..."
    new_ami="$(aws_create_image "$instance_id" "$ami_name")"
    wait_with_progress "new AMI $new_ami (snapshot finalizing — typically 4-10 min)" \
        aws_wait_image_available "$new_ami"

    log_info "writing AMI_ID into ./config"
    config_write_ami_id "$new_ami"

    log_info "terminating bake VM..."
    aws_terminate_instances "$instance_id" >/dev/null

    cleanup_on_failure=0
    log_info "done. AMI_ID=$new_ami"
}

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
        if _aws ec2 delete-security-group --group-name "${n}-sg" 2>/dev/null; then
            log_info "deleted SG ${n}-sg"
        fi
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

    # Root-volume sizes: describe-instances carries only volume IDs, so batch
    # every instance's root volume ID into one describe-volumes call for size.
    local vol_ids=()
    while IFS= read -r vid; do
        [[ -z "$vid" || "$vid" == "null" ]] && continue
        vol_ids+=("$vid")
    done < <(printf '%s' "$json" | jq -r '
        .Reservations[].Instances[]
        | (.RootDeviceName) as $rdn
        | [.BlockDeviceMappings[]? | select(.DeviceName==$rdn) | .Ebs.VolumeId] | .[0] // empty')

    # Default to empty (→ disk "-") so a describe-volumes failure (e.g. no
    # ec2:DescribeVolumes permission) degrades gracefully instead of breaking
    # the whole listing via an invalid --argjson.
    local vol_json='{"Volumes":[]}' _vj
    if [[ ${#vol_ids[@]} -gt 0 ]]; then
        if _vj="$(aws_describe_volumes "${vol_ids[@]}" 2>/dev/null)" && [[ -n "$_vj" ]]; then
            vol_json="$_vj"
        fi
    fi

    local now_epoch; now_epoch="$(date -u +%s)"
    # Join instance data with status data + SG ingress in jq. allowed_cidr
    # shows the first :22 CIDR found across the instance's SGs; "-" if none
    # configured.
    printf '%s' "$json" | jq -r --argjson statuses "$status_json" --argjson sgs "$sg_json" --argjson vols "$vol_json" '
        ($statuses.InstanceStatuses // [] | INDEX(.InstanceId)) as $sm |
        ($sgs.SecurityGroups // [] | INDEX(.GroupId)) as $sgm |
        ($vols.Volumes // [] | INDEX(.VolumeId)) as $vm |
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
            (if .InstanceLifecycle=="spot" then "spot" else "on-demand" end),
            (
                (.RootDeviceName) as $rdn
                | ([.BlockDeviceMappings[]? | select(.DeviceName==$rdn) | .Ebs.VolumeId] | .[0]) as $rvid
                | ($vm[($rvid // "")].Size // "-")
            )
        ] | @tsv
    ' | while IFS=$'\t' read -r handle name state type launch ip inst_status sys_status cidr shutdown_hours market disk; do
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$handle" "$name" "$display_state" "$type" "$market" "$launch_epoch" "$ip" "$cidr" "$shutdown_hours" "$disk"
    done
}
