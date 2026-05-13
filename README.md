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
