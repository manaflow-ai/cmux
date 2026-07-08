# Cloud VM environments (`cmux vm env`)

`cmux vm env` builds a project's development environment inside a Cloud VM from a declarative spec, snapshotting after every step. Each step is a cached layer: re-running a build restores the deepest still-valid snapshot (about a second on Freestyle) and only executes the steps after your edit. Once a spec is fully cached, `cmux vm env up` boots a ready environment in seconds.

Freestyle is the only supported provider for now.

## Spec

The spec lives at `.cmux/env.yaml` in your repo (override with `--spec <path>`). The CLI reads it from your local checkout, so cloning the repo inside the VM is just another step.

```yaml
version: 1
name: ghostty
env:
  ZIG_VERSION: 0.14.0
steps:
  - name: system packages
    run: sudo apt-get update && sudo apt-get install -y libgtk-4-dev libadwaita-1-dev blueprint-compiler
  - name: zig
    run: |
      curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz" -o /tmp/zig.tar.xz
      mkdir -p ~/.local/zig && tar -xJf /tmp/zig.tar.xz -C ~/.local/zig --strip-components 1
      echo 'export PATH="$HOME/.local/zig:$PATH"' >> ~/.zshrc.local
  - name: clone
    run: git clone https://github.com/ghostty-org/ghostty
  - name: warm build
    run: cd ghostty && ~/.local/zig/zig build
    timeoutMinutes: 45
verify:
  - run: ~/.local/zig/zig version
  - run: test -d ghostty/zig-out
```

Fields: `version` (required, must be `1`), `name`, `base` (`default` or a provider image/snapshot id), `env` (exported into every step), `steps` (each needs `run`; `name` and `timeoutMinutes` optional), `verify` (always runs, never cached). `run` accepts `|` block scalars. Steps run as user `cmux` under `bash -l` with `set -eo pipefail`, starting in `$HOME`; `sudo` is available. Only full-line `#` comments are supported — this is a strict YAML subset, and the parser errors precisely rather than guessing.

## Caching model

A layer's cache key is a hash chain over the provider, the resolved base image id, and every step up to and including it (`run` text plus the spec's `env` map). Editing step N invalidates layers N and later; renaming a step invalidates nothing; a base image rollout invalidates everything. Layers are stored per billing team and reference provider snapshots, which can contain secrets — they are never shared across teams.

## Commands

- `cmux vm env init [--goal "<text>"]` — scaffold `.cmux/env.yaml`.
- `cmux vm env build [--spec <path>] [--json] [--no-cache]` — run the spec. Restores the deepest cached layer, executes remaining steps (snapshot + register after each success), then runs `verify`. On failure the VM is left running for inspection and the report names the failing step. `--json` prints a single machine-readable report (see the `cmux-cloud-env` skill for the contract).
- `cmux vm env up [--detach]` — requires a fully cached spec; restores the final layer into a fresh VM and opens it as a cmux workspace.
- `cmux vm env layers [--all] [--json]` — list cached layers (defaults to the current spec).
- `cmux vm env logs <vm-id> [--step <n>]` — tail a step's log inside the VM.

Long steps do not stream over one request: the CLI stages a small runner in the VM, starts each step detached in its own session, and polls a status file every couple of seconds, so a 30-minute `zig build` works even though every network call stays short. If the CLI dies mid-build, already-registered layers make the re-run cheap.

## Agents

When a coding agent is asked to "set up X in a cloud VM", the intended loop is: draft `.cmux/env.yaml`, run `cmux vm env build --json`, read `failingStepIndex` and `logTail`, fix only that step, and re-run — cached layers before the failure do not re-execute. Commit the spec once verify passes. The repo skill `skills/cmux-cloud-env/SKILL.md` documents this contract for agents.
