# cmux next: docked columns and the strip scrollbar

Status: implemented 2026-10-01. User request: "make pinned/overlay/docked pane. so i can have a
docked overlay. concept should be docked column; not pane. so u can drag panes into it etc. we
should have a scrollbar kinda at the bottom that can be enabled/disabled too."

Code: `CmuxNextLayout` (`Model/DockColumn.swift`, `Geometry/DockStripGeometry.swift`,
`Geometry/StripScrollbarGeometry.swift`, `Views/ScreenContentView+Dock.swift`,
`Views/ScreenContentView+Scrollbar.swift`, `Views/StripScrollbarView.swift`,
`Views/DockBackdropView.swift`, `Model/LayoutModel+Dock.swift`), App
`Handlers/ColumnDocking.swift`, `Control/DebugDockColumns.swift`, cmux-tui
`set-column-sticky`. Tests: `Tests/CmuxNextLayoutTests/Dock*Tests.swift`,
`StripScrollbar*Tests.swift`, `Tests/CmuxNextBridgeTests/DockColumnMappingTests.swift`,
`Tests/CmuxNextSettingsTests/StripScrollbarSettingsTests.swift`.

## Model and ownership

A docked column is an ordinary column (`columns[]` in the daemon) with `dock: {edge, mode}`.
It holds panes, splits and tabs like any column. The daemon owns the flag with the rest of the
layout: it is journaled, undoable (`undo-layout`) and survives restart. The app is a projection
(OWNERSHIP-PRINCIPLES.md): it validates a change like the daemon, sends the typed op, and changes
nothing until the daemon's snapshot carries it; no optimistic copy. Capability `sticky-columns-v1`; until the pinned cmux-tui serves it the
actions are disabled with the daemon's reason and the app never sends the command.

Daemon rules (cmux-tui `set-column-sticky {pane, dock, edge, mode, transaction}`): at most one
docked column per edge per screen (making another column docked on that edge undocks the old one
in the same commit); at least one column scrolls (`dock-column-last-scrolling`); new columns are
never docked; column order is unchanged, so older clients render the column in place.

## Geometry (S1 to S6)

- S1. The first docked column per edge in daemon order holds it; any other docked column scrolls.
- S2. A screen whose columns would all be docked shows them all in the strip.
- S3. A docked column's width is a fraction of the whole viewport (column-scroll.md W3: `(view - gap) * p -
  gap`), at least its panes' minimum, at most 3/4 of the viewport (2/5 each with both edges). It
  sits one gap from its edge. Its resize handle is on its own inner edge, so the gap beside it
  keeps the neighboring strip column's handle.
- S4. Docked: the strip's viewport shrinks to end at the column; strip widths are fractions of
  the strip. Overlay: the strip keeps the full width and its fractions; its content gets an inset
  of the column's width plus a gap at that end, so at rest nothing hides under the column and
  every column can scroll out from under it.
- S5. The scroll reducer sees only the scrolling columns and the strip viewport
  (plans/cmux-next/column-scroll.md rules apply unchanged inside the strip).
- S6. Docked panes and dividers are in view coordinates and never scroll; strip content is in
  strip space starting at `stripMinX`.

## Drops (D1 to D3)

- D1. Docked panes sit above the strip and take drops (center and edges, Liquid Glass highlight
  as everywhere). An edge drop on a docked pane that has no room joins the pane instead of
  opening a column.
- D2. What a docked column covers (from the window edge to its inner edge, or to its glass rim's
  outer edge in overlay mode) takes no drop and no click, so nothing lands in a strip pane hidden
  under it.
- D3. Dragging the last pane out of a docked column removes the column (decision: auto-remove,
  because daemon columns cannot be empty and an empty docked column would be a dead area to
  close by hand). Drag autoscroll bands sit at the inner edges of the strip's uncovered range.

## View (V1 to V4)

- V1. Strip panes sliding under a docked column are clipped (layer mask) at a docked column's
  inner edge or an overlay's rim outer edge; strip dividers under it are hidden; hit testing in
  the cover never reaches a strip pane.
- V2. Overlay: a Liquid Glass rim (`OverlaySurfaceView`, opaque under Reduce Transparency) of half
  a gap around the column with a soft shadow, and an opaque Ghostty-background fill behind the
  panes, so glass never sits behind terminal text.
- V3. Stacking: strip hosts, strip dividers, glass backdrops, docked hosts, docked dividers,
  scrollbar. `sortSubviews` reorders without detaching (no surface teardown).
- V4. Strip pane rings and dims are masked out of what a docked column covers; pointer focus and
  horizontal scroll over a docked column belong to it, not the strip.

## Strip scrollbar (B1 to B5)

- B1. Thumb width is the visible share of the strip (minimum 32 pt); nil when every column fits.
  A rubber-banded offset shortens the thumb at that end.
- B2. Dragging the thumb drives the scroll reducer as a trackpad gesture (snaps on release).
- B3. A click beside the thumb pages one strip viewport toward the click and rests on the nearest
  snap, at least one snap step (`ColumnScrollEvent.page`, focus follows like a wheel notch).
- B4. `layout.stripScrollbar`: `auto` (default; fades in while the strip scrolls or the pointer is
  over the band, fades out after 1.2 s through a one-shot `DemandTimer`), `always` (while columns
  overflow), `off`. Booleans: `true` = auto, `false` = off. Settings window (Columns group) and
  palette Toggle Column Scroll Bar.
- B5. Minimal look: neutral thumb from the theme's tertiary text color, no track color, fades
  through Motion `fadeIn`/`fadeOut` (Reduce Motion snaps). It floats over the bottom of the strip's
  uncovered range like a macOS overlay scrollbar and takes the mouse only while shown.

## Entry points

Palette and CLI (`cmux action run` or the verbs): Dock Column (`column dock`, Ctrl-Cmd-P by default,
optional `edge` left|right|top|bottom, `mode` docked|overlay). cmux.json `layout.dockColumnEdge`
and `layout.dockColumnMode`, when set, are its defaults. Unset, it docks (not floats) the column
on the edge it is nearer to (left for the leftmost of several scrolling columns, else right; a side
another column holds yields to the free side), at its width clamped to 25-40%, width and pin in one
transaction (one undo). Running it again on a docked column undocks it. On a screen's only
scrolling column, which must keep scrolling, the focused tab moves into a new docked column
(`move-tab-to-column` with `dock`); when it is the screen's only tab, a fresh tab of the same kind
(a terminal in the same directory) stays in the strip (`respawn`, `tab-column-respawn-v1`). Only a
kind that cannot respawn (an agent chat, an incognito page) refuses there. A tab dragged to a window
edge band docks at that edge. Dock Column Left/Right/Top/Bottom (`column dock-left|dock-right|dock-top|dock-bottom`),
Float Column (`column float`, the same rule in overlay mode), Undock Column (`column undock`),
Move Tab to New Dock Column (`tab move-to-new-dock-column`), Toggle Column Scroll Bar (`settings toggle-column-scrollbar`).
Column and pane context menus. Directional focus treats the left docked column as before the
strip and the right one as after its end. `debug.dock` reports docked frames, strip range, scrollbar and
pane stacking, and with `pane` + `dock` (+ `edge`, `mode`) changes a column through the same
path. No default shortcut.

## Known gaps

- Chromium pages are child windows above the window content: a Chromium page in a strip pane that
  scrolls under an overlay or docked column draws above it, and the scrollbar draws under
  a Chromium page at the bottom of the strip. At rest neither overlaps (S4).
- In overlay mode the focus reveal (column-scroll.md F1) still treats the full width as visible, so a
  focused column scrolled under the overlay is not moved out automatically.
- `SplitRoom` sizes docked strip columns against the whole viewport, so a split near the minimum
  pane width may be refused or allowed a little early.
