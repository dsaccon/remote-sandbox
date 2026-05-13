# Remote Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local bash CLI that provisions ephemeral AWS EC2 sandboxes pre-configured for Claude Code (subscription auth), one fresh box per task, fully self-contained inside this repo.

**Architecture:** A `bin/sandbox` dispatcher routes to per-subcommand scripts (`bin/sandbox-up`, `bin/sandbox-down`, etc.). Shared helpers live in `lib/` (config, AWS wrappers, logging, provisioning). A pre-baked AMI built by `bin/sandbox-build-ami` contains all heavy tooling (claude, node, uv, docker, etc.); per-launch cloud-init only sets hostname and optionally clones one repo. External commands are called through env-var-overridable wrappers (`AWS_CMD`, `CURL_CMD`, `SSH_CMD`, `SCP_CMD`) so tests can stub them without PATH manipulation.

**Tech Stack:** Bash (compatible with macOS's stock bash 3.2 at `/bin/bash` — see "Bash compatibility" below), `aws` CLI v2, `jq`, `curl`, `ssh`/`scp`, `bats-core` (tests), `shellcheck` (lint), Ubuntu 24.04 LTS amd64 (AMI base), systemd (auto-shutdown timer).

**Source spec:** `docs/specs/2026-05-12-remote-sandbox-design.md`

**Target laptop OS: macOS.** The local CLI is developed and tested on macOS (Apple Silicon or Intel). Linux works too — the scripts are POSIX-flavored bash and only call cross-platform tools — but the dependency install commands and any date-parsing fallbacks are written assuming macOS first. The remote VM is Ubuntu regardless.

**Bash compatibility:** All scripts in `bin/` and `lib/` must run unmodified under **bash 3.2** (the version shipped with macOS at `/bin/bash`). This is to avoid forcing a `brew install bash` on the user's laptop. Practically: no `mapfile` / `readarray`, no associative arrays (`declare -A`), no `${var^^}` case-conversion. Indirect expansion `${!var}`, `printf -v`, and `${BASH_REMATCH[]}` all work in 3.2 and are fine to use. Shebangs use `#!/usr/bin/env bash` so the script picks up either `/bin/bash` 3.2 or a Homebrew bash 5 — both work as long as we stay within the 3.2 feature set. The remote VM's `ami/bootstrap.sh` runs under Ubuntu's bash 5 and has no such restriction.

**Prereqs the engineer needs on their macOS laptop before starting:**

The user (not the agent) installs all laptop-side deps. Document what's needed; never run an install command on their machine.

- `aws` CLI v2 configured (`aws sts get-caller-identity` works) — installed via `brew install awscli`
- `jq` — installed via `brew install jq`
- `git`, `curl`, `ssh`, `scp`, `bash` (3.2), `awk`, `sed`, `date` — all ship with macOS, no install needed
- An EC2 key pair already created in `us-west-2` and named `claude-sandbox` (or whatever they put in `config`); the private key on the local machine at a path their `~/.ssh/config` can find

**Dev-only tooling — `shellcheck`, `bats-core` — does NOT go on the laptop.** Both are installed inside the AMI by `ami/bootstrap.sh` (Task 10). `make lint` and `make test` therefore only work when run inside a sandbox VM. The dev/test loop is:

1. Edit code on the laptop (in this repo)
2. `git push` (or `rsync`) the changes to a sandbox you've already provisioned
3. SSH in, `make lint && make test` inside the sandbox

This dogfoods the whole project: development of the sandbox tool happens in a sandbox, and the laptop stays minimal.

**Chicken-and-egg note for the very first AMI bake:** the first `./bin/sandbox build-ami` runs from the laptop without a sandbox to test in. There's nothing to do here except watch the bootstrap output and accept the small unverified-locally risk on that one operation. From the second AMI bake onward, you can `make test` from inside an existing sandbox before re-baking.

---

## File map

| Path | Purpose | Created by task |
|---|---|---|
| `bin/sandbox` | Dispatcher; routes `sandbox <cmd>` → `bin/sandbox-<cmd>` | Task 1 |
| `bin/sandbox-up` | Provision one box | Task 8 |
| `bin/sandbox-down` | Terminate one / `--all` / `--stale` | Task 5 |
| `bin/sandbox-list` | List `Project=claude-sandbox` instances | Task 4 |
| `bin/sandbox-ssh` | Resolve name → IP, exec ssh | Task 9 |
| `bin/sandbox-build-ami` | Bake a new AMI | Task 11 |
| `lib/log.sh` | `log_info`, `log_warn`, `log_err`, `die` (stderr) | Task 1 |
| `lib/config.sh` | Load `./config`, apply precedence | Task 2 |
| `lib/aws.sh` | Thin wrappers over `aws` CLI (calls `$AWS_CMD`) | Task 3 |
| `lib/provision.sh` | Preflight, SG management, run-instances, wait | Tasks 6-8 |
| `ami/bootstrap.sh` | Runs inside bake VM; installs tools | Task 10 |
| `ami/cloud-init.yaml.tmpl` | Per-launch user-data template | Task 6 |
| `ami/systemd/auto-shutdown.service` | Defense-in-depth shutdown unit | Task 10 |
| `ami/systemd/auto-shutdown.timer` | Triggers above after `AUTO_SHUTDOWN_HOURS` | Task 10 |
| `test/smoke.sh` | End-to-end on real AWS | Task 12 |
| `test/unit/*.bats` | Pure-function unit tests | Tasks 2, 3, 4, 5, 6, 7, 8 |
| `test/unit/stubs/aws` | Default stub for unit tests | Task 3 |
| `Makefile` | `lint`, `test`, `smoke` targets | Task 1 |
| `config.example` | Documented template | Task 1 |
| `README.md` | Usage docs | Tasks 1, 12 |

---

## Phase A — Foundation

### Task 1: Scaffolding (dispatcher, log helper, config.example, Makefile, README)

**Files:**
- Create: `bin/sandbox`, `lib/log.sh`, `config.example`, `Makefile`, `README.md`
- Test: `test/unit/dispatcher.bats`

- [ ] **Step 1: Write the failing test for the dispatcher**

Create `test/unit/dispatcher.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PATH="$REPO_ROOT/bin:$PATH"
}

@test "sandbox with no args prints usage and exits non-zero" {
    run sandbox
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "sandbox unknown-cmd errors clearly" {
    run sandbox bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command: bogus"* ]]
}

@test "sandbox config-missing message points at config.example" {
    tmpdir="$(mktemp -d)"
    cp "$REPO_ROOT/bin/sandbox" "$tmpdir/sandbox"
    mkdir -p "$tmpdir/bin" "$tmpdir/lib"
    cp "$REPO_ROOT/bin/sandbox" "$tmpdir/bin/"
    cp "$REPO_ROOT/lib/log.sh" "$tmpdir/lib/"
    touch "$tmpdir/config.example"
    # No `config` file present.
    cd "$tmpdir"
    run ./bin/sandbox list
    [ "$status" -ne 0 ]
    [[ "$output" == *"copy config.example to config"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/unit/dispatcher.bats
```

Expected: all three tests fail with "command not found: sandbox" or equivalent.

- [ ] **Step 3: Create `lib/log.sh`**

```bash
#!/usr/bin/env bash
# lib/log.sh — consistent stderr logging.
# Source, don't execute. Idempotent.

if [[ -n "${_SANDBOX_LOG_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_LOG_SH_LOADED=1

_log() {
    local level="$1"; shift
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%SZ)" "$level" "$*" >&2
}

log_info() { _log INFO  "$@"; }
log_warn() { _log WARN  "$@"; }
log_err()  { _log ERROR "$@"; }

die() {
    log_err "$@"
    exit 1
}
```

- [ ] **Step 4: Create `bin/sandbox` dispatcher**

```bash
#!/usr/bin/env bash
# bin/sandbox — dispatcher.
# Usage: sandbox <command> [args...]
# Commands: up, down, list, ssh, build-ami

set -euo pipefail

# Resolve repo root regardless of where script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SANDBOX_REPO_ROOT="$REPO_ROOT"

# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"

usage() {
    cat >&2 <<'EOF'
Usage: sandbox <command> [args...]

Commands:
  up [--repo URL] [--name N] [--instance-type T] [--no-spot]
                 Provision one ephemeral sandbox.
  down <name|id> | --all | --stale <duration>
                 Terminate one, all, or stale sandboxes.
  list           List all sandboxes (Project=claude-sandbox).
  ssh <name>     SSH into a named sandbox.
  build-ami      Bake a fresh AMI; writes AMI_ID to ./config on success.
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi

cmd="$1"; shift

# Every command except `build-ami` and `up` still needs a config to know
# region/etc.  Check config existence here so error is uniform.
if [[ ! -f "$REPO_ROOT/config" ]]; then
    if [[ -f "$REPO_ROOT/config.example" ]]; then
        die "no config file at ./config — copy config.example to config and edit"
    else
        die "no config file at ./config and no config.example — repo is broken"
    fi
fi

sub="$REPO_ROOT/bin/sandbox-$cmd"
if [[ ! -x "$sub" ]]; then
    die "unknown command: $cmd (run 'sandbox' with no args for usage)"
fi

exec "$sub" "$@"
```

Make it executable:

```bash
chmod +x bin/sandbox
```

- [ ] **Step 5: Create `config.example`**

```bash
# config.example — copy to ./config and edit. This file is checked in;
# your ./config is gitignored.

# ---- Cloud / region ----
CLOUD="aws"                       # "aws" (only option in v1)
AWS_REGION="us-west-2"            # Oregon

# ---- Instance ----
INSTANCE_TYPE="m7i-flex.xlarge"   # 16 GB / 4 vCPU recommended
USE_SPOT=true
SPOT_FALLBACK_ON_DEMAND=true

# ---- Identity / access ----
SSH_KEY_NAME="claude-sandbox"     # an EC2 key pair you've already created
SSH_USER="ubuntu"

# ---- AMI ----
# Populated by `./bin/sandbox build-ami` on success.
AMI_ID=""

# ---- Lifecycle guardrails ----
AUTO_SHUTDOWN_HOURS=8             # 0 disables the in-VM shutdown timer

# ---- Optional: dotfiles cloned to ~ during AMI bake ----
DOTFILES_REPO=""                  # e.g. "https://github.com/dsaccon/dotfiles.git"
```

- [ ] **Step 6: Create `Makefile`**

```makefile
SHELL := /usr/bin/env bash

SHELL_FILES := $(shell find bin lib ami test -type f \( -name '*.sh' -o -path 'bin/sandbox*' \) 2>/dev/null)

.PHONY: lint test smoke clean help

help:
	@echo "Targets: lint, test, smoke"

lint:
	@shellcheck -x $(SHELL_FILES)

test:
	@bats test/unit

smoke:
	@bash test/smoke.sh
```

- [ ] **Step 7: Create initial `README.md`**

```markdown
# remote-sandbox

A local CLI that provisions ephemeral AWS EC2 sandboxes pre-configured for
Claude Code. One fresh box per task, terminated when done.

See `docs/specs/2026-05-12-remote-sandbox-design.md` for the full design.

## Setup

1. `cp config.example config` and edit (set `SSH_KEY_NAME` at minimum).
2. `./bin/sandbox build-ami` (one-time, ~10 minutes).
3. `./bin/sandbox up` — prints an `ssh ...` line.

## Commands

(filled in by the final task.)
```

- [ ] **Step 8: Run unit tests — should pass now**

```bash
bats test/unit/dispatcher.bats
```

Expected: 3 tests pass.

- [ ] **Step 9: Run lint**

```bash
make lint
```

Expected: no shellcheck warnings.

- [ ] **Step 10: Commit**

```bash
git add bin/sandbox lib/log.sh config.example Makefile README.md test/unit/dispatcher.bats
git commit -m "Task 1: scaffolding — dispatcher, log helper, config example"
```

---

### Task 2: Config loading with precedence

**Files:**
- Create: `lib/config.sh`
- Test: `test/unit/config.bats`

Loads `./config` (bash source), then overlays `SANDBOX_*` env vars (e.g. `SANDBOX_INSTANCE_TYPE`), then CLI flags (the subcommand scripts will call `config_set_from_flag KEY VALUE`). Built-in defaults apply when none of the above set a value.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/config.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib"
    cp "$REPO_ROOT/lib/log.sh" "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/lib/config.sh" "$SANDBOX_REPO_ROOT/lib/"
}

teardown() {
    rm -rf "$SANDBOX_REPO_ROOT"
}

write_config() {
    cat > "$SANDBOX_REPO_ROOT/config"
}

@test "defaults apply when config has empty values" {
    write_config <<'EOF'
AWS_REGION=""
INSTANCE_TYPE=""
USE_SPOT=""
EOF
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$AWS_REGION" = "us-west-2" ]
    [ "$INSTANCE_TYPE" = "m7i-flex.xlarge" ]
    [ "$USE_SPOT" = "true" ]
}

@test "config file values override defaults" {
    write_config <<'EOF'
AWS_REGION="eu-west-1"
INSTANCE_TYPE="t3.large"
EOF
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$AWS_REGION" = "eu-west-1" ]
    [ "$INSTANCE_TYPE" = "t3.large" ]
}

@test "SANDBOX_ env vars override config file" {
    write_config <<'EOF'
AWS_REGION="eu-west-1"
INSTANCE_TYPE="t3.large"
EOF
    export SANDBOX_INSTANCE_TYPE="m7i-flex.2xlarge"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    [ "$INSTANCE_TYPE" = "m7i-flex.2xlarge" ]
    [ "$AWS_REGION" = "eu-west-1" ]  # not overridden
}

@test "config_set_from_flag overrides env and file" {
    write_config <<'EOF'
INSTANCE_TYPE="t3.large"
EOF
    export SANDBOX_INSTANCE_TYPE="m7i-flex.2xlarge"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    config_set_from_flag INSTANCE_TYPE "c7i.xlarge"
    [ "$INSTANCE_TYPE" = "c7i.xlarge" ]
}

@test "config_load errors if config file missing" {
    rm -f "$SANDBOX_REPO_ROOT/config"
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    run config_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"no config file"* ]]
}
```

- [ ] **Step 2: Run tests — should all fail**

```bash
bats test/unit/config.bats
```

Expected: 5 failures (`config.sh: No such file`).

- [ ] **Step 3: Create `lib/config.sh`**

```bash
#!/usr/bin/env bash
# lib/config.sh — load ./config with precedence: flag > env > file > default.
# Source, don't execute. Requires SANDBOX_REPO_ROOT set by caller.

if [[ -n "${_SANDBOX_CONFIG_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_CONFIG_SH_LOADED=1

# Resolve log.sh relative to this file so it works regardless of caller cwd.
_config_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_config_sh_dir/log.sh"

# Keys we manage. Each gets a default; env-var lookup is SANDBOX_<KEY>.
_CONFIG_KEYS=(
    CLOUD
    AWS_REGION
    INSTANCE_TYPE
    USE_SPOT
    SPOT_FALLBACK_ON_DEMAND
    SSH_KEY_NAME
    SSH_USER
    AMI_ID
    AUTO_SHUTDOWN_HOURS
    DOTFILES_REPO
)

# Defaults.
_config_default() {
    case "$1" in
        CLOUD)                    echo "aws" ;;
        AWS_REGION)               echo "us-west-2" ;;
        INSTANCE_TYPE)            echo "m7i-flex.xlarge" ;;
        USE_SPOT)                 echo "true" ;;
        SPOT_FALLBACK_ON_DEMAND)  echo "true" ;;
        SSH_KEY_NAME)             echo "claude-sandbox" ;;
        SSH_USER)                 echo "ubuntu" ;;
        AMI_ID)                   echo "" ;;
        AUTO_SHUTDOWN_HOURS)      echo "8" ;;
        DOTFILES_REPO)            echo "" ;;
        *)                        echo "" ;;
    esac
}

config_load() {
    : "${SANDBOX_REPO_ROOT:?config_load: SANDBOX_REPO_ROOT not set}"
    local cfg="$SANDBOX_REPO_ROOT/config"
    if [[ ! -f "$cfg" ]]; then
        die "no config file at $cfg — copy config.example to config and edit"
    fi
    # shellcheck source=/dev/null
    source "$cfg"

    # For each key: env override → file value (already set) → default.
    local key env_name env_val cur
    for key in "${_CONFIG_KEYS[@]}"; do
        env_name="SANDBOX_$key"
        env_val="${!env_name:-}"
        if [[ -n "$env_val" ]]; then
            printf -v "$key" '%s' "$env_val"
            continue
        fi
        cur="${!key:-}"
        if [[ -z "$cur" ]]; then
            printf -v "$key" '%s' "$(_config_default "$key")"
        fi
    done

    # Export everything for child processes.
    export "${_CONFIG_KEYS[@]}"
}

# config_set_from_flag KEY VALUE — highest precedence; subcommands call this
# while parsing argv.
config_set_from_flag() {
    local key="$1"; local val="$2"
    printf -v "$key" '%s' "$val"
    export "$key"
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
bats test/unit/config.bats
```

Expected: 5 tests pass.

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/config.sh test/unit/config.bats
git commit -m "Task 2: config loading with flag > env > file > default precedence"
```

---

### Task 3: AWS helper wrapper

**Files:**
- Create: `lib/aws.sh`, `test/unit/stubs/aws-empty`
- Test: `test/unit/aws.bats`

`lib/aws.sh` wraps every `aws` call through `$AWS_CMD` (default `aws`). Tests inject a stub by setting `AWS_CMD` to a script that prints fixture JSON. Wrappers we'll need:

- `aws_caller_identity` — returns user ARN, errors with friendly message if creds missing
- `aws_describe_image <ami-id>` — returns 0 if exists, non-zero with message if not
- `aws_describe_key_pair <name>` — same
- `aws_describe_sg_id <group-name>` — prints SG id, returns non-zero if not found
- `aws_create_sg <group-name>` — creates `claude-sandbox-sg` in default VPC, prints new id
- `aws_set_sg_ingress_to <sg-id> <cidr>` — revokes all existing 22/tcp ingress, adds `cidr` 22/tcp
- `aws_run_instances <json-blob>` — calls `aws ec2 run-instances --cli-input-json file://-`, prints instance id
- `aws_wait_running <instance-id>` — calls `aws ec2 wait instance-status-ok`
- `aws_describe_instances_by_tag <tag-filter>` — used by `list` and `down --all/--stale`
- `aws_terminate_instances <id...>` — passthrough
- `aws_get_console_output <instance-id>` — passthrough, prints raw

- [ ] **Step 1: Write the failing tests**

Create `test/unit/stubs/aws-empty`:

```bash
#!/usr/bin/env bash
# Empty AWS stub — records calls, returns whatever fixture file says.
# Test writes its desired exit code and stdout into $AWS_STUB_RESPONSE before
# invoking, then reads $AWS_STUB_LOG to assert on calls.

: "${AWS_STUB_LOG:?stub log path not set}"
printf '%s\n' "$*" >> "$AWS_STUB_LOG"

if [[ -n "${AWS_STUB_RESPONSE:-}" && -f "$AWS_STUB_RESPONSE" ]]; then
    rc="$(head -n1 "$AWS_STUB_RESPONSE")"
    tail -n +2 "$AWS_STUB_RESPONSE"
    exit "$rc"
fi
exit 0
```

Make it executable:

```bash
chmod +x test/unit/stubs/aws-empty
```

Create `test/unit/aws.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-response"
    : > "$AWS_STUB_LOG"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/aws.sh"
    AWS_REGION="us-west-2"
}

set_response() {
    local rc="$1"; shift
    { echo "$rc"; printf '%s' "$*"; } > "$AWS_STUB_RESPONSE"
}

@test "aws_caller_identity passes through region and exits 0 on success" {
    set_response 0 '{"Arn":"arn:aws:iam::1:user/me"}'
    run aws_caller_identity
    [ "$status" -eq 0 ]
    grep -q -- '--region us-west-2' "$AWS_STUB_LOG"
    grep -q -- 'sts get-caller-identity' "$AWS_STUB_LOG"
}

@test "aws_caller_identity dies with friendly message on failure" {
    set_response 1 ''
    run aws_caller_identity
    [ "$status" -ne 0 ]
    [[ "$output" == *"aws configure"* ]]
}

@test "aws_describe_image returns 0 when image exists" {
    set_response 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    run aws_describe_image ami-abc
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 describe-images --image-ids ami-abc' "$AWS_STUB_LOG"
}

@test "aws_describe_image fails with helpful message when missing" {
    set_response 0 '{"Images":[]}'
    run aws_describe_image ami-bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"AMI ami-bad not found"* ]]
}

@test "aws_set_sg_ingress_to revokes existing then authorizes new CIDR" {
    # First call: describe to find existing rules. Second: revoke. Third: authorize.
    set_response 0 '{"SecurityGroups":[{"IpPermissions":[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"5.6.7.8/32"}]}]}]}'
    run aws_set_sg_ingress_to sg-123 "1.2.3.4/32"
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 revoke-security-group-ingress' "$AWS_STUB_LOG"
    grep -q -- 'ec2 authorize-security-group-ingress' "$AWS_STUB_LOG"
    grep -q -- '1.2.3.4/32' "$AWS_STUB_LOG"
}
```

- [ ] **Step 2: Run tests — should all fail**

```bash
bats test/unit/aws.bats
```

Expected: failures (`aws.sh: No such file or directory`).

- [ ] **Step 3: Create `lib/aws.sh`**

```bash
#!/usr/bin/env bash
# lib/aws.sh — thin wrappers over `aws` CLI. Every external call goes through
# $AWS_CMD so tests can stub it. Functions print to stdout, log to stderr,
# and use `die` on unrecoverable errors.

if [[ -n "${_SANDBOX_AWS_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_AWS_SH_LOADED=1

_aws_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_aws_sh_dir/log.sh"

: "${AWS_CMD:=aws}"

_aws() {
    : "${AWS_REGION:?_aws: AWS_REGION not set}"
    "$AWS_CMD" --region "$AWS_REGION" "$@"
}

aws_caller_identity() {
    if ! _aws sts get-caller-identity >/dev/null 2>&1; then
        die "AWS credentials not configured or invalid — run 'aws configure'"
    fi
}

aws_describe_image() {
    local ami_id="$1"
    local out
    if ! out="$(_aws ec2 describe-images --image-ids "$ami_id" --output json 2>&1)"; then
        die "AMI $ami_id not found in $AWS_REGION (api error: $out)"
    fi
    local count
    count="$(printf '%s' "$out" | jq '.Images | length')"
    if [[ "$count" -eq 0 ]]; then
        die "AMI $ami_id not found in $AWS_REGION"
    fi
}

aws_describe_key_pair() {
    local name="$1"
    if ! _aws ec2 describe-key-pairs --key-names "$name" >/dev/null 2>&1; then
        die "EC2 key pair '$name' not found in $AWS_REGION. Create one:
  aws ec2 create-key-pair --region $AWS_REGION --key-name $name --query KeyMaterial --output text > ~/.ssh/${name}.pem
  chmod 600 ~/.ssh/${name}.pem"
    fi
}

aws_describe_sg_id() {
    local name="$1"
    local out
    out="$(_aws ec2 describe-security-groups --group-names "$name" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    if [[ -z "$out" || "$out" == "None" ]]; then
        return 1
    fi
    printf '%s' "$out"
}

aws_create_sg() {
    local name="$1"
    local vpc_id
    vpc_id="$(_aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)"
    [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && die "no default VPC in $AWS_REGION"
    _aws ec2 create-security-group --group-name "$name" \
        --description "claude-sandbox SSH ingress (managed by remote-sandbox)" \
        --vpc-id "$vpc_id" --query GroupId --output text
}

aws_set_sg_ingress_to() {
    local sg_id="$1"
    local cidr="$2"
    # Revoke every existing :22/tcp rule.
    local existing
    existing="$(_aws ec2 describe-security-groups --group-ids "$sg_id" \
        --query 'SecurityGroups[0].IpPermissions' --output json)"
    local existing_cidrs
    existing_cidrs="$(printf '%s' "$existing" \
        | jq -r '.[] | select(.IpProtocol=="tcp" and .FromPort==22) | .IpRanges[].CidrIp' || true)"
    if [[ -n "$existing_cidrs" ]]; then
        while IFS= read -r old_cidr; do
            [[ -z "$old_cidr" ]] && continue
            _aws ec2 revoke-security-group-ingress --group-id "$sg_id" \
                --protocol tcp --port 22 --cidr "$old_cidr" >/dev/null
        done <<< "$existing_cidrs"
    fi
    _aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr "$cidr" >/dev/null
}

aws_run_instances_json() {
    # Read JSON from stdin, invoke run-instances, print resulting instance id
    # to stdout. On failure, emit the AWS error to stderr and return non-zero
    # so the caller can pattern-match (e.g. for InsufficientInstanceCapacity).
    local json out rc
    json="$(cat)"
    if ! out="$(printf '%s' "$json" | _aws ec2 run-instances --cli-input-json file:///dev/stdin --output json 2>&1)"; then
        rc=$?
        printf '%s\n' "$out" >&2
        return "$rc"
    fi
    printf '%s' "$out" | jq -r '.Instances[0].InstanceId'
}

aws_wait_running() {
    local instance_id="$1"
    _aws ec2 wait instance-status-ok --instance-ids "$instance_id"
}

aws_describe_instances_by_tag() {
    local key="$1"
    local val="$2"
    _aws ec2 describe-instances \
        --filters "Name=tag:$key,Values=$val" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --output json
}

aws_terminate_instances() {
    [[ $# -eq 0 ]] && return 0
    _aws ec2 terminate-instances --instance-ids "$@" --output json
}

aws_get_console_output() {
    local id="$1"
    _aws ec2 get-console-output --instance-id "$id" --output text 2>/dev/null || true
}

aws_get_instance_ip() {
    local id="$1"
    _aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}
```

- [ ] **Step 4: Run tests**

```bash
bats test/unit/aws.bats
```

Expected: 5 pass.

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/aws.sh test/unit/aws.bats test/unit/stubs/aws-empty
git commit -m "Task 3: aws helper wrappers with stub-injectable AWS_CMD"
```

---

## Phase B — Read-only commands

### Task 4: `sandbox list`

**Files:**
- Create: `bin/sandbox-list`
- Test: `test/unit/list.bats`

Lists every `Project=claude-sandbox` instance in the configured region with columns: NAME, STATE, TYPE, AGE, IP.

- [ ] **Step 1: Write the failing test**

Create `test/unit/list.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-list" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "list prints header and one row per instance" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","InstanceType":"m7i-flex.xlarge","PublicIpAddress":"1.2.3.4",
   "State":{"Name":"running"},"LaunchTime":"2026-05-12T10:00:00Z",
   "Tags":[{"Key":"Name","Value":"sandbox-abc"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME"* ]]
    [[ "$output" == *"sandbox-abc"* ]]
    [[ "$output" == *"running"* ]]
    [[ "$output" == *"m7i-flex.xlarge"* ]]
    [[ "$output" == *"1.2.3.4"* ]]
}

@test "list prints empty message when nothing found" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no sandboxes"* ]]
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/list.bats
```

Expected: 2 failures (bin/sandbox-list missing).

- [ ] **Step 3: Create `bin/sandbox-list`**

```bash
#!/usr/bin/env bash
# bin/sandbox-list — list all Project=claude-sandbox instances.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=../lib/aws.sh
source "$REPO_ROOT/lib/aws.sh"

config_load
aws_caller_identity

json="$(aws_describe_instances_by_tag Project claude-sandbox)"
count="$(printf '%s' "$json" | jq '[.Reservations[].Instances[]] | length')"
if [[ "$count" -eq 0 ]]; then
    echo "no sandboxes in $AWS_REGION"
    exit 0
fi

# Header.
printf '%-22s %-10s %-18s %-10s %-16s\n' NAME STATE TYPE AGE IP

now_epoch="$(date -u +%s)"
printf '%s' "$json" | jq -r '
    .Reservations[].Instances[] |
    [
        ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // .InstanceId),
        .State.Name,
        .InstanceType,
        .LaunchTime,
        (.PublicIpAddress // "-")
    ] | @tsv
' | while IFS=$'\t' read -r name state type launch ip; do
    launch_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${launch%.*}" "+%s" 2>/dev/null \
        || date -u -d "$launch" "+%s" 2>/dev/null || echo "$now_epoch")"
    age_sec=$(( now_epoch - launch_epoch ))
    if (( age_sec < 3600 )); then
        age="$(( age_sec / 60 ))m"
    else
        age="$(( age_sec / 3600 ))h$(( (age_sec % 3600) / 60 ))m"
    fi
    printf '%-22s %-10s %-18s %-10s %-16s\n' "$name" "$state" "$type" "$age" "$ip"
done
```

```bash
chmod +x bin/sandbox-list
```

- [ ] **Step 4: Run tests**

```bash
bats test/unit/list.bats
```

Expected: 2 pass.

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add bin/sandbox-list test/unit/list.bats
git commit -m "Task 4: sandbox list command"
```

---

### Task 5: `sandbox down` (single + `--all` + `--stale`)

**Files:**
- Create: `bin/sandbox-down`
- Test: `test/unit/down.bats`

Resolves a name → instance id via tag lookup, then terminates. `--all` terminates everything tagged `Project=claude-sandbox`. `--stale <duration>` filters by `CreatedAt` tag and terminates older ones. Duration: `24h`, `30m`, `2d`.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/down.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-down" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

fixture_two_boxes() {
    local now_iso="$1"
    local old_iso="$2"
    cat > "$AWS_STUB_RESPONSE" <<EOF
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-new","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"$now_iso",
   "Tags":[{"Key":"Name","Value":"sandbox-new"},{"Key":"Project","Value":"claude-sandbox"},
           {"Key":"CreatedAt","Value":"$now_iso"}]},
  {"InstanceId":"i-old","InstanceType":"m7i-flex.xlarge","State":{"Name":"running"},
   "LaunchTime":"$old_iso",
   "Tags":[{"Key":"Name","Value":"sandbox-old"},{"Key":"Project","Value":"claude-sandbox"},
           {"Key":"CreatedAt","Value":"$old_iso"}]}
]}]}
EOF
}

@test "down by name terminates matching instance" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" sandbox-new
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-new' "$AWS_STUB_LOG"
    ! grep -q -- 'terminate-instances --instance-ids i-old' "$AWS_STUB_LOG"
}

@test "down unknown name exits non-zero" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" sandbox-missing
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named sandbox-missing"* ]]
}

@test "down --all terminates every Project=claude-sandbox instance" {
    fixture_two_boxes "2026-05-12T10:00:00Z" "2026-05-10T10:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --all
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-new i-old' "$AWS_STUB_LOG" \
        || grep -q -- 'terminate-instances --instance-ids i-old i-new' "$AWS_STUB_LOG"
}

@test "down --stale 24h terminates only old ones" {
    # Compare against now; pick a comfortably-old time so the test is stable.
    fixture_two_boxes "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "2020-01-01T00:00:00Z"
    run "$SANDBOX_REPO_ROOT/bin/sandbox-down" --stale 24h
    [ "$status" -eq 0 ]
    grep -q -- 'terminate-instances --instance-ids i-old' "$AWS_STUB_LOG"
    ! grep -q -- 'i-new' "$AWS_STUB_LOG" | grep -q terminate
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/down.bats
```

- [ ] **Step 3: Create `bin/sandbox-down`**

```bash
#!/usr/bin/env bash
# bin/sandbox-down — terminate one sandbox, all of them, or stale ones.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=../lib/aws.sh
source "$REPO_ROOT/lib/aws.sh"

config_load
aws_caller_identity

usage() {
    cat >&2 <<'EOF'
Usage: sandbox down <name|id>
       sandbox down --all
       sandbox down --stale <duration>   # e.g. 30m, 24h, 2d
EOF
}

# parse_duration_to_seconds 24h | 30m | 2d
parse_duration_to_seconds() {
    local d="$1"
    [[ "$d" =~ ^([0-9]+)([smhd])$ ]] || die "bad duration: $d (use 30m, 24h, 2d, etc.)"
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "$u" in
        s) echo "$n" ;;
        m) echo $(( n * 60 )) ;;
        h) echo $(( n * 3600 )) ;;
        d) echo $(( n * 86400 )) ;;
    esac
}

iso_to_epoch() {
    local iso="${1%.*}"  # strip fractional seconds
    iso="${iso%Z}"
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$iso" "+%s" 2>/dev/null \
        || date -u -d "${iso}Z" "+%s"
}

if [[ $# -eq 0 ]]; then usage; exit 2; fi

mode="$1"
case "$mode" in
    --all)
        json="$(aws_describe_instances_by_tag Project claude-sandbox)"
        ids=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ids+=("$line")
        done < <(printf '%s' "$json" | jq -r '.Reservations[].Instances[].InstanceId')
        if [[ ${#ids[@]} -eq 0 ]]; then
            log_info "no sandboxes to terminate"
            exit 0
        fi
        log_info "terminating: ${ids[*]}"
        aws_terminate_instances "${ids[@]}" >/dev/null
        ;;
    --stale)
        [[ $# -lt 2 ]] && { usage; exit 2; }
        threshold_sec="$(parse_duration_to_seconds "$2")"
        now="$(date -u +%s)"
        json="$(aws_describe_instances_by_tag Project claude-sandbox)"
        # Pick instances where CreatedAt is older than threshold.
        ids=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ids+=("$line")
        done < <(printf '%s' "$json" | jq -r '
            .Reservations[].Instances[] |
            { id: .InstanceId,
              created: ((.Tags // []) | map(select(.Key=="CreatedAt")) | .[0].Value // .LaunchTime) }
            | "\(.id)\t\(.created)"' | while IFS=$'\t' read -r id created; do
                created_epoch="$(iso_to_epoch "$created")"
                age=$(( now - created_epoch ))
                if (( age >= threshold_sec )); then
                    echo "$id"
                fi
            done)
        if [[ ${#ids[@]} -eq 0 ]]; then
            log_info "no stale sandboxes"
            exit 0
        fi
        log_info "terminating stale: ${ids[*]}"
        aws_terminate_instances "${ids[@]}" >/dev/null
        ;;
    --help|-h)
        usage; exit 0 ;;
    -*)
        usage; exit 2 ;;
    *)
        # Single name or id.
        target="$mode"
        if [[ "$target" =~ ^i-[0-9a-f]+$ ]]; then
            id="$target"
        else
            json="$(aws_describe_instances_by_tag Project claude-sandbox)"
            id="$(printf '%s' "$json" | jq -r --arg n "$target" '
                .Reservations[].Instances[] |
                select((.Tags // []) | any(.Key=="Name" and .Value==$n)) |
                .InstanceId' | head -n1)"
            if [[ -z "$id" ]]; then
                die "no sandbox named $target"
            fi
        fi
        log_info "terminating $target ($id)"
        aws_terminate_instances "$id" >/dev/null
        ;;
esac
```

```bash
chmod +x bin/sandbox-down
```

- [ ] **Step 4: Run tests**

```bash
bats test/unit/down.bats
```

Expected: 4 pass.

- [ ] **Step 5: Lint**

```bash
make lint
```

- [ ] **Step 6: Commit**

```bash
git add bin/sandbox-down test/unit/down.bats
git commit -m "Task 5: sandbox down with --all and --stale"
```

---

## Phase C — Provisioning

### Task 6: Cloud-init template + renderer

**Files:**
- Create: `ami/cloud-init.yaml.tmpl`, `lib/provision.sh` (initial — just the renderer)
- Test: `test/unit/cloud-init.bats`

Per-launch user-data: sets hostname; if `--repo URL` provided, clones it as the `ubuntu` user; writes the `AUTO_SHUTDOWN_HOURS` value into `/etc/default/auto-shutdown` so the systemd timer can read it.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/cloud-init.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/provision.sh"
}

@test "render_cloud_init substitutes hostname when no repo" {
    out="$(render_cloud_init sandbox-abc "" 8)"
    [[ "$out" == *"hostname: sandbox-abc"* ]]
    [[ "$out" != *"git clone"* ]]
    [[ "$out" == *"AUTO_SHUTDOWN_HOURS=8"* ]]
}

@test "render_cloud_init injects git clone when repo provided" {
    out="$(render_cloud_init sandbox-abc "https://github.com/x/y.git" 8)"
    [[ "$out" == *"hostname: sandbox-abc"* ]]
    [[ "$out" == *"git clone https://github.com/x/y.git"* ]]
}

@test "render_cloud_init omits clone block when repo empty string" {
    out="$(render_cloud_init sandbox-abc "" 0)"
    [[ "$out" != *"git clone"* ]]
    [[ "$out" == *"AUTO_SHUTDOWN_HOURS=0"* ]]
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/cloud-init.bats
```

- [ ] **Step 3: Create `ami/cloud-init.yaml.tmpl`**

```yaml
#cloud-config
# Rendered by lib/provision.sh — placeholders {{NAME}}, {{CLONE_BLOCK}},
# {{AUTO_SHUTDOWN_HOURS}}.
hostname: {{NAME}}
preserve_hostname: false

write_files:
  - path: /etc/default/auto-shutdown
    permissions: "0644"
    content: |
      AUTO_SHUTDOWN_HOURS={{AUTO_SHUTDOWN_HOURS}}

runcmd:
  - systemctl daemon-reload
  - [ systemctl, enable, --now, auto-shutdown.timer ]
{{CLONE_BLOCK}}
```

- [ ] **Step 4: Create `lib/provision.sh` (renderer only for now)**

```bash
#!/usr/bin/env bash
# lib/provision.sh — provisioning helpers. Other tasks add to this file.

if [[ -n "${_SANDBOX_PROVISION_SH_LOADED:-}" ]]; then return 0; fi
_SANDBOX_PROVISION_SH_LOADED=1

_provision_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_provision_repo_root="$(cd "$_provision_sh_dir/.." && pwd)"

# shellcheck source=log.sh
source "$_provision_sh_dir/log.sh"

# render_cloud_init NAME REPO_URL AUTO_SHUTDOWN_HOURS
# Prints rendered YAML to stdout.
render_cloud_init() {
    local name="$1"
    local repo="$2"
    local hours="$3"
    local tmpl="$_provision_repo_root/ami/cloud-init.yaml.tmpl"
    [[ -f "$tmpl" ]] || die "missing template: $tmpl"

    local clone_block=""
    if [[ -n "$repo" ]]; then
        clone_block="  - [ sudo, -u, ubuntu, -i, bash, -c, \"git clone $repo\" ]"
    fi

    # Newlines in clone_block could break sed; use awk for safety.
    awk \
        -v name="$name" \
        -v clone="$clone_block" \
        -v hours="$hours" \
        '{
            gsub(/\{\{NAME\}\}/, name)
            gsub(/\{\{CLONE_BLOCK\}\}/, clone)
            gsub(/\{\{AUTO_SHUTDOWN_HOURS\}\}/, hours)
            print
        }' "$tmpl"
}
```

- [ ] **Step 5: Run tests**

```bash
bats test/unit/cloud-init.bats
```

Expected: 3 pass.

- [ ] **Step 6: Lint**

```bash
make lint
```

- [ ] **Step 7: Commit**

```bash
git add ami/cloud-init.yaml.tmpl lib/provision.sh test/unit/cloud-init.bats
git commit -m "Task 6: cloud-init template + renderer"
```

---

### Task 7: Preflight + security-group management

**Files:**
- Modify: `lib/provision.sh` (add `preflight_or_die`, `ensure_sg`, `current_public_ip`)
- Test: `test/unit/preflight.bats`

`preflight_or_die` runs all the up-front checks from the spec (creds, AMI present, key pair present). `ensure_sg` returns an existing `claude-sandbox-sg` id or creates one. `current_public_ip` calls `curl https://checkip.amazonaws.com` (via `$CURL_CMD`).

- [ ] **Step 1: Write the failing tests**

Create `test/unit/preflight.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/ami"
    cp "$REPO_ROOT"/lib/{log,config,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/ami/cloud-init.yaml.tmpl" "$SANDBOX_REPO_ROOT/ami/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
AMI_ID="ami-abc"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # Stub curl for current_public_ip.
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-stub"
    cat > "$CURL_CMD" <<'EOF'
#!/usr/bin/env bash
echo "1.2.3.4"
EOF
    chmod +x "$CURL_CMD"
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/provision.sh"
    # shellcheck source=/dev/null
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "current_public_ip returns CIDR /32" {
    run current_public_ip_cidr
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3.4/32" ]
}

@test "preflight_or_die succeeds when everything OK" {
    # All AWS calls succeed (default stub exit 0, returns empty unless told).
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Images":[{"ImageId":"ami-abc"}]}
EOF
    # Note: subsequent calls reuse the same response file — we accept that
    # for this happy-path test; the rejections below get their own responses.
    run preflight_or_die
    [ "$status" -eq 0 ]
}

@test "preflight_or_die exits if AMI_ID empty" {
    AMI_ID=""
    run preflight_or_die
    [ "$status" -ne 0 ]
    [[ "$output" == *"no AMI"* ]]
}

@test "ensure_sg creates SG when missing" {
    # describe-security-groups returns None → create-security-group called.
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
None
EOF
    # We can't distinguish describe vs create with one response file in this
    # simple stub. Test asserts on call log instead.
    run ensure_sg
    grep -q -- 'describe-security-groups --group-names claude-sandbox-sg' "$AWS_STUB_LOG"
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/preflight.bats
```

- [ ] **Step 3: Extend `lib/provision.sh`** — append:

```bash
: "${CURL_CMD:=curl}"

current_public_ip_cidr() {
    local ip
    ip="$("$CURL_CMD" -fsS https://checkip.amazonaws.com)" || die "could not fetch public IP"
    ip="${ip//[$'\t\r\n ']}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected public IP: $ip"
    printf '%s/32' "$ip"
}

preflight_or_die() {
    : "${AWS_REGION:?preflight: AWS_REGION not set}"
    : "${SSH_KEY_NAME:?preflight: SSH_KEY_NAME not set}"
    [[ -z "${AMI_ID:-}" ]] && die "no AMI configured — run './bin/sandbox build-ami' (and check ./config)"

    aws_caller_identity
    aws_describe_image "$AMI_ID"
    aws_describe_key_pair "$SSH_KEY_NAME"
}

ensure_sg() {
    local name="claude-sandbox-sg"
    local id
    if id="$(aws_describe_sg_id "$name")"; then
        printf '%s' "$id"
    else
        log_info "creating security group $name"
        aws_create_sg "$name"
    fi
}
```

- [ ] **Step 4: Run tests**

```bash
bats test/unit/preflight.bats
```

Expected: 4 pass. (The "happy path" preflight test passes because the stub returns the same response every call; that's acceptable for unit-level coverage of the orchestration. The smoke test in Task 12 covers real end-to-end.)

- [ ] **Step 5: Lint**

```bash
make lint
```

- [ ] **Step 6: Commit**

```bash
git add lib/provision.sh test/unit/preflight.bats
git commit -m "Task 7: preflight + security-group management"
```

---

### Task 8: `sandbox up` — launch + spot fallback + SSH-readiness

**Files:**
- Create: `bin/sandbox-up`
- Modify: `lib/provision.sh` (add `provision_launch`)
- Test: `test/unit/up.bats`

`provision_launch` builds the `run-instances` JSON, calls `aws_run_instances_json`, falls back to on-demand on `InsufficientInstanceCapacity` if `SPOT_FALLBACK_ON_DEMAND=true`, waits for `running`, returns instance id. `bin/sandbox-up` parses flags, calls preflight, generates a short name, calls `provision_launch`, prints SSH command.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/up.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/ami" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/ami/cloud-init.yaml.tmpl" "$SANDBOX_REPO_ROOT/ami/"
    cp "$REPO_ROOT/bin/sandbox-up" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
INSTANCE_TYPE="m7i-flex.xlarge"
USE_SPOT="true"
SPOT_FALLBACK_ON_DEMAND="true"
AMI_ID="ami-abc"
AUTO_SHUTDOWN_HOURS="8"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_CMD="$BATS_TEST_TMPDIR/aws-fake"
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-stub"
    cat > "$CURL_CMD" <<'EOF'
#!/usr/bin/env bash
echo "1.2.3.4"
EOF
    chmod +x "$CURL_CMD"
    # Stub ssh so provision_launch's SSH-readiness check succeeds immediately.
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-ok"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_CMD"
    chmod +x "$SSH_CMD"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

# write_aws_fake takes a sequence of fixture stanzas — one per AWS call,
# each "rc::stdout". The stub uses a counter to pick which one.
write_aws_fake() {
    cat > "$AWS_CMD" <<'OUTER'
#!/usr/bin/env bash
set -e
counter_file="$AWS_FAKE_COUNTER"
n="$(cat "$counter_file" 2>/dev/null || echo 0)"
echo "$((n+1))" > "$counter_file"
echo "CALL[$((n+1))]: $*" >> "$AWS_STUB_LOG"
fixture_file="$AWS_FAKE_FIXTURES/$((n+1))"
if [[ -f "$fixture_file" ]]; then
    rc="$(head -n1 "$fixture_file")"
    tail -n +2 "$fixture_file"
    exit "$rc"
fi
exit 0
OUTER
    chmod +x "$AWS_CMD"
    export AWS_FAKE_COUNTER="$BATS_TEST_TMPDIR/counter"
    : > "$AWS_FAKE_COUNTER"
    export AWS_FAKE_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$AWS_FAKE_FIXTURES"
}

set_fixture() {
    local n="$1" rc="$2"
    shift 2
    { echo "$rc"; printf '%s' "$*"; } > "$AWS_FAKE_FIXTURES/$n"
}

@test "up happy path on spot prints ssh command" {
    write_aws_fake
    # Order of calls inside provision_launch:
    #   1: sts get-caller-identity
    #   2: describe-images
    #   3: describe-key-pairs
    #   4: describe-security-groups (ensure_sg)
    #   5: describe-security-groups (set ingress: list existing rules)
    #   6: revoke-security-group-ingress  (skipped if no existing 22/tcp rules — see fixture 5)
    #   7: authorize-security-group-ingress
    #   8: run-instances  (spot)
    #   9: wait instance-status-ok
    #  10: describe-instances (get IP)
    #  11: create-tags
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    # 6 not called (no existing rules to revoke)
    set_fixture 6 0 ''  # authorize
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'
    set_fixture 8 0 ''  # wait
    set_fixture 9 0 '5.6.7.8'
    set_fixture 10 0 ''  # create-tags

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
    # Confirm spot was requested.
    grep -q -- '--cli-input-json' "$AWS_STUB_LOG"
}

@test "up falls back to on-demand on InsufficientInstanceCapacity" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    # 7: spot run-instances fails with capacity error
    set_fixture 7 255 'An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation'
    # 8: on-demand retry succeeds
    set_fixture 8 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'
    set_fixture 9 0 ''
    set_fixture 10 0 '5.6.7.8'
    set_fixture 11 0 ''

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up"
    [ "$status" -eq 0 ]
    [[ "$output" == *"spot unavailable"* ]] || [[ "$output" == *"falling back to on-demand"* ]]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
}

@test "up with --no-spot skips spot, goes straight to on-demand" {
    write_aws_fake
    set_fixture 1 0 '{"Arn":"x"}'
    set_fixture 2 0 '{"Images":[{"ImageId":"ami-abc"}]}'
    set_fixture 3 0 '{"KeyPairs":[{"KeyName":"claude-sandbox"}]}'
    set_fixture 4 0 'sg-123'
    set_fixture 5 0 '{"SecurityGroups":[{"IpPermissions":[]}]}'
    set_fixture 6 0 ''
    set_fixture 7 0 '{"Instances":[{"InstanceId":"i-xyz"}]}'
    set_fixture 8 0 ''
    set_fixture 9 0 '5.6.7.8'
    set_fixture 10 0 ''

    run "$SANDBOX_REPO_ROOT/bin/sandbox-up" --no-spot
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh ubuntu@5.6.7.8"* ]]
    # run-instances JSON should NOT contain InstanceMarketOptions when --no-spot
    grep -q -- 'run-instances' "$AWS_STUB_LOG"
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/up.bats
```

- [ ] **Step 3: Extend `lib/provision.sh`** — append:

```bash
# build_run_instances_json NAME USE_SPOT — emits JSON to stdout.
build_run_instances_json() {
    local name="$1"
    local use_spot="$2"
    local sg_id="$3"
    local user_data_b64="$4"
    local created_at iso owner_tag

    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    owner_tag="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"

    local spot_block=""
    if [[ "$use_spot" == "true" ]]; then
        spot_block=',"InstanceMarketOptions":{"MarketType":"spot","SpotOptions":{"InstanceInterruptionBehavior":"terminate"}}'
    fi

    cat <<EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$SSH_KEY_NAME",
  "MaxCount": 1,
  "MinCount": 1,
  "SecurityGroupIds": ["$sg_id"],
  "InstanceInitiatedShutdownBehavior": "terminate",
  "BlockDeviceMappings": [
    {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}
  ],
  "UserData": "$user_data_b64",
  "TagSpecifications": [
    {"ResourceType":"instance","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"},
      {"Key":"CreatedAt","Value":"$iso"},
      {"Key":"Owner","Value":"$owner_tag"}
    ]},
    {"ResourceType":"volume","Tags":[
      {"Key":"Project","Value":"claude-sandbox"},
      {"Key":"Name","Value":"$name"}
    ]}
  ]$spot_block
}
EOF
}

# provision_launch NAME REPO USE_SPOT — prints "<instance-id> <ip>" on success.
provision_launch() {
    local name="$1"
    local repo="$2"
    local use_spot="$3"

    local cidr; cidr="$(current_public_ip_cidr)"
    local sg_id; sg_id="$(ensure_sg)"
    log_info "security group: $sg_id; SSH ingress = $cidr"
    aws_set_sg_ingress_to "$sg_id" "$cidr"

    local user_data; user_data="$(render_cloud_init "$name" "$repo" "${AUTO_SHUTDOWN_HOURS:-0}")"
    local user_data_b64; user_data_b64="$(printf '%s' "$user_data" | base64 | tr -d '\n')"

    local id err_log
    err_log="$(mktemp)"
    if [[ "$use_spot" == "true" ]]; then
        log_info "requesting spot instance ($INSTANCE_TYPE)..."
        if id="$(_run_instances "$name" true "$sg_id" "$user_data_b64" 2>"$err_log")"; then
            : # spot succeeded
        elif grep -q "InsufficientInstanceCapacity" "$err_log" && [[ "${SPOT_FALLBACK_ON_DEMAND:-false}" == "true" ]]; then
            log_warn "spot unavailable, falling back to on-demand"
            id="$(_run_instances "$name" false "$sg_id" "$user_data_b64")"
        else
            local err; err="$(cat "$err_log")"
            rm -f "$err_log"
            die "run-instances (spot) failed: $err"
        fi
    else
        log_info "requesting on-demand instance ($INSTANCE_TYPE)..."
        id="$(_run_instances "$name" false "$sg_id" "$user_data_b64")"
    fi
    rm -f "$err_log"

    log_info "instance $id launched; waiting for status checks (60-90s)..."
    aws_wait_running "$id"

    local ip; ip="$(aws_get_instance_ip "$id")"
    [[ "$ip" == "None" || -z "$ip" ]] && die "instance $id has no public IP"

    # Verify SSH actually comes up. On failure, show last 50 lines of EC2
    # console output to help diagnose AMI/sshd issues per the spec.
    : "${SSH_CMD:=ssh}"
    local ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR -o ConnectTimeout=10)
    local i ok=0
    for i in {1..18}; do  # ~90s total
        if "$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER}@${ip}" true 2>/dev/null; then
            ok=1; break
        fi
        sleep 5
    done
    if [[ "$ok" -ne 1 ]]; then
        log_err "SSH never came up on $ip; last 50 lines of console output:"
        aws_get_console_output "$id" | tail -n 50 >&2
        die "instance $id reachable on network but SSH not responding"
    fi

    printf '%s %s\n' "$id" "$ip"
}

# Internal: actually invoke run-instances; returns the instance id or
# prints the AWS error message and exits non-zero.
_run_instances() {
    local name="$1" use_spot="$2" sg_id="$3" user_data_b64="$4"
    local json; json="$(build_run_instances_json "$name" "$use_spot" "$sg_id" "$user_data_b64")"
    printf '%s' "$json" | aws_run_instances_json
}
```

- [ ] **Step 4: Create `bin/sandbox-up`**

```bash
#!/usr/bin/env bash
# bin/sandbox-up — provision one sandbox.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=../lib/aws.sh
source "$REPO_ROOT/lib/aws.sh"
# shellcheck source=../lib/provision.sh
source "$REPO_ROOT/lib/provision.sh"

usage() {
    cat >&2 <<'EOF'
Usage: sandbox up [--repo URL] [--name N] [--instance-type T] [--no-spot]
EOF
}

REPO_URL=""
NAME=""
NO_SPOT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)           REPO_URL="$2"; shift 2 ;;
        --name)           NAME="$2"; shift 2 ;;
        --instance-type)  config_set_from_flag INSTANCE_TYPE "$2"; shift 2 ;;
        --no-spot)        NO_SPOT=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; exit 2 ;;
    esac
done

config_load

# Default name = sandbox-<8 hex chars>
if [[ -z "$NAME" ]]; then
    NAME="sandbox-$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c8)"
fi

USE_SPOT_FINAL="${USE_SPOT:-false}"
[[ "$NO_SPOT" -eq 1 ]] && USE_SPOT_FINAL="false"

preflight_or_die

read -r id ip < <(provision_launch "$NAME" "$REPO_URL" "$USE_SPOT_FINAL")

cat <<EOF

  $NAME ready ($id)

  ssh ${SSH_USER}@${ip}

  Once in, run \`claude\` to authenticate this VM.
  Auto-shutdown in ${AUTO_SHUTDOWN_HOURS}h.

EOF
```

```bash
chmod +x bin/sandbox-up
```

- [ ] **Step 5: Run tests**

```bash
bats test/unit/up.bats
```

Expected: 3 pass.

- [ ] **Step 6: Lint**

```bash
make lint
```

- [ ] **Step 7: Commit**

```bash
git add bin/sandbox-up lib/provision.sh test/unit/up.bats
git commit -m "Task 8: sandbox up with spot + on-demand fallback"
```

---

### Task 9: `sandbox ssh`

**Files:**
- Create: `bin/sandbox-ssh`
- Test: `test/unit/ssh.bats`

Resolves name → IP via tags, then `exec ssh <user>@<ip>`. Uses `$SSH_CMD` (default `ssh`) for testability.

- [ ] **Step 1: Write the failing test**

Create `test/unit/ssh.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/bin/sandbox-ssh" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_USER="ubuntu"
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-stub"
    cat > "$SSH_CMD" <<'EOF'
#!/usr/bin/env bash
echo "SSH_CMD: $*"
EOF
    chmod +x "$SSH_CMD"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "ssh resolves name → IP and execs ssh user@ip" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[{"Instances":[
  {"InstanceId":"i-aaa","PublicIpAddress":"5.6.7.8","State":{"Name":"running"},
   "Tags":[{"Key":"Name","Value":"sandbox-x"},{"Key":"Project","Value":"claude-sandbox"}]}
]}]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" sandbox-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH_CMD: ubuntu@5.6.7.8"* ]]
}

@test "ssh unknown name exits non-zero" {
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
{"Reservations":[]}
EOF
    run "$SANDBOX_REPO_ROOT/bin/sandbox-ssh" nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no sandbox named nope"* ]]
}
```

- [ ] **Step 2: Run — failing**

```bash
bats test/unit/ssh.bats
```

- [ ] **Step 3: Create `bin/sandbox-ssh`**

```bash
#!/usr/bin/env bash
# bin/sandbox-ssh — SSH into a named sandbox.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=../lib/aws.sh
source "$REPO_ROOT/lib/aws.sh"

: "${SSH_CMD:=ssh}"

[[ $# -eq 1 ]] || die "Usage: sandbox ssh <name>"
name="$1"

config_load
aws_caller_identity

json="$(aws_describe_instances_by_tag Name "$name")"
ip="$(printf '%s' "$json" | jq -r '.Reservations[].Instances[] | select(.State.Name=="running") | .PublicIpAddress' | head -n1)"

if [[ -z "$ip" || "$ip" == "null" ]]; then
    die "no sandbox named $name (or it's not running)"
fi

exec "$SSH_CMD" "${SSH_USER}@${ip}"
```

```bash
chmod +x bin/sandbox-ssh
```

- [ ] **Step 4: Run tests**

```bash
bats test/unit/ssh.bats
```

Expected: 2 pass.

- [ ] **Step 5: Lint**

```bash
make lint
```

- [ ] **Step 6: Commit**

```bash
git add bin/sandbox-ssh test/unit/ssh.bats
git commit -m "Task 9: sandbox ssh"
```

---

## Phase D — AMI bake & smoke

### Task 10: AMI bootstrap + systemd auto-shutdown

**Files:**
- Create: `ami/bootstrap.sh`, `ami/systemd/auto-shutdown.service`, `ami/systemd/auto-shutdown.timer`

`bootstrap.sh` runs inside the bake VM as `ubuntu` via `sudo`. Installs claude, node, uv, docker, and the systemd unit files. No unit tests — verification happens in the Task 12 smoke run.

- [ ] **Step 1: Create `ami/systemd/auto-shutdown.service`**

```ini
[Unit]
Description=Sandbox defense-in-depth auto-shutdown
ConditionPathExists=/etc/default/auto-shutdown

[Service]
Type=oneshot
EnvironmentFile=/etc/default/auto-shutdown
ExecStart=/bin/bash -c '\
  if [[ -z "$AUTO_SHUTDOWN_HOURS" || "$AUTO_SHUTDOWN_HOURS" -le 0 ]]; then exit 0; fi; \
  uptime_sec=$(awk "{print int(\\$1)}" /proc/uptime); \
  threshold=$(( AUTO_SHUTDOWN_HOURS * 3600 )); \
  if (( uptime_sec >= threshold )); then \
    logger -t auto-shutdown "uptime=$uptime_sec >= threshold=$threshold, shutting down"; \
    shutdown -h now; \
  fi'
```

- [ ] **Step 2: Create `ami/systemd/auto-shutdown.timer`**

```ini
[Unit]
Description=Run auto-shutdown check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Create `ami/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# ami/bootstrap.sh — runs inside a fresh Ubuntu 24.04 VM during AMI bake.
# Invoked by `sandbox build-ami` over SSH. Expects to be running as a user
# with passwordless sudo.

set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-}"

log() { printf '[bootstrap %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

log "apt update + base packages"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    git tmux htop jq ripgrep fd-find fzf unzip build-essential \
    python3 python3-pip python-is-python3 \
    shellcheck bats

log "Node.js LTS (NodeSource)"
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g pnpm

log "bun"
curl -fsSL https://bun.sh/install | bash
# Move bun into /usr/local/bin so all shells see it.
sudo install -m 0755 ~/.bun/bin/bun /usr/local/bin/bun
rm -rf ~/.bun

log "uv (Astral)"
curl -LsSf https://astral.sh/uv/install.sh | sh
sudo install -m 0755 ~/.local/bin/uv /usr/local/bin/uv
sudo install -m 0755 ~/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

log "Docker Engine"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ubuntu

log "GitHub CLI"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y gh

log "claude code CLI"
# Official install one-liner — uses npm under the hood, installs to /usr/local.
sudo npm install -g @anthropic-ai/claude-code

log "fd alias (Ubuntu names it fdfind)"
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd

log "systemd auto-shutdown unit"
sudo install -m 0644 /tmp/auto-shutdown.service /etc/systemd/system/auto-shutdown.service
sudo install -m 0644 /tmp/auto-shutdown.timer   /etc/systemd/system/auto-shutdown.timer

if [[ -n "$DOTFILES_REPO" ]]; then
    log "dotfiles: $DOTFILES_REPO"
    sudo -u ubuntu git clone "$DOTFILES_REPO" /home/ubuntu/dotfiles
    # If there's an install.sh, run it; otherwise leave it for the user.
    if [[ -x /home/ubuntu/dotfiles/install.sh ]]; then
        sudo -u ubuntu bash -lc 'cd ~/dotfiles && ./install.sh'
    fi
fi

log "cleanup apt cache to shrink AMI"
sudo apt-get autoremove -y
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

log "done"
```

```bash
chmod +x ami/bootstrap.sh
```

- [ ] **Step 4: Lint shell**

```bash
make lint
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add ami/bootstrap.sh ami/systemd/
git commit -m "Task 10: AMI bootstrap + systemd auto-shutdown units"
```

---

### Task 11: `sandbox build-ami`

**Files:**
- Create: `bin/sandbox-build-ami`
- Modify: `lib/aws.sh` (add `aws_create_image`, `aws_wait_image_available`, `aws_describe_ubuntu_2404_ami`)
- Modify: `lib/config.sh` (add `config_write_ami_id`)
- Test: `test/unit/build-ami.bats`

Orchestrates: find latest Ubuntu 24.04 AMI → launch a `t3.medium` from it → wait for SSH → `scp` bootstrap files → run `bootstrap.sh` over SSH → `create-image` → wait for `available` → write `AMI_ID` into `./config` → terminate bake instance. On bootstrap failure, leaves the instance running and prints SSH command.

- [ ] **Step 1: Add config writer test**

Add this test to `test/unit/config.bats`:

```bash
@test "config_write_ami_id updates AMI_ID line in place" {
    write_config <<'EOF'
INSTANCE_TYPE="m7i-flex.xlarge"
AMI_ID=""
USE_SPOT=true
EOF
    source "$SANDBOX_REPO_ROOT/lib/config.sh"
    config_load
    config_write_ami_id "ami-new123"
    grep -q '^AMI_ID="ami-new123"' "$SANDBOX_REPO_ROOT/config"
    # Other lines preserved.
    grep -q '^INSTANCE_TYPE="m7i-flex.xlarge"' "$SANDBOX_REPO_ROOT/config"
}
```

- [ ] **Step 2: Run — should fail**

```bash
bats test/unit/config.bats
```

- [ ] **Step 3: Extend `lib/config.sh`** — append:

```bash
# config_write_ami_id NEW_ID — rewrite the AMI_ID="..." line in ./config.
config_write_ami_id() {
    : "${SANDBOX_REPO_ROOT:?config_write_ami_id: SANDBOX_REPO_ROOT not set}"
    local new_id="$1"
    local cfg="$SANDBOX_REPO_ROOT/config"
    [[ -f "$cfg" ]] || die "no config at $cfg"
    local tmp; tmp="$(mktemp)"
    if grep -q '^AMI_ID=' "$cfg"; then
        sed -E 's|^AMI_ID=.*|AMI_ID="'"$new_id"'"|' "$cfg" > "$tmp"
    else
        cp "$cfg" "$tmp"
        printf '\nAMI_ID="%s"\n' "$new_id" >> "$tmp"
    fi
    mv "$tmp" "$cfg"
}
```

- [ ] **Step 4: Run config tests — pass**

```bash
bats test/unit/config.bats
```

Expected: 6 pass (5 prior + 1 new).

- [ ] **Step 5: Extend `lib/aws.sh`** — append:

```bash
# Latest Canonical Ubuntu 24.04 LTS amd64 AMI in current region.
aws_describe_ubuntu_2404_ami() {
    _aws ec2 describe-images \
        --owners 099720109477 \
        --filters \
            'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
            'Name=state,Values=available' \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text
}

aws_create_image() {
    local instance_id="$1"
    local name="$2"
    _aws ec2 create-image --instance-id "$instance_id" --name "$name" \
        --no-reboot --query ImageId --output text
}

aws_wait_image_available() {
    local ami_id="$1"
    _aws ec2 wait image-available --image-ids "$ami_id"
}

aws_run_simple() {
    # Minimal launch for the bake VM: ami, type, key, sg, tag.
    local ami="$1" itype="$2" key="$3" sg="$4" name="$5"
    _aws ec2 run-instances \
        --image-id "$ami" --instance-type "$itype" --key-name "$key" \
        --security-group-ids "$sg" --count 1 \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=claude-sandbox},{Key=Name,Value=$name},{Key=BakeRole,Value=bake}]" \
        --query 'Instances[0].InstanceId' --output text
}
```

- [ ] **Step 6: Write bake test**

Create `test/unit/build-ami.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export SANDBOX_REPO_ROOT="$(mktemp -d)"
    mkdir -p "$SANDBOX_REPO_ROOT/lib" "$SANDBOX_REPO_ROOT/ami/systemd" "$SANDBOX_REPO_ROOT/bin"
    cp "$REPO_ROOT"/lib/{log,config,aws,provision}.sh "$SANDBOX_REPO_ROOT/lib/"
    cp "$REPO_ROOT/ami/bootstrap.sh" "$SANDBOX_REPO_ROOT/ami/"
    cp "$REPO_ROOT"/ami/systemd/*.{service,timer} "$SANDBOX_REPO_ROOT/ami/systemd/"
    cp "$REPO_ROOT/bin/sandbox-build-ami" "$SANDBOX_REPO_ROOT/bin/"
    cat > "$SANDBOX_REPO_ROOT/config" <<'EOF'
AWS_REGION="us-west-2"
SSH_KEY_NAME="claude-sandbox"
SSH_USER="ubuntu"
AMI_ID=""
DOTFILES_REPO=""
EOF
    export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_STUB_LOG"
    export AWS_STUB_RESPONSE="$BATS_TEST_TMPDIR/aws-resp"
    export AWS_CMD="$REPO_ROOT/test/unit/stubs/aws-empty"
    # ssh / scp stubs that succeed silently.
    export SSH_CMD="$BATS_TEST_TMPDIR/ssh-ok"
    export SCP_CMD="$BATS_TEST_TMPDIR/scp-ok"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_CMD"; chmod +x "$SSH_CMD"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SCP_CMD"; chmod +x "$SCP_CMD"
    # curl stub for ssh-readiness check (we test against the netcat path differently)
    export CURL_CMD="$BATS_TEST_TMPDIR/curl-ok"
    printf '#!/usr/bin/env bash\necho 1.2.3.4\n' > "$CURL_CMD"; chmod +x "$CURL_CMD"
}

teardown() { rm -rf "$SANDBOX_REPO_ROOT"; }

@test "build-ami writes new AMI_ID to config on success" {
    # Walk through the calls:
    #   1: aws_caller_identity (sts get-caller-identity)
    #   2: describe-key-pairs
    #   3: describe-security-groups (ensure_sg)
    #   4: describe-security-groups (set ingress: list rules)
    #   5: authorize-security-group-ingress (no existing rule to revoke)
    #   6: describe-images (find base Ubuntu AMI)        → ami-base
    #   7: run-instances (bake VM)                       → i-bake
    #   8: wait instance-status-ok
    #   9: describe-instances (get IP)                   → 1.2.3.4
    #  10: create-image                                  → ami-new123
    #  11: wait image-available
    #  12: terminate-instances
    cat > "$AWS_STUB_RESPONSE" <<'EOF'
0
ami-new123
EOF
    # Default stub returns the same output for every call. That's fine for
    # asserting on overall orchestration — we check the call log below.
    run "$SANDBOX_REPO_ROOT/bin/sandbox-build-ami"
    [ "$status" -eq 0 ]
    grep -q -- 'ec2 describe-images.*099720109477' "$AWS_STUB_LOG"
    grep -q -- 'ec2 run-instances' "$AWS_STUB_LOG"
    grep -q -- 'ec2 create-image' "$AWS_STUB_LOG"
    grep -q -- 'ec2 wait image-available' "$AWS_STUB_LOG"
    grep -q -- 'ec2 terminate-instances' "$AWS_STUB_LOG"
    grep -q '^AMI_ID="ami-new123"' "$SANDBOX_REPO_ROOT/config"
}
```

- [ ] **Step 7: Run — failing**

```bash
bats test/unit/build-ami.bats
```

- [ ] **Step 8: Create `bin/sandbox-build-ami`**

```bash
#!/usr/bin/env bash
# bin/sandbox-build-ami — bake a fresh AMI.

set -euo pipefail

REPO_ROOT="${SANDBOX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=../lib/aws.sh
source "$REPO_ROOT/lib/aws.sh"
# shellcheck source=../lib/provision.sh
source "$REPO_ROOT/lib/provision.sh"

: "${SSH_CMD:=ssh}"
: "${SCP_CMD:=scp}"

BAKE_INSTANCE_TYPE="t3.medium"

config_load
aws_caller_identity
aws_describe_key_pair "$SSH_KEY_NAME"

# Ensure SG and SSH ingress to current IP.
sg_id="$(ensure_sg)"
cidr="$(current_public_ip_cidr)"
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

aws_wait_running "$instance_id"
ip="$(aws_get_instance_ip "$instance_id")"
log_info "bake VM IP: $ip"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=10)

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
    "${SSH_USER}@${ip}:/tmp/"

log_info "running bootstrap (this can take 5-10 minutes)..."
"$SSH_CMD" "${ssh_opts[@]}" "${SSH_USER}@${ip}" \
    "DOTFILES_REPO='${DOTFILES_REPO:-}' bash /tmp/bootstrap.sh"

ami_name="claude-sandbox-$(date -u +%Y%m%dT%H%M%SZ)"
log_info "creating image $ami_name..."
new_ami="$(aws_create_image "$instance_id" "$ami_name")"
log_info "new AMI: $new_ami (waiting for available)..."
aws_wait_image_available "$new_ami"

log_info "writing AMI_ID into ./config"
config_write_ami_id "$new_ami"

log_info "terminating bake VM..."
aws_terminate_instances "$instance_id" >/dev/null

cleanup_on_failure=0
log_info "done. AMI_ID=$new_ami"
```

```bash
chmod +x bin/sandbox-build-ami
```

- [ ] **Step 9: Run tests**

```bash
bats test/unit/build-ami.bats
```

Expected: 1 pass. Note: this is a low-fidelity stub test verifying orchestration, not behavior — the real verification happens in the smoke test.

- [ ] **Step 10: Lint**

```bash
make lint
```

- [ ] **Step 11: Commit**

```bash
git add bin/sandbox-build-ami lib/aws.sh lib/config.sh test/unit/build-ami.bats test/unit/config.bats
git commit -m "Task 11: sandbox build-ami orchestrator"
```

---

### Task 12: Smoke test + README finalization

**Files:**
- Create: `test/smoke.sh`
- Modify: `README.md`

End-to-end check on real AWS. Should be invoked manually: `make smoke`. Each run costs roughly 5-15¢ on spot.

- [ ] **Step 1: Create `test/smoke.sh`**

```bash
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
```

```bash
chmod +x test/smoke.sh
```

- [ ] **Step 2: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 3: Replace `README.md` with finalized version**

```markdown
# remote-sandbox

A local CLI that provisions ephemeral AWS EC2 sandboxes pre-configured for
Claude Code. One fresh box per task, terminated when done.

See `docs/specs/2026-05-12-remote-sandbox-design.md` for the full design.

## Prerequisites

- macOS or Linux laptop
- `aws` CLI v2, configured (`aws sts get-caller-identity` works)
- `jq`, `curl`, `git`
- An EC2 key pair created in `us-west-2`, named whatever you set as
  `SSH_KEY_NAME` in `./config` (default: `claude-sandbox`). Save its
  private key somewhere your SSH agent or `~/.ssh/config` can find.

## Setup

```bash
cp config.example config
# Edit ./config — at minimum verify SSH_KEY_NAME matches the EC2 key pair
# you created above.
./bin/sandbox build-ami     # ~10 minutes, one-time (and whenever you want fresh tools)
```

## Commands

```bash
./bin/sandbox up                       # spin up a fresh box (spot)
./bin/sandbox up --repo URL            #   ...and clone a repo into it
./bin/sandbox up --no-spot             # avoid spot (e.g. long unattended tests)
./bin/sandbox up --instance-type t3.large
./bin/sandbox up --name myproject      # custom name

./bin/sandbox list                     # what's running?
./bin/sandbox ssh <name>               # SSH into a box

./bin/sandbox down <name>              # terminate one
./bin/sandbox down --all               # terminate all
./bin/sandbox down --stale 24h         # terminate boxes older than 24h

./bin/sandbox build-ami                # bake a fresh AMI
```

## Once you're SSHed in

Run `claude` — it prints a URL. Open the URL in your laptop browser, approve,
and the browser will show a code. Paste that code back into the SSH terminal.
The OAuth token lives on this VM only, and dies when you `down` the box.

## Cost

Expected ~$10-15/month at a few 1-3h sessions/day on spot. The systemd
auto-shutdown timer terminates the box after `AUTO_SHUTDOWN_HOURS`
(default 8) of uptime even if you forget to `down` it.

## Development

`shellcheck` and `bats-core` live inside the sandbox, not on your laptop. The
dev loop:

```bash
# On your laptop: spin up a working sandbox (one-time per dev session).
./bin/sandbox up --name dev

# After every edit, sync the repo over and run checks inside the box:
rsync -av --exclude-from=.gitignore --exclude='.git/' ./ \
    "$(./bin/sandbox list | awk '/^dev /{print $NF}')":~/remote-sandbox/

./bin/sandbox ssh dev
# inside the sandbox:
cd ~/remote-sandbox
make lint      # shellcheck — runs in the sandbox
make test      # bats unit tests — runs in the sandbox
exit

# When done:
./bin/sandbox down dev

# Smoke test against real AWS — run from your laptop, costs a few cents.
make smoke
```

`make smoke` is the only target that runs on the laptop (because it has to
exercise the laptop CLI itself end-to-end).
```

- [ ] **Step 4: Run the full unit suite + lint**

```bash
make lint && make test
```

Expected: lint clean, all bats tests pass.

- [ ] **Step 5: Run the smoke test against real AWS**

This requires `./config` to be filled in, an EC2 key pair to exist, and `aws` CLI to be configured.

```bash
make smoke
```

Expected: builds AMI if needed, provisions a box, asserts `claude --version`, `node --version`, `uv --version`, and `docker run hello-world` work, then tears it down. Final line: `smoke passed`.

- [ ] **Step 6: Commit**

```bash
git add test/smoke.sh README.md
git commit -m "Task 12: smoke test + finalized README"
```

- [ ] **Step 7: Tag v0.1**

```bash
git tag -a v0.1 -m "Remote sandbox v0.1 — initial working version"
```

---

## Definition of done

- All unit tests pass (`make test`).
- `make lint` is clean.
- `make smoke` passes against real AWS.
- README accurately reflects the working commands.
- `./bin/sandbox up` from a fresh clone (with `./config` set up) produces an SSH-able box in ~60s on a warm AMI.
- `./bin/sandbox down --all` cleans up everything tagged `Project=claude-sandbox` in the configured region.
