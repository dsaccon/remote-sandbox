# GCP Multi-User (Instances) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scope every GCP sandbox to the gcloud account that launched it, so one user's `down --all` can never touch another user's boxes.

**Architecture:** A new `lib/identity.sh` resolves the caller's gcloud account by reading gcloud's own config files. The GCP driver stamps that identity as an `owner` label at launch and adds it to the server-side filter in `provider_list`. Because `down`, `ssh` and `scp` all route through `provider_list` via `lib/multicloud.sh`, scoping one filter string scopes every destructive path. `provider_resolve_ip` is the one bypass and gets its own check.

**Tech Stack:** bash 3.2, `gcloud` CLI, `jq`, bats-core for tests, shellcheck for lint.

Spec: `docs/superpowers/specs/2026-07-31-gcp-multi-user-design.md`
Companion plan: `docs/superpowers/plans/2026-08-01-gcp-multi-user-images.md` (image provenance; independent, do this one first).

## Global Constraints

- **bash 3.2 compatible.** macOS ships 3.2 and the repo is 3.2-clean. No associative arrays, no `${var,,}`, no `mapfile`.
- **Tests do not run on the laptop.** `bats` is deliberately absent (see README "Local footprint"); it lives inside a sandbox VM. Run `make test` on a sandbox box, or wherever bats is available. Do not `brew install bats-core` on the laptop.
- **Lint with `make lint`** (shellcheck -x). It must stay clean.
- **`die` calls `exit 1`** (`lib/log.sh:20`). Never let it run in the shell-completion path — completion functions execute in the user's interactive shell and `exit` would close their terminal. Contain identity resolution in a subshell there.
- **`local x="$(cmd)"` masks `cmd`'s exit status** under `set -e`. Always declare then assign on separate lines when the value comes from a function that can `die`.
- **Stub seam:** all gcloud calls go through `$GCLOUD_CMD` so tests can stub. `completion/sandbox.sh` is the documented exception — it calls `gcloud` directly.
- **Identity is not memoized.** Callers use `$(sandbox_owner_label)`, which is a subshell, so a cached global would never propagate. Each consumer resolves once into a local. Cost is two small file reads; this deviates from the spec's "memoized" wording, which was unnecessary.

---

### Task 1: Establish a green baseline

The suite must be green before behaviour changes, or later failures are unattributable. `test/unit/gcp.bats:32` asserts output ("not yet supported") that no longer exists in `lib/` since GCP baking landed in `8f1b817`.

**Files:**
- Test: `test/unit/gcp.bats:29-33`

**Interfaces:**
- Consumes: nothing.
- Produces: a green `make test`, which every later task's verification depends on.

- [ ] **Step 1: Run the full suite on a machine that has bats**

Run: `make test`
Expected: either all green (then skip to Step 4), or a failure in `gcp.bats` on the `provider_build_image` test.

- [ ] **Step 2: Confirm the assertion is stale**

Run: `grep -rn "not yet supported" lib/ bin/`
Expected: no output — the string exists only in the test.

- [ ] **Step 3: Replace the stale test with one asserting current behaviour**

In `test/unit/gcp.bats`, replace:

```bash
@test "provider_build_image is unsupported on gcp" {
    run provider_build_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"not yet supported"* ]]
}
```

with:

```bash
@test "provider_build_image delegates to the gcp baker" {
    run provider_build_image
    # Without GCP_ZONE/SSH_KEY_FILE set, _gcp_build_image must fail loudly on a
    # missing prerequisite rather than silently proceeding.
    [ "$status" -ne 0 ]
    [[ "$output" == *"build-ami"* ]]
}
```

- [ ] **Step 4: Run the suite again**

Run: `make test`
Expected: all tests pass.

- [ ] **Step 5: Commit (skip if Step 1 was already green)**

```bash
git add test/unit/gcp.bats
git commit -m "test: fix stale build-ami assertion in gcp.bats"
```

---

### Task 2: `lib/identity.sh` — resolve the caller's gcloud account

**Files:**
- Create: `lib/identity.sh`
- Test: `test/unit/identity.bats`

**Interfaces:**
- Consumes: `die` from `lib/log.sh`; `$GCLOUD_CMD` for the fallback.
- Produces:
  - `sandbox_owner_email` → prints e.g. `david@synesis.one`; `die`s if unresolvable.
  - `sandbox_owner_label` → prints e.g. `david-synesis-one`; `die`s if unresolvable or >63 chars.

  Both are consumed by Tasks 3–6 and by the images plan.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/identity.bats`:

```bash
#!/usr/bin/env bats
# test/unit/identity.bats — owner identity from gcloud's active account.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"; : > "$GCLOUD_STUB_LOG"
    export GCLOUD_STUB_RESPONSE="$BATS_TEST_TMPDIR/gcloud-resp"
    export GCLOUD_CMD="$REPO_ROOT/test/unit/stubs/gcloud-empty"
    source "$REPO_ROOT/lib/identity.sh"
}

write_cfg() {   # CONFIG_NAME EMAIL
    printf '[core]\naccount = %s\nproject = proj\n' "$2" \
        > "$CLOUDSDK_CONFIG/configurations/config_$1"
}
set_response() { local rc="$1"; shift; { echo "$rc"; printf '%s' "$*"; } > "$GCLOUD_STUB_RESPONSE"; }

@test "reads the account from the default config" {
    write_cfg default david@synesis.one
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "david@synesis.one" ]
}

@test "honours the config named by active_config" {
    write_cfg work jane@corp.com
    printf 'work\n' > "$CLOUDSDK_CONFIG/active_config"
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "jane@corp.com" ]
}

@test "CLOUDSDK_ACTIVE_CONFIG_NAME overrides active_config" {
    write_cfg work jane@corp.com
    write_cfg other bob@corp.com
    printf 'work\n' > "$CLOUDSDK_CONFIG/active_config"
    CLOUDSDK_ACTIVE_CONFIG_NAME=other run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "bob@corp.com" ]
}

@test "falls back to gcloud when the config file is absent" {
    set_response 0 'fallback@corp.com'
    run sandbox_owner_email
    [ "$status" -eq 0 ]
    [ "$output" = "fallback@corp.com" ]
    grep -q "config get-value account" "$GCLOUD_STUB_LOG"
}

@test "dies when the file is absent and gcloud yields nothing" {
    set_response 0 ''
    run sandbox_owner_email
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud auth login"* ]]
}

@test "dies when gcloud reports the account unset" {
    set_response 0 '(unset)'
    run sandbox_owner_email
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud auth login"* ]]
}

@test "label replaces @ and . with dashes" {
    write_cfg default david@synesis.one
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "david-synesis-one" ]
}

@test "label uses the full email so local parts cannot collide" {
    write_cfg default first.last@corp.com
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "first-last-corp-com" ]
}

@test "label lowercases" {
    write_cfg default David@Synesis.One
    run sandbox_owner_label
    [ "$status" -eq 0 ]
    [ "$output" = "david-synesis-one" ]
}

@test "label dies when it would exceed 63 chars" {
    write_cfg default "$(printf 'a%.0s' $(seq 1 60))@synesis.one"
    run sandbox_owner_label
    [ "$status" -ne 0 ]
    [[ "$output" == *"63"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/unit/identity.bats`
Expected: every test FAILs — `lib/identity.sh` does not exist, so `source` errors in `setup`.

- [ ] **Step 3: Write the implementation**

Create `lib/identity.sh`:

```bash
#!/usr/bin/env bash
# lib/identity.sh — who is running this command, for owner-scoping GCP
# resources. Identity is gcloud's ACTIVE ACCOUNT, read from gcloud's own config
# files so the hot path (tab completion) never spawns gcloud.
#
# Source, don't execute. Idempotent.

if [[ -n "${_SANDBOX_IDENTITY_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_IDENTITY_SH_LOADED=1

_identity_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_identity_sh_dir/log.sh"

: "${GCLOUD_CMD:=gcloud}"

# sandbox_owner_email — gcloud's active account, e.g. david@synesis.one.
#
# Fast path reads gcloud's config files directly (two small reads, no process
# spawn). Falls back to `gcloud config get-value account` if that layout ever
# changes — correct but ~1-2s, which is why it is not the default.
sandbox_owner_email() {
    local root name file email=""

    root="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
    name="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}"
    if [[ -z "$name" && -r "$root/active_config" ]]; then
        name="$(tr -d '[:space:]' < "$root/active_config")"
    fi
    [[ -z "$name" ]] && name="default"

    file="$root/configurations/config_$name"
    if [[ -r "$file" ]]; then
        # Lines look like:  account = david@synesis.one
        email="$(awk -F'=' '/^[[:space:]]*account[[:space:]]*=/ {
                     gsub(/[[:space:]]/, "", $2); print $2; exit }' "$file")"
    fi

    if [[ -z "$email" ]]; then
        email="$("$GCLOUD_CMD" config get-value account 2>/dev/null | tr -d '[:space:]')"
    fi

    [[ -n "$email" && "$email" != "(unset)" ]] \
        || die "cannot determine your gcloud account — run 'gcloud auth login'"

    printf '%s' "$email"
}

# sandbox_owner_label — GCP-label-safe form of the full email, e.g.
# david-synesis-one. Label values allow only [a-z0-9_-], max 63 chars.
#
# Uses the FULL email, not the local part: first.last@corp.com and
# first-last@corp.com both reduce to first-last, and a label collision would
# silently show two people each other's boxes.
sandbox_owner_label() {
    local email label
    email="$(sandbox_owner_email)" || return 1
    label="$(printf '%s' "$email" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9_-]/-/g')"
    [[ "${#label}" -le 63 ]] \
        || die "owner label for '$email' exceeds the 63-char GCP label limit"
    printf '%s' "$label"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/unit/identity.bats`
Expected: 10 tests, all PASS.

- [ ] **Step 5: Lint**

Run: `make lint`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/identity.sh test/unit/identity.bats
git commit -m "identity: resolve owner from gcloud's active account"
```

---

### Task 3: Stamp the owner on launch

**Files:**
- Modify: `lib/providers/gcp.sh:203-230` (`provider_launch`)
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Consumes: `sandbox_owner_label`, `sandbox_owner_email` (Task 2).
- Produces: instances labelled `owner=<label>` and carrying metadata `owner=<email>`. Tasks 4 and 5 filter on that label.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/gcp.bats`:

```bash
@test "provider_launch labels the instance with the owner" {
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = david@synesis.one\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    set_response 0 ''
    echo "ssh-ed25519 AAAA test" > "$BATS_TEST_TMPDIR/id.pub"
    GCP_SSH_PUBKEY="$BATS_TEST_TMPDIR/id.pub" AUTO_SHUTDOWN_HOURS=0 \
        run provider_launch sandbox-abc "" false "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- "--labels=project=claude-sandbox,name=sandbox-abc,owner=david-synesis-one" \
        "$GCLOUD_STUB_LOG"
    grep -q -- "owner=david@synesis.one" "$GCLOUD_STUB_LOG"
}
```

Add `source "$REPO_ROOT/lib/identity.sh"` to the `setup()` in `test/unit/gcp.bats`, after the existing `source` of the driver.

- [ ] **Step 2: Run it to verify it fails**

Run: `bats test/unit/gcp.bats -f "labels the instance with the owner"`
Expected: FAIL — the logged `--labels=` has no `owner=` and metadata shows `owner=<you>@<host>`.

- [ ] **Step 3: Implement**

In `lib/providers/gcp.sh`, add the identity source next to the existing ones near the top (after the `common.sh` source):

```bash
# shellcheck source=../identity.sh
source "$_gcp_sh_dir/../identity.sh"
```

In `provider_launch`, replace:

```bash
    local owner; owner="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"
```

with:

```bash
    # Owner is gcloud's active account — the principal GCP actually
    # authenticates, not a local guess. Declared then assigned: under `set -e`,
    # `local x="$(...)"` would mask a die() from the identity helpers.
    local owner owner_label
    owner="$(sandbox_owner_email)"
    owner_label="$(sandbox_owner_label)"
```

and in the `args=(...)` array replace:

```bash
        --labels="project=claude-sandbox,name=$name"
```

with:

```bash
        --labels="project=claude-sandbox,name=$name,owner=$owner_label"
```

The `--metadata="owner=$owner,..."` line already interpolates `$owner` and now
carries the full email; leave it as it is.

- [ ] **Step 4: Run the tests**

Run: `bats test/unit/gcp.bats`
Expected: all PASS, including the pre-existing launch regression tests.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: stamp the gcloud account as owner label + metadata on launch"
```

---

### Task 4: Filter `provider_list` by owner

This is the task that delivers the safety property: `down <name>`, `down --all` and `down --stale` all consume `provider_list` through `lib/multicloud.sh:38`, so scoping this filter scopes every destructive path.

**Files:**
- Modify: `lib/providers/gcp.sh:277-281` (`provider_list`)
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Consumes: `sandbox_owner_label` (Task 2); the `owner` label written by Task 3.
- Produces: a `provider_list` that only ever emits the caller's boxes. `down`/`ssh`/`scp` inherit this with no change of their own.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/gcp.bats`:

```bash
@test "provider_list filters instances by owner label" {
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = david@synesis.one\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    set_response 0 '[]'
    run provider_list
    [ "$status" -eq 0 ]
    grep -q -- "labels.owner=david-synesis-one" "$GCLOUD_STUB_LOG"
    grep -q -- "labels.project=claude-sandbox" "$GCLOUD_STUB_LOG"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bats test/unit/gcp.bats -f "filters instances by owner label"`
Expected: FAIL — the logged filter contains only `labels.project=claude-sandbox`.

- [ ] **Step 3: Implement**

In `provider_list`, replace:

```bash
    inst="$(_gcloud compute instances list \
        --filter="labels.project=claude-sandbox" --zones="$GCP_ZONE" --format=json 2>/dev/null || echo '[]')"
```

with:

```bash
    local owner_label
    owner_label="$(sandbox_owner_label)"
    inst="$(_gcloud compute instances list \
        --filter="labels.project=claude-sandbox AND labels.owner=$owner_label" \
        --zones="$GCP_ZONE" --format=json 2>/dev/null || echo '[]')"
```

Leave the firewall query and the jq pipeline untouched.

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all PASS. `test/unit/list.bats` and `test/unit/down.bats` must stay green — they stub gcloud and assert on normalized rows, not on the filter string.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: scope list (and thus down/ssh/scp) to the calling account"
```

---

### Task 5: Ownership check in `provider_resolve_ip`

`provider_resolve_ip` calls `instances describe <name>` directly and so bypasses the Task 4 filter. Without this, `ssh <colleague-box>` reaches a foreign box by name.

**Files:**
- Modify: `lib/providers/gcp.sh:304-318` (`provider_resolve_ip`)
- Test: `test/unit/gcp.bats`

**Interfaces:**
- Consumes: `sandbox_owner_label` (Task 2).
- Produces: `ssh`/`scp` failing cleanly on a foreign box with the existing not-found wording.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/gcp.bats`:

```bash
@test "provider_resolve_ip rejects a box owned by someone else" {
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = david@synesis.one\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    set_response 0 '{"status":"RUNNING","labels":{"project":"claude-sandbox","owner":"jane-corp-com"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}'
    run provider_resolve_ip sandbox-theirs
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named sandbox-theirs"* ]]
}

@test "provider_resolve_ip accepts a box you own" {
    export CLOUDSDK_CONFIG="$BATS_TEST_TMPDIR/gcloudcfg"
    mkdir -p "$CLOUDSDK_CONFIG/configurations"
    printf '[core]\naccount = david@synesis.one\n' \
        > "$CLOUDSDK_CONFIG/configurations/config_default"
    set_response 0 '{"status":"RUNNING","labels":{"project":"claude-sandbox","owner":"david-synesis-one"},"networkInterfaces":[{"accessConfigs":[{"natIP":"5.6.7.8"}]}]}'
    run provider_resolve_ip sandbox-mine
    [ "$status" -eq 0 ]
    [ "$output" = "5.6.7.8" ]
}
```

- [ ] **Step 2: Run them to verify the first fails**

Run: `bats test/unit/gcp.bats -f "rejects a box owned by someone else"`
Expected: FAIL — it currently returns `5.6.7.8` with status 0.

- [ ] **Step 3: Implement**

In `provider_resolve_ip`, immediately after the existing empty-json guard:

```bash
    [[ -z "$json" ]] && die "no sandbox named $name in $GCP_ZONE (try ./bin/sandbox list)"
```

insert:

```bash
    # `instances describe` bypasses the owner filter in provider_list, so check
    # ownership here too. Same wording as not-found: a box you don't own is, as
    # far as this CLI is concerned, not there.
    local owner_label box_owner
    owner_label="$(sandbox_owner_label)"
    box_owner="$(printf '%s' "$json" | jq -r '.labels.owner // empty')"
    [[ "$box_owner" == "$owner_label" ]] \
        || die "no sandbox named $name in $GCP_ZONE (try ./bin/sandbox list)"
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/gcp.sh test/unit/gcp.bats
git commit -m "gcp: reject foreign boxes in resolve_ip (ssh/scp bypassed the filter)"
```

---

### Task 6: Scope tab completion

**Files:**
- Modify: `completion/sandbox.sh:85-91` (`_sandbox_names_gcp`)
- Test: manual (completion is not covered by the bats suite)

**Interfaces:**
- Consumes: `sandbox_owner_label` (Task 2), invoked in a subshell.
- Produces: Tab suggesting only your own box names.

- [ ] **Step 1: Add a subshell-contained identity helper**

`die` calls `exit 1`, and completion runs in the user's interactive shell — an unauthenticated gcloud would close their terminal. The `( ... )` subshell contains the exit; `2>/dev/null` suppresses the message.

In `completion/sandbox.sh`, immediately above `_sandbox_names_gcp`, add:

```bash
# _sandbox_owner_label — the caller's GCP owner label, or empty. Runs in a
# SUBSHELL on purpose: lib/identity.sh dies via `exit 1` when gcloud isn't
# authenticated, and completion runs in the user's interactive shell, where a
# bare exit would close their terminal.
_sandbox_owner_label() {
    local root; root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
    [[ -r "$root/lib/identity.sh" ]] || return 0
    ( source "$root/lib/identity.sh" && sandbox_owner_label ) 2>/dev/null
}
```

- [ ] **Step 2: Apply the filter**

Replace `_sandbox_names_gcp` in full:

```bash
_sandbox_names_gcp() {
    local proj; proj="$(_sandbox_cfg GCP_PROJECT)"
    [[ -z "$proj" ]] && return 0
    local owner; owner="$(_sandbox_owner_label)"
    [[ -z "$owner" ]] && return 0
    gcloud compute instances list --project "$proj" \
        --filter="labels.project=claude-sandbox AND labels.owner=$owner" \
        --format="value(name)" 2>/dev/null
}
```

Suggesting nothing when identity can't be resolved is deliberate: offering names that `ssh` will then reject is worse than offering none.

- [ ] **Step 3: Verify by hand**

```bash
source ./init.sh
./bin/sandbox up --name owned-by-me
# wait for it to appear, then:
./bin/sandbox ssh <Tab>
```
Expected: `owned-by-me` is suggested. A box labelled with another owner (create one with raw `gcloud ... --labels=owner=someone-else`) must NOT appear.

- [ ] **Step 4: Confirm a broken identity can't kill the shell**

```bash
CLOUDSDK_CONFIG=/nonexistent bash -ic './bin/sandbox ssh \t' 2>/dev/null; echo "shell survived: $?"
```
Expected: the shell survives; completion simply offers nothing.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add completion/sandbox.sh
git commit -m "completion: suggest only the calling account's sandboxes"
```

---

### Task 7: Document the multi-user model

**Files:**
- Modify: `README.md` (the "Using GCP" section, currently around lines 148-200)

**Interfaces:**
- Consumes: behaviour from Tasks 2-6.
- Produces: documentation. Nothing depends on it.

- [ ] **Step 1: Add a subsection after "Using GCP"**

```markdown
### Sharing a GCP project with other people

Sandboxes are scoped to the gcloud account that created them. `list`, `ssh`,
`scp`, `down` and tab completion only ever see your own boxes, so someone
else's `down --all` cannot touch your work.

Each person must authenticate as themselves:

```bash
gcloud auth login
```

Your identity is gcloud's active account (`gcloud config get-value account`).
It's recorded on each box as an `owner` label plus full-email metadata.

Two caveats worth knowing:

- **This is a safety rail, not a security boundary.** Filtering happens in this
  CLI. Anyone with `roles/compute.instanceAdmin.v1` on the project can bypass it
  with raw `gcloud`. Cloud Audit Logs are the tamper-proof record of who did
  what.
- **There is no `--all-users` view, by design.** Boxes launched before this
  feature, or by someone who has left, carry no matching `owner` label and are
  invisible here — manage them with raw `gcloud`, or label them:

  ```bash
  gcloud compute instances add-labels NAME --zone ZONE \
      --labels=owner=$(gcloud config get-value account | tr -c 'a-z0-9_-' '-')
  ```

AWS boxes are **not** scoped yet — a cross-cloud `list` shows GCP filtered and
AWS unfiltered.
```

- [ ] **Step 2: Verify the relabel command produces the same form the code does**

Run: `printf '%s' "david@synesis.one" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g'`
Expected: `david-synesis-one`. Confirm the README's `tr -c` one-liner yields the same string; if it doesn't (`tr -c` appends a trailing dash for the newline), use the `sed` form in the README instead.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document GCP multi-user scoping and its limits"
```

---

## Self-Review

**Spec coverage.** Identity → Task 2. Instance launch labelling → Task 3. List filter → Task 4. `provider_resolve_ip` bypass → Task 5. Completion → Task 6. Threat-model and no-escape-hatch documentation → Task 7. Destructive paths need no task, as the spec notes: they inherit Task 4 through `provider_list_all`. Image provenance, `list-images` columns, `image-info` and the `delete-image` guard are the companion plan.

**Deviation from the spec, deliberate:** the spec says identity is "memoized into a shell variable — resolved at most once per process". Callers use `$(sandbox_owner_label)`, which is a subshell, so a memo global can never propagate back. Each consumer resolves once into a local instead. Cost is two file reads per command; the memo bought nothing.

**Type consistency.** `sandbox_owner_email` and `sandbox_owner_label` are named identically in Tasks 2-6 and in the images plan. The label form (`david-synesis-one`) is consistent across the implementation, all tests, and the README relabel snippet.

**Untested by construction:** Task 6 has no bats coverage because completion isn't in the suite, so its verification is manual (Steps 3-4) — including an explicit check that a broken identity can't kill the shell.
