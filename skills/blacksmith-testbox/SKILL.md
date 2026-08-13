---
name: blacksmith-testbox
description: >
  Provision and reuse a beefy Blacksmith Testbox for cmux-tui Rust builds,
  capture remote timings, download raw evidence, and clean up safely. Never
  run cargo, rustc, or Zig builds on the local Mac.
---

# cmux-tui Blacksmith Testbox

This lane is Linux-only. It uses
`.github/workflows/ci-workflow-guard-tests-testbox.yml`, job
`cmux-tui-rust`, on `blacksmith-32vcpu-ubuntu-2404`. The workflow is a
setup-only entrypoint for a reusable Testbox. It checks out the exact dispatch
SHA, initializes the `ghostty` source submodule, installs Linux C/LLVM headers,
installs the repository-pinned Zig and Rust toolchains, fetches Zig and Cargo
dependencies, and then hands control back to Testbox. It does not run Rust tests
or Rust compilation during warmup. `zig build --fetch` only hydrates Zig
packages and exits before compilation.

The repository's single Rust toolchain source is
`cmux-tui/rust-toolchain.toml`. The workflow invokes
`./.github/actions/setup-cmux-tui-rust`, so a workflow-specific Rust version
must never be added.

## Hard safety boundary

* Never run `cargo`, `rustc`, `rustup`, `zig build`, or another Rust/Zig build
  command on Lawrence's Mac. This includes local fallback builds and local
  test commands.
* Run every Blacksmith CLI command from the root of the intended isolated
  worktree. The CLI synchronizes that directory and can delete remote files
  that are not represented locally.
* Put remote build commands inside `blacksmith testbox run`. The benchmark
  helper also requires `CMUX_TESTBOX_REMOTE=1`, so an accidental local launch
  exits before invoking a compiler.
* Use this Testbox only for Linux-compatible cmux-tui work. Use the hosted
  macOS workflows for Swift, Xcode, XCTest, GUI, and app-host verification.

## Authentication and root guard

Check authentication without printing credentials:

```bash
blacksmith auth whoami
```

If the CLI is missing, install it once with:

```bash
curl -fsSL https://get.blacksmith.sh | sh
```

If authentication or dispatch is blocked, use the Blacksmith Console at
https://app.blacksmith.sh. The exact retry command, after the workflow is
available on the selected ref, is:

```bash
cd "$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse HEAD)"
blacksmith testbox warmup .github/workflows/ci-workflow-guard-tests-testbox.yml \
  --ref "$SHA" --job cmux-tui-rust --idle-timeout 30
```

A workflow that exists only on a feature branch can be rejected by GitHub's
workflow-dispatch API. If Blacksmith reports `workflow not found` or a 404,
do not change the ref or fall back to a local build. Open the Console, make the
workflow available on the repository's dispatchable default-branch revision,
and rerun the exact command above with the full SHA recorded in the evidence.

Use this guard before any warmup or run:

```bash
cd "$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse HEAD)"
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "HEAD is not a full commit SHA" >&2; exit 1 ;;
esac
```

The branch must be pushed before warmup. Record `git status --short --branch`
and the full SHA in the scratch evidence before dispatching.

## Warmup, run, and stop

Warm the exact branch head with the stable workflow/job pair:

```bash
cd "$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse HEAD)"
blacksmith testbox warmup .github/workflows/ci-workflow-guard-tests-testbox.yml \
  --ref "$SHA" \
  --job cmux-tui-rust \
  --idle-timeout 30
```

Save the returned `tbx_...` ID. One ID belongs to one worktree or agent. Wait
for setup if needed:

```bash
blacksmith testbox status --id <TBX_ID> --wait --wait-timeout 15m
```

Run harmless remote identity and dependency checks from the repository root:

```bash
blacksmith testbox run --id <TBX_ID> --debug \
  'set -euo pipefail; printf "sha="; git rev-parse HEAD; printf "runner="; uname -a; printf "cpus="; nproc; rustup show active-toolchain; rustc --version; cargo --version; "${CMUX_ZIG:-zig}" version'
```

Run a build only through the remote-only timing helper:

```bash
blacksmith testbox run --id <TBX_ID> --debug \
  'CMUX_TESTBOX_REMOTE=1 ./scripts/blacksmith-cmux-tui-testbox-stage.sh first-clean'
blacksmith testbox run --id <TBX_ID> --debug \
  'CMUX_TESTBOX_REMOTE=1 ./scripts/blacksmith-cmux-tui-testbox-stage.sh incremental-noop'
blacksmith testbox run --id <TBX_ID> --debug \
  'CMUX_TESTBOX_REMOTE=1 ./scripts/blacksmith-cmux-tui-testbox-stage.sh changed-file'
```

The complete capture procedure, including warmup wall time, run transcripts,
and aggregation, is in `skills/blacksmith-testbox/benchmark.md`.

Download raw remote timing files before stopping:

```bash
mkdir -p .cmux-scratch/testbox-benchmark-raw
blacksmith testbox download --id <TBX_ID> testbox-benchmark/ \
  .cmux-scratch/testbox-benchmark-raw/
```

Stop disposable capacity and prove cleanup:

```bash
blacksmith testbox stop --id <TBX_ID>
blacksmith testbox list --all
```

`list --all` must report no active Testbox. Keep the warmup log, setup/job/run
IDs, status output, downloaded `*.json`/`*.time`/`*.log` files, stop output, and
final list output in a separate `.cmux-scratch/` evidence artifact. Never add
credentials or private keys to that artifact.

## Timing interpretation

The benchmark reports two clocks. The local CLI transcript measures sync,
transport, queueing, and the remote command. The downloaded `/usr/bin/time -p`
record measures the remote `cargo build -p cmux-tui --locked` command. Compare
remote `real` or `time_real_seconds` values for build performance, and retain
CLI wall time when evaluating Testbox overhead.

`first-clean` is target-clean but dependency-warm: warmup runs `cargo fetch` and
`zig build --fetch`, and the workflow may restore registry, git, and Zig caches.
`incremental-noop` measures a second build on the same VM. `changed-file` adds a
comment to `cmux-tui/crates/cmux-tui/src/main.rs`, builds, and restores the
original file. The helper serializes stages with a remote lock. These are
deliberately different from a cold-VM benchmark.

Do not invent a local baseline. The cmux-tui instructions prohibit local Rust
builds, so local evidence is explicitly unavailable. Prior hosted correctness
runs without Cargo durations are provenance only. Prior Blacksmith macOS
Swift/Xcode timing artifacts use a different OS, architecture, runner, cache,
and workload, so they are context rather than a comparable Rust baseline.
