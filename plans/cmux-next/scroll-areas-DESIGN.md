# cmux next: scroll areas (design)

Status: design and prototype 2026-10-20 (subagent "Scroll areas in layout"). Step 1 (horizontal
overflow scroll areas, client only, behind `layout.scrollAreas`, default off) is implemented.
Steps 2 to 4 wait for the user's decisions at the end of this note.
Builds on: layout-model.md (the frame, decided), rows.md (columns of rows), column-scroll.md
(the strip scroll reducer), dock-column.md, column-sizing.md, focus.md, OWNERSHIP-PRINCIPLES.md.
Gallery: `plans/cmux-next/scroll-areas-gallery/index.html` (three clickable designs).

## The request

Lawrence, 2026-10-20 (paraphrased): introduce a "scroll area". Do horizontal first, but design it so
it also works vertically (columns versus rows). Today a docked column is one column: it can
hold splits, but nothing in it can scroll. A scroll area would let a split hold scrolling
content, and could let a workspace hold more than one workspace (a view that shows two
workspaces side by side, each with its own tabs). This could be complex and confusing, so make
a prototype first, then develop it. There is probably a generalization that makes the layout
system more flexible.

## The missing generalization

Today's layout has three container kinds at fixed depths:

```
Screen  = horizontal strip of Columns          (scrolls on x; column-scroll.md)
Column  = vertical strip of Rows               (scrolls on y; rows.md)
Row     = SplitTree                            (never scrolls; panes shrink to fit)
Dock    = a Column pinned to an edge            (layout-model.md)
```

A strip and a split are the same thing with a different sizing rule:

| Container | Children sized as | When children need more room than it has |
| --- | --- | --- |
| split (`fit`) | ratios that sum to 1 | panes shrink to their minimum, then shrink evenly (SplitGeometry) |
| strip (`scroll`) | each child its own extent, in permille of the viewport | the container scrolls |

So the general node is one container with an axis and a sizing rule:

```
Node = Pane(pane)
     | Box { axis: h | v, sizing: fit | scroll, children: [Node], extents, pin? }
     | Ref(workspace, screen)            // step 4 only, see "Nested workspaces"
```

Today's model is the special case `Box(h, scroll)[ Box(v, scroll)[ Box(fit) tree ] ]`, with
docks as pinned children of the outer box. A **scroll area** is a `Box(axis, scroll)` anywhere
below the screen: inside a docked column, inside one side of a split, inside a row.

### Rules that keep it simple (S1 to S6)

- S1. Flatten same-axis nesting. A `Box(h, scroll)` directly inside a `Box(h, scroll)` is
  merged into its parent (its children become the parent's children). There is never a
  horizontal strip directly inside a horizontal strip, so one wheel gesture never has two
  same-axis owners with nothing between them. The reducer normalizes this in the same commit,
  as rows.md R2 removes empty containers.
- S2. Depth cap. At most three scroll boxes on any path from the screen to a pane (the
  screen strip, a column's rows, and one scroll area). Deeper requests are refused
  (`scroll-area-depth`). TLC checks the model at this bound (layout-model.md refused design D,
  "recursive containers", because its depth was unbounded; the cap is the answer to that).
- S3. Every box is non-empty (rows.md R2): a scroll area whose last child leaves is removed in
  the same commit, and a scroll area with one child that fits becomes that child.
- S4. Sizes are store state in permille of the box's own viewport (column-scroll.md W2, E5).
  Offsets, focus and the remembered pane per child stay client view state (rows.md
  ownership table). The store never reads a viewport.
- S5. One reducer path. The screen strip, the row strip and every scroll area run the same
  `ColumnScrollState.reduce` (reveal F1 to F7, layout changes L1 to L7, gestures T1 to T4),
  fed through an adapter (`RowScroll` today, `ScrollAreaScroll` for areas). No new scroll
  rules; scroll areas inherit every edge case already solved for columns.
- S6. Old clients. A scroll area folds into a split chain in the compat projection (as rows
  fold into a vertical split chain, rows.md), so an old client sees the same panes in a split.

## Three interaction designs (the gallery)

| | A. Overflow splits (Recommended) | B. Explicit scroll areas | C. Side-by-side workspaces |
| --- | --- | --- | --- |
| What the user does | nothing new: split as today | Make Scroll Area on a pane or dock, then New Column inside it | select two workspaces, View Side by Side |
| When it scrolls | a split that cannot give every pane its minimum width scrolls instead of squashing | always a strip; its children keep their own widths | the screen is a strip of whole workspaces |
| New concepts shown to the user | none (a scrollbar appears when a split overflows) | "scroll area" (a box with its own New Column, its own scrollbar) | "side-by-side view" (a group of workspaces shown together) |
| Store change | none in step 1 (the client derives it from minimums) | `Box(scroll)` node, ops `WrapInScrollArea`, `InsertAreaChild`, `UnwrapScrollArea` | `Ref` nodes or a view record that lists workspaces |
| Docked column gets scrolling content | yes, automatically | yes, explicitly | no |
| Risk of confusion | low: the only change is "it scrolls instead of getting tiny" | medium: two kinds of "new column" | high: who owns a tab, what close and focus do |

Strongest objection to each:

- A: it is implicit. A user cannot ask for a scroll area where the panes would still fit.
  Answer: B's explicit op builds on A's geometry later without a rewrite; A ships first because
  it fixes the real pain (a docked column or a narrow column that squashes its splits) with no
  new vocabulary.
- B: "New Column" now means two things (in the screen strip, or in the area that has focus).
  Answer: it means "the strip that holds the focused pane", which is already true for New Row.
  Still, the two meanings are why B waits for dogfood of A.
- C: a tab would show in two workspaces, or the view would own workspaces, and then closing,
  moving and focus each need a second rule. See the next section.

## Nested workspaces (recommendation: do not nest; ship C later as a view)

A workspace that contains workspaces gives every tab two owners. Close, move to workspace,
unread, notifications, the sidebar, restore and the CLI's `workspace.list` would each need a
rule for "the inner workspace". That is the confusion the user is worried about.

Recommendation: never nest ownership. If C ships, it is a **view**, not a container:

- A side-by-side view is a client view record `{ id, workspaces: [ws], widths }`, shown as
  a screen-level strip whose items are the live screens of those workspaces (`Ref`). Each
  workspace keeps its own tabs, focus and history; nothing is copied.
- The sidebar shows the view as one row with the workspaces' icons stacked; selecting any of
  them can open the view (setting) or the workspace alone (default).
- Closing the view never closes a workspace. Closing a workspace removes it from the view;
  a view with one workspace left goes away (S3).
- Cmd-Opt-arrows cross from one workspace's last column into the next workspace's first
  column (geometric, the same rule as today's strip).

Decision for the user: build C as a view after A ships, or drop it.

## Geometry (step 1, implemented)

- G1. A split tree whose minimum width (`SplitGeometry.minimumSize`, which already adds the
  minimum widths of a horizontal chain) is wider than its frame is laid out in a content rect
  as wide as that minimum, then shown through its frame: the frame is the area's window, the
  tree scrolls inside it. Panes keep `layout.minimumPaneWidth` (never squashed).
- G2. It applies to every top-level tree: a split screen, each strip column, each docked
  column and each row. One tree has at most one scroll area (its root), so S1 holds by
  construction.
- G3. With scroll areas on, a strip column or a docked column no longer widens to fit its
  splits (column-scroll.md `minimumWidths`): it keeps its width, and its splits scroll inside
  it. A column still never gets narrower than one pane's minimum.
- G4. With the setting off, geometry is byte-for-byte today's (tests compare both).
- G5. Each area is recorded in `ScreenGeometry.scrollAreas` (window, content width, the panes
  and dividers it holds) so views, hit testing and focus read one source.

## Focus and keyboard (K1 to K5)

- K1. Cmd-Opt-arrows keep Ghostty pane navigation: they move to the geometric neighbor in the
  pressed direction. Inside an area, panes are mapped into the area's window in proportion
  (as top and bottom docks are mapped across the strip today, `navigationFrames`), so left
  and right step through the area's panes one by one, and right from the area's last pane
  leaves the area for the next column. No new chord; nothing is rebound.
- K2. A pane that gets focus (any source: keyboard, click, CLI with focus, close successor)
  is revealed in its area with column-scroll.md F1 (minimal reveal), then its column is
  revealed in the screen strip. Inner first, outer second, so the outer reveal sees the
  final inner position.
- K3. A click never scrolls a pane that is fully visible (F5): content does not move under
  the pointer.
- K4. Automation (CLI, MCP, scripts) never moves an area's offset unless the op asks to
  focus (focus.md, socket focus policy).
- K5. Reduce Motion: reveals snap (the spring is skipped, `Motion.policy`).

## Scrolling input and snapping (I1 to I5)

- I1. Horizontal trackpad gestures and Shift-wheel over an area scroll the area. Vertical ones
  stay with the pane (terminal scrollback), as for rows (rows.md V5).
- I2. Innermost first, with hand-off at the start only: a gesture that begins over an area
  that can move in the gesture's first direction scrolls the area; one that begins over an
  area already at that end scrolls the screen strip instead. A gesture never switches owner
  midway (no fight, column-scroll.md T1).
- I3. Pane content that scrolls sideways itself (a wide web page, `paneContentClaimsHorizontalScroll`)
  keeps the gesture, as today.
- I1-I3 under `layout.scrollModifier` `command` (default since 2026-10-24): the gesture must begin
  with Command held (plain scrolls over a pane are the pane's, so I3 needs no claim); I2's
  innermost-first rule is unchanged. `none` keeps I1 to I3 as written.
- I4. Release snaps to pane edges (the strip's snap points with the area's cells as columns),
  a mouse-wheel notch moves one snap point (T2, T4).
- I5. Focus after an area scroll: unchanged if the focused pane is still visible, else the pane
  farthest in the gesture's direction that is fully visible (T3).

## Persistence and restore

Step 1 stores nothing new: areas are derived from the split ratios and minimums the daemon
already stores, and offsets are view state (rows.md), so a restart restores the same areas
scrolled to reveal the focused pane. Step 2's `Box(scroll)` node is store state: journaled,
undoable (`undo-layout`), in v2 layout documents and blueprints, behind capability
`scroll-areas-v1`; an older binary refuses ops on it and renders the compat split chain (S6).

## CLI, MCP and Cmd+Shift+P parity

| Surface | Step 1 | Step 2 (B) |
| --- | --- | --- |
| Setting | `layout.scrollAreas` (cmux.json, Settings > General > Columns, MDM) | same |
| Cmd+Shift+P | the Settings row is searchable ("Scroll Areas") | Make Scroll Area, Unwrap Scroll Area, New Column in Scroll Area, Focus Next Pane in Area |
| CLI | `cmux settings set layout.scrollAreas true` | `cmux pane scroll-area wrap|unwrap`, `cmux pane new-column --in-area` |
| MCP | settings tools | `pane_scroll_area_wrap`, `pane_scroll_area_unwrap` |
| Right-click | none | pane menu: Make Scroll Area; area menu: Unwrap |

Every step 2 action uses one shared action path (CLAUDE.md "Shared behavior policy").

## What can confuse users, and the answer

| Risk | Answer |
| --- | --- |
| "Where did my pane go?" (scrolled out of an area) | the area shows a thin scrollbar while it overflows; focus always reveals; K1 reaches every pane |
| Two scrollbars at once (strip and area) | the area's bar sits inside its window, the strip's at the screen bottom (layout-model.md F4) |
| Wheel goes to the wrong strip | I2: innermost wins only when it can move; owner fixed per gesture |
| Terminal resize churn while scrolling | panes in an area keep their size; scrolling moves them, never resizes them |
| Nested workspaces | not nested; C is a view and waits for a decision |

## Steps

1. Done: overflow scroll areas, horizontal, client only, setting off by default (this branch).
   Tests: `ScrollAreaGeometryTests` (geometry G1 to G5, K1 navigation mapping, S5 reveal).
2. Explicit `Box(scroll)` in the reducer and daemon (`scroll-areas-v1`), ops, TLA+ at the S2
   bound, actions on every surface (design B).
3. Vertical scroll areas: the same code with the axis swapped (rows already prove the
   transposed reducer, `RowScroll`).
4. Side-by-side workspaces as a view (design C), if the user wants it.

## Open questions for the user

1. Ship design A (automatic: a split that cannot fit scrolls instead of squashing) as the
   default once dogfood is clean? Reply `turn it on by default` or `keep it opt-in`.
2. Build explicit scroll areas (design B, "Make Scroll Area")? Reply `build B` or `A is enough`.
3. Nested workspaces: reply `build side-by-side view` (design C, a view, never ownership) or
   `drop nested workspaces`.
