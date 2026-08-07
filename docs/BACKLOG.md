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

**Status:** Idea — **premise disproved, needs re-measuring before anyone builds
it.** Downgraded from Accepted 2026-08-06.

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

## Adding to this list

Append a new numbered section with a **Status** line and enough context that
someone (or a future session) can pick it up cold: what it is, why, rough shape,
and any known constraints. Keep it terse — this is a backlog, not a spec.
