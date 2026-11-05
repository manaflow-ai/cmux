# Hover preload: wake the pages a hover will show (cmux-ad m34)

Ask (Lawrence 2026-11-05): "the moment i mouseover a workspace or tab, we should preload the websites that
is very likely to become visible, if they were hibernated we should wake them up. think of edge case like
user rapidly moving mouse over entire sidebar; we don't want to cause any main thread lag at all."

## Before

| Pointer on | What happened |
| --- | --- |
| A tab in a strip (`TabStripView.onHoverTab`) | `BrowserHibernation.noteHover`: a frozen page thawed **at once** on every tab the pointer crossed, then a full `replan()` (O(hidden pages)) ran on the main thread; a hibernated page restored after 150 ms. A sweep across a strip thawed every page it crossed and kept each awake 30 s. |
| A workspace row in the sidebar | Only the agent chat read-ahead (`onHoverTab`, HQ#5914). No browser page of that workspace woke: a click on it showed frozen or discarded pages, which thaw or reload after the click. |

## Rule

1. **What wakes.** The pages the click would show, nothing else. For a tab: that tab. For a workspace row:
   the selected tab of each pane on its shown screen (only the zoomed pane when one is zoomed), from the
   window's parked content when it has one, else the window's remembered tab of each pane
   (`TabSelectionMemory`), else the daemon's default tab: the order a show resolves it in. Only browser tabs (WebKit and Chromium). A frozen page thaws
   (one message); a hibernated page restores from its saved history in the background (the lifecycle
   keeps it hidden until selected).
2. **Intent, not every hover.** A wake starts only after the pointer rests on one row or tab for the dwell
   (`HoverWakeIntent.dwell`, 100 ms). A row change restarts the dwell; leaving cancels it; a newer target
   replaces the older one. Dwell bounds the speed: to stay 100 ms on a 28 pt row the pointer moves less
   than 280 pt/s, so a sweep over the sidebar (one row per frame at 120 Hz) starts no wake.
3. **Bounded.** One intent wakes at most `HoverWakeBudget.pages` pages: 2 normally, 1 under memory
   pressure warning or Low Power Mode, 0 at critical pressure, 0 when `browser.keepNeighborTabsAwake` is 0
   (the person asked that no hidden page be kept awake early). At most `HoverWakeBudget.inFlight` (2)
   hover-restored pages live at once (`HoverRestores`): a newer intent discards the oldest first (cause
   `hover-replaced`). A restore counts as in flight until its load ends. A frozen page's thaw is free.
4. **Grace, then back.** A woken page that is not shown stays awake `hoverGrace` (30 s), then it freezes
   again by the freeze rule, and a page that a hover *restored* is discarded again (cause `hover-grace`),
   through the same probe as every discard, so a page the person touched meanwhile is kept.
5. **Safety.** A restore is the same restore as a click (`BrowserHibernation.restore`: GET of the saved
   history, the record's profile, no form resubmission: a page that shows a form result is never
   discarded in the first place). A page the person hibernated (Hibernate Tab or Hibernate Workspace)
   never restores on hover.
   With no `browser.hibernation` written, only pages that workspace hibernation discarded restore on
   hover (they reload on the click anyway); other discarded pages wait for the click as before (#25791).
   A thaw does no network.

## Zero main-thread cost while the pointer moves

- The sidebar's `setHovered` already runs per row change (it repaints the hover pill). It now also calls
  `onHoverWorkspace(id)`, which writes the row id and the time into `HoverWakeGate` (a `Mutex`) and arms
  its timer only when none is armed. No layout, no model write, no observation.
- The tab strip's hover does the same through the tab gate. `replan()` no longer runs per crossed tab.
- The timer (`DemandTimer`) sleeps off the main thread. When it fires, the gate checks the dwell off the
  main thread: a target that changed within the dwell re-arms for the time left. Only a target that held
  for the dwell hops to the main actor, once; there the gate checks again that the pointer still rests on
  it (a leave during the hop wakes nothing), then the resolution (O(panes of one workspace)) and the
  thaw or restore run. A sweep over 200 rows costs the main thread 200 lock writes and nothing else.
- Page work (the reload, the first paint) runs in the WebKit and Chromium processes.

## Chromium

Chrome's speculation rules (`moderate` eagerness, developer.chrome.com/docs/web-platform/prerender-pages)
start a prerender only after the pointer rests on a link (200 ms on desktop) or on pointerdown, and keep at
most 2 such prerenders, first in first out: a new one replaces the oldest. The bookmark bar and New Tab
Page tiles use the same hover trigger. cmux copies that: a dwell before any work, at most 2 in flight, a
newer intent replaces an older one. cmux differs in two places: the dwell is 100 ms (the target is a page
that is already in memory or has a saved history, not a network fetch of an unknown page, so a false
start costs less), and Chrome never wakes a Memory Saver discarded tab on hover (it reloads on
activation); cmux does, because the person asked for it and the grace puts the page back.

## Measures (to fill from the fleet)

- (a) Sweep over 200 rows at 120 Hz: 0 missed refreshes, main p99 vs base, 0 wakes started.
- (b) Dwell 150 ms on a row with 3 hibernated pages, then click: first frame shows real content;
  time-to-content p50/p95 before vs after.
- (c) Pages woken by hover hibernate again after the grace.

## Files

- `CmuxNextHibernation/HoverWakeIntent.swift`: the dwell machine, the budget and the target resolution (pure).
- `CmuxNextHibernation/HoverWakeGate.swift`: the off-main gate (lock + one `DemandTimer`).
- `CmuxNextHibernation/HoverRestores.swift`: the hover-restored pages, oldest first, and which still load.
- `CmuxNextApp/Hibernation/BrowserHibernation.swift`: tab and workspace intents, the cap, the grace re-discard.
- `CmuxNextSidebar/Views/SidebarListView+HoverPrefetch.swift`: `onHoverWorkspace`.
- Tests: `HoverWakeIntentTests` (pure: sweep, dwell, cancel, replace, budget, targets),
  `HoverWakeTests` (live WebKit pages: a strip sweep wakes nothing, a dwell wakes, a workspace intent
  wakes the cap, the grace puts a restored page back).
