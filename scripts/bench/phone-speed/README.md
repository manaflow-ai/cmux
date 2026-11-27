# Phone terminal deterministic speed detector

Leo: “these feel extremely mockable to be de facto enough”. The detector
`phone-speed-icount` measures real `cmux-terminal-projection` code under
Callgrind on Linux x86_64, without an app, simulator or phone. The PR pipeline
runs it when the projection, harness or pinned compiler changes. This scoped
instruction budget is deliberately blocking under that request.

Each case performs ten production operations: key echo, ANSI streamed output,
and alternating portrait/landscape viewports, with 100 and 10,000 history rows.
The detector fails above the checked-in instruction baseline plus 10%, or if
long scrollback costs over 20% more than short scrollback. Missing instrumentation,
zero counts and missing/duplicate baseline cases fail closed. Baseline generation
is explicit (`update`) and refused in CI; it must never be part of a PR check.

Run the same gate with `python3 ci/run run --job linux --only phone-speed-icount`.
`scripts/bench/cmux-bench phone-speed --import LOG` records the six counts in the
shared benchmark schema. The harness has an independent tiny Cargo workspace:
its only production dependency is the real projection crate, so it does not
build the app, Ghostty or the daemon. Its lockfile is committed.

## Calibration status and limits

**Physical-device calibration is pending.** There is no fixed conversion from
these x86_64 instruction counts to iPhone milliseconds yet. Existing iOS audit
TTI receipts found in the handbook were simulator measurements, not physical
hardware. The capability index points to Instruments, but contains no usable
matching workload/device measurement. This detector must not be counted as a
completed hardware-speed replacement or used to promise a frame-rate budget.

To calibrate once, run the identical ten-operation fixtures against the same
production commit in an optimized physical-iPhone build, outside Instruments
sampling overhead. Record hardware model, OS, compiler/profile, commit, date,
workload, sample count and a durable receipt URL. Record median CPU nanoseconds
and Callgrind instructions per case; freeze each workload's ns/instruction
factor together with that provenance. Use it only for that workload and model,
never to turn runner wall time into phone time. Revisit it when the workload,
compiler, device floor or architecture changes. Real-device access belongs to
the coordinator; it is not required for each PR.

This component check catches extra CPU work and growth with terminal history.
It does not cover Swift view layout, the default unprojected Ghostty renderer,
GPU presentation, memory bandwidth/cache behavior, hardware throttling, radios
or total app responsiveness. Keep occasional real-device thermal/presentation
sanity checks. Other simulator flow tests cover correctness at those boundaries.

## Initial instruction baseline (2026-11-27)

Production source: `ce9313d70c8eaf4c4756e550754f05e1676bb6be`,
Rust 1.95.0 release profile, Linux x86_64 Ubuntu 24.04, Callgrind 3.22.0.
The exact six counts and shell `time` receipt are checked into
`../tests/fixtures/phone-speed/check.log`. Fixture setup runs with instrumentation
disabled; collection is bounded by `phone_icount_measured`. The baseline run
cost 35.799 seconds wall, 21.246 user CPU + 2.701 system CPU (23.947 CPU seconds)
on the shared Linux lane. These are CI cost measurements, not phone speed.
The initial cold standalone build before instrumentation support took 38.31
seconds; adding the header binding's build dependencies took 144 seconds on
this loaded lane. A warm run does not repeat that compilation. The step's
300-second bound includes compilation and six independent Callgrind processes.
