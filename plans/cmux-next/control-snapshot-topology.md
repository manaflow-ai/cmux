# Control snapshot: the daemon serves the topology (design note, cx-9c8m)

Status: design, 2026-10-10. Owner: main-thread isolation lane (epic cx-9c8m).

## Problem

`ControlSnapshotPublisher.publishNow` (CmuxNextApp/Control) runs on the main
actor after every settled model change, at most once per display frame. Each
run rebuilds the whole `ControlTopology` from the daemon mirrors:
`ControlTopologyMapper` copies every workspace, screen, pane and tab of the
local store and of every remote session store, then `TabSearchFactsBuilder`
walks the location trail, every pane's pending closes and the closed-tab log.
The cost is O(all tabs) per frame while the model churns (an agent storm, a
1,000-workspace sidebar), on the thread that draws. The only guard is a debug
log above 2 ms. The copy also duplicates daemon state into a second Swift value
tree that every CLI read then serializes again (`topology.json`).

About 90% of the snapshot is daemon state that cmux-tui already owns and
serves (`list-workspaces`, the session tree, `appliedSequence`). The rest is
app-local: windows (key, visible, hidden, members), focus, the tab each pane
shows (`selectedTab`), app-only page tabs and page titles (`ControlPageFacts`),
pending closes, recency from the location trail, and the closed-tab log.

## Decision

1. The daemon is the source of the daemon part. Read-only control requests that
   need workspaces, screens, panes, tabs and groups (`tree`, `list-*`,
   `identify`, Search Tabs rows, `action.run` target resolution) read a
   daemon-served tree at the request's sequence, not a Swift copy. The local
   daemon answers over its socket; remote sessions over their existing
   connections (the app keeps one per session already).
2. The app publishes only an overlay: a small value of app-local facts keyed by
   daemon ids (windows, focus, selected tab per pane, app-only page tabs, page
   titles, pending closes, last-active times, closed tabs). Its size is
   O(windows + panes shown + closed log), not O(all tabs), and it changes only
   on focus, selection and window events.
3. A control read joins tree + overlay off the main actor (in the control
   router's actor/queue). Read-your-writes keeps working: a compat write
   carries the daemon sequence it produced (`daemonSequence` today), and the
   read waits for a tree at or after that sequence (the existing
   `CompatWriteBarrier` contract, moved from the Swift mirror to the daemon
   reply).
4. Search Tabs facts move with it: recency and closed tabs are overlay fields;
   workspace titles of closed tabs come from the daemon tree (no per-record
   search; the interim Swift index landed in ced35d89ad72).

## Steps (each one landing, about 1 hour)

1. Overlay type in CmuxNextControl (`ControlAppOverlay`) and an incremental
   publisher: the main actor builds only the overlay; the topology is still
   built, but off the main actor from an immutable mirror value the store
   already has after each batch (measure first: if the store cannot hand out an
   immutable value cheaply, step 2 comes first).
2. Daemon read path: the control router asks cmux-tui for the tree (one
   pipelined request, cached by sequence, shared by concurrent readers) and
   joins the overlay. Remote sessions use their session connection.
3. Delete `ControlTopologyMapper.topology` from the publish path; the publisher
   publishes the overlay only. Keep the mapper for `debug.*` dumps if needed.
4. Spec: if cmux-tui lacks a field the readers need (for example page tab
   kinds), add it to the daemon tree (spec change, CORE window) instead of
   keeping it in the overlay.

## Proof

- Bench: `scripts/cmux-next/bench-cli-storm.sh` (2,000 CLI requests, 32
  clients) on a 1,000-workspace fixture before and after: main-thread stalls
  over 50 ms stay 0, `debug.hangs` (MainThreadWatchdog) reports none, p99 frame
  under 16.7 ms.
- Behavior: `cmux tree`, `cmux identify`, Search Tabs and `action.run` target
  resolution give the same answers on a tagged app (socket transcript diff of
  the same script before and after).

## Not decided here

- Whether the overlay should also live in the daemon (a frontend-state record
  per window), so a second frontend (GPUI, mobile) can answer the same queries.
  The overlay is app-local today; a later step can move it once a second
  frontend needs it.
