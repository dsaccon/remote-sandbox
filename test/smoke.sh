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

NAME="smoke-$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c6)"

cleanup() {
    log_info "smoke cleanup: terminating $NAME"
    "$REPO_ROOT/bin/sandbox-down" "$NAME" || true
}
trap cleanup EXIT

log_info "provisioning $NAME (spot if available)..."
"$REPO_ROOT/bin/sandbox-up" --name "$NAME" >/tmp/sandbox-up.out
cat /tmp/sandbox-up.out

ip="$(awk '/ssh ubuntu@/ {sub("^.*@",""); print; exit}' /tmp/sandbox-up.out)"
[[ -z "$ip" ]] && { log_err "could not parse IP from sandbox-up output"; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

log_info "waiting for SSH on $ip..."
for i in {1..30}; do
    if ssh "${ssh_opts[@]}" "ubuntu@${ip}" true 2>/dev/null; then break; fi
    sleep 5
    [[ $i -eq 30 ]] && { log_err "SSH never came up"; exit 1; }
done

log_info "asserting tools..."
ssh "${ssh_opts[@]}" "ubuntu@${ip}" 'set -e; claude --version; node --version; uv --version; docker run --rm hello-world >/dev/null && echo docker-ok'

log_info "smoke passed"
