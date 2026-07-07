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
  neovim, Node, `pnpm`, `bun`, `uv`, Docker, `gh` — all installed during the
  AMI bake (one-time, ~10 min) so they never touch your main machine. (Claude
  Code is installed per-session, not baked — see "Once you're SSHed in".)

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

### AWS IAM permissions

The IAM user whose keys go in `.env` needs the EC2 actions below. This is the
full set the CLI calls across `up` / `list` / `ssh` / `down` / `build-ami` /
`list-images` / `delete-image`. Attach it as an inline policy on that user:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RemoteSandbox",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVolumes",
        "ec2:DescribeVpcs",
        "ec2:GetConsoleOutput",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateImage",
        "ec2:DeregisterImage",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    }
  ]
}
```

`Resource: "*"` because most calls are account-wide describe/list operations;
resource-level scoping of `RunInstances` + tagging is fiddly and not worth it
for a personal tool. Trim to taste:

- Drop `ec2:CreateImage` / `DeregisterImage` / `DeleteSnapshot` if you never
  `build-ami` / `delete-image`.
- Drop `ec2:DescribeVolumes` and `list` just shows `-` in the DISK column
  (it degrades gracefully rather than erroring).

Editing IAM requires an **admin** identity — the sandbox user itself is
deliberately not allowed to change its own permissions.

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

## Using GCP

GCP support is newer and lighter-weight than the AWS path — there's no
AMI-equivalent baking yet (see below).

Prerequisites:

- `gcloud` CLI installed and authenticated for your project.
- A GCP project (its ID goes in `GCP_PROJECT` below).
- A service account with permission to create/delete both instances and
  firewall rules. `up` creates a per-sandbox firewall rule (and `down`
  deletes it), so instance permissions alone aren't enough. Least-privilege
  is two predefined roles: `roles/compute.instanceAdmin.v1` (instances) plus
  `roles/compute.securityAdmin` (firewall rules). Simpler but broader:
  the single `roles/compute.admin` role covers both. Download the account's
  key as JSON and keep it out of git: this repo already ignores
  `*.key`/`*.pem`, so save it with one of those extensions (e.g.
  `gcp-key.key`) even though the content is JSON — gcloud only cares about
  the content, not the filename.

Setup, in addition to the steps above:

```bash
# .env — point gcloud/ADC at the service account key.
echo 'GOOGLE_APPLICATION_CREDENTIALS=/absolute/path/to/gcp-key.key' >> .env

# ./config
CLOUD="gcp"
GCP_PROJECT="your-project-id"
```

`source ./init.sh` picks up `GOOGLE_APPLICATION_CREDENTIALS` from `.env` and
exports it for `gcloud`, printing `init: GOOGLE_APPLICATION_CREDENTIALS set
for gcloud` when the path exists.

`up`, `list`, `ssh`, `scp`, `down`, `spot`, and `build-ami` all work the same
as AWS. Two differences to know about:

- **First boot is slow until you bake an image.** With `GCP_IMAGE` unset (the
  default), each `up` boots a stock `ubuntu-2404-lts` instance and runs the
  full bootstrap at first boot — ~5-10 minutes before the box is usable, vs.
  ~60-90s off a baked image. Run `./bin/sandbox build-ami` once (with
  `CLOUD=gcp`, or `build-ami --cloud gcp`) to bake a custom image; it writes
  `GCP_IMAGE` into `./config` and subsequent boots are fast. The GCP bake runs
  the same `ami/bootstrap.sh` as AWS, so the image has the identical toolset.
- **`list-images` / `delete-image` span both clouds** (with a `PROVIDER`
  column), so your baked GCP images show up there alongside AWS AMIs — no need
  to drop to raw `gcloud`.

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
./bin/sandbox <TAB>             # → up | down | list | ssh | scp | spot | build-ami | --help
./bin/sandbox up <TAB>          # → --repo --name --instance-type --spot --no-spot --help
./bin/sandbox ssh <TAB>         # → live list of your running sandbox names
./bin/sandbox scp <TAB>         # → live names; then local file completion for <src>
./bin/sandbox down <TAB>        # → live names + --all + --stale
./bin/sandbox down --stale <TAB># → 30m | 1h | 4h | 12h | 24h | 48h | 7d
```

Name suggestions query the **active cloud** (`CLOUD` in `./config`) each Tab
press (~200-500ms latency) — EC2 when `CLOUD=aws`, GCE when `CLOUD=gcp` — so the
names offered for `ssh`/`scp`/`down` match the boxes those commands can reach.
(Bake VMs are filtered out on AWS.) Re-source `init.sh` after pulling updates
that touch `completion/sandbox.sh`.

## Commands

Run `./bin/sandbox --help` for the full list, or `./bin/sandbox <cmd> --help`
for details on any subcommand.

```bash
./bin/sandbox up                       # spin up a fresh box (into CLOUD) — non-blocking
./bin/sandbox up --cloud gcp           #   ...into gcp this launch (overrides config CLOUD)
./bin/sandbox up --repo URL            #   ...and clone a repo into it
./bin/sandbox up --no-spot             # avoid spot for this launch (overrides USE_SPOT)
./bin/sandbox up --spot                # force spot for this launch (overrides USE_SPOT)
./bin/sandbox up --instance-type t3.large
./bin/sandbox up --disk-size 128       # root disk in GB (default 64; both clouds)
./bin/sandbox up --name myproject      # custom name
./bin/sandbox up --ssh-cidr 1.2.3.4/32 # override the SSH ingress CIDR for this sandbox
./bin/sandbox up --ssh-cidr 0.0.0.0/0  # ...or leave SSH open to the world

./bin/sandbox list                     # what's running across BOTH clouds (PROVIDER column)
./bin/sandbox list --active            #   ...just the ready ones (terse output)
./bin/sandbox list --cloud gcp         #   ...only one cloud
./bin/sandbox ssh <name>               # SSH into a box
#   ...opens as a cmux ssh workspace instead if cmux is installed and running
#   (set SSH_USE_CMUX=false in ./config to always use plain ssh)

./bin/sandbox scp <name> <src> <dest>  # upload a file/dir to a box
./bin/sandbox scp <name> <src>         #   ...omit dest to pick it with the arrow keys
./bin/sandbox scp <name> -d <remote> <local>  # download a file FROM a box
./bin/sandbox scp <name> -d            #   ...omit remote to pick a file with the arrow keys,
                                        #      then you're prompted for the local dest (Enter = cwd)
./bin/sandbox scp <name> -d -o ~/dl    #   ...or set the local dest up front with -o/--output

./bin/sandbox spot status              # show the standing spot default (USE_SPOT)
./bin/sandbox spot off                 # make on-demand the standing default
./bin/sandbox spot on                  # make spot the standing default

./bin/sandbox down <name>              # terminate one (found in whichever cloud)
./bin/sandbox down --all               # terminate all — lists them, asks to confirm
./bin/sandbox down --all --yes         #   ...skip the confirmation prompt
./bin/sandbox down --stale 24h         # terminate boxes older than 24h (asks to confirm)
./bin/sandbox down --all --cloud aws   #   ...restrict a bulk terminate to one cloud

./bin/sandbox build-ami                # bake a fresh image for CLOUD (aws AMI / gcp image)
./bin/sandbox build-ami --cloud gcp    #   ...bake for a specific cloud
./bin/sandbox list-images              # baked images across BOTH clouds (PROVIDER column;
                                        #   CURRENT=yes for the ./config image `up` boots from)
./bin/sandbox list-images --active     #   ...only images in use
./bin/sandbox list-images --cloud gcp  #   ...only one cloud   (alias: list-amis)
./bin/sandbox delete-image <id|name>… # delete old images in whichever cloud they live in
                                        #   (AMI + snapshot on aws, image on gcp; alias: delete-ami)
./bin/sandbox delete-image <id> --force #   ...allow deleting the current image
```

### Working across both clouds

`CLOUD` in `./config` is just the **default launch target** for `up`. Everything
that acts on an *existing* box works across **both** clouds regardless of
`CLOUD`:

- `list` shows aws + gcp together, with a `PROVIDER` column.
- `ssh <name>` / `scp <name>` / `down <name>` find the box in whichever cloud it
  lives in — you don't switch `CLOUD` to reach an AWS box from a gcp default.
- `down --all` / `down --stale` span both clouds, print what they'll terminate,
  and ask for confirmation (`--yes` skips it).
- `list-images` / `delete-image` span both clouds too (AWS AMIs + GCP images).

Add `--cloud aws|gcp` to any of these (including `up`) to scope that one command
to a single cloud. If a name somehow exists in both clouds, the command asks you
to disambiguate with `--cloud`.

`build-ami` never deletes the previous image — each AWS bake adds an AMI + a
~30 GB EBS snapshot (~$1.50/month each); each GCP bake adds a custom image
(~$0.05/GB-month). Use `list-images` to see them and `delete-image` to clean
up; the current image (referenced in `./config`) is protected unless you pass
`--force`.

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
NAME                   STATE          TYPE               MARKET     AGE   IP
sandbox-26bdd2af       pending        m7i-flex.xlarge    spot       5s    -
# ...20s later...
sandbox-26bdd2af       initializing   m7i-flex.xlarge    spot       25s   54.218.x.x
# ...60s later...
sandbox-26bdd2af       ready          m7i-flex.xlarge    spot       85s   54.218.x.x

$ ./bin/sandbox ssh sandbox-26bdd2af
```

`./bin/sandbox ssh` against a non-`ready` instance now gives a useful error
("still booting", "stopped", etc.) instead of "no sandbox named X".

## Once you're SSHed in

Claude Code is not baked into the AMI (a pinned version goes stale fast and is
a pain to upgrade in place) — install the latest yourself:

    npm install -g @anthropic-ai/claude-code

Then run `claude` — it prints a URL. Open the URL in your laptop browser,
approve, and the browser will show a code. Paste that code back into the SSH
terminal. The OAuth token lives on this VM only, and dies when you `down` the box.

## Cost

Expected ~$10-15/month at a few 1-3h sessions/day on spot. The systemd
auto-shutdown timer is opt-in: set `AUTO_SHUTDOWN_HOURS` in `./config`
to a positive number and the box terminates after that many hours of
uptime even if you forget to `down` it. Default is `0` (disabled).

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
