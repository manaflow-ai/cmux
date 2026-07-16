# iOS panes + tabs UX (from scratch)

## Why the user opens the iOS app

cmux workspaces are AI coding-agent sessions running on the Mac. The phone is a
remote window into those sessions, used in short bursts away from the desk. The
jobs, ranked:

1. Triage: which agent needs me right now.
2. Read: one terminal at full fidelity, enough to decide (approve, answer,
   judge output).
3. Act: send a short reply or command.
4. Peek: a workspace on the Mac usually has more than one screen. On the Mac a
   workspace is a spatial arrangement of panes (bonsplit splits), and each pane
   holds a stack of tabs. Agent terminal + dev server + logs + editor. The user
   must be able to check any of those screens from the phone.

Phone constraints: one readable terminal at a time, thumb-zone-first, bursty
10-60s sessions, gestures must not fight terminal scrolling or the keyboard.

## What is wrong today

Tabs are a flat list inside a top-right toolbar menu (`TerminalPickerMenu`):
not glanceable, two taps, worst reach zone, no live status. Panes do not exist
on the phone at all; the wire payload collapses the split tree into a flat
`terminals[]` list, so the Mac's spatial structure is invisible.

## Mental model to expose

A workspace is a small set of live screens arranged spatially on the Mac. The
phone shows exactly one screen at full fidelity, plus:

- a persistent, glanceable, thumb-reachable strip of every screen (grouped by
  pane, exactly mirroring the Mac structure),
- one-swipe / one-tap switching with live peek,
- a zoomed-out workspace map that mirrors the Mac's true split geometry.

## The three surfaces of the design

### 1. Surface strip (top, replaces the toolbar menu)

Docked directly under the navigation bar, full width. Contents, left to
right:

- Map button: a glyph that miniatures the workspace's REAL split layout
  (drawn live from the layout tree, not a generic icon; the pane containing
  the current tab renders brighter). Tap = open workspace map.
- Tab chips grouped by pane: chips of the same pane sit in one visual
  container (containers only appear when the workspace has >1 pane). Chip =
  status dot (green working / orange needs-input) + title. Selected chip =
  prominent tint. Tap = switch (autofocus-suppressed like today's picker).
  Long-press = Close Tab (when >1 terminal). Browser/plugin tabs show a kind
  icon instead of a status dot.
- "+" button: new tab in the currently viewed pane (`pane_id` on the wire).

Why top, not bottom: `GhosttySurfaceView` owns the whole bottom dock
(terminal grid / accessory toolbar / composer band / keyboard) in ONE
coordinate system, and a competing SwiftUI bottom bar is a documented past
failure mode there (the round-5/6 safeAreaInset fight). The top edge has no
keyboard math, never stacks with the composer, and thumb-switching is served
by the pager gesture instead; the strip's primary job is glanceability.

### 2. Surface pager (gesture switching with live peek)

The terminal area becomes a horizontal pager over the workspace's surfaces in
spatial (bonsplit DFS) order — the same order as the bar. Horizontal pan with
|dx|>|dy| pages between surfaces; the incoming neighbor is mounted and LIVE
during the drag (the streaming substrate already delivers render frames to any
surface with a registered sink). Neighbor surfaces mount in preview-only mode:
they receive frames but do not send viewport grants and do not take keyboard
focus, so peeking never resizes panes on the Mac. On settle, the new current
surface activates its viewport grant; if the keyboard was up, focus transfers.
Leading-edge swipe-back to the workspace list keeps priority within ~20pt of
the left edge.

### 3. Workspace map (the pane construct made visible)

Full-screen zoom-out that renders the workspace as its true split geometry
(orientation + divider ratios from the layout tree). Each pane region shows:

- a live-ish miniature of its selected tab (rendered from a `render_grid`
  replay snapshot as tiny styled text, Exposé-style),
- the pane's tab strip as mini pills when the pane has >1 tab,
- status dots per tab.

Tap a tab/pane → it becomes the full-screen surface (zoom transition). Swipe
down dismisses. Non-terminal panels (browser) render as icon cards.

Status semantics everywhere ride the existing chat-session descriptors
(working / needs input / idle) matched by surface id, so the bar doubles as
in-workspace triage.

## Wire contract additions (Mac side, additive)

`mobile.workspace.list` gains per-workspace `layout`, serialized from
`bonsplitController.treeSnapshot()` (`ExternalTreeNode`, already Codable):

```json
{"type":"split","orientation":"horizontal","ratio":0.5,
 "first":{...},"second":{...}}
{"type":"pane","pane_id":"...","tabs":[{"id":"<panel-uuid>",
 "kind":"terminal|browser|other","title":"..."}],
 "selected_tab_id":"..."}
```

`terminals[]` stays unchanged for backward compat; `layout` references the same
ids. `paneLayoutVersionPublisher` already nudges `workspace.updated`, so
structure changes propagate with no new observer work.

New verbs:

- `mobile.terminal.create` gains optional `pane_id` (create the tab in that
  pane instead of the Mac-focused one).
- `mobile.terminal.close` (alias `terminal.close`): close one tab by surface
  id; rejected when it is the workspace's last terminal.

Both dispatched from `mobileHostHandleRPC` and passed through the control
socket (`ControlCommandCoordinator+MobileHost`) so they are CLI-testable
against a tagged build.

Older Mac + newer phone: `layout` absent → phone falls back to a flat
single-group strip (still strictly better than the menu). Newer Mac + older
phone: additive field is ignored.

## iOS architecture

- `MobileWorkspaceLayout` value model (decode of `layout`) in
  `CmuxMobileShellModel`; DFS order helper must reproduce `terminals[]` order.
- Bar, pager, map live in `CmuxMobileShellUI` as small files; rows/chips take
  value snapshots + action closures only (snapshot-boundary rule).
- `TerminalPickerMenu` is deleted from the toolbar; its non-tab actions (New
  Workspace, New Browser, View as Text, Copy Debug Logs, Send Feedback) move
  to the leading workspace-title menu.
- Fixture routes (`CMUX_UITEST_SURFACE_NAV_PREVIEW`, `..._MAP_PREVIEW`) render
  the bar/pager/map with deterministic fake layout + grid data for pixel
  verification and UI tests.

## Out of scope (follow-ups)

Creating splits from the phone; reordering tabs from the phone; browser-pane
live preview.
