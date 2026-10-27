# Neighbor tabs stay awake

Status: shipped behind `browser.keepNeighborTabsAwake` (default 1).
Owner of the code: `BrowserHibernation` (Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation/).

## Problem

A hidden browser page goes to sleep in two steps (plans/cmux-next/tab-lifecycle.md):

1. **Freeze** (`browser.freezeHiddenTabs`, 30 s): a hidden Chromium page stops its
   timers, tasks and rendering. It thaws when it is shown again. The thaw is a CDP
   message that the show sends on the main thread. The page then has to run its
   paused work before it draws a new frame.
2. **Hibernate** (`browser.hibernation`, 60 min by default): the engine page closes.
   A show restores it from the saved history, which is a full reload.

Ctrl-Tab, Cmd-Shift-[ ], Cmd-1...9 and clicks usually go to a tab near the current
one. Those switches paid the thaw or the reload every time.

## Rule

Each pane's shown tab keeps `N` tabs on each side awake (`N` = the setting, 0-3,
default 1). Neighbors wrap as `PaneController.selectAdjacent` does, so the last
tab's next neighbor is the first tab.

- A neighbor never freezes or hibernates (exemption `neighbor` in `debug.surfaces`).
- A tab that becomes a neighbor wakes at once. A frozen page thaws. A hibernated
  page restores in the background, and the lifecycle keeps it hidden.
- A tab that stops being a neighbor starts its hidden clock again, so it freezes
  `freezeHiddenTabs` seconds later, not at once.
- Hover: when the pointer moves onto a hidden tab in a strip, a frozen page thaws
  at once. A hibernated page restores only after the pointer stays 150 ms, so a
  sweep across the strip reloads nothing. A hovered page stays awake 30 s.
- Memory pressure (warning or critical) and Energy Saver set `N` to 0, and the
  normal freeze and hibernate rules apply again. While the `energySaver` feature is
  off, macOS Low Power Mode does the same (`EnergyPolicy.pageSaver`), as it did before
  the saver existed.

## Inputs

- `PaneController.noteNeighbors()` reports the strip order and shown tab after
  every show, every strip change (reorder, close, new tab) and every presence change.
  A pane off screen (parked workspace, away layout) reports no shown tab.
  `teardown` removes the pane.
- `TabStripView.onHoverTab` reports hover changes.
- The app's Energy Saver policy (`mainWork.energy`, written by `EnergyPolicyDriver` from AppServices'
  `energyMonitor` and `energy.saver`; its `pageSaver`) and the memory pressure source.

`NeighborTabs` is the pure part: per-pane order and selection to the awake set.

## Surfaces

- Settings: Browser > Memory > Keep Neighbor Tabs Awake (stepper, 0-3).
- cmux.json: `"browser": { "keepNeighborTabsAwake": 1 }`.
- Cmd+Shift+P, CLI and MCP: `browser.keepNeighborTabsAwake.0` ... `.3`
  (`cmux settings keep-no-neighbor-tabs-awake`, `keep-1-neighbor-tab-awake`,
  `keep-2-neighbor-tabs-awake`, `keep-3-neighbor-tabs-awake`).
- `debug.surfaces` `hibernation`: `neighbor_radius`, `awake_neighbors`, `frozen`,
  `prewarmed_total`, `cold_shows_total` (a show that had to thaw the page).

## Cost

With `N` = 1, at most 2 extra hidden pages per visible pane stay unfrozen. A
hidden Chromium renderer that is not frozen wakes about 0.5-1.5 times a second
(a154, msg 2654). `scripts/cmux-next/bench_power.py --scenarios tabs20,neighbors`
measures the power cost and the neighbor-vs-far switch times, with
`keepNeighborTabsAwake` 0 (before) and 1 (after).

## Tests

- `NeighborTabsTests`: the neighbor set after a switch, a reorder, a close, at the
  last and first tab, with radius 2, for small panes and for two panes; the radius
  under pressure and Energy Saver; setting parsing.
- `NeighborTabsWakeTests` (live WebKit pages, freeze seam): neighbors thaw before
  the switch; a switch to a neighbor is warm (no thaw at show) and a far switch is
  cold; hover thaws; a reorder thaws the new neighbor; a hibernated neighbor
  restores in the background; pressure, Energy Saver and 0 keep no neighbor awake; the saver
  reaches the cmux pages' lifecycle.
