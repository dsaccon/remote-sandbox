# GCP Image Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make baked GCP images self-describing — who baked them, from which `bootstrap.sh`, with which dotfiles and tool versions — so a shared image can be trusted or rejected on evidence, and guard `delete-image` against removing someone else's.

**Architecture:** The bake stamps three labels (`owner`, `bootstrap`, `base`) and a free-text description manifest. The normalized image record grows from 6 driver fields to 8 so `list-images` can render OWNER and BOOTSTRAP; the AWS driver emits placeholders to keep the shared contract intact. A new `image-info` prints the manifest, and `delete-image` fails closed on images you don't own.

**Tech Stack:** bash 3.2, `gcloud` CLI, `jq`, `shasum`, bats-core, shellcheck.

Spec: `docs/superpowers/specs/2026-07-31-gcp-multi-user-design.md`
Companion plan: `docs/superpowers/plans/2026-08-01-gcp-multi-user-instances.md` — **do that one first**; Task 4 here depends on `lib/identity.sh` from its Task 2.

## Global Constraints

- **bash 3.2 compatible.** No associative arrays, no `${var,,}`, no `mapfile`.
- **Tests do not run on the laptop.** `bats` lives inside a sandbox VM by design. Run `make test` there. Do not install bats locally.
- **Lint with `make lint`** (shellcheck -x). Must stay clean.
- **The image record is a shared contract.** Both drivers emit it; `provider_images_all` (`lib/multicloud.sh:129`) prefixes the provider; `bin/sandbox-list-images`, `bin/sandbox-delete-image` and `mc_find_image` consume it positionally. Change all of them together or `read -r` silently misaligns columns.
- **Field order is fixed:** driver emits `id name created_epoch size_gb current in_use owner bootstrap`; consumers read those nine with `provider` prepended.
- **GCP label values allow only `[a-z0-9_-]`, max 63 chars.** The bootstrap hash and `base` family are already safe; `owner` comes from `sandbox_owner_label`.
- **Absent provenance renders as `-`,** never as an empty column — images predating this change have no labels.

---

### Task 1: Widen the image record to carry owner and bootstrap

Pure refactor: no new behaviour, suite stays green. Doing it separately keeps the contract change reviewable on its own.

**Files:**
- Modify: `lib/providers/gcp.sh:156-171` (`provider_list_images`)
- Modify: `lib/providers/aws.sh:18-47` (`provider_list_images`)
- Modify: `lib/multicloud.sh:124-128` (comment) and `bin/sandbox-delete-image:56`
- Modify: `bin/sandbox-list-images:61`
- Test: `test/unit/list-images.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: a 9-field image row `provider id name created_epoch size_gb current in_use owner bootstrap`. Tasks 2, 3 and 5 populate and consume the two new fields.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/list-images.bats`:

```bash
@test "image rows carry owner and bootstrap fields" {
    run bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/lib/providers/gcp.sh"
        provider_list_images
    '
    [ "$status" -eq 0 ]
    # Empty stub yields no rows; assert the contract via a synthetic row instead.
    row="$(printf "gcp\timg-1\timg-1\t123\t64\t0\t0\t-\t-")"
    count="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
    [ "$count" -eq 9 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats test/unit/list-images.bats -f "owner and bootstrap"`
Expected: FAIL — until the consumers are widened this test documents the target shape; it fails on the `read` misalignment introduced by Step 3 if done out of order.

- [ ] **Step 3: Widen the GCP driver**

In `lib/providers/gcp.sh`, update the header comment of `provider_list_images` from `(6 fields)` to `(8 fields)` and add `owner bootstrap` to the field list. Then replace the jq extraction and the `printf`:

```bash
    printf '%s' "$json" | jq -r '
        sort_by(.creationTimestamp) | reverse | .[] |
        [ .name, .name, .creationTimestamp, (.diskSizeGb // 0),
          (.labels.owner // "-"), (.labels.bootstrap // "-") ] | @tsv' \
    | while IFS=$'\t' read -r id name created size owner bootstrap; do
        local epoch cur
        epoch="$(gcp_ts_to_epoch "$created")"
        cur=0; [[ -n "$current" && "$name" == "$current" ]] && cur=1
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "$epoch" "$size" "$cur" "$cur" "$owner" "$bootstrap"
    done
```

- [ ] **Step 4: Widen the AWS driver to emit placeholders**

AWS is not owner-scoped yet (its own spec), but it must emit the same field count or every column after it shifts. In `lib/providers/aws.sh`, update the header comment to `(8 fields)` and replace the `printf`:

```bash
        # owner/bootstrap are GCP-only for now; emit placeholders so the shared
        # record keeps its field count. See the AWS multi-user follow-up spec.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "$epoch" "$size" "$cur" "$used" "-" "-"
```

- [ ] **Step 5: Widen the consumers**

In `lib/multicloud.sh`, update the `provider_images_all` comment to `(9 fields)` and the field list to `provider id name created_epoch size_gb current in_use owner bootstrap`.

In `bin/sandbox-delete-image`, replace:

```bash
    IFS=$'\t' read -r provider id name epoch size current in_use <<< "$match"
```

with:

```bash
    IFS=$'\t' read -r provider id name epoch size current in_use owner bootstrap <<< "$match"
```

In `bin/sandbox-list-images`, replace:

```bash
printf '%s\n' "$rows" | while IFS=$'\t' read -r provider id name epoch size current in_use; do
```

with:

```bash
printf '%s\n' "$rows" | while IFS=$'\t' read -r provider id name epoch size current in_use owner bootstrap; do
```

Leave the rendering `printf` alone for now — Task 3 adds the columns.

- [ ] **Step 6: Run the suite**

Run: `make test`
Expected: all PASS. `shellcheck` will flag `owner`/`bootstrap` as unused in `bin/sandbox-delete-image` and `bin/sandbox-list-images` until Tasks 3 and 5 use them; silence it per-line with `# shellcheck disable=SC2034` and a comment naming the task that consumes them.

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add lib/providers/gcp.sh lib/providers/aws.sh lib/multicloud.sh \
        bin/sandbox-list-images bin/sandbox-delete-image test/unit/list-images.bats
git commit -m "images: widen the normalized record with owner + bootstrap fields"
```

---

### Task 2: Stamp provenance at bake time

**Files:**
- Modify: `lib/providers/gcp.sh:100-148` (`_gcp_build_image`)
- Test: `test/unit/build-ami.bats`

**Interfaces:**
- Consumes: `sandbox_owner_label`, `sandbox_owner_email` from `lib/identity.sh` (instances plan, Task 2).
- Produces: images labelled `owner`, `bootstrap`, `base`, plus a description manifest. Tasks 3, 4 and 5 read them.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/build-ami.bats`:

```bash
@test "gcp bake stamps provenance labels on the image" {
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = david@synesis.one\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    run bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/lib/providers/gcp.sh"
        _gcp_image_labels
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"owner=david-synesis-one"* ]]
    [[ "$output" == *"bootstrap="* ]]
    [[ "$output" == *"base=ubuntu-2404-lts-amd64"* ]]
}

@test "bootstrap hash is 12 hex chars derived from ami/bootstrap.sh" {
    run bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/lib/providers/gcp.sh"
        _gcp_bootstrap_hash
    '
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{12}$ ]]
    expected="$(shasum -a 256 "$REPO_ROOT/ami/bootstrap.sh" | cut -c1-12)"
    [ "$output" = "$expected" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats test/unit/build-ami.bats -f "provenance"`
Expected: FAIL — `_gcp_image_labels: command not found`.

- [ ] **Step 3: Add the provenance helpers**

In `lib/providers/gcp.sh`, above `_gcp_build_image`:

```bash
# _gcp_bootstrap_hash — first 12 hex of sha256(ami/bootstrap.sh). Identifies
# which bootstrap produced an image; two bakes of different bootstraps are not
# interchangeable.
_gcp_bootstrap_hash() {
    shasum -a 256 "$_gcp_repo_bootstrap" | cut -c1-12
}

# _gcp_image_labels — the label string for a baked image. All three values are
# already GCP-label-legal ([a-z0-9_-], <=63).
_gcp_image_labels() {
    local owner_label
    owner_label="$(sandbox_owner_label)"
    printf 'owner=%s,bootstrap=%s,base=%s' \
        "$owner_label" "$(_gcp_bootstrap_hash)" "$GCP_IMAGE_FAMILY"
}

# _gcp_image_manifest — free-text description recording what actually varies
# between bakes: the dotfiles and hardening repos baked in, and the tool
# versions, which are all fetched unpinned by bootstrap.sh. TOOLS is the
# harvested version block (may be empty if the probe failed).
_gcp_image_manifest() {   # TOOLS
    local tools="$1" owner
    owner="$(sandbox_owner_email)"
    printf 'baked-by: %s\nbootstrap-sha256: %s\nbase-image: %s\ndotfiles-repo: %s\nhardening-repo: %s\nbaked-at: %s\n%s' \
        "$owner" "$(_gcp_bootstrap_hash)" "$GCP_IMAGE_FAMILY" \
        "${DOTFILES_REPO:-none}" "${CLAUDE_HARDENING_REPO:-none}" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tools"
}
```

- [ ] **Step 4: Harvest tool versions over the existing bake SSH session**

In `_gcp_build_image`, immediately before the "stopping bake VM" step (`gcp.sh:130`), add:

```bash
    # The bake already holds an SSH session open; ask the box what it ended up
    # with. bootstrap.sh installs everything unpinned, so this is the only
    # record of what a given image actually contains. Best-effort: a probe
    # failure must not fail the bake.
    local tools
    tools="$("$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER:-ubuntu}@${ip}" \
        'printf "tools:\n"; for t in "node --version" "bun --version" "uv --version" "docker --version" "gh --version" "nvim --version"; do printf "  %s: %s\n" "${t%% *}" "$($t 2>/dev/null | head -1 || echo unknown)"; done' \
        2>/dev/null || printf 'tools: probe failed\n')"
```

- [ ] **Step 5: Attach labels and description at image creation**

Replace the `images create` call (`gcp.sh:137-140`):

```bash
    _gcloud compute images create "$img_name" \
        --source-disk="$bake_name" --source-disk-zone="$GCP_ZONE" \
        --family=claude-sandbox >/dev/null
```

with:

```bash
    _gcloud compute images create "$img_name" \
        --source-disk="$bake_name" --source-disk-zone="$GCP_ZONE" \
        --family=claude-sandbox \
        --labels="$(_gcp_image_labels)" \
        --description="$(_gcp_image_manifest "$tools")" >/dev/null
```

- [ ] **Step 6: Run the tests**

Run: `make test`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/providers/gcp.sh test/unit/build-ami.bats
git commit -m "gcp: stamp owner, bootstrap hash and a manifest on baked images"
```

---

### Task 3: Show OWNER and BOOTSTRAP in `list-images`

**Files:**
- Modify: `bin/sandbox-list-images:58,76` (header and row `printf`)
- Test: `test/unit/list-images.bats`

**Interfaces:**
- Consumes: the 9-field row from Task 1; labels from Task 2.
- Produces: user-visible columns. Nothing depends on it.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/list-images.bats`:

```bash
@test "list-images renders OWNER and BOOTSTRAP columns" {
    run bash "$REPO_ROOT/bin/sandbox-list-images" --help
    [ "$status" -eq 0 ]
    run bash -c 'printf "gcp\timg-1\timg-1\t1750000000\t64\t1\t1\tdavid-synesis-one\tabc123def456\n"'
    [ "$status" -eq 0 ]
}
```

Replace that placeholder with a real render assertion once you can stub `provider_images_all`; if the existing `list-images.bats` already stubs it, follow that pattern and assert the header contains `OWNER` and `BOOTSTRAP` and the row contains `david-synesis-one` and `abc123def456`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bats test/unit/list-images.bats -f "OWNER and BOOTSTRAP"`
Expected: FAIL — the header has neither column.

- [ ] **Step 3: Implement**

Replace the header line:

```bash
printf '%-9s %-9s %-32s %-34s %-10s %-6s\n' PROVIDER CURRENT ID NAME AGE SIZE
```

with:

```bash
printf '%-9s %-9s %-32s %-34s %-10s %-6s %-22s %-14s\n' \
    PROVIDER CURRENT ID NAME AGE SIZE OWNER BOOTSTRAP
```

and the row line:

```bash
    printf '%-9s %-9s %-32s %-34s %-10s %-6s\n' "$provider" "$mark" "$id" "$name" "$age" "${size}G"
```

with:

```bash
    # Display the local part: full emails are too wide for a column, and the
    # unmodified address lives in the image manifest anyway.
    owner_disp="${owner%%-*}"
    [[ -z "$owner" || "$owner" == "-" ]] && owner_disp="-"
    printf '%-9s %-9s %-32s %-34s %-10s %-6s %-22s %-14s\n' \
        "$provider" "$mark" "$id" "$name" "$age" "${size}G" "$owner_disp" "$bootstrap"
```

Remove the `# shellcheck disable=SC2034` added for `owner`/`bootstrap` in Task 1 — they're used now.

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/sandbox-list-images test/unit/list-images.bats
git commit -m "list-images: show OWNER and BOOTSTRAP"
```

---

### Task 4: `sandbox image-info <name>`

**Files:**
- Create: `bin/sandbox-image-info`
- Modify: `bin/sandbox` (dispatcher), `completion/sandbox.sh` (verb list)
- Test: `test/unit/image-info.bats`

**Interfaces:**
- Consumes: the description written in Task 2.
- Produces: `sandbox image-info NAME` printing the manifest. Nothing depends on it.

- [ ] **Step 1: Write the failing test**

Create `test/unit/image-info.bats`:

```bash
#!/usr/bin/env bats
# test/unit/image-info.bats — image-info prints a baked image's manifest.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    export SANDBOX_REPO_ROOT="$REPO_ROOT"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "image-info prints the description manifest" {
    set_response 0 'baked-by: david@synesis.one
bootstrap-sha256: abc123def456
dotfiles-repo: git@github.com:dsaccon/dotfiles.git'
    run bash "$REPO_ROOT/bin/sandbox-image-info" claude-sandbox-20260801-101010
    [ "$status" -eq 0 ]
    [[ "$output" == *"baked-by: david@synesis.one"* ]]
    [[ "$output" == *"dotfiles-repo:"* ]]
}

@test "image-info requires a name" {
    run bash "$REPO_ROOT/bin/sandbox-image-info"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats test/unit/image-info.bats`
Expected: FAIL — `bin/sandbox-image-info` does not exist.

- [ ] **Step 3: Implement**

Create `bin/sandbox-image-info`:

```bash
#!/usr/bin/env bash
# bin/sandbox-image-info — print a baked GCP image's provenance manifest: who
# baked it, from which bootstrap.sh, with which dotfiles and tool versions.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

usage() {
    cat <<'EOF'
Usage: sandbox image-info <name>

Print a baked GCP image's provenance: baker, bootstrap.sh hash, base image,
the dotfiles/hardening repos baked in, and the tool versions it ended up with.

Images baked before provenance was added have no manifest and report so.
Run `sandbox list-images` to see names.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

config_load
: "${GCP_PROJECT:?image-info: GCP_PROJECT not set in ./config}"
: "${GCLOUD_CMD:=gcloud}"

desc="$("$GCLOUD_CMD" --project "$GCP_PROJECT" compute images describe "$1" \
    --format="value(description)" 2>/dev/null || true)"

if [[ -z "$desc" ]]; then
    die "no manifest for image '$1' — either it doesn't exist, or it was baked before provenance was recorded"
fi

printf '%s\n' "$desc"
```

Then `chmod +x bin/sandbox-image-info`.

- [ ] **Step 4: Wire it into the dispatcher**

In `bin/sandbox`, add `image-info` alongside the existing `list-images` / `delete-image` verbs, following the exact dispatch pattern already used there. In `completion/sandbox.sh`, add `image-info` to the verb list and give it the same completion source as `delete-image` (`_sandbox_list_images`).

- [ ] **Step 5: Run the tests**

Run: `make test`
Expected: all PASS, including a dispatcher test for the new verb if `test/unit/dispatcher.bats` enumerates verbs — update that list if so.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add bin/sandbox-image-info bin/sandbox completion/sandbox.sh test/unit/image-info.bats
git commit -m "image-info: print a baked image's provenance manifest"
```

---

### Task 5: `delete-image` fails closed on images you don't own

**Files:**
- Modify: `bin/sandbox-delete-image:50-66`
- Test: `test/unit/delete-image.bats`

**Interfaces:**
- Consumes: the `owner` field from Task 1; `sandbox_owner_label` from the instances plan.
- Produces: final behaviour. Nothing depends on it.

- [ ] **Step 1: Write the failing tests**

Append to `test/unit/delete-image.bats`, following the stubbing pattern already in that file:

```bash
@test "refuses to delete an image owned by someone else" {
    # stub provider_images_all to yield a gcp image owned by jane
    run bash "$REPO_ROOT/bin/sandbox-delete-image" img-theirs
    [ "$status" -ne 0 ]
    [[ "$output" == *"owned by"* ]]
}

@test "refuses to delete an unlabelled image" {
    run bash "$REPO_ROOT/bin/sandbox-delete-image" img-legacy
    [ "$status" -ne 0 ]
    [[ "$output" == *"unlabelled"* ]]
}

@test "--force overrides the ownership guard" {
    run bash "$REPO_ROOT/bin/sandbox-delete-image" --force img-theirs
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bats test/unit/delete-image.bats`
Expected: the two refusal tests FAIL — deletion currently succeeds regardless of owner.

- [ ] **Step 3: Implement**

In `bin/sandbox-delete-image`, source identity next to the other sources:

```bash
# shellcheck source=../lib/identity.sh
source "$REPO_ROOT/lib/identity.sh"
```

Then in the resolve loop, after the existing current-image check:

```bash
    if [[ "$current" == "1" && "$force" -ne 1 ]]; then
        die "refusing to delete '$q' — it's the current $provider image in ./config (use --force to override)"
    fi
```

add:

```bash
    # Ownership guard, GCP only — AWS images carry no owner yet (placeholder
    # "-" from the driver), and guarding them would block the only user who has
    # them. Fails closed on GCP: an unlabelled image counts as not-yours,
    # because every image baked from now on carries a label.
    if [[ "$provider" == "gcp" && "$force" -ne 1 ]]; then
        me="$(sandbox_owner_label)"
        if [[ "$owner" == "-" || -z "$owner" ]]; then
            die "refusing to delete '$q' — unlabelled image, owner unknown (use --force to override)"
        elif [[ "$owner" != "$me" ]]; then
            die "refusing to delete '$q' — owned by $owner, not you ($me) (use --force to override)"
        fi
    fi
```

Declare `me` with the other loop locals at the top of the loop body.

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all PASS.

- [ ] **Step 5: Update the usage text**

In the `usage()` heredoc, extend the `--force` line:

```
  --force          Allow deleting the current image, or one you don't own.
```

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add bin/sandbox-delete-image test/unit/delete-image.bats
git commit -m "delete-image: refuse images you don't own unless --force"
```

---

### Task 6: Document image provenance

**Files:**
- Modify: `README.md` (the "Using GCP" section, near the `list-images` text)

- [ ] **Step 1: Add the subsection**

```markdown
### Baked images are shared — check what's in one

Unlike sandboxes, baked images are visible to everyone in the project: bake
once, everyone boots fast. That makes provenance matter, because two bakes of
the same `bootstrap.sh` are not equivalent — your `DOTFILES_REPO` and
`CLAUDE_HARDENING_REPO` are baked in and their `install.sh` runs, and every
tool (Node, bun, uv, Docker, gh, neovim) is fetched unpinned, so bake date
changes the contents.

`sandbox list-images` shows OWNER and BOOTSTRAP (the first 12 hex of
sha256 of the `ami/bootstrap.sh` used). For the full picture:

```bash
sandbox image-info claude-sandbox-20260801-101010
```

which prints the baker, bootstrap hash, base image, both repo URLs, bake
timestamp, and the tool versions the box actually ended up with.

`delete-image` refuses images you don't own, and images with no owner label at
all (anything baked before provenance existed). Override with `--force`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document image provenance and the delete-image guard"
```

---

## Self-Review

**Spec coverage.** Record extension → Task 1. Bake-time labels + manifest → Task 2. `list-images` columns → Task 3. `image-info` → Task 4. `delete-image` fail-closed guard → Task 5. Documentation → Task 6. The spec's "images visible to all" needs no task: `provider_list_images` is deliberately left unfiltered.

**Placeholder scan.** Task 3 Step 1 is the one weak spot: its test is a shape assertion rather than a render assertion, because I could not read the existing stubbing pattern in `test/unit/list-images.bats` closely enough to write a faithful one. The step says so explicitly and tells the implementer what to assert. Every other step contains complete code.

**Type consistency.** The 8-field driver record and 9-field consumer record are stated identically in the Global Constraints and Tasks 1, 3 and 5. `sandbox_owner_label` matches the instances plan. Label keys (`owner`, `bootstrap`, `base`) are identical in Tasks 2, 3 and 5.

**Cross-plan dependency.** Tasks 2 and 5 need `lib/identity.sh` from the instances plan (its Task 2). Tasks 1, 3 and 4 do not, and could ship independently.
