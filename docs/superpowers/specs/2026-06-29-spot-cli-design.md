# Spot as a first-class CLI concept — design

Date: 2026-06-29

## Problem

Sandboxes launch as spot instances by default (`USE_SPOT=true` in `config`),
with `InstanceInterruptionBehavior=terminate`. AWS can reclaim spot capacity at
any time — commonly during an idle overnight stretch — which terminates the
instance and (via `DeleteOnTermination=true`) deletes its EBS volume. The box
then disappears from AWS entirely. This surprised the user: a sandbox left
overnight was gone the next morning.

Today the CLI exposes spot only as a one-directional `--no-spot` flag on
`sandbox up`. There is no way to:

- force spot **on** from the CLI when the config default is off,
- flip the standing default without hand-editing `./config`,
- see whether an existing instance is spot or on-demand.

This makes the single most important durability/cost tradeoff in the tool
invisible and awkward to control.

## Goals

1. Make spot a symmetric, discoverable per-launch choice on `sandbox up`.
2. Provide an easy persistent toggle for the standing default.
3. Surface spot vs on-demand in `sandbox list`.
4. Keep docs, `--help`, and shell completion in sync.

Non-goals: changing the default market type, changing interruption behavior
(terminate vs stop/hibernate), or adding IAM permissions to confirm reclaims.

## Design

### 1. Per-launch flags `--spot` / `--no-spot` (`bin/sandbox-up`)

Add `--spot` to complement the existing `--no-spot`. A flag overrides the
config `USE_SPOT` default for that one launch only; config stays the standing
default.

Implement as a tri-state captured during argv parsing:

- neither flag → use config `USE_SPOT`
- `--spot` → force `true`
- `--no-spot` → force `false`
- both flags → exit non-zero with `conflicting --spot/--no-spot`

Precedence: **per-launch flag > config default**. The resolved value feeds the
existing `provision_launch` path unchanged (it already takes a `use_spot`
argument). The existing `NO_SPOT` variable is replaced by this tri-state so the
two flags share one code path.

`up --help` documents both flags and the precedence rule.

### 2. Persistent default toggle: `sandbox spot [on|off|status]`

New subcommand `bin/sandbox-spot`, dispatched like the others via
`bin/sandbox`:

- `sandbox spot` or `sandbox spot status` → print the current standing default,
  e.g. `spot: on (USE_SPOT=true)` / `spot: off (USE_SPOT=false)`.
- `sandbox spot on` → set `USE_SPOT="true"` in `./config`.
- `sandbox spot off` → set `USE_SPOT="false"` in `./config`.
- any other arg → usage error, exit 2.

Config writing: generalize the existing one-off `config_write_ami_id` in
`lib/config.sh` into a reusable helper:

```
config_write_key KEY VALUE
```

It rewrites the `KEY="..."` line in `./config` if present, or appends it if
missing (same rewrite-or-append behavior `config_write_ami_id` has today).
`config_write_ami_id` is rewired to call `config_write_key AMI_ID "$new_id"`,
removing the duplicated sed/append logic. This refactor is in scope because the
toggle needs the same machinery.

`sandbox spot status` reads the value via `config_load` (respecting the normal
flag > env > file > default precedence) so it reports the same value `up` would
actually use.

### 3. `list` shows market type (`bin/sandbox-list`)

Add a `MARKET` column with values `spot` / `on-demand`, placed immediately
after `TYPE`. The value derives from `.InstanceLifecycle` in the
describe-instances JSON that `list` already fetches (`aws_describe_instances_by_tag`
returns full objects, no `--query` projection): `"spot"` → `spot`, absent/any
other → `on-demand`.

Changes within `sandbox-list`:

- jq projection: emit the market value as an additional, **always-non-empty**
  field (`if .InstanceLifecycle=="spot" then "spot" else "on-demand" end`),
  appended at the **end** of the `@tsv` array to avoid disturbing the existing
  field ordering and the tab-splitting quirk documented in the file (empty
  status fields collapsing under `IFS=$'\t'`). Because the field is never
  empty, trailing placement is safe.
- `read` loop: capture the new trailing `market` variable.
- header + row `printf`: insert a `MARKET` column (width 10, fits `on-demand`)
  after `TYPE`.
- `list --help`: document the `MARKET` column in the legend.

### 4. Docs & completion

- `completion/sandbox.sh`:
  - add `--spot` to the `up` flag list.
  - add `spot` to the top-level subcommand list.
  - add a `spot` case completing `on off status --help`.
- `bin/sandbox` dispatcher `usage()`:
  - add `--spot` to the `up` line.
  - add a `spot [on|off|status]` command entry.
- `README.md`: document the per-launch flags, the toggle, and the `MARKET`
  column where spot/lifecycle is discussed.
- `config.example`: extend the `USE_SPOT` comment to mention `sandbox spot
  on|off` and the `--spot`/`--no-spot` flags.

## Testing

bats unit tests, matching existing harness style (stubbed `aws`,
`SANDBOX_REPO_ROOT` in a tmpdir):

- `test/unit/up.bats`:
  - `--spot` resolves to a spot launch when config `USE_SPOT=false`.
  - `--no-spot` resolves to on-demand when config `USE_SPOT=true`.
  - passing both `--spot` and `--no-spot` exits non-zero with the conflict
    message.
- `test/unit/spot.bats` (new):
  - `spot on` writes `USE_SPOT="true"`; `spot off` writes `USE_SPOT="false"`.
  - `spot status` prints the current value.
  - rewrites an existing line rather than appending a duplicate.
- `test/unit/list.bats`:
  - a row with `"InstanceLifecycle":"spot"` renders `spot`.
  - a row without it renders `on-demand`.
- `test/unit/dispatcher.bats`: `sandbox spot` routes to `bin/sandbox-spot`.
- `test/unit/config.bats`: `config_write_key` rewrites an existing key and
  appends a missing one.

## Decisions

- Column name `MARKET` (`spot`/`on-demand`) over a `SPOT` yes/no column —
  self-describing.
- Subcommand shape `sandbox spot on|off|status` — matches the verb-noun style
  of the rest of the CLI.
- Per-launch flag always wins over the config default.
