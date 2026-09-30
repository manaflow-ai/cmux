# cmux next: niri column scrolling

Status: implemented 2026-09-30. Code: `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Scroll/`
(`ColumnScrollState.reduce`, pure), fed by `ScreenContentView+Scrolling.swift`. Tests:
`Tests/CmuxNextLayoutTests/ColumnScroll*Tests.swift` (reducer) and
`ColumnCloseScrollTests.swift` (live view). User request: "niri scroll should scroll as
little as possible. think of all edge cases for niri too, like scroll animation if we
close right most column."

Source: niri `src/layout/scrolling.rs` at commit `1f03391ea644c2a43597de7f637269e26d1e1b49`.
Line numbers below refer to that commit.

## Model

The strip scrolls by one offset: the content-space x of the viewport's leading edge. niri
stores the view offset relative to the active column (`view_pos = column_x(active) +
view_offset`, `view_pos`, 2323). cmux stores the absolute offset and gets the same camera
behavior by shifting the offset with the focused column (rule L1). cmux clamps every
resting offset to `0...contentWidth - viewport`; niri does not clamp and can show empty
space beside the first or last column. That is the one deliberate difference; it follows
from "no empty space at the right" in the request.

One reducer owns every rule. The view steps a spring (`Motion.spring(.scroll)`); every
change retargets it from the presented value and keeps its velocity.

## Focus (reveal)

F1. `never` (default): niri `compute_new_view_offset` (5588). The column plus its padding
(`min(gap, (view - width) / 2)`) is fully visible: nothing moves. Else align the edge that
needs less motion. A column at least as wide as the view is left-aligned.

F2. `always`: niri `compute_new_view_offset_centered` (606): the column centered; a column
as wide as the view is left-aligned. Clamped at the strip ends, so the first and last
columns sit at the edges.

F3. `on-overflow`: niri `compute_new_view_offset_for_column` (655-713). The source is the
target's neighbor on the side focus came from. If source + target + two gaps fit in the
view, F1; else F2. Without a previous column (first placement, re-fit), F1.

F4. A column wider than the view with splits inside (cmux extension; niri has no
horizontal splits inside a column): if the focused pane is visible, nothing moves; else
the column's left edge if that shows the pane; else F1 on the pane.

F5. A click never centers: the column under the pointer only scrolls far enough to be fully
visible (F1), in every mode. A visible column never moves on click. niri centers on click
in `always`; cmux does not, because content moving under the pointer during a mouse-down
starts a drag selection in the wrong place.

F6. Fast focus sequences retarget from the current target (niri uses `target_view_pos` in
`compute_new_view_offset_fit`, 597) and never queue. The spring keeps its presented value
and velocity (niri restarts at velocity 0, `animate_view_offset_with_config` FIXME, 757).

F7. `center-column` centers once, regardless of the mode.

## Layout changes

L1. Camera anchor: across insertions, removals, width changes and window resizes, the
previously focused column keeps its on-screen position (niri keeps `view_offset` relative
to the active column: `add_column` 999, `remove_column_by_idx` 1192, `update_config` 343).
A reorder (move column left/right) keeps the camera itself (niri `move_column_to` 1710,
"Preserve the camera position", 1724). After the anchor, the focused column is re-fitted with
the mode (niri calls `animate_view_offset_to_column` after each of these).

L2. Closing the rightmost column: the camera does not jump in the frame of the close; the
spring runs from the old offset to the new end, so empty space at the right closes with
`scroll` motion and none remains at rest. Pane frames still snap (motion.md: close is one
frame). Before this change the clamp snapped with the structural change.

L3. Closing a column left of the focus: the focused column stays where it is (L1); no
motion when the new end allows it.

L4. Closing the focused column: the daemon and the focus coordinator pick the successor
(the neighbor that slid into place, niri `min(active, len - 1)`, 1270); the content-space
camera stays and the successor is revealed with F1.

L5. Opening a column right of the focused one and focusing it records a restore point
(niri `activate_prev_column_on_removal`, 1058). Closing that column while focus returns to
the previous column restores the old view, then re-fits (1246-1260). Focusing any other
column forgets it (830).

L6. Resizing: the focused column's left edge stays (L1); widening it at the right edge
reveals the new edge. During a column-edge or divider drag the view holds and the reveal
runs once the drag ends (niri interactive resize keeps the offset, 1377-1395, and fits at
the end).

L7. Window resize: frames snap; the focused column keeps its screen x, then F1 fits it
(niri `update_config`, 362-366). No animation during live resize.

## Trackpad and wheel

T1. A gesture takes over from the presented value; an automatic scroll in flight stops
where it is (niri `view_offset_gesture_begin`, 3054). While the gesture runs, focus changes
and layout changes never move the target (no fight); the camera anchor still applies so
content under the fingers does not jump.

T2. Release: project the fling (UIScrollView normal deceleration), snap to the nearest
snapping point; a fast fling advances at least one point. Rubber band past the ends
springs back. Snapping points per mode follow niri `view_offset_gesture_end` (3203-3420):
column left and right alignments with padding (`never`), column centers (`always`), and
centers for an edge whose neighbor cannot share the screen (`on-overflow`). Clamped to the
strip (niri: "Prevent the gesture from snapping further than the first/last column").

T3. Focus after a scroll: if the focused column is still visible at the snap, focus stays
(cmux: a peek does not move the keyboard). Else, as niri (3435-3500), the column farthest in
the gesture's direction that is fully visible takes focus, with the pane last focused in
it. This keeps the automatic reveal from fighting the scroll later: the focused column is
always visible after a scroll.

T4. A mouse-wheel notch moves to the adjacent snapping point and applies T3.

## Settings and entry points

`layout.centerFocusedColumn` in cmux.json: `"never"` (default), `"always"`,
`"on-overflow"`. Palette: Scroll Columns Minimally, Always Center Focused Column, Center
Focused Column on Overflow (`layout.centerFocusedColumn.{never,always,onOverflow}`), which
apply at once and write cmux.json. cmux-next has no Settings window yet; cmux.json and the
palette are the settings surfaces.

## Not done

- niri's `always-center-single-column` and fullscreen or maximized columns: cmux has no
  equivalent column states.
- Columns wider than the view cannot occur today (widths are 0.1...1.0 of the view and
  minimum widths cap at the view minus gaps); F4 is covered by reducer tests only.
