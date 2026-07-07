#!/usr/bin/env bash
# lib/providers/gcp.sh — GCP (GCE) driver. All gcloud calls go through
# $GCLOUD_CMD so tests can stub it.
if [[ -n "${_SANDBOX_GCP_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_GCP_SH_LOADED=1
_gcp_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../log.sh
source "$_gcp_sh_dir/../log.sh"
# common.sh gives resolve_ssh_cidr (used by the bake); harmless if already loaded.
# shellcheck source=../common.sh
source "$_gcp_sh_dir/../common.sh"
_gcp_repo_bootstrap="$(cd "$_gcp_sh_dir/../.." && pwd)/ami/bootstrap.sh"

: "${GCLOUD_CMD:=gcloud}"
: "${GCP_IMAGE_FAMILY:=ubuntu-2404-lts-amd64}"
: "${GCP_IMAGE_PROJECT:=ubuntu-os-cloud}"
_gcloud() {
    : "${GCP_PROJECT:?_gcloud: GCP_PROJECT not set}"
    "$GCLOUD_CMD" --project "$GCP_PROJECT" "$@"
}

# gcp_validate_name NAME — enforce RFC1035 (GCE instance/firewall names).
gcp_validate_name() {
    local n="$1"
    [[ "$n" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
        || die "invalid --name '$n' for gcp: must be RFC1035 (lowercase, digits, hyphens; start with a letter; <=63 chars)"
}

provider_check_creds() {
    command -v "$GCLOUD_CMD" >/dev/null 2>&1 || die "gcloud not on PATH — install the Google Cloud SDK"
    [[ -n "${GCP_PROJECT:-}" ]] || die "GCP_PROJECT not set in ./config"
    if ! _gcloud compute images list --filter="name=nonexistent" >/dev/null 2>&1; then
        die "gcloud auth/project check failed — set GOOGLE_APPLICATION_CREDENTIALS and GCP_PROJECT"
    fi
}

provider_preflight() {
    provider_check_creds
    local pub="${GCP_SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
    [[ -r "$pub" ]] || die "SSH public key not readable: $pub (set GCP_SSH_PUBKEY)"
    if [[ -n "${GCP_IMAGE:-}" ]]; then
        _gcloud compute images describe "$GCP_IMAGE" >/dev/null 2>&1 \
            || die "GCP_IMAGE '$GCP_IMAGE' not found in project $GCP_PROJECT"
    fi
}

# _gcp_build_image — bake a custom GCP image with the same tooling as the AWS
# AMI (runs the same ami/bootstrap.sh). Writes GCP_IMAGE into ./config on
# success. Mirrors _aws_build_image. Uses $REPO_ROOT (set by bin/sandbox-build-ami)
# and $SSH_CMD/$SCP_CMD (stubbable in tests).
_gcp_build_image() {
    : "${SSH_CMD:=ssh}"
    : "${SCP_CMD:=scp}"
    : "${GCP_PROJECT:?build-ami: GCP_PROJECT not set}"
    : "${GCP_ZONE:?build-ami: GCP_ZONE not set}"
    : "${SSH_KEY_FILE:?build-ami: SSH_KEY_FILE not set}"
    local pub="${GCP_SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
    [[ -r "$pub" ]] || die "SSH public key not readable: $pub (set GCP_SSH_PUBKEY)"
    [[ -r "$SSH_KEY_FILE" ]] || die "SSH key file not readable: $SSH_KEY_FILE"

    provider_check_creds

    local bake_machine="e2-medium"
    # bake_name / kf / cleanup_on_failure are NOT local: the EXIT trap below
    # references them, and it fires after this function has returned (when its
    # locals would be out of scope, tripping `set -u`).
    bake_name="sandbox-bake-$(date -u +%Y%m%d-%H%M%S)"
    local cidr; cidr="$(resolve_ssh_cidr)"

    log_info "creating bake firewall ${bake_name}-fw (SSH from $cidr)"
    _gcloud compute firewall-rules create "${bake_name}-fw" \
        --network=default --direction=INGRESS --action=ALLOW \
        --rules=tcp:22 --source-ranges="$cidr" --target-tags="$bake_name" >/dev/null

    kf="$(mktemp)"
    printf '%s:%s\n' "${SSH_USER:-ubuntu}" "$(cat "$pub")" > "$kf"

    # Leave the VM + firewall up on failure so the bake can be debugged.
    cleanup_on_failure=1
    trap '
        rm -f "$kf"
        if [[ $cleanup_on_failure -eq 1 ]]; then
            log_warn "bake failed; leaving $bake_name up for debugging."
            _ip="$(_gcloud compute instances describe "$bake_name" --zone="$GCP_ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "?")"
            echo "  Debug:  ssh ${SSH_USER:-ubuntu}@${_ip}"
            echo "  Tear down:"
            echo "    gcloud compute instances delete $bake_name --zone $GCP_ZONE --project $GCP_PROJECT --quiet"
            echo "    gcloud compute firewall-rules delete ${bake_name}-fw --project $GCP_PROJECT --quiet"
        fi' EXIT

    log_info "launching bake VM ($bake_machine) as $bake_name..."
    _gcloud compute instances create "$bake_name" --zone="$GCP_ZONE" \
        --machine-type="$bake_machine" \
        --image-family="$GCP_IMAGE_FAMILY" --image-project="$GCP_IMAGE_PROJECT" \
        --tags="$bake_name" \
        --metadata-from-file="ssh-keys=$kf" \
        --format="value(name)" >/dev/null
    rm -f "$kf"

    local ip
    ip="$(_gcloud compute instances describe "$bake_name" --zone="$GCP_ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)")"
    log_info "bake VM IP: $ip"

    local ssh_opts=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10)

    log_info "waiting for SSH..."
    local i
    for i in $(seq 1 30); do
        if "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER:-ubuntu}@${ip}" true 2>/dev/null; then
            break
        fi
        sleep 5
        [[ "$i" -eq 30 ]] && die "SSH never came up on $ip"
    done

    log_info "uploading bootstrap files..."
    "$SCP_CMD" "${ssh_opts[@]}" \
        "$REPO_ROOT/ami/bootstrap.sh" \
        "$REPO_ROOT/ami/systemd/auto-shutdown.service" \
        "$REPO_ROOT/ami/systemd/auto-shutdown.timer" \
        "$REPO_ROOT/ami/xterm-ghostty.src" \
        "${SSH_USER:-ubuntu}@${ip}:/tmp/"

    log_info "running bootstrap (this can take 5-10 minutes)..."
    "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER:-ubuntu}@${ip}" \
        "DOTFILES_REPO='${DOTFILES_REPO:-}' CLAUDE_HARDENING_REPO='${CLAUDE_HARDENING_REPO:-}' bash /tmp/bootstrap.sh"

    # Stop before imaging: GCP can't image a disk attached to a running VM
    # (the analog of AWS's reboot-before-snapshot for a consistent disk).
    log_info "stopping bake VM to image its disk cleanly..."
    _gcloud compute instances stop "$bake_name" --zone="$GCP_ZONE" >/dev/null

    local img_name; img_name="claude-sandbox-$(date -u +%Y%m%d-%H%M%S)"
    log_info "creating image $img_name (family claude-sandbox)..."
    _gcloud compute images create "$img_name" \
        --source-disk="$bake_name" --source-disk-zone="$GCP_ZONE" \
        --family=claude-sandbox >/dev/null

    log_info "writing GCP_IMAGE into ./config"
    config_write_key GCP_IMAGE "$img_name"

    log_info "deleting bake VM + firewall..."
    _gcloud compute instances delete "$bake_name" --zone="$GCP_ZONE" --quiet >/dev/null
    _gcloud compute firewall-rules delete "${bake_name}-fw" --quiet >/dev/null 2>&1 || true

    cleanup_on_failure=0
    log_info "done. GCP_IMAGE=$img_name"
}

provider_build_image() { _gcp_build_image; }

# provider_list_images — normalized image records for GCP custom images in the
# claude-sandbox family, newest first (6 fields):
#   id  name  created_epoch  size_gb  current  in_use
# GCP images are name-addressed (id == name). Deleting an image doesn't affect
# already-running VMs, so in_use == current (the GCP_IMAGE in ./config).
provider_list_images() {
    local json current="${GCP_IMAGE:-}"
    json="$(_gcloud compute images list --filter="family=claude-sandbox" --format=json 2>/dev/null || echo '[]')"
    printf '%s' "$json" | jq -r '
        sort_by(.creationTimestamp) | reverse | .[] |
        [ .name, .name, .creationTimestamp, (.diskSizeGb // 0) ] | @tsv' \
    | while IFS=$'\t' read -r id name created size; do
        local epoch cur
        epoch="$(gcp_ts_to_epoch "$created")"
        cur=0; [[ -n "$current" && "$name" == "$current" ]] && cur=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$epoch" "$size" "$cur" "$cur"
    done
}

# provider_delete_image NAME — delete a GCP custom image.
provider_delete_image() {
    local name="$1"
    log_info "deleting image $name"
    _gcloud compute images delete "$name" --quiet >/dev/null
}

# gcp_render_startup NAME REPO -> startup-script text on stdout.
# No baked image: run ami/bootstrap.sh at first boot, then optional clone.
# Baked image (GCP_IMAGE set): just hostname + optional clone.
gcp_render_startup() {
    local name="$1" repo="$2"
    printf '#!/usr/bin/env bash\nset -e\nhostnamectl set-hostname %s || true\n' "$name"
    if [[ -z "${GCP_IMAGE:-}" ]]; then
        printf 'export DOTFILES_REPO=%q CLAUDE_HARDENING_REPO=%q\n' \
            "${DOTFILES_REPO:-}" "${CLAUDE_HARDENING_REPO:-}"
        cat "$_gcp_repo_bootstrap"     # ami/bootstrap.sh body, inlined
    fi
    # NB: an `[[ -n "$repo" ]] && printf ...` one-liner here would make this
    # function return the test's exit status (1) when $repo is empty — under the
    # caller's `set -e` that aborts provider_launch AFTER the firewall is created
    # but before the instance is launched. Use an explicit if so we always
    # return 0.
    if [[ -n "$repo" ]]; then
        printf 'sudo -u %s -i bash -c %q\n' "${SSH_USER:-ubuntu}" "git clone $repo"
    fi
}

provider_launch() {  # NAME REPO USE_SPOT CIDR -> instance name
    local name="$1" repo="$2" use_spot="$3" cidr="$4"
    local zone="$GCP_ZONE" hours="${AUTO_SHUTDOWN_HOURS:-0}"
    local pub="${GCP_SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
    local owner; owner="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"

    # per-sandbox firewall (global object, scoped by target tag)
    _gcloud compute firewall-rules create "${name}-fw" \
        --network=default --direction=INGRESS --action=ALLOW \
        --rules=tcp:22 --source-ranges="$cidr" --target-tags="$name" >/dev/null
    log_info "firewall: ${name}-fw  SSH ingress = $cidr"

    # metadata files: ssh-keys + startup-script. Capture prep/launch failures
    # (rc) instead of letting `set -e` abort mid-way, so a failed launch can roll
    # the firewall back rather than orphaning the <name>-fw rule.
    local kf sf rc=0
    kf="$(mktemp)"; sf="$(mktemp)"
    trap 'rm -f "$kf" "$sf"' RETURN
    { printf '%s:%s\n' "${SSH_USER:-ubuntu}" "$(cat "$pub")" > "$kf" \
        && gcp_render_startup "$name" "$repo" > "$sf"; } || rc=$?

    local args=(compute instances create "$name" --zone="$zone"
        --machine-type="${GCP_MACHINE_TYPE}"
        --boot-disk-size="${DISK_SIZE_GB:-64}GB"
        --tags="$name"
        --labels="project=claude-sandbox,name=$name"
        --metadata="owner=$owner,auto-shutdown-hours=$hours"
        --metadata-from-file="ssh-keys=$kf,startup-script=$sf"
        --format="value(name)")
    if [[ -n "${GCP_IMAGE:-}" ]]; then
        args+=(--image="$GCP_IMAGE")
    else
        args+=(--image-family="$GCP_IMAGE_FAMILY" --image-project="$GCP_IMAGE_PROJECT")
    fi
    [[ "$use_spot" == "true" ]] && args+=(--provisioning-model=SPOT)
    if [[ "$hours" -gt 0 ]]; then
        args+=(--max-run-duration="${hours}h" --instance-termination-action=DELETE)
    elif [[ "$use_spot" == "true" ]]; then
        args+=(--instance-termination-action=DELETE)   # clean up on preemption
    fi

    if [[ "$rc" -eq 0 ]]; then
        log_info "requesting gcp instance ($GCP_MACHINE_TYPE, spot=$use_spot)..."
        _gcloud "${args[@]}" || rc=$?
    fi

    if [[ "$rc" -ne 0 ]]; then
        log_warn "launch failed — rolling back firewall ${name}-fw"
        _gcloud compute firewall-rules delete "${name}-fw" --quiet >/dev/null 2>&1 || true
        return "$rc"
    fi
}

# gcp_ts_to_epoch RFC3339 -> unix epoch (best-effort; falls back to now).
gcp_ts_to_epoch() {
    local ts="$1"; ts="${ts//Z/+00:00}"
    local off="${ts: -6}" body="${ts:0:${#ts}-6}"
    body="${body%.*}"                       # strip fractional seconds
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "${body}${off/:/}" +%s 2>/dev/null \
        || date -d "${body}${off}" +%s 2>/dev/null \
        || date -u +%s
}

# gcp_map_state GCE_STATUS -> normalized state.
gcp_map_state() {
    case "$1" in
        PROVISIONING|STAGING) echo initializing ;;
        RUNNING)              echo ready ;;
        STOPPING)             echo stopping ;;
        TERMINATED)           echo stopped ;;
        *)                    echo running ;;
    esac
}

provider_list() {
    local inst fw
    inst="$(_gcloud compute instances list \
        --filter="labels.project=claude-sandbox" --zones="$GCP_ZONE" --format=json 2>/dev/null || echo '[]')"
    fw="$(_gcloud compute firewall-rules list \
        --filter="name~-fw$" --format=json 2>/dev/null || echo '[]')"
    # jq emits: name rawstatus machinetype market rawts ip ash allowed disk
    printf '%s' "$inst" | jq -r --argjson fw "$fw" '
        ($fw | map({(.targetTags[0] // ""): (.sourceRanges[0] // "-")}) | add // {}) as $cidr |
        .[] | [
            .name,
            .status,
            (.machineType | split("/") | last),
            (if .scheduling.provisioningModel=="SPOT" then "spot" else "on-demand" end),
            .creationTimestamp,
            (.networkInterfaces[0].accessConfigs[0].natIP // "-"),
            ((.metadata.items // [] | map(select(.key=="auto-shutdown-hours")) | .[0].value) // "-"),
            ($cidr[.name] // "-"),
            (.disks[0].diskSizeGb // "-")
        ] | @tsv
    ' | while IFS=$'\t' read -r name rawstatus mtype market rawts ip ash cidr disk; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$name" "$(gcp_map_state "$rawstatus")" "$mtype" "$market" \
            "$(gcp_ts_to_epoch "$rawts")" "$ip" "$cidr" "$ash" "$disk"
    done
}

provider_resolve_ip() {   # NAME -> IP or die
    local name="$1" json status ip
    json="$(_gcloud compute instances describe "$name" --zone="$GCP_ZONE" --format=json 2>/dev/null || true)"
    [[ -z "$json" ]] && die "no sandbox named $name in $GCP_ZONE (try ./bin/sandbox list)"
    status="$(printf '%s' "$json" | jq -r '.status // empty')"
    case "$status" in
        PROVISIONING|STAGING) die "sandbox $name is still booting (status: $status). Try again shortly." ;;
        STOPPING|TERMINATED)  die "sandbox $name is $status — halted or gone. Up a fresh one." ;;
        RUNNING) : ;;
        *) die "sandbox $name is in unexpected status '$status'" ;;
    esac
    ip="$(printf '%s' "$json" | jq -r '.networkInterfaces[0].accessConfigs[0].natIP // empty')"
    [[ -n "$ip" ]] || die "sandbox $name is running but has no external IP yet — check './bin/sandbox list'"
    printf '%s' "$ip"
}

provider_terminate_ids() {   # NAME...
    [[ $# -eq 0 ]] && return 0
    _gcloud compute instances delete "$@" --zone="$GCP_ZONE" --quiet >/dev/null
}

provider_cleanup_net() {     # NAME...
    local n
    for n in "$@"; do
        if _gcloud compute firewall-rules delete "${n}-fw" --quiet 2>/dev/null; then
            log_info "deleted firewall ${n}-fw"
        fi
    done
}
