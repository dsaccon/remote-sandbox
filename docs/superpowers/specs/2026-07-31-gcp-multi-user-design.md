# GCP Multi-User — Design

**Date:** 2026-07-31
**Status:** Draft, pending user review

## Goal

Let several people share one GCP project without stepping on each other. Each
user sees and manages only their own sandboxes; baked images stay shared, but
carry enough provenance to decide whether you want to boot someone else's.

## Scope

**In:** owner identity derived from the GCP service account; `list`, `ssh`,
`scp`, `down` (single / `--all` / `--stale`) and tab completion scoped to the
calling user; image provenance labels + manifest; `list-images` OWNER/BOOTSTRAP
columns; `image-info`; `delete-image` ownership guard.

**Deferred (follow-up spec):** the same treatment for AWS. Until then the AWS
`Owner` tag keeps its `$USER@hostname` value and AWS boxes are **not** filtered
— a cross-cloud `list` shows GCP scoped to you and AWS unscoped. Accepted
deliberately: there is one user today.

**Explicitly out:** any migration code. Resources predating this change carry
no `owner` label and therefore won't match anyone's filter. Relabelling is a
manual, one-off `gcloud` chore done before a second user is onboarded — see
"Manual onboarding" below. No `reclaim` command, no legacy-format fallbacks.

## Threat model

This is a **safety rail, not a security boundary.** Filtering happens
client-side in this CLI. Anyone holding `roles/compute.instanceAdmin.v1` on the
project can bypass it entirely with raw `gcloud`. It prevents accidents — a
mistyped `down --all` taking out a colleague's work — and nothing more.

A real boundary would need IAM conditions on resource labels, per-user service
accounts with narrowed roles, or separate projects. Cloud Audit Logs remain the
tamper-proof record of who actually created and deleted what
(`gcloud logging read`), and are the ground truth if labels ever disagree.

**Prerequisite:** each user authenticates as their **own service account**. Two
people sharing one key are the same principal — same audit entries, same
derived owner — and filtering would do nothing.

## Decisions summary

| Topic | Decision |
|---|---|
| Owner identity | The service account's `client_email`, read from the key JSON at `$GOOGLE_APPLICATION_CREDENTIALS`. |
| Why not `$USER@hostname` | A second, weaker identity that can disagree with the authoritative one. It was a single-user breadcrumb, not a discriminator. |
| Why not `gcloud auth list` | Same answer, ~1–2s slower. The key file is a local read; `gcloud`'s Python startup is not, and this sits in the tab-completion path. |
| Cost | Zero API calls. One `jq` read of a local file, memoized per process. |
| Storage | Label `owner=<local-part>` (server-side filterable) + full email in instance metadata `owner` (audit, disambiguation). |
| Why both | GCP label values forbid `@` and `.`, so the full email can't be a label. SA account IDs are lowercase alphanumeric + hyphens — already label-legal — so the local part works. |
| Instance scope | Hard isolation. No `--all-users` escape hatch. |
| Image scope | Visible to all; `delete-image` guarded. |
| Unresolvable identity | Hard error. Never fall back to unfiltered. |

## Architecture

### `lib/identity.sh` (new)

    sandbox_owner_email   -> jane-sandbox@proj.iam.gserviceaccount.com
    sandbox_owner_label   -> jane-sandbox

`sandbox_owner_email` reads `.client_email` from the file named by
`$GOOGLE_APPLICATION_CREDENTIALS`. `sandbox_owner_label` takes the part before
`@` and lowercases it. If anything outside `[a-z0-9_-]` remains it **dies**
rather than stripping the offending characters — silently rewriting could map
two distinct identities onto one label. The check is defensive: GCP already
constrains SA account IDs to that charset. Both functions memoize into a shell
variable, so identity resolves at most once per process.

Sourced by the GCP driver **and** by `completion/sandbox.sh`, which queries
`gcloud` directly rather than going through the driver and so must resolve
identity itself. The AWS driver does not consume it until the follow-up spec.

### Instances

**Launch** (`provider_launch`, `gcp.sh:203`) — add `owner=<label>` to the
existing `--labels`, and set the existing `--metadata` `owner=` to the full
email instead of `$USER@hostname`. No new API calls; both flags already exist.

**List** (`provider_list`, `gcp.sh:278`) — the filter becomes:

    labels.project=claude-sandbox AND labels.owner=<me>

Server-side. The jq pipeline is untouched.

**Resolve** (`provider_resolve_ip`, `gcp.sh:305`) — this calls
`instances describe <name>` directly and so **bypasses the list filter**. It
must check `labels.owner` against the caller and `die` with the existing
"no sandbox named X" message when it doesn't match. Without this, `ssh
<colleague-box>` reaches a foreign box by name; it would fail on the SSH key,
but should fail cleanly at the CLI instead.

**Destructive paths need no changes.** `down <name>`, `--all` and `--stale` all
route through `mc_find` / `provider_list_all` (`lib/multicloud.sh:38`), which
consume `provider_list`. Scoping the filter scopes the blast radius. This is
the whole safety property, and it falls out of one string.

### Completion

`_sandbox_names_gcp` (`completion/sandbox.sh:85`) queries `gcloud` with its own
filter and needs the same `labels.owner` predicate. Otherwise Tab suggests
boxes that `ssh` then rejects — worse than no completion. It sources
`lib/identity.sh` for itself. Cache mechanics (`_SANDBOX_CACHE_TTL=15`) are
unchanged; the added work on a cold Tab is one local `jq` read of the key file,
and the warm path is untouched. This is the reason identity must not require a
`gcloud` or `aws` invocation — those would land squarely in the completion path
and undo the latency work in `fd5650c` / `e2fea07`.

### Images

Images are created today with a name and `--family` and nothing else
(`gcp.sh:137`). Two bakes of the same `bootstrap.sh` are not equivalent, so
provenance records what actually varies:

- **`DOTFILES_REPO` / `CLAUDE_HARDENING_REPO`** are baked in — `bootstrap.sh:81-92`
  clones each and runs its `install.sh`. Booting a shared image runs whatever
  the baker's dotfiles installed. This is the most important field to surface.
- **Tool versions.** Node, bun, uv, docker, gh and neovim are all fetched
  unpinned (`bootstrap.sh:22-64`), so bake date changes the contents.

**Labels** (structured, filterable): `owner`, `bootstrap=<first 12 hex of
sha256(ami/bootstrap.sh)>`, `base=<source image family>`.

**Description** (free text, 2048-char budget) — the manifest: baker email,
bootstrap hash, both repo URLs, base image, bake timestamp, and tool versions
harvested over the SSH session the bake already holds open.

**`list-images`** stays unfiltered and gains OWNER and BOOTSTRAP columns.
Images without an owner label show `-`.

**`image-info <name>`** (new) prints the manifest.

**`delete-image`** refuses when an image carries an `owner` label that isn't
yours, unless `--force`. A *missing* owner label is allowed through — those are
pre-provenance images, and guarding them would only obstruct the one user who
has them.

## Data flow — `sandbox list` (CLOUD=gcp)

1. `bin/sandbox-list` → `provider_list_all` → GCP driver.
2. Driver sources `lib/identity.sh`; `sandbox_owner_label` reads the key file
   (local, memoized).
3. `gcloud compute instances list --filter="labels.project=claude-sandbox AND
   labels.owner=<me>"`.
4. Existing jq pipeline emits the normalized 10-field record. Unchanged.

## Error handling

| Condition | Behavior |
|---|---|
| `GOOGLE_APPLICATION_CREDENTIALS` unset | `die`: point at the README's GCP setup. |
| File missing / unreadable | `die` with the path. |
| Not valid JSON, or no `client_email` | `die`: "not a service account key — user-account ADC isn't supported for multi-user". |
| Local part not label-legal after sanitizing | `die` with the offending value. |
| `ssh`/`scp`/`down` naming a foreign box | `die` "no sandbox named X (try ./bin/sandbox list)" — the existing message. |
| `delete-image` on a foreign image | `die` naming the owner, suggesting `--force`. |

Every failure is fatal by design. A fallback to unfiltered operation would
silently restore the accident this feature exists to prevent.

## Testing

Extend `test/unit/gcp.bats`; add `test/unit/identity.bats`. Existing
`GCLOUD_CMD` stub seam and a fixture SA key JSON under `test/unit/stubs/`.

- Identity: happy path; each failure mode in the table above; memoization.
- Launch: `owner` label applied; metadata holds the full email.
- List: filter string carries `labels.owner`.
- Resolve: foreign box rejected by `ssh` and `scp`.
- Down: `--all` and `--stale` exclude foreign boxes.
- Completion: `_sandbox_names_gcp` filter carries owner.
- Images: labels + description written at bake; `list-images` unfiltered and
  renders OWNER/BOOTSTRAP; `image-info` prints the manifest; `delete-image`
  guard fires on foreign, passes on unlabelled, passes on `--force`.

## Manual onboarding (no code)

Before a second user starts, relabel existing resources once:

    gcloud compute instances add-labels NAME --zone ZONE \
        --labels=owner=<your-sa-local-part> --project PROJECT
    gcloud compute images add-labels NAME \
        --labels=owner=<your-sa-local-part> --project PROJECT

Anything left unlabelled stays invisible to `list` and untouched by `down`, and
must be managed with raw `gcloud`.

## Open questions / risks

- **No escape hatch, by choice.** Cleaning up a departed colleague's boxes
  requires raw `gcloud`. Accepted as the cost of hard isolation.
- **Local-part collisions.** Two SAs in different projects could share a local
  part. Irrelevant for a single shared project; the full email in metadata
  disambiguates if it ever matters.
- **`.env.example` omits `GOOGLE_APPLICATION_CREDENTIALS`** — the README tells
  you to append it by hand. Worth fixing alongside, since identity now depends
  on it.

## Out of scope / future work

- AWS multi-user (follow-up spec): needs a different identity source, since
  there's no local credential file to read. Either the access key ID (free,
  unreadable) or `aws sts get-caller-identity` (~1s, human-readable ARN).
- IAM-enforced isolation via label conditions or per-user projects.
- Pinning tool versions in `bootstrap.sh` so bakes are reproducible.
