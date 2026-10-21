# Tab switch rewrite: design (a168, u2873)

Goal: a tab switch costs O(1) main-thread work at any tab count, finishes inside one
frame (16.7 ms at 60 Hz, 8.3 ms at 120 Hz), keeps hidden tabs near zero CPU, and
keeps memory bounded. Correctness (focus, first responder, selection, scroll, IME,
accessibility) is proven by tests. Numbers are in [BASELINE.md](BASELINE.md).

## 1. What a switch must do (first principles)

A switch changes three facts and nothing else:

1. Which tab view is shown in the pane (one `isHidden` flip off, one on).
2. Which view is first responder (one `makeFirstResponder`).
3. Which strip cell looks selected (two cells restyle, two separator lines change,
   and a scroll only if the new cell is out of view).

Everything else is a cost that must not be on the switch path:

- No view moves between superviews or windows (a WKWebView re-attach costs
  170-215 ms; a terminal re-attach costs a daemon replay).
- No relayout of the strip or of the pane tree (no `structure()` map, no
  snapshot).
- No sync disk write and no sync IPC (the window record save is async and
  coalesced; the daemon focus intent is fire-and-forget).
- No walk over every tab (a walk costs about 1 us per tab per pass; at 60 tabs
  two passes are 100 us, which is the whole budget of the in-process path).

## 2. The path after this work

`PaneController.select` -> focus intent `.selectTab` -> `FocusEffectApplier` ->
`applySelection` -> `ContentPresentationScheduler.showNow` -> `showSelected`:

| Stage | Work | Order |
|---|---|---|
| withdraw / present | content cache hands the old view back, the new one out | O(1) |
| content | dictionary lookup of the tab's view | O(1) |
| strip | `syncSelection`: restyle 2 cells, separator lines around old and new (`TabSeparatorVisibility.apply(to:around:)`), occlusion only while a strip move is in flight (`movesInFlight`), reveal via `TabSlotIndex` | O(1) at rest; reveal O(N) only when the strip overflows and the cell is out of view |
| view | `PaneContentView.show`: unhide 1, hide 1 (parking keeps hidden views in `contentHost`) | O(1) |
| focus | `.contentPresented` -> first responder | O(1) |
| invariant | debug check: exactly one shown view | O(1) |

The work gate (`TabSwitchWorkBudgetTests`) counts row passes (occlusion,
separators, frames) per switch at 2, 10 and 30 tabs and fails when a switch at rest
runs any. This is the CI regression test. It counts work, not time, because
shared fleet hosts differ by 70x on the same timing bench (0.4 ms on one host, 29 ms
on another). Timing benches (`TabSwitchPathBench`, `TabStripSelectionBench`,
`TabSwitchCycleBench`) print numbers and check behavior: 0 view moves, 0 strip
snapshots, exactly 1 shown view.

## 3. Out-of-process content (the frame the user sees)

The main-thread path ends at the Core Animation commit. The user sees the new tab
when its content draws:

- Terminal: the renderer is paused by ghostty occlusion while hidden and resumes on
  unhide; the last frame stays in its IOSurface, so the first commit already shows
  it.
- Chromium (CEF): one host view per pane, `tabActivate` swaps the browser; the
  compositor frame comes from the GPU process. `PanePaintHold` holds the old
  picture until the first paint, so there is no blank frame.
- WebKit pages (Markdown, file viewer, chat/New Tab): parked hidden; on unhide the
  web content process gets `visibilitychange` and draws.

`tab-switch-matrix.py` now reports `content_frame_ms` per Chromium and WebKit
switch: the page's own first `requestAnimationFrame` after it becomes visible,
measured from the input send. This is the number to drive under one frame next.

## 4. Hidden tabs: CPU and memory policy (kept, not rewritten)

The policy already exists and is correct in shape; this work keeps it:

- Terminals: hidden surfaces sit in one LRU (`WarmSetBudget`): 1/64 of physical
  memory at about 48 MB each, 8 to 24 surfaces, 6 under a pressure warning, 0 when
  critical. An evicted surface re-attaches with a daemon replay.
- Chromium pages freeze after 30 s hidden (`browser.freezeHiddenTabs`) and
  hibernate after 60 min (`browser.hibernation`, `moderate`), earlier under memory
  pressure.
- Parked views: no count cap (a118 removed the cap of 8 in ffe13a1eae3); the
  pane's live tabs bound the set, and each owner frees its own memory.

## 5. Next steps (not done in this work)

1. Content-frame readiness: from the real-window matrix, drive Chromium and
   WebKit `content_frame_ms` under one frame (for WebKit: keep the page
   "visible but occluded" so it does not throttle and redraw from cold; for CEF:
   send `WasHidden(false)` before the swap).
2. Strip scroll in content coordinates: when the strip overflows, reveal today
   runs `applyFrames` over all cells (about 50-100 us at 60 tabs). Scrolling one
   layer makes it O(1). It touches hit testing, drag, groups, the phantom cell and
   the edge fade (9 files), so it is deferred.
3. Terminal warm set past 24 tabs: the 25th hidden terminal pays a replay. A
   cheaper hidden state (drop the IOSurfaces, keep the grid) would make the
   budget larger at the same memory.
