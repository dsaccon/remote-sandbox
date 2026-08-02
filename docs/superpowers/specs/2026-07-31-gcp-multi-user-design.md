# GCP Multi-User — Design

**Date:** 2026-07-31
**Revised:** 2026-08-01 — identity source corrected (see "Correction" below)
**Status:** Draft, pending user review

## Goal

Let several people share one GCP project without stepping on each other. Each
user sees and manages only their own sandboxes; baked images stay shared, but
carry enough provenance to decide whether you want to boot someone else's.

## Correction (2026-08-01)

The first draft derived identity from a service-account key JSON at
`$GOOGLE_APPLICATION_CREDENTIALS`. That was wrong on three counts:

1. That variable is **not set** in this repo's `.env`, and the working setup
   authenticates as a **user account** (`gcloud auth login`), not a service
   account.
2. Nothing in the codebase reads it. `gcp.sh:33` mentions it only inside an
   error-message string; `init.sh:50` exports it *if already set*, which has
   never fired.
3. The `gcloud` CLI doesn't consult it anyway — it drives Application Default
   Credentials for client libraries, while `gcloud` uses its own credential
   store.

Identity now comes from gcloud's **active account**.

## Correction (2026-08-01, during implementation)

The draft claimed `provider_resolve_ip` was a live bypass — that without an
ownership check there, `ssh <colleague-box>` would reach a foreign box by name.
That was wrong: **`provider_resolve_ip` has no callers.** `ssh` and `scp` use
`mc_resolve_ip` → `mc_find` → `provider_list_all` → `provider_list`, which the
owner filter already scopes. It has been unused since the cross-cloud refactor
in `e594762`; only the driver contract keeps it alive.

The check was implemented anyway as defence in depth and is covered by tests,
but the protection for `ssh`/`scp` comes from the list filter, not from it.

## Scope

**In:** owner identity derived from gcloud's active account; `list`, `ssh`,
`scp`, `down` (single / `--all` / `--stale`) and tab completion scoped to the
calling user; image provenance labels + manifest; `list-images`
OWNER/BOOTSTRAP columns; `image-info`; `delete-image` ownership guard.

**Deferred:** the same treatment for AWS, as its own spec — it needs a
different identity source, since there's no local credential file to read.
Until then AWS boxes are **not** filtered, so a cross-cloud `list` shows GCP
scoped and AWS unscoped. Accepted deliberately: there is one user today.

**Explicitly out:** any migration code. Resources predating this change carry
no `owner` label and won't match anyone's filter. Relabelling is a manual,
one-off `gcloud` chore done before a second user is onboarded — see "Manual
onboarding". No `reclaim` command, no legacy-format fallbacks.

## Threat model

This is a **safety rail, not a security boundary.** Filtering happens
client-side in this CLI. Anyone holding `roles/compute.instanceAdmin.v1` on the
project can bypass it with raw `gcloud`. It prevents accidents — a mistyped
`down --all` taking out a colleague's work — and nothing more.

A real boundary would need IAM conditions on resource labels, per-user narrowed
roles, or separate projects. Cloud Audit Logs remain the tamper-proof record of
who created and deleted what (`gcloud logging read`), and are ground truth if
labels ever disagree.

**Prerequisite:** each user authenticates as their **own Google account** via
`gcloud auth login`. Two people sharing one credential are one principal — same
audit entries, same derived owner — and filtering would do nothing.

## Decisions summary

| Topic | Decision |
|---|---|
| Owner identity | gcloud's active account (e.g. `david@synesis.one`), read from gcloud's own config files. |
| Why not `$USER@hostname` | A second, weaker identity that can disagree with the principal GCP authenticates. It was a single-user breadcrumb, not a discriminator. |
| Why not `gcloud config get-value account` | Correct but ~1–2s per call, dominated by gcloud's Python startup — and this sits in the tab-completion path. Used only as a fallback. |
| Cost | Two small local file reads. No process spawn, no API call. |
| Storage | Label `owner=<sanitized full email>` (server-side filterable) + unmodified email in instance metadata `owner` (authoritative, audit). |
| Why both | GCP label values allow only `[a-z0-9_-]`, so `david@synesis.one` can't be a label; the sanitized form `david-synesis-one` can. |
| Display | Local part (`david`) in list columns; full email available via metadata. |
| Instance scope | Hard isolation. No `--all-users` escape hatch. |
| Image scope | Visible to all; `delete-image` guarded, failing closed. |
| Unresolvable identity | Hard error. Never fall back to unfiltered. |

## Architecture

### `lib/identity.sh` (new)

    sandbox_owner_email   -> david@synesis.one
    sandbox_owner_label   -> david-synesis-one

**`sandbox_owner_email`** reads gcloud's active account from disk:

1. Config root is `$CLOUDSDK_CONFIG` if set, else `~/.config/gcloud`.
2. Active config name is `$CLOUDSDK_ACTIVE_CONFIG_NAME` if set, else the
   contents of `<root>/active_config`, else `default`.
3. Read `account` from the `[core]` section of
   `<root>/configurations/config_<name>`.

If any step fails, fall back to `gcloud config get-value account`. The fast
path stays fast; correctness doesn't depend on gcloud's internal layout
holding. Memoized into a shell variable — resolved at most once per process.

**`sandbox_owner_label`** lowercases the email and replaces every character
outside `[a-z0-9_-]` with `-`. It uses the **full** email, not the local part:
`first.last@corp.com` and `first-last@corp.com` would otherwise both reduce to
`first-last`, and a label collision silently breaks isolation by showing two
people each other's boxes. `die` if the result exceeds the 63-char label limit.

Sourced by the GCP driver **and** by `completion/sandbox.sh`, which queries
`gcloud` directly rather than going through the driver and so must resolve
identity itself. The AWS driver does not consume it.

### Instances

**Launch** (`provider_launch`, `gcp.sh:203`) — add `owner=<label>` to the
existing `--labels`, and set the existing `--metadata` `owner=` to the
unmodified email instead of `$USER@hostname`. No new API calls; both flags
already exist.

**List** (`provider_list`, `gcp.sh:278`) — the filter becomes:

    labels.project=claude-sandbox AND labels.owner=<label>

Server-side. The jq pipeline is untouched.

**Resolve** (`provider_resolve_ip`, `gcp.sh:305`) — checks `labels.owner`
against the caller and `die`s with the existing "no sandbox named X" message
when it doesn't match, since `instances describe <name>` doesn't go through the
list filter.

This is **defence in depth, not a live hole** — see the correction below. It
guards the driver contract in case something calls it later.

**Every user-facing path is covered by the list filter alone.** `ssh` and `scp`
resolve through `mc_resolve_ip` → `mc_find`, and `down <name>` / `--all` /
`--stale` through `mc_find` / `provider_list_all` (`lib/multicloud.sh:38`) —
all of which consume `provider_list`. Scoping that one filter scopes the blast
radius. That is the whole safety property, and it falls out of one string.

### Completion

`_sandbox_names_gcp` (`completion/sandbox.sh:85`) queries `gcloud` with its own
filter and needs the same `labels.owner` predicate, or Tab suggests boxes that
`ssh` then rejects — worse than no completion. It sources `lib/identity.sh`
itself. Cache mechanics (`_SANDBOX_CACHE_TTL=15`) are unchanged; the added work
on a cold Tab is two local file reads, which is why identity must not spawn
`gcloud`.

### Images

Images are created today with a name and `--family` and nothing else
(`gcp.sh:137`). Two bakes of the same `bootstrap.sh` are not equivalent, so
provenance records what actually varies:

- **`DOTFILES_REPO` / `CLAUDE_HARDENING_REPO`** are baked in —
  `bootstrap.sh:81-92` clones each and runs its `install.sh`. Booting a shared
  image runs whatever the baker's dotfiles installed. The most important field
  to surface.
- **Tool versions.** Node, bun, uv, docker, gh and neovim are fetched unpinned
  (`bootstrap.sh:22-64`), so bake date changes the contents.

**Labels:** `owner`, `bootstrap=<first 12 hex of sha256(ami/bootstrap.sh)>`,
`base=<source image family>`.

**Description** (free text, 2048-char budget) — the manifest: baker email,
bootstrap hash, both repo URLs, base image, bake timestamp, and tool versions
harvested over the SSH session the bake already holds open.

**`list-images`** stays unfiltered and gains OWNER and BOOTSTRAP columns.
Images with no owner label show `-`.

**`image-info <name>`** (new) prints the manifest.

**`delete-image` fails closed:** it refuses unless the image's `owner` label
matches you; `--force` overrides. A *missing* label counts as not-yours. Every
image predating this change is unlabelled, but manual relabelling covers those,
so a permanent permissive branch for a transient state isn't warranted.

## Data flow — `sandbox list` (CLOUD=gcp)

1. `bin/sandbox-list` → `provider_list_all` → GCP driver.
2. Driver sources `lib/identity.sh`; `sandbox_owner_label` reads gcloud's
   config files (local, memoized).
3. `gcloud compute instances list --filter="labels.project=claude-sandbox AND
   labels.owner=<label>"`.
4. Existing jq pipeline emits the normalized 10-field record. Unchanged.

## Error handling

| Condition | Behavior |
|---|---|
| gcloud config files unreadable *and* `gcloud config get-value account` fails | `die`: "cannot determine your gcloud account — run `gcloud auth login`". |
| Active account empty (never authenticated) | Same `die`. |
| Sanitized label exceeds 63 chars | `die` with the offending value. |
| `ssh`/`scp`/`down` naming a foreign box | `die` "no sandbox named X (try ./bin/sandbox list)" — the existing message. |
| `delete-image` on a foreign or unlabelled image | `die` naming the owner (or "unlabelled"), suggesting `--force`. |

Every failure is fatal by design. Falling back to unfiltered operation would
silently restore the accident this feature exists to prevent.

## Testing

Extend `test/unit/gcp.bats`; add `test/unit/identity.bats`. Existing
`GCLOUD_CMD` stub seam, plus fixture gcloud config files in a temp
`$CLOUDSDK_CONFIG` — which makes the fast path directly testable without
touching the real `~/.config/gcloud`.

- Identity: fast path; `CLOUDSDK_ACTIVE_CONFIG_NAME` honored; non-default
  config name; fallback to `gcloud` when files are absent; both-fail `die`;
  sanitization of dots and `@`; over-63-char `die`; memoization.
- Launch: `owner` label applied; metadata holds the unmodified email.
- List: filter string carries `labels.owner`.
- Resolve: `provider_resolve_ip` rejects a foreign box and an unlabelled one,
  and still reports "booting" for a box you own. (Asserted directly on the
  driver — `ssh`/`scp` don't call it; they are covered by the list filter.)
- Down: `--all` and `--stale` exclude foreign boxes.
- Completion: `_sandbox_names_gcp` filter carries owner.
- Images: labels + description written at bake; `list-images` unfiltered and
  renders OWNER/BOOTSTRAP; `image-info` prints the manifest; `delete-image`
  refuses foreign, refuses unlabelled, passes on `--force`.

## Manual onboarding (no code)

Before a second user starts, relabel existing resources once:

    gcloud compute instances add-labels NAME --zone ZONE \
        --labels=owner=<your-sanitized-email> --project PROJECT
    gcloud compute images add-labels NAME \
        --labels=owner=<your-sanitized-email> --project PROJECT

Anything left unlabelled stays invisible to `list`, untouched by `down`, and
undeletable by `delete-image` without `--force`.

## Open questions / risks

- **No escape hatch, by choice.** Cleaning up a departed colleague's boxes
  needs raw `gcloud`. Accepted as the cost of hard isolation.
- **gcloud's config layout is internal.** The fast path could break on a future
  gcloud release; the `gcloud config get-value account` fallback covers it, at
  the cost of a slow Tab until someone notices.
- **`README.md:165-181` / `init.sh:47-53` document a credential mechanism
  nothing reads.** Pre-existing and independent of this feature; tracked in
  `docs/BACKLOG.md`. Noted here only because this spec's identity source
  replaces the assumption they encode.
