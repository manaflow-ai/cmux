# Web UI latency harness contract (v1)

Leo's scope is “TONS of perf stuff ... ultra fast ultra responsive ... EVERYTHING IN THE WEB UI”.
Extend `scripts/latency/run.ts` and these production component fixtures; do not create another runner.
Program completion requires an every-PR Linux Chromium gate and ten measured cases each below
50 ms p95 or linked to an open fixing PR. This core change supplies evidence, not that terminal receipt.

Run on CI or the managed fleet:

```sh
bun scripts/latency/run.ts --ci --engine chromium --runs 10 --json results.json --require longTasks,reactCommits,cpu
```

`--ci` writes JSON and a GitHub summary and fails on budget or evidence errors. Explicit `--no-fail`
suppresses only the legacy frame budget verdict, for an external budget validator or a report.
Missing browsers/cases, timeouts, page errors, empty/nonfinite samples and unsupported required
instrumentation still fail. Filters deliberately narrow the selected cases; the gate owns its required list.
The existing dispatch scoreboard fetches the integration branch tip and passes that verified SHA
as `--base`, so its shallow topic checkout does not need a merge-base history.

JSON `schemaVersion: 1` records `source` repository/head/base, browser versions, runner, viewport and
production/development mode; `expectedCases`, requested `runs`, throttle, `results` and `errors`.
Each result's stable ID is `engine/page/action.id` (falling back to the action name). Raw samples
retain work/paint durations, frame gaps, genuine Long Tasks durations, Event Timing duration/ID
when delivered, and the delta of fixture `window.__latencyReactCommits` from actual Profiler commits.
`latencyMs` gives interpolated p50/p95/max; `frame_time` (also `scroll_frame_time`) uses frame-window
gaps, and other cases use paint. The first gap begins at input; the last extends from its rAF
callback through the post-render task so later work in that rendering opportunity is retained.
`target_painted` and `drag_target_painted` mean the first task after the target's rendering opportunity;
they are lab proxies, not pixel verification or INP. Scroll frame duration is never INP.

`longTasks` contains only Long Tasks API entries; unsupported is null. Deprecated `longTaskRuns`
is a legacy estimate including >50 ms frame stalls, not an actual Long Tasks API count. `framesSummary` reports
count, estimated dropped frames relative to calibrated refresh, and maximum gap. `trace` contains
CDP thread-CPU script/style/layout counters over the input window plus control round trips; paint
duration is null, with a reason. It is not a full trace, so requiring `trace` currently fails closed.
Idle CPU uses CDP `ThreadTime` with [`threadTicks`](https://chromedevtools.github.io/devtools-protocol/tot/Performance/#method-enable) on the renderer main thread; it excludes other
threads/processes. Real OS wakeups are null with a reason: context switches are never wakeups.

Installation schedules no work. `arm` owns observers, listeners, rAF and post-render task handles;
completion and every error stop them before settle. Idle sampling disposes the probe first.
Host-command fixtures call `__latency.markInput(kind)` immediately before their in-page effect.
