# Default-grid Ghostty instruction detector

> Native study and target-artifact reuse across two managed Linux jobs passed.
> Production cache publication and physical-device calibration remain unverified.

Leo: “these feel extremely mockable to be de facto enough”.

`phone-default-speed-icount` measures the actual pinned `ghostty-next` terminal
core, through the production `ghostty-vt` Rust API, on Linux x86_64. Ten updates
feed ANSI/Unicode primary-screen output or cursor-addressed full-screen editor
updates into an unchanged 120×40 Mac grid. Both cases seed 100 and 10,000 terminal
lines before collection. Callgrind counts decoding, frame extraction and
protocol-v7 styled render-command generation, with fixture setup excluded.

The gate rejects instruction counts over baseline +10%, a long-history cost
over short-history +20%, missing instrumentation and malformed baselines.
`update` is explicit and refused in CI. The example uses the production Cargo workspace and lock directly; its optional
`phone-speed` feature enables Valgrind only for explicit detector builds. The Zig CPU is pinned to `baseline`
so different CI processors do not select different optimized instruction sets.

## What this proves

The default iPhone terminal receives Mac-grid bytes through
`TerminalSurfaceView.feed` → `ghostty_surface_process_output` in GhosttyNextKit.
This harness exercises the same pinned Ghostty terminal core without projection.
`RenderState::build_frame` and `RenderFrame::runs` additionally exercise the real
Rust frame/remote render-command pipeline. Those commands are a host-side
surrogate, **not** the phone's UIKit/Metal renderer or font shaping pipeline.

This detector catches added CPU work in the measured core paths and growth with
retained history. It does not measure iPhone frame latency, Swift layout, GPU
presentation, font rasterization, true radio behavior, memory bandwidth, cache
pressure or thermal throttling. Occasional device sanity checks remain useful.

## Calibration

Physical-device calibration is pending; no fixed ns/instruction factor is
invented. Record model, OS, compiler, exact Ghostty pin and cmux source, workload,
optimized-build CPU samples and a durable receipt for identical ten-update
fixtures on the supported floor device. Freeze each workload's median
CPU-ns/instruction factor only after that measurement. Its scope remains the
terminal core; it cannot convert Rust command generation into Metal render time.
Until then this is a relative instruction regression detector, not completed
hardware-speed flow coverage or an end-to-end phone performance claim.

## Reproduce

`python3 ci/run run --job linux --only phone-default-speed-icount`

Import its receipt using `scripts/bench/cmux-bench phone-default-speed --import LOG`.
The detector is `ghostty-vt`'s `phone_default_speed` example, built in the normal
dev/test profile (Ghostty itself remains ReleaseFast). PRs restore the existing
workspace target cache. Its producer seeds this exact detector after its final
daemon build, then preserves the native output and its `cmux-transport-rewrite`
build dependency when pruning. The v2 cache namespace distinguishes these
archives from older saves. A separate managed consumer reported
`Fresh ghostty-vt-sys` on its first build with unchanged native and build-dependency
hashes; see the portability receipt below. Cargo Git and registry sources must
be populated separately; the target archive does not provide them.
A second build must report `Fresh ghostty-vt-sys`;
a native rebuild on that warm invocation fails. Initial setup cost is recorded
separately and must be judged from the managed receipt.
The Rust wrapper's dev optimization is part of the instruction baseline.

The explicit developer study uses a fresh target, records wall/user/system CPU,
then runs a warm build, both repeated checks, excess-work and no-op mutations,
and an unchanged-original check. Mutations use a separate example and leave the
production source intact. Invoke `scripts/bench/phone-default-speed/study.py`
through `cmux-ci test`, with `/tmp/phone-default-speed-receipt` as the artifact.
It records a candidate baseline only in study mode, never in the gating path.

## Native study receipt

Fleet job `2978cff4b2873d8e3b2af071` ran source
[`e2e5d1978520074bd0d568ac1751ffd2a92590a0`](https://github.com/manaflow-ai/cmux/commit/e2e5d1978520074bd0d568ac1751ffd2a92590a0)
with Ghostty pin `5c01c7171dc2c00d486f231adda7fb5bf6e55c97`, Rust 1.95.0 and the
baseline Zig CPU setting. [study-receipt.json](study-receipt.json) preserves the
source identity, per-command costs and mutation results. [baseline.tsv](baseline.tsv)
and the importer fixture are copied from that job's actual artifacts.

| Command | Wall seconds | User CPU seconds | System CPU seconds | Total CPU seconds |
| --- | ---: | ---: | ---: | ---: |
| Cold build, fresh target | 150.387 | 368.923 | 18.433 | 387.356 |
| Warm build, same job and target | 0.264 | 0.165 | 0.051 | 0.216 |
| Instruction check | 1.216 | 1.143 | 0.046 | 1.189 |

CPU includes waited child processes; these command costs exclude source transfer,
tool setup and external cache daemons. The warm build reported `Fresh ghostty-vt-sys`.
Repeated checks and the restored original passed. Extra render work exceeded all
four budgets and exited 1; no-op primary and alternate updates failed final-frame
assertions and exited 101. These results establish the detector's native behavior;
target-artifact portability is covered by the separate receipt below.
Physical-device calibration remains pending.

Read the job with `cmux-ci status 2978cff4b2873d8e3b2af071`. To smoke-test the real
receipt importer without writing to the ledger:

```sh
scripts/bench/cmux-bench phone-default-speed \
  --import scripts/bench/tests/fixtures/phone-default-speed/check.log \
  --build e2e5d1978520074bd0d568ac1751ffd2a92590a0 --no-ledger --json
```

## Cross-job target reuse receipt

[portability-receipt.json](portability-receipt.json) records producer
`93aa307772bd630b08cbe116` and consumer `cdb7df4c2d52289bf3200a41` at
[`7498893c03c60b057c33bc59c1ae79be69ad374d`](https://github.com/manaflow-ai/cmux/commit/7498893c03c60b057c33bc59c1ae79be69ad374d).
They ran on separate managed Linux workers with identical paths, compiler and
environment. The producer used the production metadata-aware pruning command
and source-mtime manifest. Its 56,096,664-byte target archive restored all 65
native-output and seven retained build-dependency hashes unchanged.

| Command | Wall seconds | CPU seconds |
| --- | ---: | ---: |
| Producer cold build | 188.476 | 411.332 |
| Consumer source-only fetch | 3.722 | 2.414 |
| Consumer first offline build | 2.068 | 5.190 |

The consumer populated Cargo sources with `cargo fetch --locked --target
x86_64-unknown-linux-gnu` before restoring the target; this preparation did not
create a target or change Cargo.lock. Its first build used `--offline`, reported
`Fresh ghostty-vt-sys` and `Fresh cmux-transport-rewrite`, and preserved both hash
sets. The whole consumer worker took 22.389 seconds, excluding queue and input
transfer. This proves target reuse with the stated source-cache prerequisite;
it does not establish cold-registry behavior or production R2 cache publication.
Retrieve either job's artifact with `cmux-ci artifact JOB OUTPUT` to inspect the
full logs and hash manifests.
