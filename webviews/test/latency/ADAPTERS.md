# Autonomous action samplers

An action may supply `measureRun(page, context)` instead of `prepare`/`input` when its
measurement owns several inputs and targets. Return an `AdapterRun`: complete, timeout or
unsupported, with raw observations, nullable latencies, causal input/postpaint timestamps,
separate frame gaps and explicit instrumentation support. Register owned cleanup through
`context.onCleanup` before awaiting work; obey `context.signal` and the deadline.

Reports retain these runs in `adapterRuns`; `samples` stays empty for these cases. They are
never fabricated predicate-probe samples. Superseded observations retain null latency and do
not enter distributions. A complete run needs a genuinely painted target with valid causal
timestamps. Timeouts, unsupported runs, failed cleanup and missing required instrumentation
fail the evidence gate. An expired sampler's page closes before reuse; later actions get a
fresh page. Missing idle measurements on a closed page stay unsupported.

`drag_target_painted` uses move-to-target postpaint observations. `frame_time` uses recorded
frame gaps, separately. Release-to-paint, last-move-to-paint and already-painted-before-release
remain named raw fields. A release-tail confirmation cannot establish whole-drag latency.
These metrics are not EventTiming INP; estimated rAF drops are not compositor dropped frames.

The core wrapper independently observes Long Tasks and snapshots the profiling fixture's
commit counter around `measureRun`. It drains queued entries before disconnecting. These
measured values can supply instrumentation absent from a standalone adapter; missing APIs,
counters or finalization stay null with explicit reasons. No adapter zero is trusted as a substitute.

Both rail cases invoke the owner's repaired `308f5d9` pointer sampler on the resident
3,000-turn fixture. They retain its raw targets, painted/superseded/deadline statuses and
separate release receipt. The drag case aggregates move-to-paint latency; the cadence case
aggregates recorded frame gaps. Missing targets, deadlines and missing required instrumentation
still fail. The wrapper adds actual Long Tasks and Profiler counter deltas around the sampler.
The other fourteen flow cases remain independently selectable.
