# App activation (Cmd-Tab back to cmux) in a heavy session

User report, 2026-10-21 (msg 9674, 9682): Cmd-Tab to cmux got laggier than it was a while ago,
"consider if there's a ton of workspaces and browser tabs and acp chat tabs too".

## Bench

`scripts/cmux-next/activation-perf.py` (also the perf gate's `activation` scenario). A tagged
Debug app, launched without activation, builds 150 workspaces, 100 Chromium tabs and 100 chat tabs,
then 20 resign/become pairs through `debug.app_activation`: every activation observer of the app
runs as on a real Cmd-Tab, the window never takes the display. Two modes:

- `heavy_app_only`: the app's own notices (`didBecomeActive` and the panels). Older builds support
  only this mode, so it compares builds.
- `heavy`: also the main window's resign/become key and main notices, as Cmd-Tab posts them.

Per activation: `observers_ms` (main-thread time the notices took to deliver, timed by the app),
the round trip, the drain (the next main-actor round trip: work the observers queued), and
`indicator_resyncs` (status indicators re-checked; `debug.layout_counters`).

Fleet GUI host cmux-lawrence-2, `nx-remote --needs gui --app-from-fleet cmux`, `--sample` for the
main thread's call graph.

## Results (ms, p50 / p95)

| build | mode | notices | round trip + drain | indicators re-checked |
|---|---|---|---|---|
| Oct 17 (6f97bdbf2a4) | app only | (no timing) | 9.2 / 15.4 | (no counter) |
| Oct 19 (6b80a07d47f) | app only | (no timing) | 8.6 / 14.6 | (no counter) |
| head 694c2a24da3 + bench | with key/main | 28.2 / 57.1 | 56.8 / 116.5 | 368 |
| fix (indicators) | with key/main | 23.2 / 29.6 | 30.3 / 35.6 | 0-32 |
| fix (indicators + hover) | app only | 0.5 / 1.4 | 5.7 / 6.6 | 0-32 |
| fix (indicators + hover) | with key/main | 21.0 / 24.0 | 30.3 / 38.4 | 0 |

The Oct 20 nightly and the parent of #22802 do not build on the fleet (base was red at that time:
a stale optchat inspector page, a Sidebar compile error), so the bisect is by attribution: the
sample of head shows `StatusIndicatorAppearance.resync` under the activation post, and the counter
shows 368 indicators per activation (22 in a 1-workspace session).

## Causes

1. **#22802 (Leo, 2026-10-20, 51f452a7b84), "stopped sidebar and tab spinners start again on their
   own".** `StatusIndicatorAppearance` re-checks every registered indicator on `didBecomeActive`,
   `didUnhide`, every window's `didBecomeMain` and wake. Every sidebar row, pane header and every
   tab that was ever busy registers, parked workspaces' strips and hidden groups too. Each re-check
   reads occlusion, rebuilds the plan, sets tooltip and accessibility label and marks the view for
   layout and display (then rebuilds its glyph layers in the next commit). O(session), twice per
   Cmd-Tab. Fixed: a `StatusIndicatorView` out of a window or under a hidden ancestor, and a
   `TabCell` whose strip is not shown, owe the resync and run it once when they show again.
2. **PointerHover key-window change (older: cx-8w027.10, Oct 8 / Oct 18; viewWindow's
   deallocation check Oct 20).** Each key change re-files every hover target and refreshes all
   targets filed under the window, parked workspaces included: O(targets in the window), about
   20 ms in this session. Trimmed (one integer sort key instead of a tuple compare through the
   runtime's tuple metadata; the weak-reference selector looked up once). Still O(all): see
   Follow-up.

## Budgets

perf-gate.py `activation`: at most 64 indicators re-checked per activation in the heavy session
(blocks; host-independent). The notices' main-thread time over 8 ms p95 is a warning (today it
warns at ~24 ms because of the hover refresh).

## Follow-up

- PointerHover: a key change should touch only the targets that hover now and the ones under the
  pointer (hit-test chain), not every target filed under the window; parked workspaces' targets
  should be filed apart. Then tighten the warning into a budget.
- Real Cmd-Tab (window server activation, first frame) needs `--needs input` on a GUI host; the
  synthetic path covers the app's own work only.
