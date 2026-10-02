# cmux next: layout model (proposal)

Status: proposal 2026-10-02 by the layout model lead (rows work continues inside this lane).
Not the spec: the coordinator writes the spec from this ("spec proposal: layout model").
Builds on rows.md (columns of rows, approved), sticky-column.md (left and right sticky columns,
implemented), column-sizing.md and OWNERSHIP-PRINCIPLES.md (binding).

Lawrence (verbatim): "make sure we have sticky/overlaid top/right/bottom in addition to left
column. so i kinda mean sticky row? just ensure sticky left/right is amazing for now, and
top/bottom can just be 'good' if we're confused on how to row/column should work... maybe it
should just be grid instead? idk, i want you to figure out how to design it in a cohesive way".

## Recommendation in one paragraph

Design A, the frame. A screen is a scrolling strip of columns (each column a vertical stack of
rows that may scroll, rows.md) inside a frame of four edge docks. The left and right docks are
today's sticky columns, unchanged. The top and bottom docks are sticky rows: screen-wide bands
that hold one split tree. Every dock is either pinned (it takes space: the strip ends at its
inner edge) or overlay (it floats: the strip keeps its size, gets an inset at that edge so
nothing is covered at rest, and its content scrolls under the dock). Each screen has a frame
orientation (decision L2): column-major, where the side docks run the full height and the top
and bottom docks sit between them, or row-major, where the top and bottom docks run the full
width and the side docks sit between them. There is no 2D grid. A dock is stored as a column
with a `pin {edge, mode}`, so one record type, one reducer path and one set of invariants cover
columns, rows, all four edges and both orientations.

## Vocabulary

| Word | Meaning |
| --- | --- |
| strip | the horizontally scrolling list of unpinned columns |
| column | a vertical band of the strip; a vertical stack of rows (rows.md) |
| row | a horizontal band of a column; holds one split tree |
| dock | a column pinned to a screen edge: left, right, top or bottom; at most one per edge |
| pinned | dock mode that takes space from the strip (code and wire name today: `docked`) |
| overlay | dock mode that floats over the strip; the strip gets an inset at that edge |
| frame | the four docks around the strip |
| orientation | per screen: `column_major` (side docks own the corners) or `row_major` (top/bottom docks own the corners) |

## Designs compared

- A, the frame: column strip, per-column row stacks, four edge docks.
- B, the grid: a 2D grid of cells that scrolls on both axes, with sticky first and last rows
  and columns (frozen panes).
- C, stacked strips: workspace-level rows, each row its own horizontal strip of columns
  inside one screen; a top or bottom sticky row is a pinned strip.
- D, recursive containers (considered): a general container tree where any container may scroll on
  either axis and any container may be pinned.

| Question | A frame | B grid | C stacked strips | D recursive |
| --- | --- | --- | --- | --- |
| Every container non-empty (I3) | holds | breaks: a cell row needs a pane in every column, or holes become first-class empty cells | holds | holds |
| New Column | after the focused column, scrolls horizontally | adds a cell to every row (N terminals or holes) | inside the focused strip only | anywhere; rules per container |
| New Row | below the focused row in its column (rows.md) | adds a cell to every column (N terminals or holes) | a new screen-wide strip; every column scrolls away | anywhere |
| Sticky left and right | today's sticky columns, unchanged | frozen first/last column, also frozen per row: a sticky cell per row | per strip (scrolls away with its strip) or global (breaks the model) | any container |
| Sticky top and bottom | screen-wide docks | frozen first/last row aligned to columns | a pinned strip | any container |
| Alignment | columns independent; rows independent per column | perfect | columns align inside a strip | none |
| Resize | column width, row height per column, dock extent | a column resizes every row's cell; a row resizes every column's cell | per strip | per container |
| Client scroll state | strip x, y per column with overflowing rows | one x and one y | y, plus x per strip | one offset per scrolling container |
| Overlap with screens | none | some | high: full-height strips are screens stacked | some |
| Change to today's code | add top/bottom to the sticky edge set; rows.md | new model; sticky columns and rows replaced | sticky columns move under strips | new model; every rule rewritten |
| Old clients | see a dock as an ordinary column | cannot render | lossy | cannot render |
| Model checking | small state (bounded edges, flat lists) | holes multiply states | moderate | unbounded nesting |

Strongest objection to each:

- A: a top or bottom dock does not scroll with the strip, so it cannot line up with columns. A
  terminal pinned above its own column ("a header per column") is not a top dock. Answer:
  per-column sticky rows, reserved in rows.md, cover that later without a new model; the common
  top/bottom case (logs, an agent, a monitor across the screen) is a screen-wide band.
- B: alignment is the point of a grid, and alignment forces holes. A new row needs a pane in
  every column (one command spawning N terminals) or empty cells that are dead areas the user
  closes by hand, and either breaks "every container non-empty". Resizing one terminal's height
  resizes the whole row. The prototype shows the holes.
- C: a full-height strip is a screen, which cmux already has. New Row moves every column off
  screen. Left and right sticky columns become either per strip (they scroll away vertically) or
  global (no longer part of any strip), so sticky left/right gets worse, the one thing that must
  be excellent.
- D: everything is possible, so focus, scroll, reveal and drop rules have no fixed shape. The
  model cannot be checked at useful bounds, and old clients cannot render it.

Choice: A. It keeps sticky left/right exactly as implemented (excellent today), adds top/bottom
as the same concept on the other axis, and adds one field value instead of a new model.

## Model (A)

```
Screen { orientation: column_major | row_major, columns: [Column] }  // strip order; docks are columns with a pin
Column { id, extent_permille, pin?: Pin, rows: [Row] }  // extent: width (strip, left, right) or height (top, bottom)
Pin    { edge: left | right | top | bottom, mode: pinned | overlay }
Row    { id, height_permille, root: SplitTree }   // rows.md
```

Invariants (on top of layout-invariants.md I1 to I4 and rows.md R1 to R6):

| Id | Invariant |
| --- | --- |
| E1 | At most one dock per edge. Pinning a column to an edge that has a dock unpins the old one in the same commit (today's sticky rule, four edges). |
| E2 | At least one strip column. A removal that leaves only docks unpins them all in the same commit (today's normalize, four edges). |
| E3 | A top or bottom dock holds exactly one row; its split tree fits the band and never scrolls (v1). |
| E4 | Left and right docks may hold several rows and scroll them vertically (rows.md G5). |
| E5 | Dock extents are permille of the viewport's width (left, right) or height (top, bottom), 100..=1000 in the store; each client clamps to its own maximum share. The store never sees a viewport. |
| E6 | Docks keep their place in the column list, so an old client renders a dock as an ordinary column with every pane. |
| E7 | Orientation changes only which docks own the corners and what each dock's length is measured against; it never changes membership, order, extents or any other field. Every op, focus and drop rule is the same in both orientations. |

Ownership: pins, extents and dock membership are workspace-store layout state written only
through typed ops validated by the pure reducer. Which dock a client shows collapsed (none in
v1), scroll offsets and focus are client view state.

## Geometry (client)

- F1. Placement order follows the screen's orientation (decision L2). Column-major (default):
  left and right docks first, full height; top and bottom docks span between their inner edges
  (pinned) or under overlay side docks; rows of the strip live in the space between the side
  docks. Row-major: top and bottom docks first, full width; left and right docks span between
  their inner edges; the strip's columns live in the space between the top and bottom docks.
  The strip takes the rest in both. A dock's extent (width for left/right, height for
  top/bottom) is the same share in both orientations; only its length changes.
- F2. Pinned: the strip's viewport ends at the dock's inner edge. Overlay: the strip keeps the
  full extent on that axis and gets an inset of the dock plus a gap at that edge; at rest
  nothing is covered. Left/right: today's S3/S4 unchanged. Top/bottom: every column's rows lay
  out above (or below) the inset; a column whose rows overflow (rows.md G2) scrolls them under
  the overlay.
- F3. Shares: left/right as today (3/4, 2/5 each with both). Top/bottom at most 1/2 of the
  height, 1/3 each with both; at least the band's minimum pane height. These are client
  viewport math in both orientations; the store holds only permille (E5).
- F1a. Orientation is an explicit input of the pure placement function, and F1, F3 and F4 are
  tested in both orientations.
- F4. Stacking: strip panes, strip dividers, then the docks that do not own the corners, then
  the docks that do (column-major: top/bottom below left/right; row-major: left/right below
  top/bottom), then scrollbars. The strip scrollbar sits at the bottom of the strip's uncovered
  area, so a pinned or overlay bottom dock moves it up (today it uses the view's height). The
  row scrollbar (rows.md V5) sits inside its column's frame, never under a right dock.
- F5. What a dock covers, from its inner edge (or its overlay rim's outer edge) out to the
  window edge, takes no clicks or drops for the strip (sticky-column.md D2, four edges). In the
  clip mask the strip stays visible under an overlay's glass rim and is clipped beyond it, on
  both axes.
- F6. Reveal needs the scroll reducer, not only geometry: `ColumnStrip` and the vertical row
  strip carry the uncovered range (leading and trailing insets), and the reveal (column scroll
  rule F1) and the snap points use it. This closes sticky-column.md's known overlay gap for
  left/right and gives top/bottom overlays their vertical reveal.

## Ops (variants of the one LayoutOp set)

| Op | Effect | Rejects |
| --- | --- | --- |
| `SetPin { column, pin: Option<Pin> }` | pins or unpins a column in place (generalizes `set-column-sticky` to four edges); E1, E2 in the same commit | top/bottom on a column with more than one row (`dock-needs-one-row`); last strip column (`last-scrolling-column`) |
| `PinRow { row, edge: top \| bottom, mode, new_column, extent_permille }` | "Make Row Sticky Top/Bottom": lifts one row out of its column into a new dock column; an emptied source column is removed (and normalized) in the same commit | left/right edge; the pin would not survive normalization (the row is the only row of the last strip column), which TLC found as an op that only churns ids |
| `MoveTab { tab, to: Destination::Dock { edge, mode, new_column, new_row, new_pane, extent_permille } }` | a dropped or moved tab opens the dock on that edge (or joins its pane when the dock exists: `Destination::Pane`) | dock exists on that edge (the resolver names its pane instead) |
| `UnpinDock { column, after_column }` | a dock becomes a strip column after `after_column` (the client resolves it; focus is client state) | last dock never rejects; unknown column |
| `SetExtent { column, extent_permille }` | resize a strip column or a dock (generalizes `set-viewport-pane-width`) | out of range |
| `SetOrientation { screen, orientation }` | switches the frame between column-major and row-major (E7) | unknown screen; no-op when unchanged |

Every op carries a client-chosen idempotency key and caller-chosen ids for new entities, is
validated by `cmux-layout-reducer`, and ends with `request-settled`. Destructive policy (removing
an emptied column or dock, unpinning on E2) is decided by the store in the same commit.

## Daemon, wire and storage

- Capability `edge-docks-v1`. Today `columns[].sticky {edge: left | right, mode}` and the
  stored `RegistryViewportColumn.sticky` use a closed enum with `deny_unknown_fields`, so a
  `top` value would break an older client's decode and an older binary's load. Top/bottom docks
  therefore go in a new optional field `columns[].dock {edge: top | bottom, mode}` on the wire
  and in the side table that rows.md adds (`resource_screen_rows` gains a per-column `dock`
  record), never in `sticky`. An older client and an older binary see an ordinary column.
- Left/right keep `sticky` unchanged; the reducer and the app read both into one `Pin`.
  `ColumnSticky` no longer denies unknown fields (b652fa6b2da), but `StickyEdge` and
  `StickyMode` are closed enums, so the separate `dock` field stays necessary.
- One reducer path: `SetPin` extends today's `reduce_column_sticky` / `apply_column_sticky`
  (cmux-tui `mux/sticky_columns.rs`) and `normalize_sticky_columns`
  (`model/layout_columns.rs`), never a parallel path; `SetPin` and `SetExtent` land in the
  v2 `column.update` reducer (`reduce_column_update`, branch feat-cmux-next-column-update-op)
  once it merges. `workspace.layout.apply` keeps a column's flag when its id survives, so the
  `apply-layout` refusal for top/bottom screens is a check there.
- Orientation is a screen field in the same side table (`resource_screen_rows` gains a screen
  record); an older binary ignores it and draws column-major, which only moves corners.
- Legacy writes on a screen with a top/bottom dock follow rows.md's table; `set-column-sticky`
  with left/right on a top/bottom dock re-pins it (E1); `apply-layout` refuses screens with
  top/bottom docks until blueprints carry pins.

## Focus and scroll (client view state; user-initiated only)

- K0. Focus after close picks only neighbors that are still in the closed pane's column after
  the change (TLC finding); a row lifted into a dock is no longer "above" it.
- K1. Cmd-Opt-arrows move geometrically across the frame with history (focus.md 4a): up from a
  strip column's top visible row goes to the top dock, down from the bottom to the bottom dock,
  left from the first visible strip column to the left dock (today). From the top dock, down
  goes to the most recently focused strip pane under it, else the one with the largest x
  overlap.
- K2. Reveal uses the uncovered area: a focused strip pane scrolls out from under an overlay dock
  on either axis (this also closes sticky-column.md's known gap for left/right overlays).
- K3. After a user-initiated move or drop into or out of a dock, the moved tab gets focus and is
  revealed; Option files it away. Automation (CLI, MCP, scripts, remote) never moves focus or
  scroll unless the op asks (`origin`, central check).
- K4. Docks never scroll horizontally; left/right docks scroll their rows vertically (E4) with
  their own client offset.

## Keyboard model

| Action | Default | Inside a dock |
| --- | --- | --- |
| Split Right / Down (Cmd-D, Cmd-Shift-D) | unchanged | splits inside the dock |
| New Column (Ctrl-Cmd-D) | after the focused column | from a left/right dock: a strip column at that end of the strip; from top/bottom: refused with a HUD |
| New Row (Ctrl-Cmd-Shift-D) | below the focused row | left/right dock: a row in the dock; top/bottom: refused (E3) |
| Make Column Sticky Left/Right, Unstick, Toggle Sticky Overlay | exist (no shortcut) | unchanged |
| Toggle Frame Orientation | new (palette, CLI `screen toggle-frame-orientation`, screen menu; no shortcut) | `SetOrientation` |
| Make Row Sticky Top / Bottom | new (no shortcut) | from a strip row: `PinRow` |
| Move Tab to Top/Bottom/Left/Right Dock | new (palette, CLI, tab menu) | `Destination::Dock` or the dock's pane |
| Focus Dock Top/Bottom/Left/Right | new (palette, CLI; no shortcut) | |

Every new action declares palette, CLI verb, right-click placement (column, row and tab menus)
and MCP, or a reasoned exemption.

## Drag and drop

- DD1. Each screen edge has a thin outer band (the drop edge band) that offers "Dock Top /
  Bottom / Left / Right" while that edge has no dock: `Destination::Dock`.
- DD2. Dock panes take drops like any pane (center and edges). An edge drop on a dock pane with no
  room joins the pane (sticky-column.md D1).
- DD3. What a dock covers takes no drop for the strip (F5).
- DD4. Dragging the last tab out of a dock removes the dock in the same commit.

## Mapping to today's structures

| Today | Change |
| --- | --- |
| app `LayoutColumn.sticky: StickyColumn {edge: left/right, mode}` | `StickyEdge` gains `top`, `bottom`; decode reads `sticky` and `dock` |
| app `StickyStripGeometry.partition/place` | partition by four edges; place side docks, then top/bottom bands (F1 to F3) |
| app `ScreenGeometry` (`stripMinX/stripWidth`, `clipMinX/MaxX`, `fixedPanes`) | adds the vertical strip range (`stripMinY/stripHeight`, `clipMinY/MaxY`) |
| daemon `ColumnSticky`, `normalize_sticky_columns`, `set-column-sticky` | four-edge `Pin`; normalize unchanged in shape; E3 check |
| reducer `Column` (rows.md: `rows`) | adds `pin: Option<Pin>`; ops above |

## Prototypes (DEV Debug Settings, "Panes and Columns" section)

Tunables `layout.prototype.model`: `off` (default) | `frameDocks` (A) | `grid` (B);
`layout.prototype.dockEdge`: `bottom` | `top`; `layout.prototype.orientation`: `columnMajor` |
`rowMajor`. View-only:
the geometry reinterprets the current screen, nothing is written to the store, and the switch
applies live.
- A, `frameDocks`: the right sticky column is drawn as a top or bottom dock
  (`layout.prototype.dockEdge`), pinned or overlay from its sticky mode, between the side docks.
- B, `grid`: each strip column's panes become grid cells by index; rows share one height across
  columns; a column with fewer panes shows holes.
Screenshots and recordings are listed in "Evidence".

## Ownership of the work

- Layout model lead: this proposal, the reducer ops, the daemon (`edge-docks-v1`, side table,
  `column.update` integration), the TLA+ model, the prototypes.
- App four-edge geometry (F1 to F6: `StickyStripGeometry`, `ScreenGeometry`,
  `ScreenContentView+Sticky` stacking, clip, hit testing and navigation frames,
  `DropZoneGeometry.target(atView:)`, scrollbar placement, the scroll reducer insets): a
  separate task for the sticky-column geometry owner, assigned by the coordinator after
  Lawrence picks the model.

## Evidence (2026-10-02)

- TLA+ (`formal/LayoutRows.tla`, `FRAME = TRUE`): docks on four edges, `PinRow`, orientation;
  invariants R1 to R6, E3, E7, view validity and focus locality pass at one client and two ops
  (595,522 states); three mutants fail. The runs found two gaps, both fixed in the rules:
  `PinRow` on the only row of the last strip column (now rejected) and a close-focus successor
  that followed a row lifted into a dock (candidates must stay in the closed pane's column).
  Details in formal/README.md. proptest waits for the reducer step.
- Geometry: `LayoutModelPrototypeTests` (7 tests) pin the frame in both orientations and both
  edges, docks drawn from plain columns, the grid's shared rows and holes, and off = real layout.
- Live build lmproto-v1 (fleet job a5dbd34f2414ad8ecd984564): the tunables switch live and the
  app stayed in the background (`app_active` false, no key window). The screenshots are not
  evidence of the design: the seed made two full-width columns, and the sticky view path places
  sticky panes by edge rather than by the geometry frame, so the band draws as a right column.
  Live rendering of the prototypes is UNVERIFIED until the view path reads the frame (part of
  the app geometry task above). No recordings were made.

## Verification plan

- TLA+: `formal/LayoutRows.tla` extended to four-edge pins (`SetPin`, `PinRow`, `UnpinDock`,
  `Destination::Dock`), invariants E1 to E3 plus rows.md's, mutants for each.
- proptest in `cmux-layout-reducer` once it lands: the same ops and invariants.
- Swift: geometry tests for F1 to F5 (corners, shares, insets), reveal under overlays (K2),
  drop bands (DD1).

## Steps

1. This proposal; prototypes A and B; TLA+ for A.
2. Reducer: `Pin` and the ops above (after the crate lands; rows step 2 adds rows in the same
   change set).
3. Daemon: `edge-docks-v1`, `dock` field, side-table record, E3.
4. App: four-edge geometry, top/bottom bands, reveal under overlays, drop bands.
5. Surfaces: actions above.

## Decisions for Lawrence

1. Model A, the frame (recommended), against B, the grid, or C, stacked strips.
2. Decided (L2): both orientations exist, per screen. Open: the default for new screens,
   column-major (recommended: left/right, the excellent pair, never shrink) or row-major; and
   whether Settings offers a default orientation (recommended: yes, `layout.frameOrientation`).
3. Top/bottom docks hold one split tree that fits (recommended for v1), or a horizontally
   scrolling strip of their own.
4. UI names "Pinned" and "Overlay" (recommended; the wire keeps `docked`), or keep "Docked".
5. Per-column sticky rows (a header pinned above its own column) later, or never.
