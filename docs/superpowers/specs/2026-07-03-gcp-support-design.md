# GCP Support — Design

**Date:** 2026-07-03
**Status:** Draft, pending user review

## Goal

Let `remote-sandbox` provision ephemeral sandboxes on **Google Cloud (GCE)** in
addition to AWS EC2, selected by a single `CLOUD` setting in `./config`. AWS
remains the default and stays fully working. This realizes the multi-cloud
structure the original design anticipated ("Repo structure leaves room for
`provision.gcp.sh` later"; `CLOUD` key already present but unread).

## Scope

**In (MVP):** `up`, `down` (single / `--all` / `--stale`), `list`, `ssh`,
`scp`, and `spot` working with `CLOUD=gcp`. AWS behavior unchanged.

**Deferred (follow-up):** GCP image baking. MVP GCP boxes boot from a **stock
Ubuntu 24.04 image** and run the existing `ami/bootstrap.sh` at first boot via a
startup-script (reuses the already-cloud-agnostic bootstrap). Trade-off: first
`ready` takes ~5–10 min of tool installs per box, versus seconds from a baked
image. Users who want fast boots can bake an image out-of-band and set
`GCP_IMAGE`. `build-ami`, `list-amis`, and `delete-ami` are AWS-only in the MVP
and `die` with a clear message under `CLOUD=gcp`.

## Decisions summary

| Topic | Decision |
|---|---|
| Provider abstraction | Driver library: `lib/providers/{aws,gcp}.sh` behind `lib/provider.sh` dispatch, selected by `$CLOUD`. |
| Data model | `list`/`down` consume a **normalized TSV record** from the driver; cloud-specific JSON never leaves the driver. |
| GCP transport | Official `gcloud` CLI, mirroring how AWS uses the `aws` CLI (same `*_CMD` stub seam for tests). |
| Self-destruct | GCP control-plane `--max-run-duration=<h> --instance-termination-action=DELETE`. No in-VM timer needed on GCP. |
| Per-sandbox SSH ingress | GCP firewall rule scoped by network tag (`<name>-fw` + instance `--tags=<name>`), 1:1 with the per-sandbox SG model. |
| Tagging | GCP **labels** for `project`/`name` (label-legal); `owner` + `auto-shutdown-hours` in instance **metadata**; age from native `creationTimestamp`. |
| Spot | GCP `--provisioning-model=SPOT`. Spot→on-demand fallback stays AWS-only (driver-specific launch). |
| Auth | Service-account key JSON referenced by `GOOGLE_APPLICATION_CREDENTIALS` (gitignored, mirrors the `.env` pattern). |
| Default machine / zone | `e2-standard-4` (cost-optimized, matches the AWS `m7i-flex.xlarge` spirit) in `us-west1-b`. |
| Image (MVP) | Stock `ubuntu-2404-lts-amd64` (`ubuntu-os-cloud`), or a user-baked image via `GCP_IMAGE`. |

## Architecture — the provider seam

### `lib/` layout

```
lib/
  provider.sh          # dispatch: read $CLOUD, source the driver, expose provider_*
  providers/
    aws.sh             # AWS driver: today's lib/aws.sh + the AWS half of provision.sh
    gcp.sh             # GCP driver (new)
  common.sh            # cloud-agnostic helpers extracted from provision.sh
  config.sh            # unchanged mechanics; gains GCP keys (see Config)
  log.sh               # unchanged
```

### What moves where (refactor of the current code)

- `lib/aws.sh` → `lib/providers/aws.sh` (keeps the `AWS_CMD`/`_aws` seam).
- AWS-specific functions in `lib/provision.sh` (`build_run_instances_json`,
  `provision_launch`, `ensure_sg`, `preflight_or_die`) move **into the AWS
  driver** as the bodies of its `provider_*` implementations.
- Cloud-agnostic functions in `lib/provision.sh` (`render_cloud_init`,
  `resolve_ssh_cidr`, `current_public_ip_cidr`) move to **`lib/common.sh`**.
- New `lib/provider.sh`: reads `$CLOUD`, sources `providers/<cloud>.sh`, and
  `die`s on an unknown value with the list of supported clouds.
- Every `bin/sandbox-*` script sources `lib/provider.sh` (+ `lib/common.sh` +
  `lib/config.sh`) instead of `lib/aws.sh`, and calls `provider_*` instead of
  `aws_*`.

### Driver contract

Each driver implements exactly these. Nothing in `bin/` references a cloud.

| Function | Responsibility |
|---|---|
| `provider_preflight` | Verify CLI present, creds valid, project/region/zone set, image + SSH key resolvable. `die` with actionable messages. |
| `provider_launch NAME REPO USE_SPOT CIDR` | Create the per-sandbox network rule, launch the box, print its instance id. Spot-fallback policy lives here (AWS only). |
| `provider_list` | Emit normalized TSV, one row per box (schema below). |
| `provider_resolve_ip NAME` | Print the running box's public IP; `die` with a state-specific message (booting / stopped / gone). Shared by `ssh` + `scp`. |
| `provider_terminate_ids ID...` | Delete/terminate instances by id. |
| `provider_cleanup_net NAME...` | Delete the per-sandbox SG (AWS) / firewall rule (GCP) for these names. Best-effort, silent on the expected "still in use" race. |
| `provider_build_image` | AWS: today's bake flow. GCP: `die "image baking not yet supported on gcp — bake out-of-band and set GCP_IMAGE"`. |

### Normalized `list` record

One tab-separated row per box:

```
id ⇥ name ⇥ state ⇥ type ⇥ market ⇥ launch_epoch ⇥ ip ⇥ allowed_cidr ⇥ ash_hours
```

- `state`: normalized enum
  `pending | initializing | ready | impaired | running | stopping | stopped | shutting-down | terminated`.
  AWS fills all of it; GCP fills the subset it can express (see mapping).
- `market`: `spot | on-demand`.
- `launch_epoch`: **unix epoch** — each driver converts its own timestamp
  format (`LaunchTime` / `creationTimestamp`), so the presentation layer never
  parses cloud-shaped timestamps.
- `ip` / `allowed_cidr` / `ash_hours`: `-` when absent.

**Policy stays shared, mechanism goes in the driver.** `list`'s age/EXPIRES math
and `down --stale`'s "what counts as stale" stay in the command scripts,
operating on the normalized record. `down --all`/`--stale` filter the record by
`state`/age, then call `provider_terminate_ids` + `provider_cleanup_net`.

## GCP concept mapping

| Concept | GCP realization |
|---|---|
| Image | MVP: `--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud`, or user-baked via `GCP_IMAGE`. |
| Launch | `gcloud compute instances create <name> --zone=$GCP_ZONE --machine-type=$GCP_MACHINE_TYPE --image-family/--image ... --tags=<name> --labels=project=claude-sandbox,name=<name> --metadata=owner=...,auto-shutdown-hours=... --metadata-from-file=user-data=<rendered>`. |
| Per-sandbox SSH ingress | `gcloud compute firewall-rules create <name>-fw --network=default --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=<cidr> --target-tags=<name>`. Instance carries `--tags=<name>`. `down` → `firewall-rules delete <name>-fw`. Firewall rules are global (no zone); instances are zonal. |
| Tags | **Labels** `project=claude-sandbox`, `name=<name>` (label-legal). `owner` (`user@host`) and `auto-shutdown-hours` are **not** label-legal → instance **metadata**. Age uses native `creationTimestamp`. |
| Spot | `--provisioning-model=SPOT`; detected in `list` via `.scheduling.provisioningModel=="SPOT"`. |
| Self-destruct | `--max-run-duration=${AUTO_SHUTDOWN_HOURS}h --instance-termination-action=DELETE` (control-plane enforced; min 30s, max 120d). Omit when `AUTO_SHUTDOWN_HOURS=0`. In-VM systemd auto-shutdown timer is unused on GCP. `down` = `instances delete`. |
| SSH keys | Public key (from `GCP_SSH_PUBKEY`, default `${SSH_KEY_FILE}.pub`) injected via instance metadata `ssh-keys=$SSH_USER:<pubkey>`. `ssh`/`scp` use the same local private key + `SSH_USER` as AWS. Preflight `die`s if the public key is unreadable. |
| IP | `.networkInterfaces[0].accessConfigs[0].natIP`. |
| State | GCP has no EC2 status-checks: `PROVISIONING/STAGING → initializing`, `RUNNING → ready`, `STOPPING → stopping`, GCP `TERMINATED → stopped`. Deleted boxes vanish from `list` immediately (no ~1h terminated-lingering) — minor UX difference from AWS. |
| Console output | `gcloud compute instances get-serial-port-output` (parity for the AWS `get-console-output` debug path; not on the MVP critical path). |

### Naming constraints (GCP-only validation)

GCP instance names, label values, and firewall-rule names must be RFC1035 /
label-legal: lowercase letters, digits, hyphens (values also `_`), start with a
letter, ≤63 chars. The default `sandbox-<8hex>` complies. When `CLOUD=gcp`, a
user-supplied `--name` is validated and rejected with a clear message if it
isn't compliant (AWS remains lax about Name tags).

## Config changes

`CLOUD` is finally **read** (dispatch + validation). New keys default empty and
are required only when `CLOUD=gcp`:

```bash
CLOUD="aws"                      # "aws" | "gcp"

# ---- GCP (only used when CLOUD=gcp) ----
GCP_PROJECT=""                   # required for gcp
GCP_ZONE="us-west1-b"            # gcp is zonal; only the zone is needed
GCP_IMAGE=""                     # blank → stock ubuntu-2404-lts; or a baked image name
GCP_MACHINE_TYPE="e2-standard-4" # 4 vCPU / 16 GB, cost-optimized (~m7i-flex.xlarge)
GCP_SSH_PUBKEY=""                # path to the SSH *public* key injected at launch;
                                 # blank → defaults to ${SSH_KEY_FILE}.pub
```

- `INSTANCE_TYPE` stays AWS-only; GCP reads `GCP_MACHINE_TYPE` (families are
  named too differently to share one key cleanly).
- `config.sh`'s `_CONFIG_KEYS` and `_config_default` grow the new keys; env
  overrides use the existing `SANDBOX_<KEY>` convention.
- Preflight validates that gcp-required keys are non-empty and that `CLOUD` is a
  known value.

## Auth & setup (GCP)

Mirrors the AWS "creds live in-repo, gitignored" ethos:

- A **service-account key JSON** referenced by `GOOGLE_APPLICATION_CREDENTIALS`
  (path inside the repo, gitignored like `.env`), plus `GCP_PROJECT`.
- `init.sh` exports `GOOGLE_APPLICATION_CREDENTIALS` alongside the AWS vars when
  present. `gcloud` uses ADC from that key; no `~/.config/gcloud` interactive
  login required.
- Prerequisites documented in the README: `gcloud` CLI installed, a GCP project,
  a service account with Compute Instance Admin (create/delete instances +
  firewall rules), and its key JSON downloaded into the repo.
- Preflight (`CLOUD=gcp`): confirm `gcloud` on PATH, `GOOGLE_APPLICATION_CREDENTIALS`
  readable, project set, and a cheap authenticated call succeeds (e.g.
  `gcloud compute images describe-from-family ...` or `auth print-access-token`).

`gcloud` is the GCP control-plane CLI (the analog of the already-required `aws`
CLI), not agent-facing dev tooling — consistent with the minimal-laptop-footprint
posture, which is about keeping *dev* tooling in the sandbox.

## Data flow — `sandbox up` (CLOUD=gcp)

1. Load config + flags; `provider.sh` selects the GCP driver.
2. `provider_preflight`: gcloud present, creds/project valid, image + SSH public
   key resolvable, gcp-required keys set, `--name` RFC1035-valid.
3. `resolve_ssh_cidr` (shared) → the `:22` source range.
4. `provider_launch`:
   a. Create firewall rule `<name>-fw` (`--target-tags=<name>`, `--source-ranges=<cidr>`, `tcp:22`).
   b. Render cloud-init/startup-script. MVP (no baked image): the startup-script
      runs `ami/bootstrap.sh`, then the optional `--repo` clone. With a baked
      `GCP_IMAGE`, the startup-script is just hostname + optional clone (as AWS
      cloud-init is today).
   c. `gcloud compute instances create` with labels, metadata, `--tags`,
      `--provisioning-model=SPOT` if spot, and `--max-run-duration`/`DELETE` if
      `AUTO_SHUTDOWN_HOURS>0`.
   d. Print the instance id. Non-blocking, like AWS.
5. `up` prints the same "track with `sandbox list` → `sandbox ssh`" guidance.

## Error handling

Same shape and tone as the current AWS messages:

| Failure | Behavior |
|---|---|
| Unknown `CLOUD` value | `die` listing supported clouds. |
| `gcloud` not on PATH | `die` with an install hint. |
| `GOOGLE_APPLICATION_CREDENTIALS` unset/unreadable, or project unset | `die` naming the missing item + fix. |
| gcp-required config key empty | `die` naming the key. |
| `--name` not RFC1035-valid (gcp) | `die` with the naming rule. |
| `build-ami` / `list-amis` / `delete-ami` under gcp | `die "not yet supported on gcp"` (image baking deferred). |
| Launch API error | Surface the gcloud stderr; no silent fallback (spot fallback is AWS-only). |

## Testing

- **`GCLOUD_CMD` seam** in the GCP driver mirrors `AWS_CMD`; stubbed by a fake
  `gcloud` like `test/unit/stubs/aws-empty`.
- New `test/unit/gcp.bats` — GCP driver: launch arg assembly, label/metadata
  split, firewall-rule create/delete, normalized-record emission, state mapping,
  `--name` validation.
- New `test/unit/provider.bats` — dispatch on `$CLOUD`, unknown-cloud `die`,
  and that `list`/`down` consume the normalized record identically across
  drivers.
- `test/unit/aws.bats` updates its source path (`lib/aws.sh` →
  `lib/providers/aws.sh`); AWS behavior assertions unchanged.
- `test/smoke.sh` gains a `CLOUD=gcp` variant (manual, costs cents): `up` → wait
  → `ssh` asserts `claude`/`docker` present → `down` → confirm firewall rule
  cleaned up.
- `make lint` (shellcheck) stays clean across the new files.

## Open questions / risks

- **First-boot latency (MVP, no baked image):** ~5–10 min of `bootstrap.sh`
  installs on every `up`. Acceptable for MVP; the image-baking follow-up removes
  it. `GCP_IMAGE` lets a user opt into a hand-baked image immediately.
- **Exact `gcloud` flag spellings** (`--max-run-duration`, `--instance-termination-action`,
  `--provisioning-model`, image-family flags) are verified as GA but pinned
  against the current CLI at implementation time.
- **Service-account scope:** needs create/delete on instances + firewall rules.
  Document a least-privilege role rather than Owner.
- **Region/zone parity:** AWS default is `us-west-2`; GCP default `us-west1-b`
  (nearby, not identical). Both configurable.

## Out of scope / future work

- GCP image baking (`build-ami` for GCP) — the primary follow-up.
- ARM (Graviton / Tau T2A) images.
- OS Login as an alternative to metadata SSH keys.
- Multi-region/zone orchestration, multi-project.
- Egress lockdown (unchanged threat model).
