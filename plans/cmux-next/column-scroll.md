# cmux next: column strip scrolling

Status: implemented 2026-09-30. Code: `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Scroll/`
(`ColumnScrollState.reduce`, pure), fed by `ScreenContentView+Scrolling.swift`. Tests:
`Tests/CmuxNextLayoutTests/ColumnScroll*Tests.swift` (reducer) and
`ColumnCloseScrollTests.swift` (live view). User request: the column strip must scroll as
little as possible, and every edge case needs a rule, for example the scroll animation when
the rightmost column closes.

## Model

The strip scrolls by one offset: the content-space x of the viewport's leading edge. cmux
stores the absolute offset and shifts it with the focused column (rule L1), so the camera
follows the focused column. cmux clamps every resting offset to
`0...contentWidth - viewport`, so the strip never shows empty space beside the first or
last column ("no empty space at the right" in the request).

One reducer owns every rule. The view steps a spring (`Motion.spring(.scroll)`); every
change retargets it from the presented value and keeps its velocity.

## Focus (reveal)

F1. `never` (default): minimal reveal. The column plus its padding
(`min(gap, (view - width) / 2)`) is fully visible: nothing moves. Else align the edge that
needs less motion. A column at least as wide as the view is left-aligned.

F2. `always`: the column centered; a column as wide as the view is left-aligned. Clamped at
the strip ends, so the first and last columns sit at the edges.

F3. `on-overflow`: the source is the target's neighbor on the side focus came from. If
source + target + two gaps fit in the view, F1; else F2. Without a previous column (first
placement, re-fit), F1.

F4. A column wider than the view with splits inside: if the focused pane is visible,
nothing moves; else the column's left edge if that shows the pane; else F1 on the pane.

F5. A click never centers: the column under the pointer only scrolls far enough to be fully
visible (F1), in every mode. A visible column never moves on click, because content moving
under the pointer during a mouse-down starts a drag selection in the wrong place.

F6. Fast focus sequences retarget from the current target and never queue. The spring
keeps its presented value and velocity.

F7. `center-column` centers once, regardless of the mode.

## Layout changes

L1. Camera anchor: across insertions, removals, width changes and window resizes, the
previously focused column keeps its on-screen position. A reorder (move column left/right)
keeps the camera itself. After the anchor, the focused column is re-fitted with the mode.

L2. Closing the rightmost column: the camera does not jump in the frame of the close; the
spring runs from the old offset to the new end, so empty space at the right closes with
`scroll` motion and none remains at rest. Pane frames still snap (motion.md: close is one
frame). Before this change the clamp snapped with the structural change.

L3. Closing a column left of the focus: the focused column stays where it is (L1); no
motion when the new end allows it.

L4. Closing the focused column: the daemon and the focus coordinator pick the successor
(the neighbor that slid into place, `min(active, len - 1)`); the content-space camera stays
and the successor is revealed with F1.

L5. Opening a column right of the focused one and focusing it records a restore point.
Closing that column while focus returns to the previous column restores the old view, then
re-fits. Focusing any other column forgets it.

L6. Resizing: the focused column's left edge stays (L1); widening it at the right edge
reveals the new edge. During a column-edge or divider drag the view holds and the reveal
runs once the drag ends.

L7. Window resize: frames snap; the focused column keeps its screen x, then F1 fits it. No
animation during live resize.

## Column widths

W1. A new column is 1/2 of the view when no setting overrides it. Before this change cmux
used 2/3 (the cmux-tui default for `new-pane-right`).

W2. `layout.defaultColumnWidth` in cmux.json changes it: a proportion from 0.1 to 1.0
(for example `0.5`, `0.6667`). A bad value keeps 0.5 and shows a diagnostic. Fixed pixel
widths are not supported, because the daemon stores a column width as a fraction of the
view (`set-viewport-pane-width`); a fixed width would change on each window resize.

W3. Proportions include the gaps: `(view - gap) * p - gap` (`ColumnStripGeometry.pixelWidth`).
Two columns with `p + q = 1` fill the view exactly.

W4. (Since 2026-10-02 only with `layout.newColumnWidth` = fixed; the default matchCurrent never
resizes a column, plans/cmux-next/column-sizing.md.) A lone full-width column changes to
`1 - new width` (1/2 with the default) when a second column opens next to it, so both
columns are fully visible and the view does not move. Reason: a cmux workspace starts as
one full-width column. Without W4, the reveal (F1) of the new column pushes the first
column out, and only its empty right part shows. W4 does not apply when the lone column is
not full width, when there are two or more columns, when the new column is wider than 0.9
of the view, or when the lone column closes in the same step (its only tab moves out).

W5b. Order and shape (found live on tag nxset, 2026-09-30). A workspace that never had
a second column is a split tree in cmux-tui: its root is a leaf, not a viewport, and the
app mirrors it as `.splits`, not as one column. W4 treats that shape as a lone
full-width column. cmux-tui refuses `set-viewport-pane-width` while the root is not a
viewport, so the width change goes out after the new column exists
(`LayoutModel.prepareNewColumn` returns it, `commitNewColumnResize` sends it once the
new-column command succeeded). Sent first, it was refused and the first column stayed
full width, scrolled off screen.

W5. Every path that opens a column uses W1 to W4: the New Column action, a split with no
room, and a tab or tab group dropped into a new column (`AppServices.newColumnWidth`,
`LayoutModel.prepareNewColumn`, rules in `NewColumnWidth.plan`). The width change is a
daemon intent (`set-viewport-pane-width`) with an optimistic patch
(architecture.md section 1), sent before the new column. Workspace blueprints keep their
own widths. A workspace that no window shows gets W1 only.

## Trackpad and wheel

T1. A gesture takes over from the presented value; an automatic scroll in flight stops
where it is. While the gesture runs, focus changes and layout changes never move the
target (no fight); the camera anchor still applies so content under the fingers does not
jump.

T2. Release: project the fling (UIScrollView normal deceleration), snap to the nearest
snapping point; a fast fling advances at least one point. Rubber band past the ends
springs back. Snapping points per mode: column left and right alignments with padding
(`never`), column centers (`always`), and centers for an edge whose neighbor cannot share
the screen (`on-overflow`). Clamped to the strip, so a gesture never snaps past the first
or last column.

T3. Focus after a scroll: if the focused column is still visible at the snap, focus stays
(a peek does not move the keyboard). Else the column farthest in the gesture's direction
that is fully visible takes focus, with the pane last focused in it. This keeps the
automatic reveal from fighting the scroll later: the focused column is always visible
after a scroll.

T4. A mouse-wheel notch moves to the adjacent snapping point and applies T3.

## Settings and entry points

`layout.centerFocusedColumn` in cmux.json: `"never"` (default), `"always"`,
`"on-overflow"`. Palette: Scroll Columns Minimally, Always Center Focused Column, Center
Focused Column on Overflow (`layout.centerFocusedColumn.{never,always,onOverflow}`), which
apply at once and write cmux.json. `layout.defaultColumnWidth` (W2) has no palette
action. cmux-next has no Settings window yet; cmux.json and the
palette are the settings surfaces.

## Not done

- Always centering a single column, and fullscreen or maximized columns: cmux has no
  equivalent column states.
- Columns wider than the view cannot occur today (widths are 0.1...1.0 of the view and
  minimum widths cap at the view minus gaps); F4 is covered by reducer tests only.
