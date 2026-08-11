# Feature backlog

A living list of features and improvements under consideration. Not a roadmap —
no dates or commitments. When an item gets picked up it graduates to a design
spec under `docs/specs/` (or `docs/superpowers/specs/`) and a build plan under
`docs/superpowers/plans/`; leave a pointer here and mark it **In progress** /
**Shipped** rather than deleting it.

Status legend: **Idea** · **Accepted** · **In progress** · **Shipped** · **Won't do**

---

## 1. Stop / restart a sandbox without terminating it

**Status:** Idea

Add lifecycle verbs to pause a box and bring it back, distinct from `down`
(which terminates). Rough shape:

- `sandbox stop <name|id>` — halt the instance, keep the disk.
- `sandbox start <name|id>` — boot a previously stopped box.
- `sandbox restart <name|id>` — convenience `stop` + `start` (optional; could
  just be documented as running the two).

Both clouds support this natively:

- **AWS:** `aws ec2 stop-instances` / `start-instances`.
- **GCP:** `gcloud compute instances stop` / `start` — the `stop` half is
  already used internally by `build-ami` (see `lib/providers/gcp.sh`), so the
  driver seam is proven.

**Partly already built — the STATE column.** `sandbox list` already renders a
`STATE` column, and the drivers already surface the full lifecycle
(`pending → initializing → ready → impaired → running → stopping → stopped →
shutting-down → terminated`; see `compute_display_state` in
`lib/providers/aws.sh`). The AWS query already includes `stopped` instances, so
a stopped box shows up in `list` today without further work. The gap is the
`stop`/`start` **commands**, not the status display.

**Design considerations to resolve when this is picked up:**

- **Public IP changes on stop/start.** A stopped-then-started EC2 instance gets
  a *new* public IP (unless an Elastic IP is attached). `list` reads the live IP
  so it self-corrects, but any cached `~/.ssh/known_hosts` entry / user notes go
  stale. GCP ephemeral external IPs behave the same. Decide: accept the churn
  (document it) vs. optionally attach a static IP.
- **Self-destruct / auto-shutdown interaction.** AWS boxes rely on an *in-VM*
  timer (`shutdown -h`) for `auto-shutdown-hours`; that clock does **not** run
  while the instance is stopped, so a stopped box could outlive its intended
  expiry once restarted. GCP uses a control-plane `--max-run-duration` with a
  `DELETE` action — need to confirm how stop/start interacts with that (it may
  DELETE on the original schedule regardless of the stop). This is the main
  correctness question for the feature.
- **Cost note for the docs.** Stopped EC2 instances incur **no compute charge**
  but still bill for the attached EBS volume (and now we default to a 64 GB root
  disk). Worth stating so "stop" isn't mistaken for "free."
- **`ssh` / `scp` UX.** These currently resolve a *running* sandbox IP
  (`provider_resolve_ip` → `aws_resolve_running_sandbox_ip`). Against a stopped
  box they should fail with a clear "box is stopped, run `sandbox start` first"
  message rather than a confusing empty result.

---

## 2. Run a session on GCP Cloud Run (and its limitations)

**Status:** Idea — leaning **Won't do** for the interactive-sandbox use case;
see below. Worth capturing the analysis either way.

Today's GCP support (see `docs/superpowers/specs/2026-07-03-gcp-support-design.md`)
provisions **GCE VMs** — full Ubuntu machines you SSH into, same model as AWS
EC2. This item asks whether we could instead (or additionally) launch a session
on **Cloud Run**, GCP's serverless container platform.

**The core question raised: can I run Docker inside a Cloud Run instance?**

Short answer: **no — you cannot run the Docker daemon inside Cloud Run.** It is
*not* a docker-in-docker situation you can make work, for architectural reasons:

- Cloud Run runs your container in a **sandboxed** execution environment (gVisor
  syscall interception in gen1; a microVM-based sandbox in gen2). Neither grants
  **privileged mode**, access to `/dev`, or the kernel capabilities `dockerd`
  needs. There is no way to start the Docker daemon inside the container.
- The correct GCP pattern for "I need to build/run containers" is to **not** do
  it inside Cloud Run: use **Cloud Build** (or a GCE VM, i.e. what we already
  have) for image builds, and deploy the resulting image to Cloud Run.

**Beyond Docker, Cloud Run is a poor fit for this tool's whole model:**

- **No SSH.** Cloud Run services are request-driven (HTTP/gRPC), not machines
  you SSH into. Our entire UX (`sandbox ssh`, `scp`, an interactive Claude Code
  session in a shell) assumes a real box with sshd. Cloud Run has no ingress
  path for that.
- **Ephemeral / no persistent shell.** The filesystem is in-memory and
  per-instance; there's no durable box that "restarts" (which also makes it
  orthogonal to backlog item #1).
- **Request/instance lifecycle, not a long-lived box.** Even with the
  instance-based billing / min-instances options, the model is scale-to-load
  containers, not a pet VM for a coding session.

**Where Cloud Run *could* make sense (a different, narrower feature):** running
the sandbox's **non-interactive, containerized workloads** — a headless "run
this repo's build/test in a fresh container and give me the result" mode — where
no SSH, no Docker daemon, and no persistence are needed. That's a meaningfully
different product from today's SSH-a-box flow and should be its own spec if we
want it. GCP **Cloud Run Jobs** (run-to-completion, up to the job task timeout)
would be the right primitive there, not Cloud Run *services*.

> Note: Cloud Run capabilities and limits (execution environments, timeouts,
> gVisor vs. microVM sandboxing) evolve. Re-verify against current GCP docs
> before committing to any of the above — but the "no `dockerd` inside Cloud
> Run" constraint has been stable and is architectural, not a quota.

---

## 3. Make tab completion instant (serve cache, refresh in background)

**Status:** Partly shipped 2026-08-11 — the cheap fix, not the full SWR feature.

Measured a cold `_sandbox_list_names_fresh` (2026-08-11): **7.2s the first run,
then ~0.8s** — and the split is aws ~1.2s / gcp ~0.7s. So the 7.2s was a one-time
**credential/DNS warmup** (first `gcloud`/`aws` call of a session refreshes its
token; you'd pay it on any cloud command), *not* a per-Tab cost, and caching
can't remove it. Steady-state cold Tab is ~0.8s, already cached. That confirms
the skepticism below: full stale-while-revalidate isn't worth its complexity.

Shipped instead, for the "`up` → `ssh <newbox><Tab>`" flow:
- `sandbox up` primes the names cache with the just-launched box (reuses
  completion's own query + cache path, backgrounded, best-effort).
- `_SANDBOX_CACHE_TTL` 15s → **120s** so that primed entry is still fresh when the
  box reaches ready (~60-90s) and you tab to `ssh` it.

Follow-ups the longer TTL invites (both minor, left open): invalidate the names
cache on `down` so a terminated box doesn't linger up to 120s in completion; and
key `_sandbox_cached` on the config file's *contents* rather than its path (see
the last note below) so switching `CLOUD`/`GCP_PROJECT` doesn't serve stale
names for the window. Full SWR is still the ceiling if ~0.8s ever isn't enough.

Original analysis (still the reason not to build SWR):

> **The 2-3s figure below is wrong.** Measured on a dev machine: `gcloud
> version` — that is, full SDK and Python startup with no network at all —
> takes **0.59s**, not 2-3s. Whatever made Tab feel slow was not interpreter
> startup.
>
> The one latency source actually measured during item 5's investigation was
> environmental (broken IPv6 routing stalling every Google endpoint for ~76s per
> call), which no amount of caching would have hidden — it would have served
> stale names forever and never successfully refreshed.
>
> Anyone picking this up should first time a cold Tab on a *healthy* network. If
> the real number is a few hundred milliseconds, this item is not worth its
> complexity — stale-while-revalidate brings a cache-invalidation problem, a
> refresh lock, and detached-process handling into a directory that currently
> has **zero test coverage**.
>
> Note also that `_sandbox_cached` keys on the config file's *path*, not its
> contents (`completion/sandbox.sh:50`), so switching `CLOUD` or `GCP_PROJECT`
> keeps serving the old cloud's names until the TTL lapses. At 15s that is
> invisible; behind any longer serve-stale window it would not be.

A cold Tab currently blocks on two cloud round trips run in parallel
(`completion/sandbox.sh:71`): `gcloud compute instances list` and
`aws ec2 describe-instances` (~1s). Result is cached for 15s
(`_SANDBOX_CACHE_TTL`), so the cost recurs whenever the cache goes cold. Prior
work (`fd5650c`, `e2fea07`, `6d235d4`) shortened the wait but never removed it
from the critical path.

Rough shape: on Tab, print whatever is cached and return immediately, then kick
off a detached refresh for the next invocation — stale-while-revalidate. After
the first ever use, Tab never blocks.

Trade-off: a box created seconds ago may not appear until the following Tab.
Mild, given `up` takes ~60s+ before a box is usable. Priming the cache at the
end of `up` would close most of that gap.

Constraint: the refresh must not leave orphaned background jobs or write a
half-formed cache file — the existing atomic `mv` pattern in `_sandbox_cached`
already handles the latter and should be kept.

---

## 4. `GOOGLE_APPLICATION_CREDENTIALS` is documented but never read

**Status:** Shipped (docs corrected 2026-08-02)

The README's "Using GCP" setup now documents `gcloud auth login`, states plainly
that no service-account key is needed, and explains what the variable actually
does. `init.sh`'s message no longer claims it is "for gcloud". The misleading
`die` text in `lib/providers/gcp.sh:33` is **not** fixed — see below.

Original report:

`README.md:165-181` walks you through creating a service account and setting
`GOOGLE_APPLICATION_CREDENTIALS` in `.env`, and `init.sh:47-53` prints
`init: GOOGLE_APPLICATION_CREDENTIALS set for gcloud`. Nothing consumes it:
`lib/providers/gcp.sh:33` mentions it only inside an error-message string, and
`init.sh` exports it only *if already set*.

It also wouldn't work as documented — that variable drives Application Default
Credentials for client libraries, whereas the `gcloud` CLI authenticates from
its own credential store. The setup that actually works is `gcloud auth login`,
which the README never mentions.

Fix: document `gcloud auth login`, and either drop the variable entirely or
explain what it's genuinely for. Related: `.env.example` lists only the three
AWS variables, so a fresh GCP setup gets no template at all — that is now
correct rather than a gap, since GCP needs nothing in `.env`.

Still open, split out of this item:

## 5. `provider_check_creds` reports a guess instead of the real error

**Status:** Shipped (2026-08-06)

`provider_check_creds` now surfaces gcloud's own stderr, `provider_list_all`
prints it as a warning instead of discarding it, and each cloud is bounded by
`SANDBOX_CLOUD_TIMEOUT` (default 25s). A new `provider_configured` keeps a cloud
you never set up silent, so an AWS-only user sees no gcp noise.

**What made this urgent.** A debugging session hit exactly the hidden failure
this item predicted, and the consequence was worse than "a misleading message":
`./bin/sandbox list` sat for **85 seconds** and then printed `no sandboxes in
gcp`. gcloud had been printing `Reauthentication required.` the entire time —
discarded first by `>/dev/null 2>&1` in the probe, then again by
`( provider_check_creds ) >/dev/null 2>&1 || exit 0` in `provider_list_all`.
Finding the cause took roughly twenty turns; the error text would have taken
one.

The underlying fault was environmental (a network handing out a global IPv6
address it could not route, so gcloud stalled on a TCP connect timeout for every
dual-stack Google endpoint — AWS was unaffected because its classic endpoints
publish no AAAA record). Nothing in this repo could have prevented that. The
defect was refusing to say so.

Original report:

`lib/providers/gcp.sh:33` ran the preflight probe with `>/dev/null 2>&1` and,
on any failure, died with "set GOOGLE_APPLICATION_CREDENTIALS and GCP_PROJECT"
— advice that is wrong (nothing reads that variable) and usually irrelevant.
Observed causes it hid: an expired credential needing reauthentication (common
in Workspace orgs), the Compute Engine API not being enabled, and a wrong
project id. Each needs a different fix, and the message pointed at none of them.

---

## 6. `down` leaks the security group of a renamed sandbox

**Status:** Idea (bug)

`provider_cleanup_net` (`lib/providers/aws.sh`) derives the security group name
from the sandbox's *current* name — `<name>-sg`. But the SG's name is fixed when
`aws_create_per_sandbox_sg` creates it at launch, and EC2 security-group names
are immutable. Rename a box and the two diverge permanently.

Renaming is not hypothetical: every lookup in the CLI resolves through the EC2
`Name` tag (`lib/aws.sh`), so retagging an instance renames it as far as `list`,
`ssh`, `scp` and `down` are concerned. Doing that leaves cleanup hunting for an
SG that never existed. The miss returns `InvalidGroup.NotFound`, which
`provider_cleanup_net` deliberately swallows as "legacy sandbox sharing the old
shared SG" — so the real group is left behind with no warning at all.

Observed on a live account: both running sandboxes had mismatched SGs
(`mega-stuff` → `sandbox-80f5b81f-sg`, `dave-misc` → `sandbox-d30921b1-sg`), so
both were set to leak on teardown. The same account had accumulated 13 orphaned
groups from the earlier leak that `3a81f33` fixed. A leaked SG later blocks
`up --name <original-name>` with `InvalidGroup.Duplicate`, permanently.

Rough shape — stop deriving the name. Either:

- look the group up by its `SandboxName` tag, which `aws_create_per_sandbox_sg`
  already sets at creation; or
- read the instance's attached group IDs *before* terminating it, and delete
  those by ID.

The second is more robust (independent of both tags and naming) but must not
touch a shared or default group, so it needs to filter to groups tagged
`Project=claude-sandbox`.

Constraint: keep a silent path for genuinely-absent groups. The current
`NotFound` branch exists because pre-per-sandbox-SG boxes share an older group
and would otherwise warn on every `down`. Whatever replaces the name lookup has
to stay quiet for those while no longer hiding this case.

GCP: `<name>-fw` rules are derived the same way, but GCE instance names are
immutable, so a rename can't cause the drift there. Worth confirming no other
path can desynchronise them before treating this as AWS-only.

---

## 7. Query AWS and GCP concurrently in the command path

**Status:** Shipped (2026-08-07). Both `provider_list_all` (`list` / `ssh` /
`scp` / `down`) and `provider_images_all` (`list-images` / `delete-image`) now
launch every in-scope cloud's query + watchdog up front and reap in order, so a
dual-cloud command waits out the slower cloud, not the sum. `provider_images_all`
also gained the per-cloud `SANDBOX_CLOUD_TIMEOUT` bound it previously lacked.
Both are covered by bats timing tests.

The tab-completion path already queries both clouds **concurrently**
(`completion/sandbox.sh:70`, `sort -u <(...aws...) <(...gcp...)`), so a cold Tab
waits out only the slower cloud. The actual commands do **not** — they query the
clouds one after another.

`provider_list_all` (`lib/multicloud.sh`) — which backs **`list`, `ssh`, `scp`,
and `down`** — loops over the clouds, backgrounds each query, then immediately
`wait`s for it before starting the next. The `&` is there only so the stall
watchdog (item #5) can bound a hung cloud; it buys **no** cross-cloud
concurrency. So AWS fully completes before GCP even starts: a dual-cloud command
pays `aws + gcp`, not `max(aws, gcp)`. `provider_images_all` (backs
`list-images` / `delete-image`) is fully sequential too — plain subshells, and
it has no timeout at all.

Payoff (dual-cloud users only — `provider_configured` already short-circuits a
cloud you never set up, so single-cloud users are unaffected):

- **Healthy case:** `list` / `ssh` / `scp` / `down` drop from two back-to-back
  round trips (~2s) to one (~1s).
- **Degraded case — the bigger win:** two slow/stalled clouds cost up to
  `2 × SANDBOX_CLOUD_TIMEOUT` sequentially; in parallel the whole thing is
  bounded to a single timeout window. This is the failure mode item #5 hit (85s).

**Shape:** launch every in-scope cloud's query *and its watchdog* up front, then
reap in a stable cloud order. The watchdogs must start at launch, not at reap —
otherwise two stalled clouds still serialize to `2 × timeout`.

**Constraints — must preserve item #5's behavior:** per-cloud timeout bound, the
cloud's own error text surfaced, an unconfigured cloud stays silent, and a broken
cloud never suppresses the healthy cloud's rows. All of this runs under
`set -euo pipefail` inside a `$(...)` subshell, so every line has to stay
`set -e`-safe (guarded `kill`/`wait`).

**Scope:** done in two commits — `provider_list_all` (the hot path) first, then
`provider_images_all` (rare admin ops), which also picked up the
`SANDBOX_CLOUD_TIMEOUT` bound it previously lacked.

---

## 8. Speed up the drivers — collapse each cloud's serial CLI calls

**Status:** Shipped (2026-08-07). Both drivers' `provider_list` now fetch their
independent secondary CLI calls concurrently — AWS: instance-status / SG /
volumes (which each depend only on describe-instances); GCP: `instances list` /
`firewall-rules list`. Measured `provider_list` with a per-call-sleep stub: AWS
4.77s→2.47s, GCP 2.52s→1.34s, so a dual-cloud `list` should drop ~3.5s→~2s. A
bats timing test guards each driver.

Item #7 made the two clouds run concurrently, but each cloud's *own* driver still
fires several CLI calls **in series**, and CLI process cold-starts (`aws` /
`gcloud` are Python, ~0.5–1s each) plus their network round-trips dominate
`list`'s wall time. Measured by wall-clock: `--cloud aws` ~3s, `--cloud gcp`
~3s, both ~3.5s — so #7 *is* overlapping the clouds (3.5 ≈ `max`, not `6` =
`sum`), but each cloud is individually slow. Because the default `list` is gated
by the slower cloud, **both** drivers need this or the default won't improve.

AWS `provider_list` (`lib/providers/aws.sh`) — four serial calls:
1. `describe-instances` (base)
2. `describe-instance-status`
3. `describe-security-groups`
4. `describe-volumes`

Calls 2–4 depend only on call 1's output, not on each other → run them
concurrently. ~4 serial → 1 + max(3) ≈ 2 rounds.

GCP `provider_list` (`lib/providers/gcp.sh`) — two serial, independent calls
(`instances list`, `firewall-rules list`) → run concurrently. ~2 → 1 round.

The machine overlaps concurrent CLIs (proven by #7's 3.5s ≈ max), so this pays
off. Same launch-then-reap pattern.

**Constraint:** preserve graceful degradation (missing `ec2:DescribeVolumes` →
DISK `-`; a failed query → empty list), and don't depend on CLI call *order* —
concurrent calls make the order non-deterministic (the stub log is already
order-independent).

---

## 9. Manage `~/.ssh/config` entries for sandboxes

**Status:** Idea

Let `remote-sandbox` write / refresh / remove host entries in the user's SSH
config so a box is reachable by name from **native** tooling — `ssh <name>`,
`scp`, `rsync`, git-over-ssh, IDE Remote-SSH (VS Code / Cursor) — without going
through `sandbox ssh` each time.

**Primary use (decided 2026-08-08): plain `ssh` / `scp` / `rsync` by name** —
not IDE Remote-SSH. So no ControlMaster/keepalive tuning is needed and entries
needn't survive long-lived daemon sessions; they just need to be correct while
the box exists. Note the overlap: `sandbox ssh` / `sandbox scp` already cover the
interactive case, so the marginal value is letting *arbitrary* ssh-based tools
(plain `ssh`, `rsync`, `git`) address a box by name. Real, but a convenience
layer — lower priority than the active bug (#6).

**Feasibility: good.** The tool already resolves name→IP (`mc_resolve_ip`) and
has the `up` / `down` lifecycle hooks to attach to. The work is entirely local
file management.

**Recommended approach — a dedicated Include file, not inline edits.** Own a
single file (e.g. `~/.ssh/claude-sandbox.config`) and add ONE
`Include ~/.ssh/claude-sandbox.config` line to `~/.ssh/config`, once and
idempotently. We only ever rewrite the file we own → **no risk of clobbering
hand-edited config**. (OpenSSH ≥7.3 supports `Include`; macOS ships new enough.)
Fallback if Include is unwanted: a delimited managed block
(`# >>> claude-sandbox >>>` … `# <<< claude-sandbox <<<`) edited surgically.

**Lifecycle — a sync model, not write-once.** Boxes are ephemeral and IPs change
on stop/start (see #1), so entries go stale fast:

- `up` → add/update the box's entry.
- `down` → remove it.
- `sandbox ssh-config sync` (or fold into `list`) → reconcile the managed file
  from the current cross-cloud `list`: add missing, fix changed IPs, drop
  terminated. This is the robust primitive; the up/down hooks are conveniences.

**Entry contents:** `Host <name>` (consider a prefix to avoid colliding with the
user's own hosts), `HostName <ip>`, `User $SSH_USER`, `IdentityFile
$SSH_KEY_FILE`. Handle host-key churn from reused ephemeral IPs:
`StrictHostKeyChecking accept-new` + a dedicated `UserKnownHostsFile`
(e.g. `~/.ssh/claude-sandbox_known_hosts`) so it never warns on a reused IP or
pollutes the real `known_hosts`.

**Opt-in.** Gate behind a config flag (e.g. `MANAGE_SSH_CONFIG=true`), off by
default — it writes to a security-sensitive file, which matters given this
project's minimal-blast-radius posture.

**Testing.** Add an `SSH_CONFIG_FILE` override (defaults to `~/.ssh/config`) so
tests write to a temp file, mirroring the existing `AWS_CMD` / `GCLOUD_CMD` stub
seam.

**Open questions:** whether to also manage `known_hosts` (vs the
`accept-new` + dedicated-file approach above); interaction with #1 (a restarted
box needs its `HostName` refreshed).

---

## Adding to this list

Append a new numbered section with a **Status** line and enough context that
someone (or a future session) can pick it up cold: what it is, why, rough shape,
and any known constraints. Keep it terse — this is a backlog, not a spec.
