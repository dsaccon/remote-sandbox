# Remote Sandbox — Design

**Date:** 2026-05-12
**Status:** Draft, pending user review

## Goal

A local CLI that provisions a fresh, ephemeral AWS EC2 sandbox per task, pre-configured for use with Claude Code via the user's subscription. The user SSHes in, runs `claude`, and works. The sandbox is destroyed after the task. This isolates coding agents from the user's main laptop, primarily to limit blast radius from supply-chain attacks against tools the agent might run.

## Non-goals

- Multi-user / team workflows.
- Web-based IDE access (no code-server, no Coder workspace UI).
- Persistent state across sandboxes (each task starts clean).
- A management control plane.
- GCP support in v1 (the design leaves room for it; not implemented).
- Automatic GitHub auth on the box — the user handles git auth manually once SSHed in.

## Build vs buy: build

Coder.com (OSS or Cloud) was considered and rejected:

- Coder's value is fleets of templated workspaces for many devs accessed via web IDE. This use case is one person, SSH-only, ephemeral.
- Coder OSS requires running a Postgres + control-plane server 24/7 — that adds always-on infra, the opposite of the "minimize work on the main machine" goal.
- It adds another auth layer (Coder identity) on top of AWS, Claude, and GitHub.

A DIY bash CLI wrapping `aws ec2 run-instances` + a pre-baked AMI is small (~200-300 LOC of shell), has no long-running infra, and adds no new auth.

## Decisions summary

| Topic | Decision |
|---|---|
| Interaction model | SSH + terminal `claude` in tmux. No remote IDE. |
| Lifecycle | Ephemeral — one fresh box per task, terminated when done. |
| Bootstrap | Pre-baked AMI; per-launch cloud-init only sets hostname and optional repo clone. |
| Ready state | Bare box with Claude Code installed + dotfiles; optional `--repo URL` to clone one repo at launch. |
| Claude Code auth | Interactive per spin-up: user runs `claude`, gets a URL, approves in laptop browser, pastes the returned code back into the SSH terminal. OAuth token lives on the ephemeral VM and dies with it. |
| GitHub auth | Out of scope — user handles it manually once SSHed in. |
| Cloud | AWS only in v1. Repo structure leaves room for `provision.gcp.sh` later. |
| Instance type | `m7i-flex.xlarge` default (4 vCPU / 16 GB / ~$0.156/hr on-demand). Configurable. |
| Spot | On by default with automatic on-demand fallback on `InsufficientInstanceCapacity`. `--no-spot` flag for sessions where interruption would be especially costly. |
| Region | `us-west-2` (Oregon) default. Configurable. |
| Disk | 30 GB gp3 root EBS, `DeleteOnTermination=true`. Nothing persists. |
| Auto-shutdown | Systemd timer on the box: `shutdown -h now` after `AUTO_SHUTDOWN_HOURS` uptime (default 8). |
| Config location | In-repo at `./config` (gitignored), `./config.example` checked in. |
| First-run UX | `./bin/sandbox` errors with "no config — copy `config.example` to `config` and edit" if `config` is missing. |

Expected cost at typical use (a few 1-3 hour sessions/day on spot): ~$10-15/month.

## Architecture

### Repo layout

Everything self-contained inside the repo root:

```
remote-sandbox/
    bin/
        sandbox                   # main CLI entry (dispatcher)
        sandbox-up
        sandbox-down
        sandbox-list
        sandbox-ssh
        sandbox-build-ami
    lib/
        aws.sh                    # thin wrappers over `aws` CLI
        config.sh                 # config loading + precedence
        provision.sh              # core "launch a box" logic
        log.sh                    # consistent stderr logging
    ami/
        bootstrap.sh              # runs once during AMI bake
        cloud-init.yaml.tmpl      # rendered per-launch
        systemd/
            auto-shutdown.service
            auto-shutdown.timer
    test/
        smoke.sh                  # end-to-end: build-ami (skip if current), up, ssh, down
        unit/                     # bats-core tests for pure helpers
    docs/
        specs/                    # design docs (this file)
    config.example                # checked in, documents every setting
    config                        # gitignored; user creates from example
    .gitignore                    # ignores: config, *.local, .aws-cache/, state/
    README.md
```

Nothing is installed outside this directory. The user runs `./bin/sandbox up` from inside the repo. No `~/.config/...`, no `~/.local/bin/...` symlink.

The only home-dir touch points come from tools the user already configures: `~/.aws/credentials` (AWS CLI) and wherever the user stores their EC2 key pair.

### Config file

Format: bash-sourced (zero extra deps, supports comments). `lib/config.sh` sources it and applies precedence.

```bash
# config.example — copy to ./config and edit

# Cloud / region
CLOUD="aws"                       # "aws" | "gcp" (future)
AWS_REGION="us-west-2"            # Oregon

# Instance
INSTANCE_TYPE="m7i-flex.xlarge"   # 16 GB / 4 vCPU — recommended default
USE_SPOT=true
SPOT_FALLBACK_ON_DEMAND=true

# Identity / access
SSH_KEY_NAME="claude-sandbox"     # name of an existing EC2 key pair in AWS
SSH_USER="ubuntu"

# AMI — populated by `./bin/sandbox build-ami` on success
AMI_ID=""

# Lifecycle guardrails
AUTO_SHUTDOWN_HOURS=8             # 0 = disabled

# Optional: dotfiles cloned to ~ during AMI bake
DOTFILES_REPO=""                  # e.g. "https://github.com/dsaccon/dotfiles.git"
```

**Precedence (highest wins):** CLI flag → `SANDBOX_*` env var → `config` file → built-in default.

### CLI commands

| Command | Behavior |
|---|---|
| `./bin/sandbox up [--repo URL] [--name N] [--instance-type T] [--no-spot]` | Provision one box. Prints `ssh ubuntu@<ip>` and a hint to run `claude`. |
| `./bin/sandbox down <name\|id>` | Terminate one box. |
| `./bin/sandbox down --all` | Terminate every box tagged `Project=claude-sandbox` owned by user. |
| `./bin/sandbox down --stale 24h` | Terminate boxes older than N hours. |
| `./bin/sandbox list` | List all `Project=claude-sandbox` instances: name, state, type, age, IP. |
| `./bin/sandbox ssh <name>` | Resolve name → IP, `ssh` in. Convenience wrapper. |
| `./bin/sandbox build-ami [--base ubuntu-24.04]` | Bake a new AMI. Writes new `AMI_ID` to `config` on success. |

### Data flow — `sandbox up`

1. Load `config` + flags. Validate `AMI_ID` is set; otherwise exit with "run `./bin/sandbox build-ami`".
2. Preflight: `aws sts get-caller-identity`, AMI exists in region, EC2 key pair exists, security group exists (create if missing).
3. Rewrite the security group's SSH ingress rule to the laptop's current public IP (`curl -s https://checkip.amazonaws.com`).
4. Render `cloud-init.yaml` from template — substitutes hostname, optional `git clone <repo>`.
5. `aws ec2 run-instances` with `InstanceInitiatedShutdownBehavior=terminate` (so the in-VM auto-shutdown timer terminates instead of stopping) and `InstanceMarketOptions={MarketType: spot, SpotOptions: {InstanceInterruptionBehavior: terminate}}` if `USE_SPOT=true`.
6. On `InsufficientInstanceCapacity`, if `SPOT_FALLBACK_ON_DEMAND=true`: log "spot unavailable, falling back to on-demand" and retry without market options.
7. Wait for `running` + status checks (typically 30-60s with pre-baked AMI).
8. Print `ssh ubuntu@<ip>` and the hint: `(once in, run \`claude\` to authenticate this VM)`.

### Data flow — `sandbox build-ami`

1. Launch a t3.medium from stock `ubuntu-24.04 amd64` AMI.
2. Wait for SSH.
3. `scp` `ami/bootstrap.sh`, `ami/systemd/*` to the instance.
4. Run `bootstrap.sh` over SSH (installs tools, dotfiles, systemd timer).
5. On success: `aws ec2 create-image`, wait for `available`, write new `AMI_ID` into `config`.
6. Terminate the bake instance.
7. On failure: leave the bake instance running, print its ID + SSH command for the user to debug.

## Operational details

### Network / security

- Default VPC, public IP — no custom VPC plumbing.
- Security group `claude-sandbox-sg`: ingress SSH (22) from the laptop's current public IP only; egress open (needed for `apt`, `npm`, `git`, Claude API).
- Egress lockdown is explicitly out of scope. The threat model is "isolate the agent's process from my laptop's filesystem and credentials," not "agent cannot reach the internet" — agents need internet to do their job.

### Disk / state

- Root EBS: 30 GB gp3, `DeleteOnTermination=true`.
- No additional volumes. Nothing persists between sandboxes by design.

### Tagging

Every instance:
```
Project    = claude-sandbox
Name       = sandbox-<short-id>     # or --name override
CreatedAt  = <ISO 8601 UTC>
Owner      = $USER on $(hostname)
```

`./bin/sandbox list` and `down --stale` filter on `Project=claude-sandbox`.

### Auto-shutdown (defense in depth)

The AMI ships a systemd timer that runs `shutdown -h now` after `AUTO_SHUTDOWN_HOURS` of uptime (not idle — uptime is simpler and more predictable). When `shutdown -h` runs on an EC2 instance, the instance stops (not terminates) by default — but since `DeleteOnTermination=true` on the root volume, we want **terminate** behavior. We achieve that by setting `InstanceInitiatedShutdownBehavior=terminate` at launch time.

This protects against the "laptop dies, box runs forever" failure mode without trusting the laptop to clean up.

### Error handling — concrete cases

| Failure | Behavior |
|---|---|
| `aws sts get-caller-identity` fails | Exit with "AWS credentials not configured — run `aws configure`". |
| `AMI_ID` empty or not found in region | Exit with "no AMI — run `./bin/sandbox build-ami`". |
| EC2 key pair missing | Exit with key name + suggested `aws ec2 create-key-pair` command. |
| Spot `InsufficientInstanceCapacity` | One-line notice; retry on-demand if `SPOT_FALLBACK_ON_DEMAND=true`, else exit non-zero. |
| Other spot launch errors | Exit non-zero with message; do not silently fall back (could mask real bugs). |
| SSH timeout after `running` state | Fetch `aws ec2 get-console-output`, print last 50 lines, exit non-zero. |
| `build-ami` bootstrap fails | Leave the bake instance running; print its ID + SSH command for the user to debug. Do not write to `AMI_ID`. |
| `config` missing | Exit with "copy `config.example` to `config` and edit" hint. |

### AMI contents

Base: **Ubuntu 24.04 LTS, amd64.** Installed by `ami/bootstrap.sh`:

- `claude` CLI via the official installer.
- Node LTS (via NodeSource or fnm), `pnpm`, `bun`.
- `uv` (Astral Python toolchain) via `curl -LsSf https://astral.sh/uv/install.sh | sh`.
- `docker` (Docker Engine from Docker's official apt repo); `ubuntu` user added to `docker` group so `docker run` works without sudo.
- `git`, `gh`, `ripgrep`, `fd-find`, `jq`, `fzf`, `tmux`, `htop`.
- Dotfiles (optional: if `DOTFILES_REPO` set in config at bake time, clone to `~`).
- systemd `auto-shutdown.service` + `auto-shutdown.timer`.

ARM (Graviton) variant is out of scope for v1. Docker images on amd64 have the broadest compatibility.

## Testing

- `shellcheck` on every `.sh` file. Run via pre-commit or `make lint`.
- `bats-core` unit tests for the pure helpers — config precedence and cloud-init template rendering are the main targets.
- `test/smoke.sh` — end-to-end on real AWS: skip `build-ami` if `AMI_ID` is current, then `up` → wait → SSH in → assert `claude --version` and `docker run hello-world` work → `down`. Run manually before each release. Tagged with `Smoke=true` so a stuck smoke instance is easy to identify.

## Open questions / risks

- **Anthropic TOS for many ephemeral cloud VMs sharing one subscription:** not publicly documented. The expected usage (one user, a handful of boxes per day, each authed via the supported `claude` login flow) is consistent with normal use, but worth keeping an eye on if usage scales.
- **Spot interruption rates** vary by region/AZ. If `us-west-2` ever shows high interruption for `m7i-flex.xlarge`, swap instance family.
- **AMI staleness:** the user must remember to rerun `build-ami` periodically to get security updates. Mitigation: a small `./bin/sandbox doctor` could warn if the AMI is >30 days old. Optional, deferred.

## Out of scope / future work

- GCP provisioner.
- ARM (Graviton) AMI.
- Egress allowlist.
- Multi-region / multi-account.
- Headless / unattended agent runs (current design assumes interactive SSH).
- Persistent per-project EBS scratch volume.
- Web IDE option.
