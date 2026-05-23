# remote-sandbox

A local CLI that provisions ephemeral AWS EC2 sandboxes pre-configured for
Claude Code. One fresh box per task, terminated when done.

See `docs/specs/2026-05-12-remote-sandbox-design.md` for the full design and
`docs/superpowers/plans/2026-05-12-remote-sandbox.md` for the build plan.

## Local footprint — deliberately tiny

This is a near-zero-dependency utility by design. Everything you have to
install on the laptop:

```bash
brew install awscli jq
```

That's it.

- **Already on macOS, no install needed:** `git`, `curl`, `ssh`, `scp`,
  `bash` (3.2 is fine — scripts are 3.2-clean), `awk`, `sed`, `date`,
  `openssl`.
- **Lives inside the sandbox, NOT on your laptop:** `shellcheck`, `bats-core`,
  neovim, Node, `pnpm`, `bun`, `uv`, Docker, `gh`, the Claude Code CLI —
  all installed during the AMI bake (one-time, ~10 min) so they never
  touch your main machine.

This narrow footprint is the project's reason for existing: to limit blast
radius from supply-chain attacks on dev tooling by keeping the laptop side
spartan. The tool that *creates* sandboxes is itself one of the things that
should run with minimal local trust.

## Prerequisites

- macOS laptop (Linux works too; install/setup commands assume macOS)
- `aws` CLI v2, configured (`aws sts get-caller-identity` works) — installed via `brew install awscli`
- `jq` — installed via `brew install jq`
- An EC2 key pair created in `us-west-2`, named whatever you set as
  `SSH_KEY_NAME` in `./config` (default: `claude-sandbox`). Save its
  private key somewhere your SSH agent or `~/.ssh/config` can find:

  ```bash
  aws ec2 create-key-pair --region us-west-2 --key-name claude-sandbox \
      --query KeyMaterial --output text > ~/.ssh/claude-sandbox.pem
  chmod 600 ~/.ssh/claude-sandbox.pem
  ```

## Setup

One-time, in this order:

```bash
# 1. AWS credentials — populate .env from the template.
cp .env.example .env
chmod 600 .env
# Edit .env: paste AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY from the IAM
# user you created for this project. AWS_DEFAULT_REGION=us-west-2 is fine.

# 2. Project config — region, instance type, key pair name, etc.
cp config.example config
# Edit ./config — at minimum verify SSH_KEY_NAME matches the EC2 key pair
# you created above.

# 3. Load credentials into your shell (see "Each new terminal" below) and
#    verify before you go further:
source ./init.sh
aws sts get-caller-identity   # should print your account / IAM user ARN

# 4. Bake the AMI. ~10 minutes; you'll re-run this whenever you want fresh
#    tools or apt updates baked into the image.
./bin/sandbox build-ami
```

## Each new terminal

`aws` CLI and `./bin/sandbox` both read credentials from environment variables.
Before running any command in a freshly-opened terminal:

```bash
source ./init.sh
```

This loads `.env` into the environment **and** registers tab completion for
`./bin/sandbox`. You'll see:

```
init: exported [AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION] from ...
init: tab completion registered for ./bin/sandbox
```

The script refuses to run if you execute it (`./init.sh`) because that would
set vars in a subshell that dies immediately — it must be **sourced**.

Tab completion covers:

```
./bin/sandbox <TAB>             # → up | down | list | ssh | build-ami | --help
./bin/sandbox up <TAB>          # → --repo --name --instance-type --no-spot --help
./bin/sandbox ssh <TAB>         # → live list of your running sandbox names
./bin/sandbox down <TAB>        # → live names + --all + --stale
./bin/sandbox down --stale <TAB># → 30m | 1h | 4h | 12h | 24h | 48h | 7d
```

Name suggestions query EC2 each Tab press (~200-500ms latency). Bake VMs
(`sandbox-bake-...`) are filtered out — only your real sandboxes appear.
Re-source `init.sh` after pulling updates that touch `completion/sandbox.sh`.

## Commands

Run `./bin/sandbox --help` for the full list, or `./bin/sandbox <cmd> --help`
for details on any subcommand.

```bash
./bin/sandbox up                       # spin up a fresh box (spot) — non-blocking
./bin/sandbox up --repo URL            #   ...and clone a repo into it
./bin/sandbox up --no-spot             # avoid spot (e.g. long unattended tests)
./bin/sandbox up --instance-type t3.large
./bin/sandbox up --name myproject      # custom name

./bin/sandbox list                     # what's running? (see STATE values below)
./bin/sandbox list --active            #   ...just the ready ones (terse output)
./bin/sandbox ssh <name>               # SSH into a box

./bin/sandbox down <name>              # terminate one
./bin/sandbox down --all               # terminate all
./bin/sandbox down --stale 24h         # terminate boxes older than 24h

./bin/sandbox build-ami                # bake a fresh AMI
./bin/sandbox list-amis                # list AMIs you own (* = current)
./bin/sandbox list-amis --active       #   ...only AMIs in use (current + any in-use)
./bin/sandbox delete-ami <ami-id> [...] # delete old AMIs (+ their snapshots)
```

`build-ami` never deletes the previous AMI — each bake adds an AMI + a
~30 GB EBS snapshot (~$1.50/month each). Use `list-amis` to see them and
`delete-ami` to clean up; the current AMI (referenced in `./config`) is
protected.

### Sandbox lifecycle

`./bin/sandbox up` returns control as soon as AWS accepts the launch request
(typically <2s). The instance moves through these STATE values, visible in
`./bin/sandbox list`:

| STATE | Meaning |
|---|---|
| `pending` | EC2 has accepted the launch, instance is booting; no public IP yet |
| `initializing` | Instance is `running` but EC2 status checks haven't passed yet (typically 60-90s in this state) |
| `ready` | Both EC2 status checks passed — SSH should accept connections |
| `impaired` | A status check failed; instance is in trouble. Inspect with `aws ec2 get-console-output --instance-id ...` |
| `running` | Running, but status checks returned a non-standard value (`insufficient-data`/`not-applicable`) — rare |
| `stopping` / `stopped` | Halted (often by the in-VM auto-shutdown timer). For ephemeral use, treat as gone. |
| `shutting-down` / `terminated` | Killed (manually via `down`, by spot reclaim, or by `shutdown -h` on a `DeleteOnTermination=true` volume). |

Typical sequence after `./bin/sandbox up`:

```bash
$ ./bin/sandbox list
NAME                   STATE          TYPE               AGE        IP
sandbox-26bdd2af       pending        m7i-flex.xlarge    5s         -
# ...20s later...
sandbox-26bdd2af       initializing   m7i-flex.xlarge    25s        54.218.x.x
# ...60s later...
sandbox-26bdd2af       ready          m7i-flex.xlarge    85s        54.218.x.x

$ ./bin/sandbox ssh sandbox-26bdd2af
```

`./bin/sandbox ssh` against a non-`ready` instance now gives a useful error
("still booting", "stopped", etc.) instead of "no sandbox named X".

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
