# Default-grid Ghostty instruction detector

> Unvalidated draft: no baseline or native measurement exists. The standalone
> build exceeded its 600s and 1800s bounds; the provisional CI route must not land.
> Integration must reuse an existing production compilation and demonstrate its cost.

Leo: “these feel extremely mockable to be de facto enough”.

`phone-default-speed-icount` measures the actual pinned `ghostty-next` terminal
core, through the production `ghostty-vt` Rust API, on Linux x86_64. Ten updates
feed ANSI/Unicode primary-screen output or cursor-addressed full-screen editor
updates into an unchanged 120×40 Mac grid. Both cases seed 100 and 10,000 terminal
lines before collection. Callgrind counts decoding, frame extraction and
protocol-v7 styled render-command generation, with fixture setup excluded.

The gate rejects instruction counts over baseline +10%, a long-history cost
over short-history +20%, missing instrumentation and malformed baselines.
`update` is explicit and refused in CI. Dependency versions, sources and checksums
must match identities in the production workspace lock; optional dependencies
enabled only by other workspace features are not required. The Zig CPU is pinned to `baseline`
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
The harness has a small standalone Cargo workspace; native Ghostty compilation
is required on a cold cache. The CI step retains Zig's local objects in its global
cache, matching the repository's existing setup-zig/cache pattern, so checkout
cleanup does not discard native compilation. Its 30-minute step timeout is a cold
ceiling, not a measured duration or a claim that a cold build is cheap. Measured run and setup cost will be recorded with
the first baseline before this detector is enabled as a PR gate.
