# Sidebar lag after Oct 21 (cmux-next)

Lawrence 2026-10-21: "i feel like sidebar got a lot laggier recently."

## First principles

One agent event (a new step, state or chip of one acpmux session) costs work for that one
session's row, never for every row. A pull request answer patches the rows whose badge
changed. A frame does no work for rows off screen, and a configure does not draw an image
that has not changed.

## Causes

1. **Every agent event mapped every chat row** (fab3d514f83 #23390 turned `sidebar.laneStatus`
   and `sidebar.rowStatus` on; f43268546be #23474 added the "Now:" step, `sidebar.nowLine`).
   Each row's mapping read `AgentLaneStore.lanes`, one observed dictionary, so a write of any
   session's lane marked every row that read it dirty, and the next flush ran the full
   `make()` of each. A working agent writes its lane several times a second (each tool call
   is a new step), so with N agent workspaces each event cost O(N) mappings on the main
   thread, and the step text made the re-mapped rows really differ (patch, configure, group
   header redraw).
2. **The pull request badge pass ran on every agent event** (bd60f6fac4b #23495 turned
   `sidebar.pullRequestBadges` on by default). The feed's observation read every workspace's
   tabs and the whole lanes dictionary, so every event re-ran the pass over all workspaces.
   And any badge difference counted as a structural list change: `showModelChange` laid out
   every row (`SidebarLayout.make`).
3. **The hover card rebuilt on every step of the hovered row** (b035c0bae4d #23510 added the
   "since you looked" passes; #23474 made the row change often): timeline read, content
   build, refit, though the card does not show the step.
4. **A new machine image on every configure** (0038f3eecf1 #22763): every patch and every
   row scrolled in drew a new `NSImage`.

## Fix

- `AgentLaneStore` keeps one observable cell per session (`AgentLaneCell`): a row reads
  `lane(session)` and is told about its own sessions only. The badge feed reads
  `links(session)` (`AgentLaneLinks`: folder, pull requests, spawnedBy, peer, chat), which a
  new step or state leaves alone. `lanes` stays for readers of the whole store.
- A badge change patches the changed rows (`SidebarListView.patchRows`); the list lays out
  again only when a row's height changes.
- A patch that changes only the step leaves the hover card alone.
- The row's machine mark image is drawn again only when the mark or its size changes.

All features stay on with their defaults (a419's minimal sidebar defaults untouched).

## Measurement

`SidebarLagBench` (CmuxNextAppTests): a 260 x 900 pt sidebar over 150 and 500 workspaces, four
scenarios (scroll with three agents streaming, pointer sweep, ticks under a still pointer,
clicks walking the selection), main-thread CPU per frame. `SidebarLaneTickCostTests` times
one lane event through the real row feed and lane status mapping and counts rows mapped.
Results: see the report in the a-session (fleet runs, before/after).
