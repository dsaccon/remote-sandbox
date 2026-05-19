#!/usr/bin/env bash
# test/smoke.sh — end-to-end on real AWS. Manual.
#
# Skips build-ami if AMI_ID is already set. Provisions a box, asserts
# claude+docker work, tears down.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
config_load

if [[ -z "${AMI_ID:-}" ]]; then
    log_info "no AMI_ID — running build-ami first (this takes ~10 minutes)"
    "$REPO_ROOT/bin/sandbox-build-ami"
    config_load
fi

NAME="smoke-$(openssl rand -hex 3)"

cleanup() {
    log_info "smoke cleanup: terminating $NAME"
    "$REPO_ROOT/bin/sandbox-down" "$NAME" || true
}
trap cleanup EXIT

log_info "provisioning $NAME (spot if available)..."
"$REPO_ROOT/bin/sandbox-up" --name "$NAME"

# up is non-blocking — poll list until our sandbox shows 'ready'.
log_info "waiting for $NAME to reach 'ready' (typically 60-120s)..."
ip=""
for i in {1..40}; do  # ~200s budget
    row="$("$REPO_ROOT/bin/sandbox-list" 2>/dev/null | awk -v n="$NAME" '$1==n')"
    state="$(echo "$row" | awk '{print $2}')"
    ip="$(echo "$row"   | awk '{print $5}')"
    case "$state" in
        ready)       break ;;
        impaired|stopped|stopping|terminated|shutting-down)
            log_err "sandbox $NAME reached unexpected state '$state' during smoke"
            exit 1
            ;;
    esac
    sleep 5
    [[ $i -eq 40 ]] && { log_err "sandbox $NAME never reached 'ready'"; exit 1; }
done

[[ -z "$ip" || "$ip" == "-" ]] && { log_err "no IP for $NAME (state was '$state')"; exit 1; }
log_info "$NAME ready at $ip"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
if [[ -n "${SSH_KEY_FILE:-}" && -r "$SSH_KEY_FILE" ]]; then
    ssh_opts+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
fi

log_info "asserting tools on $ip..."
ssh "${ssh_opts[@]}" "ubuntu@${ip}" 'set -e; claude --version; node --version; uv --version; nvim --version | head -1; docker run --rm hello-world >/dev/null && echo docker-ok'

log_info "smoke passed"
