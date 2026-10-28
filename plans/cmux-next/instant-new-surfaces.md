# Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D: baseline (instant-new-surfaces)

Ask (Lawrence, 2026-10-19): "cmd n and cmd t and cmd d and cmd shift d need to always be instant,
from first principles." Budget used here: the command's result is in the window's model at the
first display frame after the key (1 frame), every time, idle and under load; nothing on the key
path waits for the daemon.

## How it was measured

- In-app bench: `debug.new_tab {action: "bench_create", command}` (DEBUG builds,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugInstantCreateBench.swift`). The key
  goes through the real key path (`debug.key`). Reported per run: `key_ms` (the key's synchronous
  main-thread time, handler included), `visible_ms` (first display-link frame at which the window
  model shows the result: another workspace / another selected tab / a new focused pane),
  `frames_to_visible`, `confirmed_ms` (first frame at which the daemon's object replaced the
  stand-in), and `BenchSpans` marks.
- Driver: `scripts/cmux-next/instant-new-surfaces-bench.py` (10 runs per command; `idle`, then
  `load` = one `yes` per core plus 8 CLI loops against the tag's daemon).
- Where: an owned fleet Mac mini through `cmux-next frame pacing` (`suites=instant`), 60 Hz display.
  Baseline run: https://github.com/manaflow-ai/cmux/actions/runs/39244213530 (app built from
  11236365f49, which is feat-cmux-next d3c2b2514cc plus the bench only).
- Daemon side (headless cmux-tui, send to reply), this Mac (loaded, load average about 30), with
  the perf-lifecycle agent's `cmux-tui/scripts/bench-lifecycle.py` (15 rounds):
  `artifacts/daemon-lifecycle-loaded.json`.

## App: key to visible (ms; frames at 60 Hz)

| Command | Phase | key ms p50 / max | visible ms p50 / p95 | frames p50 / max | daemon confirm ms p50 / p95 |
| --- | --- | --- | --- | --- | --- |
| Cmd-D (split right, terminal) | idle | 0.7 / 7.1 | 18.9 / 36.0 | 2 / 3 | 81 / 107 |
| Cmd-Shift-D (split down, terminal) | idle | 1.3 / 1.4 | 27.6 / 35.2 | 2 / 3 | 90 / 113 |
| Cmd-T (New Tab page) | idle | 4.0 / 15.5 | 11.6 / 23.8 | 1 / 2 | 51 / 69 |
| Cmd-N (new workspace, New Tab page) | idle | 1.0 / 1.1 | 82.5 / 100.7 | 5 / 7 | 99 / 116 |
| Cmd-D (split right; the page split, see note) | load | 2.0 / 2.5 | 21.8 / 30.8 | 2 / 2 | 51 / 70 |
| Cmd-Shift-D (page split, see note) | load | 2.2 / 2.7 | 22.6 / 34.4 | 2 / 3 | 54 / 69 |
| Cmd-T | load | 6.6 / 7.8 | 22.9 / 34.1 | 2 / 3 | 59 / 74 |
| Cmd-N | load | 0.4 / 0.5 | 115.2 / 158.3 | 7 / 10 | 133 / 182 |

Note: in the baseline's load phase the focused pane was the New Tab page left by the Cmd-N
runs, so its splits took the page-split path (NewTabPage.split), not the terminal split. The bench
now restores a focused terminal before every split and Cmd-T run.

Main-thread spans (idle, p50 / max): Cmd-T `newTab.open` 3.4 / 11.0 ms; a split's
`terminal.surface` (Ghostty surface creation, on the next presentation frame) 3.3 / 4.2 ms.

## Daemon: send to reply (ms, this Mac loaded)

| Op | p50 | p95 |
| --- | --- | --- |
| new-tab (terminal) | 114 | 660 |
| split right / down | 112 / 107 | 203 / 216 |
| new-workspace | 126 | 661 |
| new-tab (browser) | 31 | 46 |

Earlier observations on the user's Mac: `cmux-tui` 100-190 ms per request when idle, and CLI
calls timing out at 2 s (a37, a51).

## Stages and causes

- Cmd-N (the slow one): `newWorkspace` -> Task -> `WorkspaceSpawner.create` -> `pin-workspace`
  (home daemon) -> `create-workspace` -> `new-conversation-tab` -> `FirstTabHold` waited for the
  store to list the tab -> window reconcile -> page shows. Marks (idle p50): pin returned 21 ms,
  create sent 22 ms, created 72 ms, page shown 75 ms. Three sequential daemon round trips on the
  key path; under load each one stretches (daemon p95 660 ms above).
- Cmd-D / Cmd-Shift-D: already optimistic (`split-client-keys-v1`), but two main-actor hops
  late: the provisional pane's intent was applied inside the handler's `Task`, and the window
  followed the store through an `ObservationStream`. Each hop lands after the key turn's Core
  Animation commit, so the pane showed at frame 2 (sometimes 3).
- Cmd-T: already optimistic (the New Tab page's provisional tab, prewarmed spare, synchronous
  selection); 1 frame idle, 2 under load, with 3-11 ms of main-thread work in the key's turn.
- PTY: the terminal's shell starts after the daemon's reply (spawn plus host start). The
  terminal view shows on its theme background before that and buffers keys
  (`CreationInputCoordinator`), so it does not gate "visible".

## After (instant-new-surfaces)

Run: https://github.com/manaflow-ai/cmux/actions/runs/39254573573 (app at 7c32d9a3744, same
mini class, same bench). "Frame" = which display frame after the key showed the result
(1 = the first frame drawn); "visible ms" = key to that frame.

| Command | Phase | visible ms p50 before -> after | frame p50 / max before -> after | key ms p50 before -> after |
| --- | --- | --- | --- | --- |
| Cmd-N | idle | 82.5 -> 42.3 | 4 / 6 -> 1 / 3 | 1.0 -> 14.0 |
| Cmd-N | load | 115.2 -> 43.3 | 5 / 6 -> 1 / 1 | 0.4 -> 6.9 |
| Cmd-T | idle | 11.6 -> 16.5 | 1 / 1 -> 1 / 1 | 4.0 -> 4.9 |
| Cmd-T | load | 22.9 -> 20.2 | 1 / 1 -> 1 / 1 | 6.6 -> 5.9 |
| Cmd-D | idle | 18.9 -> 25.2 | 1 / 1 -> 1 / 1 | 0.7 -> 9.1 |
| Cmd-D | load (terminal now) | 21.8 -> 23.3 | 1 / 3 -> 1 / 1 | 2.0 -> 6.8 |
| Cmd-Shift-D | idle | 27.6 -> 21.4 | 1 / 1 -> 1 / 1 | 1.3 -> 7.7 |
| Cmd-Shift-D | load (terminal now) | 22.6 -> 20.3 | 1 / 3 -> 1 / 1 | 2.2 -> 5.4 |

Reading it:
- Cmd-N no longer waits for the daemon: the workspace and its page are in the first frame
  (9 of 10 idle, 10 of 10 loaded), about 2x sooner idle and 2.7x loaded; the daemon confirms
  later (113 / 172 ms p50). Its cost moved onto the key's turn (window switch, page mount:
  `cmdN.start` 8-15 ms), so the first frame itself comes about 40 ms after the key. That is the
  next thing to cut.
- Cmd-D / Cmd-Shift-D now lay out and mount the new pane in the key's turn (`split.layout`
  6-8 ms) instead of after two main-actor hops; worst case under load went from frame 3 to
  frame 1. The terminal surface (`terminal.surface` 3-4 ms) is still created on the next
  presentation frame.
- Cmd-T was already optimistic; unchanged within noise.
- The earlier "frames_to_visible" column above (ms divided by the refresh period) counted a
  late first frame as several; the bench now reports the frame index.

## Changes by other lanes (for PL-cef-tab)

- 2026-10-27, workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md): `TabContentCache+Lifecycle.swift`
  gains `holdsMemory(_:)`, `hibernateTabs(_:)` and `evictHiddenTerminal(_:)`. They run only when an idle workspace
  hibernates (at most one pass a minute), never on the new-tab path; a hidden terminal is evicted through the new
  `SurfaceLedger.evictHidden`, a page through `BrowserHibernation.hibernateForWorkspace`.
