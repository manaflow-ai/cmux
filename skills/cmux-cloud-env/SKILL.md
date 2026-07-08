---
name: cmux-cloud-env
description: "Set up a project's development environment in a cmux Cloud VM with `cmux vm env`. Use when asked to make a repo buildable/runnable in a cloud VM or sandbox, to write or fix .cmux/env.yaml, or when a cloud build fails with missing toolchains (e.g. 'zig doesn't exist')."
---

# Cloud VM environment setup

Goal: a committed `.cmux/env.yaml` whose `cmux vm env build` passes verify. After that, anyone (and any agent) gets a ready environment from `cmux vm env up` in seconds, because every step is a cached VM snapshot layer.

## The loop

1. If no `.cmux/env.yaml` exists, scaffold with `cmux vm env init --goal "<what should work>"`, then replace the template steps with your best guess. Put slow-changing things first (apt packages, toolchains), the repo clone after them, and a warm build last — earlier layers survive later edits.
2. Run `cmux vm env build --json`. The command exits non-zero on failure and prints one JSON report on stdout.
3. On failure, read `failingStepIndex`, `steps[i].exitCode`, and `steps[i].logTail`. The VM stays running: probe it directly with `cmux vm exec <vmId> -- <cmd>` (e.g. `command -v zig`, `apt-cache search`) and `cmux vm env logs <vmId> --step <i>` for the full log.
4. Edit ONLY the failing step or later ones. Steps before it are cached; editing an earlier step invalidates its layer and everything after it, which costs a rebuild of those layers. Renaming steps is free.
5. Re-run `cmux vm env build --json`. Repeat until `ok: true` (verify passed).
6. Commit `.cmux/env.yaml`. Destroy leftover debug VMs with `cmux vm rm <vmId>` unless the user wants them.

## Report contract (`--json`)

Single JSON object on stdout: `ok`, `specPath`, `specDigest`, `provider`, `baseImageId`, `vmId`, `cache{deepestCachedStepIndex, restoredSnapshotId, restoreMs}`, `steps[{index, name, status: cached|ok|failed|timeout|lost|skipped|pending, exitCode, durationMs, snapshotId, chainHash, logTail}]`, `verify[{index, status, exitCode, durationMs, logTail}]`, `failingStepIndex` (step indices continue into verify: `steps.count + verifyIndex`), `error`, `finalLayerRegistered` (false means `cmux vm env up` will refuse even when `ok` is true), `hint`.

## Spec rules

- Strict YAML subset: top-level `version: 1`, `name`, `base`, `env`, `steps`, `verify`. Steps: `name`, `run` (plain or `|` block), `timeoutMinutes`. Full-line `#` comments only. The parser errors precisely; trust its line numbers.
- Steps run as user `cmux` (`sudo` available), `bash -l`, `set -eo pipefail`, cwd `$HOME`. Persist PATH changes for later steps and interactive shells via `~/.zshrc.local` AND use explicit paths within the same build (each step is a fresh login shell, so `export PATH=...` does not carry across steps).
- `verify` runs every build and is never cached — put the real proof there (`zig build test`, `test -d repo/zig-out`), not an `echo`.
- Default step timeout is 30 minutes; set `timeoutMinutes` on long warm builds.
- The base image already has: git, gh, build-essential, python3, node, bun, mise, zsh, tmux, and the agent CLIs. Don't reinstall those.
- Only the Freestyle provider supports env layers today.

## Pitfalls

- `apt-get install` needs `sudo` and benefits from a preceding `sudo apt-get update` in the SAME step (separate steps can cache-split: the update layer goes stale while install re-runs).
- The VM is linux/amd64 (x86_64) — pick x86_64 toolchain tarballs.
- Interactive prompts hang forever; every command must be non-interactive (`-y`, `DEBIAN_FRONTEND=noninteractive` is preset).
- If `cmux vm env build` fails before step 0 (create/restore/staging), that's infrastructure, not your spec — check `cmux vm ls` and retry once before changing anything.
