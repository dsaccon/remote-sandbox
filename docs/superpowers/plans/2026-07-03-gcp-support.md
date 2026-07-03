# GCP Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Google Cloud (GCE) backend to `remote-sandbox` — `up`/`down`/`list`/`ssh`/`scp`/`spot` selectable with `CLOUD=gcp` — behind a driver-based provider seam, without changing AWS behavior.

**Architecture:** Introduce `lib/provider.sh` (dispatch on `$CLOUD`) → `lib/providers/{aws,gcp}.sh` drivers implementing a shared `provider_*` contract, plus `lib/common.sh` for cloud-agnostic helpers. `list`/`down` consume a normalized TSV record so cloud-specific JSON never leaves a driver. Phase 1 is a behavior-preserving refactor that moves today's AWS code behind the seam (AWS stays green throughout); Phase 2 adds the GCP driver; Phase 3 wires docs/setup.

**Tech Stack:** Bash (3.2-clean), `aws` CLI, `gcloud` CLI, `jq`, `bats-core` (tests), `shellcheck` (lint). Both run in the sandbox, not the laptop.

## Global Constraints

- **Bash 3.2-clean** — the laptop default; no bash-4 features (no associative arrays, `${x^^}`, etc.). Existing scripts are 3.2-clean; keep them so.
- **`make lint` (shellcheck) stays clean** across all new/modified files.
- **AWS behavior is unchanged** — every existing `test/unit/*.bats` assertion must still pass (source paths in tests may move, assertions may not).
- **No new laptop dependencies** beyond the `gcloud` CLI (the GCP control-plane analog of the already-required `aws` CLI).
- **External-command seams** — every cloud call goes through `$AWS_CMD` / `$GCLOUD_CMD` (default `aws` / `gcloud`) so bats can stub it. Same pattern for `$SSH_CMD`/`$SCP_CMD`/`$CURL_CMD`.
- **GCP naming** — instance names, firewall-rule names: RFC1035 (`^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$`). Label values: `^[a-z0-9_-]{0,63}$`. Validate `--name` when `CLOUD=gcp`; put non-label-legal values (`owner`, timestamps) in metadata.
- **Config precedence** (unchanged): CLI flag → `SANDBOX_*` env → `./config` → built-in default.

## Provider contract (implemented by every driver)

Defined conceptually in Task 3; each function lives in the driver. `bin/` calls only these.

| Function | Signature → output |
|---|---|
| `provider_preflight` | `()` → validates creds/CLI/config; `die` on failure |
| `provider_launch` | `(NAME REPO USE_SPOT CIDR)` → prints instance handle (id) on stdout |
| `provider_list` | `()` → normalized TSV rows (schema below) on stdout |
| `provider_resolve_ip` | `(NAME)` → public IP on stdout; `die` with state-specific message |
| `provider_terminate_ids` | `(HANDLE...)` → terminate/delete by handle |
| `provider_cleanup_net` | `(NAME...)` → delete per-sandbox SG/firewall; best-effort, silent |
| `provider_build_image` | `()` → AWS bakes; GCP `die`s "not yet supported" |

**Normalized `provider_list` record** — one tab-separated row per box, fields in this exact order, `-` for any absent field:

```
handle  name  state  type  market  launch_epoch  ip  allowed_cidr  ash_hours
```

- `handle`: the provider's terminate handle — AWS `i-…` instance id; GCP instance name.
- `state`: normalized enum `pending|initializing|ready|impaired|running|stopping|stopped|shutting-down|terminated`.
- `market`: `spot|on-demand`.
- `launch_epoch`: unix epoch (driver converts its own timestamp format).
- `ash_hours`: the auto-shutdown-hours tag/metadata value, or `-`.

---

# Phase 1 — Provider seam (behavior-preserving; AWS stays green)

### Task 1: GCP config keys

**Files:**
- Modify: `lib/config.sh` (the `_CONFIG_KEYS` array and `_config_default` case)
- Test: `test/unit/config.bats`

**Interfaces:**
- Produces: config vars `GCP_PROJECT`, `GCP_ZONE`, `GCP_IMAGE`, `GCP_MACHINE_TYPE`, `GCP_SSH_PUBKEY` (exported by `config_load`), plus the already-present `CLOUD`.

- [ ] **Step 1: Write the failing test** — add to `test/unit/config.bats`:

```bash
@test "config_load defaults the GCP keys" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$GCP_ZONE" = "us-west1-b" ]
    [ "$GCP_MACHINE_TYPE" = "e2-standard-4" ]
    [ "$GCP_PROJECT" = "" ]
    [ "$GCP_IMAGE" = "" ]
    [ "$GCP_SSH_PUBKEY" = "" ]
}

@test "config_load lets env override a GCP key" {
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    SANDBOX_GCP_PROJECT="my-proj" source "$SANDBOX_REPO_ROOT/lib/config.sh"
    SANDBOX_GCP_PROJECT="my-proj" config_load
    [ "$GCP_PROJECT" = "my-proj" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "$SANDBOX_REPO_ROOT_OF_REPO" && bats test/unit/config.bats`
Expected: FAIL — `GCP_ZONE: unbound variable` / empty.

- [ ] **Step 3: Implement** — in `lib/config.sh`, add the keys to `_CONFIG_KEYS` (after `CLOUD`):

```bash
_CONFIG_KEYS=(
    CLOUD
    GCP_PROJECT
    GCP_ZONE
    GCP_IMAGE
    GCP_MACHINE_TYPE
    GCP_SSH_PUBKEY
    AWS_REGION
    INSTANCE_TYPE
    # ...rest unchanged...
)
```

and add cases to `_config_default`:

```bash
        CLOUD)                    echo "aws" ;;
        GCP_PROJECT)              echo "" ;;
        GCP_ZONE)                 echo "us-west1-b" ;;
        GCP_IMAGE)                echo "" ;;
        GCP_MACHINE_TYPE)         echo "e2-standard-4" ;;
        GCP_SSH_PUBKEY)           echo "" ;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats test/unit/config.bats`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add lib/config.sh test/unit/config.bats
git commit -m "config: add GCP keys (project, zone, image, machine-type, ssh-pubkey)"
```

---

### Task 2: Extract `lib/common.sh` (cloud-agnostic helpers)

Move the three provider-neutral helpers out of `lib/provision.sh` so both drivers can share them. `provision.sh` keeps working by sourcing `common.sh` (it is deleted in Task 3).

**Files:**
- Create: `lib/common.sh`
- Modify: `lib/provision.sh` (remove the 3 functions; source `common.sh` at top)
- Test: `test/unit/cloud-init.bats` (source `common.sh` instead of `provision.sh`)

**Interfaces:**
- Produces: `render_cloud_init NAME REPO HOURS`, `resolve_ssh_cidr [OVERRIDE]`, `current_public_ip_cidr` — identical signatures/behavior to today.

- [ ] **Step 1: Create `lib/common.sh`** with the source-guard + these three functions moved verbatim from `lib/provision.sh` (lines 18–71: `render_cloud_init`, `current_public_ip_cidr`, `resolve_ssh_cidr`, and the `: "${CURL_CMD:=curl}"` line). Header:

```bash
#!/usr/bin/env bash
# lib/common.sh — cloud-agnostic helpers shared by all provider drivers.
if [[ -n "${_SANDBOX_COMMON_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_COMMON_SH_LOADED=1
_common_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_common_repo_root="$(cd "$_common_sh_dir/.." && pwd)"
# shellcheck source=log.sh
source "$_common_sh_dir/log.sh"

: "${CURL_CMD:=curl}"

# render_cloud_init NAME REPO_URL AUTO_SHUTDOWN_HOURS  → rendered YAML on stdout.
# (body copied verbatim from provision.sh; uses $_common_repo_root for the tmpl path)
```

Note: `render_cloud_init` references `$_provision_repo_root` for the template path — rename that to `$_common_repo_root` in the moved copy.

- [ ] **Step 2: Trim `lib/provision.sh`** — delete the three moved functions and the `: "${CURL_CMD:=curl}"` line; add `source "$_provision_sh_dir/common.sh"` right after it sources `log.sh`.

- [ ] **Step 3: Point `cloud-init.bats` at common.sh** — change its `setup()` source line:

```bash
    source "$REPO_ROOT/lib/common.sh"
```

- [ ] **Step 4: Run tests**

Run: `bats test/unit/cloud-init.bats test/unit/preflight.bats`
Expected: PASS (render_cloud_init from common.sh; preflight still finds resolve_ssh_cidr via provision.sh→common.sh).

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh lib/provision.sh test/unit/cloud-init.bats
git commit -m "refactor: extract cloud-agnostic helpers into lib/common.sh"
```

---

### Task 3: Provider dispatch + AWS driver

Relocate the AWS code behind the seam. This is a **move**, not a rewrite: `git mv` the file and absorb `provision.sh`'s AWS-specific functions, then add the thin `provider_*` wrappers. `provider_list`/`terminate`/`cleanup` normalization is Tasks 4–5; here we cover `preflight`, `launch`, `resolve_ip`, `build_image`.

**Files:**
- Rename: `lib/aws.sh` → `lib/providers/aws.sh`
- Modify: `lib/providers/aws.sh` (fix internal `source log.sh` path; absorb AWS funcs from provision.sh; add `provider_*` wrappers)
- Create: `lib/provider.sh`
- Delete: `lib/provision.sh`
- Test: `test/unit/aws.bats`, `test/unit/preflight.bats`, `test/unit/build-ami.bats` (source-path updates); create `test/unit/provider.bats`

**Interfaces:**
- Consumes: `lib/common.sh` (Task 2), `lib/config.sh` (`$CLOUD`).
- Produces: `lib/provider.sh` exposing all `provider_*` (contract table above). AWS driver implements `provider_preflight`, `provider_launch NAME REPO USE_SPOT CIDR`, `provider_resolve_ip NAME`, `provider_build_image`, plus keeps its existing `aws_*` internals and the `$AWS_CMD`/`_aws` seam.

- [ ] **Step 1: Move the file**

```bash
mkdir -p lib/providers
git mv lib/aws.sh lib/providers/aws.sh
```

Then in `lib/providers/aws.sh` fix the log source path (it's now one level deeper):

```bash
_aws_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../log.sh
source "$_aws_sh_dir/../log.sh"
```

- [ ] **Step 2: Absorb the AWS provisioning functions** — move these from `lib/provision.sh` into `lib/providers/aws.sh` verbatim: `preflight_or_die`, `ensure_sg`, `build_run_instances_json`, `provision_launch`, `_run_instances`. (They already call `aws_*` and `$AWS_CMD`.) `lib/provision.sh` is now empty of logic.

- [ ] **Step 3: Add the `provider_*` wrappers** at the bottom of `lib/providers/aws.sh`:

```bash
# ---- provider contract (AWS) ----
provider_preflight() { preflight_or_die; }

provider_launch() {  # NAME REPO USE_SPOT CIDR -> instance id
    provision_launch "$1" "$2" "$3" "$4"
}

provider_resolve_ip() { aws_resolve_running_sandbox_ip "$1"; }

provider_build_image() { _aws_build_image; }   # defined in Task 6 (moves sandbox-build-ami body); for now:
# provider_build_image is wired in Task 6. Leave a stub that dies until then:
```

Note for the implementer: keep `provider_build_image` as `_aws_build_image` and implement it in Task 6 when `sandbox-build-ami` is refactored. Until then define:

```bash
provider_build_image() { die "provider_build_image not wired yet"; }
```

- [ ] **Step 4: Create `lib/provider.sh` (dispatch)**

```bash
#!/usr/bin/env bash
# lib/provider.sh — select and load the cloud driver named by $CLOUD, and
# expose the provider_* contract. Source AFTER config_load (needs $CLOUD).
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
```

- [ ] **Step 5: Update existing tests' source paths**
  - `test/unit/aws.bats`: `source "$REPO_ROOT/lib/providers/aws.sh"`
  - `test/unit/preflight.bats`: copy `lib/{log,config,common}.sh` + `lib/providers/aws.sh`; source `lib/providers/aws.sh` (for `preflight_or_die`/`ensure_sg`).
  - `test/unit/build-ami.bats`: copy `lib/{log,config,common}.sh` + `lib/providers/aws.sh` (drop `provision`).

- [ ] **Step 6: Write `test/unit/provider.bats`** (dispatch behavior):

```bash
#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    source "$REPO_ROOT/lib/provider.sh"
}
@test "provider_load dies on unknown CLOUD" {
    CLOUD="azure"
    run provider_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown CLOUD"* ]]
}
@test "provider_load sources the aws driver and defines provider_preflight" {
    CLOUD="aws"
    provider_load
    declare -F provider_preflight >/dev/null
    declare -F provider_launch >/dev/null
}
```

- [ ] **Step 7: Delete the empty shim**

```bash
git rm lib/provision.sh
```

- [ ] **Step 8: Run the full suite**

Run: `bats test/unit/`
Expected: PASS — `aws.bats`, `preflight.bats`, `build-ami.bats`, new `provider.bats` green. (bin scripts still source `lib/aws.sh` — fixed in Tasks 4–6; run `make lint` is deferred until then.)

Note: because bin scripts still `source lib/aws.sh` (now gone) they are temporarily broken between Task 3 and Task 6. That's acceptable inside Phase 1 as long as each *task's tests* pass; do not run `make smoke` until Phase 1 completes. If you prefer green bin scripts at every step, do Tasks 3–6 as one commit.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: introduce provider seam + AWS driver (lib/provider.sh, lib/providers/aws.sh)"
```

---

### Task 4: Normalize `provider_list` (AWS) and refactor `sandbox-list`

Move the AWS-shaped list logic (status-check batching, SG-ingress batching, `compute_display_state`) into the AWS driver's `provider_list`, which emits the normalized TSV. `sandbox-list` becomes provider-agnostic: format age/EXPIRES, apply `--active`, print columns.

**Files:**
- Modify: `lib/providers/aws.sh` (add `provider_list`; move `compute_display_state` in from sandbox-list)
- Modify: `bin/sandbox-list` (source `provider.sh`; consume normalized TSV)
- Test: `test/unit/list.bats` (copy new lib layout)

**Interfaces:**
- Produces: `provider_list` emitting the normalized record (schema above). `compute_display_state STATE INST_STATUS SYS_STATUS` now lives in the AWS driver.

- [ ] **Step 1: Update `list.bats` setup** to copy the new layout and keep the existing three assertions:

```bash
    mkdir -p "$SANDBOX_REPO_ROOT/lib/providers"
    cp "$REPO_ROOT"/lib/{log,config,common,provider}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/lib/providers/aws.sh" "$SANDBOX_REPO_ROOT/lib/providers/"
    cp "$REPO_ROOT/bin/sandbox-list" "$SANDBOX_REPO_ROOT/bin/"
```

Keep the existing three tests unchanged (they assert `sandbox-list` output: header, `initializing` for status-less running, `spot`/`on-demand`).

- [ ] **Step 2: Run to verify failure**

Run: `bats test/unit/list.bats`
Expected: FAIL — `sandbox-list` still sources `lib/aws.sh` (gone).

- [ ] **Step 3: Add `provider_list` to `lib/providers/aws.sh`.** Move `compute_display_state` from `bin/sandbox-list` into the driver, then implement `provider_list` by lifting the describe + status-batch + SG-batch + the jq join from today's `sandbox-list` (lines ~74–134), but emit the normalized 9-field TSV. Emit `launch_epoch` by converting `LaunchTime` inside the driver (reuse the `date -j -f … || date -d …` fallback). Field order: `handle name state type market launch_epoch ip allowed_cidr ash_hours`.

```bash
compute_display_state() { : ; }   # moved verbatim from sandbox-list

provider_list() {
    local json states='pending,running,stopping,stopped,shutting-down,terminated'
    json="$(aws_describe_instances_by_tag Project claude-sandbox "$states")"
    # ... existing running-id + SG-id batching from sandbox-list ...
    # Final jq emits raw fields; a bash while-loop converts state via
    # compute_display_state and LaunchTime→epoch, then prints the 9-field TSV.
}
```

(The implementer lifts the exact jq from `sandbox-list`; the only change is the output shape — TSV of the 9 normalized fields, with `state` already resolved via `compute_display_state` and `launch_epoch` numeric.)

- [ ] **Step 4: Rewrite `bin/sandbox-list`** to consume the normalized stream:

```bash
source "$REPO_ROOT/lib/provider.sh"
# ...arg parsing unchanged...
config_load
provider_load
provider_preflight   # aws: aws_caller_identity via preflight; see note
printf '%-22s %-14s %-18s %-10s %-10s %-8s %-16s %-18s\n' \
    NAME STATE TYPE MARKET AGE EXPIRES IP ALLOWED
now_epoch="$(date -u +%s)"
provider_list | while IFS=$'\t' read -r handle name state type market launch_epoch ip cidr ash; do
    age_sec=$(( now_epoch - launch_epoch ))
    # ...age formatting + EXPIRES from ash + age (unchanged logic)...
    if [[ "$only_active" -eq 1 && "$state" != "ready" ]]; then continue; fi
    printf '%-22s %-14s %-18s %-10s %-10s %-8s %-16s %-18s\n' \
        "$name" "$state" "$type" "$market" "$age" "$expires" "$ip" "$cidr"
done
```

Note: `provider_preflight` for `list` should be lightweight — for AWS it currently just needs `aws_caller_identity`. Keep `list`/`down` calling `aws_caller_identity` directly (it's cloud-neutral enough) OR add a cheap `provider_check_creds`. Simplest: keep `aws_caller_identity` for AWS list/down and have the GCP driver define a same-named no-op-ish cred check. Decide in Task 7; for now `list` calls `provider_check_creds` (add `provider_check_creds() { aws_caller_identity; }` to the AWS driver).

- [ ] **Step 5: Run tests + lint**

Run: `bats test/unit/list.bats && shellcheck bin/sandbox-list lib/providers/aws.sh`
Expected: PASS; empty "no sandboxes" case still prints its message (guard: if `provider_list` yields no rows, print `no sandboxes in $AWS_REGION`).

- [ ] **Step 6: Commit**

```bash
git add lib/providers/aws.sh bin/sandbox-list test/unit/list.bats
git commit -m "refactor: AWS provider_list emits normalized records; sandbox-list is provider-agnostic"
```

---

### Task 5: Normalize `down` onto `provider_list`

`sandbox-down` stops parsing EC2 JSON. It resolves targets and staleness against the normalized `provider_list`, then calls `provider_terminate_ids` + `provider_cleanup_net`.

**Files:**
- Modify: `lib/providers/aws.sh` (add `provider_terminate_ids`, `provider_cleanup_net`)
- Modify: `bin/sandbox-down`
- Test: `test/unit/down.bats` (new lib layout)

**Interfaces:**
- Consumes: `provider_list` (Task 4).
- Produces: `provider_terminate_ids HANDLE...` (AWS: `aws_terminate_instances`), `provider_cleanup_net NAME...` (AWS: delete `<name>-sg`).

- [ ] **Step 1: Update `down.bats` setup** to the new layout (copy `lib/{log,config,common,provider}.sh` + `lib/providers/aws.sh` + `bin/sandbox-down`). Keep existing assertions; adjust any that fed raw multi-call EC2 responses so they exercise the `provider_list`→terminate path (the stub returns the describe JSON `provider_list` issues, then the terminate call is asserted in `AWS_STUB_LOG`).

- [ ] **Step 2: Run to verify failure**

Run: `bats test/unit/down.bats`
Expected: FAIL (sources missing `lib/aws.sh`).

- [ ] **Step 3: Add driver functions** to `lib/providers/aws.sh`:

```bash
provider_terminate_ids() { [[ $# -eq 0 ]] && return 0; aws_terminate_instances "$@" >/dev/null; }
provider_cleanup_net() {
    local n
    for n in "$@"; do
        _aws ec2 delete-security-group --group-name "${n}-sg" 2>/dev/null \
            && log_info "deleted SG ${n}-sg" || true
    done
}
```

- [ ] **Step 4: Rewrite `bin/sandbox-down`** to use `provider_list`. Replace the three EC2-JSON branches (`--all`, `--stale`, single) with logic over the normalized stream. Sketch:

```bash
source "$REPO_ROOT/lib/provider.sh"
config_load; provider_load; provider_check_creds

rows="$(provider_list)"   # handle name state type market launch_epoch ip cidr ash
select_ids=(); select_names=()
case "$mode" in
  --all)   # every row whose state is a live/terminable one
     while IFS=$'\t' read -r h n s _; do
        [[ -z "$h" ]] && continue
        case "$s" in shutting-down|terminated) continue;; esac
        select_ids+=("$h"); select_names+=("$n")
     done <<< "$rows" ;;
  --stale) # rows older than threshold (now - launch_epoch >= threshold_sec)
     ... ;;
  *)       # single name or handle: match n==target or h==target
     ... ;;
esac
[[ ${#select_ids[@]} -eq 0 ]] && { log_info "nothing to terminate"; exit 0; }
provider_terminate_ids "${select_ids[@]}"
provider_cleanup_net "${select_names[@]}"
```

`parse_duration_to_seconds` stays in `sandbox-down` (cloud-neutral). The `^i-` direct-id branch is removed — targets resolve through `provider_list` (down only ever touches `Project=claude-sandbox` boxes). Preserve the "already shutting-down/terminated → nothing to do" message for a single target by checking its row's `state`.

- [ ] **Step 5: Run tests + lint**

Run: `bats test/unit/down.bats && shellcheck bin/sandbox-down lib/providers/aws.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/aws.sh bin/sandbox-down test/unit/down.bats
git commit -m "refactor: sandbox-down operates on normalized provider_list records"
```

---

### Task 6: Flip remaining bin scripts to `provider_*`

Point `up`, `ssh`, `scp`, `build-ami`, `list-amis`, `delete-ami` at the seam. Image commands `die` cleanly under `CLOUD=gcp`.

**Files:**
- Modify: `bin/sandbox-up`, `bin/sandbox-ssh`, `bin/sandbox-scp`, `bin/sandbox-build-ami`, `bin/sandbox-list-amis`, `bin/sandbox-delete-ami`
- Modify: `lib/providers/aws.sh` (implement `_aws_build_image` = today's `sandbox-build-ami` body; wire `provider_build_image`)
- Test: `test/unit/scp.bats`, `test/unit/build-ami.bats` (new layout)

**Interfaces:**
- Consumes: `provider_load`, `provider_preflight`, `provider_launch`, `provider_resolve_ip`, `provider_build_image`.

- [ ] **Step 1: `sandbox-ssh` + `sandbox-scp`** — replace:

```bash
source "$REPO_ROOT/lib/aws.sh"        # →  source "$REPO_ROOT/lib/provider.sh"
...
aws_caller_identity                   # →  provider_load; provider_check_creds
ip="$(aws_resolve_running_sandbox_ip "$name")"   # →  ip="$(provider_resolve_ip "$name")"
```

Everything else in these two scripts (cmux, key handling, the scp browser) is cloud-agnostic and unchanged.

- [ ] **Step 2: `sandbox-up`** — source `provider.sh`; after `config_load` add `provider_load`; replace `preflight_or_die` → `provider_preflight`, `provision_launch …` → `provider_launch "$NAME" "$REPO_URL" "$USE_SPOT_FINAL" "$ssh_cidr"`. `resolve_ssh_cidr` now comes from `common.sh` (via provider.sh). Keep the launch-summary output.

- [ ] **Step 3: `sandbox-build-ami`** — move its entire body into `_aws_build_image()` in `lib/providers/aws.sh` (it is AWS-specific end to end), and reduce `bin/sandbox-build-ami` to:

```bash
source "$REPO_ROOT/lib/provider.sh"
# ...--help unchanged...
config_load
provider_load
provider_build_image
```

Set `provider_build_image() { _aws_build_image; }` in the AWS driver (replacing the Task 3 stub).

- [ ] **Step 4: `sandbox-list-amis` + `sandbox-delete-ami`** — these are AWS-only. After `config_load`, guard:

```bash
config_load
if [[ "${CLOUD:-aws}" != "aws" ]]; then
    die "image management (list-amis/delete-ami) is only supported on aws (CLOUD=$CLOUD)"
fi
aws_caller_identity   # keep — source lib/providers/aws.sh directly here
```

(These two may continue to `source lib/providers/aws.sh` directly since they are AWS-specific; they don't need the dispatcher.)

- [ ] **Step 5: Update `scp.bats` + `build-ami.bats`** to the new lib layout (copy `lib/{log,config,common,provider}.sh` + `lib/providers/aws.sh`). Keep assertions.

- [ ] **Step 6: Run the whole suite + lint**

Run: `make lint && make test` (equivalently `shellcheck` all `.sh`/bin + `bats test/unit/`)
Expected: PASS. Phase 1 complete — AWS fully behind the seam, all tests green, lint clean.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: route all sandbox commands through the provider seam"
```

---

# Phase 2 — GCP driver

### Task 7: GCP driver skeleton — seam, preflight, name validation

**Files:**
- Create: `lib/providers/gcp.sh`
- Create: `test/unit/stubs/gcloud-empty`
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Produces: `$GCLOUD_CMD`/`_gcloud` seam; `provider_check_creds`, `provider_preflight`, `provider_build_image`, and helper `gcp_validate_name NAME`.

- [ ] **Step 1: Create the gcloud stub** `test/unit/stubs/gcloud-empty` (mirror `aws-empty`): logs argv to `$GCLOUD_STUB_LOG`, prints `$GCLOUD_STUB_RESPONSE` body, exits with its rc. Reuse the aws-empty structure exactly, renaming the env vars. `chmod +x`.

- [ ] **Step 2: Write failing tests** in `test/unit/gcp.bats`:

```bash
setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    source "$REPO_ROOT/lib/providers/gcp.sh"
    GCP_PROJECT="proj"; GCP_ZONE="us-west1-b"; SSH_USER="ubuntu"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "gcp_validate_name accepts RFC1035 names" {
    run gcp_validate_name sandbox-26bdd2af
    [ "$status" -eq 0 ]
}
@test "gcp_validate_name rejects uppercase/underscore" {
    run gcp_validate_name My_Box
    [ "$status" -ne 0 ]
    [[ "$output" == *"RFC1035"* ]]
}
@test "provider_preflight dies when GCP_PROJECT empty" {
    GCP_PROJECT=""
    run provider_preflight
    [ "$status" -ne 0 ]
    [[ "$output" == *"GCP_PROJECT"* ]]
}
@test "provider_build_image is unsupported on gcp" {
    run provider_build_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"not yet supported"* ]]
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bats test/unit/gcp.bats`
Expected: FAIL — `gcp.sh` not found.

- [ ] **Step 4: Implement the skeleton** `lib/providers/gcp.sh`:

```bash
#!/usr/bin/env bash
# lib/providers/gcp.sh — GCP (GCE) driver. All gcloud calls go through
# $GCLOUD_CMD so tests can stub it.
if [[ -n "${_SANDBOX_GCP_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_GCP_SH_LOADED=1
_gcp_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../log.sh
source "$_gcp_sh_dir/../log.sh"

: "${GCLOUD_CMD:=gcloud}"
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

provider_build_image() {
    die "image baking not yet supported on gcp — bake out-of-band and set GCP_IMAGE (see docs)"
}
```

- [ ] **Step 5: Run tests + lint**

Run: `bats test/unit/gcp.bats && shellcheck lib/providers/gcp.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats test/unit/stubs/gcloud-empty
git commit -m "gcp: driver skeleton — seam, preflight, name validation, build-image guard"
```

---

### Task 8: GCP `provider_launch`

**Files:**
- Modify: `lib/providers/gcp.sh`
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Consumes: `render_cloud_init` (common.sh) for the baked-image path; `ami/bootstrap.sh` for the no-bake startup-script.
- Produces: `provider_launch NAME REPO USE_SPOT CIDR` → prints instance name (the GCP handle) on stdout; creates firewall rule `<name>-fw`.

- [ ] **Step 1: Write failing tests** (assert the firewall create, the instance create, and the conditional flags land in `$GCLOUD_STUB_LOG`):

```bash
@test "provider_launch creates a per-sandbox firewall rule and an instance" {
    set_response 0 ''    # gcloud calls succeed, empty output
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=0
    run provider_launch sandbox-abc "" false "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'compute firewall-rules create sandbox-abc-fw' "$GCLOUD_STUB_LOG"
    grep -q -- 'source-ranges=1.2.3.4/32' "$GCLOUD_STUB_LOG"
    grep -q -- 'target-tags=sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'compute instances create sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'labels=project=claude-sandbox,name=sandbox-abc' "$GCLOUD_STUB_LOG"
}

@test "provider_launch adds spot + max-run-duration flags when requested" {
    set_response 0 ''
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub"; echo "ssh-ed25519 AAAA test" > "$GCP_SSH_PUBKEY"
    AUTO_SHUTDOWN_HOURS=8
    run provider_launch sandbox-abc "" true "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'provisioning-model=SPOT' "$GCLOUD_STUB_LOG"
    grep -q -- 'max-run-duration=8h' "$GCLOUD_STUB_LOG"
    grep -q -- 'instance-termination-action=DELETE' "$GCLOUD_STUB_LOG"
}
```

- [ ] **Step 2: Run to verify failure** — `bats test/unit/gcp.bats` → FAIL (`provider_launch` undefined).

- [ ] **Step 3: Implement** in `lib/providers/gcp.sh`:

```bash
: "${GCP_IMAGE_FAMILY:=ubuntu-2404-lts-amd64}"
: "${GCP_IMAGE_PROJECT:=ubuntu-os-cloud}"

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
    [[ -n "$repo" ]] && printf 'sudo -u %s -i bash -c %q\n' "${SSH_USER:-ubuntu}" "git clone $repo"
}

provider_launch() {  # NAME REPO USE_SPOT CIDR -> instance name
    local name="$1" repo="$2" use_spot="$3" cidr="$4"
    local zone="$GCP_ZONE" hours="${AUTO_SHUTDOWN_HOURS:-0}"
    local pub="${GCP_SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
    local owner="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"

    # per-sandbox firewall (global object, scoped by target tag)
    _gcloud compute firewall-rules create "${name}-fw" \
        --network=default --direction=INGRESS --action=ALLOW \
        --rules=tcp:22 --source-ranges="$cidr" --target-tags="$name" >/dev/null
    log_info "firewall: ${name}-fw  SSH ingress = $cidr"

    # metadata files: ssh-keys + startup-script (+ user-data if baked image uses cloud-init)
    local kf sf; kf="$(mktemp)"; sf="$(mktemp)"
    trap 'rm -f "$kf" "$sf"' RETURN
    printf '%s:%s\n' "${SSH_USER:-ubuntu}" "$(cat "$pub")" > "$kf"
    gcp_render_startup "$name" "$repo" > "$sf"

    local args=(compute instances create "$name" --zone="$zone"
        --machine-type="${GCP_MACHINE_TYPE}"
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

    log_info "requesting gcp instance ($GCP_MACHINE_TYPE, spot=$use_spot)..."
    _gcloud "${args[@]}"
}
```

Add near the top: `_gcp_repo_bootstrap="$(cd "$_gcp_sh_dir/../.." && pwd)/ami/bootstrap.sh"`.

- [ ] **Step 4: Run tests + lint** — `bats test/unit/gcp.bats && shellcheck lib/providers/gcp.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: provider_launch (firewall-by-tag, startup-script bootstrap, spot + max-run-duration)"
```

---

### Task 9: GCP `provider_list`

**Files:**
- Modify: `lib/providers/gcp.sh`
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Produces: `provider_list` emitting the 9-field normalized TSV; helper `gcp_ts_to_epoch RFC3339`.

- [ ] **Step 1: Write failing test** — feed a `gcloud compute instances list --format=json` fixture and assert the normalized row:

```bash
@test "provider_list emits a normalized row" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
[{"name":"sandbox-abc","status":"RUNNING","machineType":"https://.../machineTypes/e2-standard-4",
  "creationTimestamp":"2026-07-03T10:00:00.000-07:00",
  "scheduling":{"provisioningModel":"SPOT"},
  "networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}],
  "metadata":{"items":[{"key":"auto-shutdown-hours","value":"8"}]},
  "tags":{"items":["sandbox-abc"]}}]
EOF
    run provider_list
    [ "$status" -eq 0 ]
    # handle name state type market ... ip ... ash
    [[ "$output" == *"sandbox-abc"*"ready"*"e2-standard-4"*"spot"*"5.6.7.8"*"8"* ]]
}
```

- [ ] **Step 2: Run to verify failure** — FAIL (`provider_list` undefined for gcp).

- [ ] **Step 3: Implement**:

```bash
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
    # jq emits: name rawstatus machinetype market rawts ip ash allowed
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
            ($cidr[.name] // "-")
        ] | @tsv
    ' | while IFS=$'\t' read -r name rawstatus mtype market rawts ip ash cidr; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$name" "$(gcp_map_state "$rawstatus")" "$mtype" "$market" \
            "$(gcp_ts_to_epoch "$rawts")" "$ip" "$cidr" "$ash"
    done
}
```

(`handle` and `name` are both the instance name on GCP.)

- [ ] **Step 4: Run tests + lint** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: provider_list — normalized records, state map, timestamp→epoch, firewall CIDR join"
```

---

### Task 10: GCP `resolve_ip`, `terminate_ids`, `cleanup_net`

**Files:**
- Modify: `lib/providers/gcp.sh`
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Produces: `provider_resolve_ip NAME`, `provider_terminate_ids NAME...`, `provider_cleanup_net NAME...`.

- [ ] **Step 1: Write failing tests**:

```bash
@test "provider_resolve_ip returns the natIP for a RUNNING box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
{"status":"RUNNING","networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -eq 0 ]
    [ "$output" = "5.6.7.8" ]
}
@test "provider_resolve_ip dies for a booting box" {
    cat > "$GCLOUD_STUB_RESPONSE" <<'EOF'
0
{"status":"PROVISIONING","networkInterfaces":[{"accessConfigs":[{}]}]}
EOF
    run provider_resolve_ip sandbox-abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"booting"* ]]
}
@test "provider_terminate_ids deletes by name+zone" {
    set_response 0 ''
    run provider_terminate_ids sandbox-abc
    [ "$status" -eq 0 ]
    grep -q -- 'compute instances delete sandbox-abc' "$GCLOUD_STUB_LOG"
    grep -q -- 'zone=us-west1-b' "$GCLOUD_STUB_LOG"
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**:

```bash
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
        _gcloud compute firewall-rules delete "${n}-fw" --quiet 2>/dev/null \
            && log_info "deleted firewall ${n}-fw" || true
    done
}
```

- [ ] **Step 4: Run tests + lint** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: resolve_ip (state-aware), terminate_ids, cleanup_net"
```

---

### Task 11: `up` name-validation hook + docs & setup wiring

**Files:**
- Modify: `bin/sandbox-up` (validate `--name` when `CLOUD=gcp`)
- Modify: `config.example`, `init.sh`, `README.md`
- Test: `test/unit/up.bats` (add a gcp name-validation case if up.bats already stubs launch; otherwise a gcp.bats-level check)

**Interfaces:**
- Consumes: `gcp_validate_name` (Task 7).

- [ ] **Step 1: `sandbox-up` name validation** — after `provider_load` and computing `NAME`, guard for GCP:

```bash
provider_load
if [[ "${CLOUD:-aws}" == "gcp" ]]; then gcp_validate_name "$NAME"; fi
```

(For AWS, `NAME` remains unvalidated as today.)

- [ ] **Step 2: `config.example`** — under the cloud section, document the GCP keys (verbatim values from the spec):

```bash
CLOUD="aws"                       # "aws" | "gcp"

# ---- GCP (only used when CLOUD=gcp) ----
GCP_PROJECT=""                    # required for gcp
GCP_ZONE="us-west1-b"             # gcp is zonal; only the zone is needed
GCP_IMAGE=""                      # blank → stock ubuntu-2404-lts (bootstrap runs
                                  # at first boot, ~5-10 min); or a baked image name
GCP_MACHINE_TYPE="e2-standard-4"  # 4 vCPU / 16 GB, cost-optimized (~m7i-flex.xlarge)
GCP_SSH_PUBKEY=""                 # SSH *public* key injected at launch;
                                  # blank → ${SSH_KEY_FILE}.pub
```

- [ ] **Step 3: `init.sh`** — after the `.env` export block, export the GCP ADC var if the file is present, so `gcloud` picks it up:

```bash
# GCP: gcloud reads Application Default Credentials from this path.
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS
    echo "init: GOOGLE_APPLICATION_CREDENTIALS set for gcloud"
fi
```

(Users put `GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json` in `.env`, which the existing `set -a; source` already exports — this block just confirms/validates it.)

- [ ] **Step 4: `README.md`** — add a "Using GCP" subsection: prerequisites (`gcloud` installed, a project, a service account with Compute Instance Admin + its key JSON gitignored in-repo), the `.env` line `GOOGLE_APPLICATION_CREDENTIALS=...`, setting `CLOUD=gcp` + `GCP_PROJECT`, and a note that `build-ami`/`list-amis`/`delete-ami` are AWS-only for now (bake out-of-band and set `GCP_IMAGE` for fast boots). Note the MVP first-boot delay.

- [ ] **Step 5: Run the whole suite + lint + a manual dispatch smoke**

Run: `make lint && make test`
Expected: PASS.
Manual: `CLOUD=gcp SANDBOX_GCP_PROJECT=x ./bin/sandbox list` against the gcloud stub or a real project returns without AWS calls.

- [ ] **Step 6: Commit**

```bash
git add bin/sandbox-up config.example init.sh README.md test/unit/up.bats
git commit -m "gcp: validate --name; document GCP setup (config.example, init.sh, README)"
```

---

## Deferred (out of this plan, noted for follow-up)

- **GCP image baking** — a `provider_build_image` for GCP (`gcloud compute images create` from a bootstrapped instance). Removes the first-boot bootstrap delay. Primary follow-up.
- **Tab completion for GCP names** — `completion/sandbox.sh` (`_sandbox_list_names`) queries EC2 directly; under `CLOUD=gcp` name completion silently returns nothing (static completions still work). Add a `gcloud`-backed branch keyed on `$CLOUD`.
- **`get-serial-port-output`** parity for the GCP debug path (AWS `get-console-output`).

## Self-Review

- **Spec coverage:** provider seam (T3) ✓; normalized list/down (T4/T5) ✓; gcloud transport + `GCLOUD_CMD` seam (T7) ✓; self-destruct max-run-duration+DELETE (T8) ✓; firewall-by-tag (T8) ✓; labels+metadata split (T8/T9) ✓; spot→SPOT (T8) ✓; SSH pubkey injection + `GCP_SSH_PUBKEY` (T7/T8) ✓; state map (T9) ✓; service-account-key auth via `GOOGLE_APPLICATION_CREDENTIALS` (T11) ✓; `e2-standard-4`/`us-west1-b` defaults (T1) ✓; image commands die under gcp (T6) ✓; MVP no-bake bootstrap-at-boot (T8) ✓; naming validation (T7/T11) ✓; tests per driver (T7–T10) ✓.
- **Placeholder scan:** the one intentional forward-reference is `provider_build_image` (stub in T3 → real in T6); called out explicitly. No TBD/"add error handling"/vague steps.
- **Type/name consistency:** `provider_*` names and the 9-field record order are identical across T3–T10; `provider_check_creds` is defined for AWS (T4) and GCP (T7) and consumed by list/down/ssh/scp; `gcp_validate_name` defined T7, consumed T11; `handle` (col 1) is the terminate arg for `provider_terminate_ids` in both drivers.
