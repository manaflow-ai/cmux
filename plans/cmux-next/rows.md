# cmux next: rows (each column a vertical strip of rows)

Status: design 2026-10-01, not implemented. Owner: rows lead (branch `feat-cmux-next-rows`).
User request (2026-10-01, paraphrased): support rows in addition to columns, with D-based
chords for new columns and new rows; check whether the auto-layout pane chord (Cmd-Ctrl-N)
needs a new shortcut; keep ownership in Rust as for columns; design it to be cohesive.

Binding: OWNERSHIP-PRINCIPLES.md, layout-invariants.md, column-sizing.md, sticky-column.md,
column-scroll.md. Formal model: `formal/LayoutRows.tla`.

## Answer: Cmd-Ctrl-N needs no new shortcut

Cmd-Ctrl-N is New Pane (Auto Layout) (`newPaneAutoLayout`): it splits the focused pane along
its longer side, inside the pane's own column, and never opens a column. With rows it splits
inside the focused pane's row and never opens a row. It does not collide with any D chord, so
it keeps Cmd-Ctrl-N. The user is right: no new shortcut.

The chords then read as one table, where Shift means the vertical axis and Ctrl means "a new
scrolling unit instead of a split":

| Chord | Action | Scrolls |
| --- | --- | --- |
| Cmd-D | Split Right, inside the row | never |
| Cmd-Shift-D | Split Down, inside the row | never |
| Cmd-Ctrl-D | New Column, after the focused column | horizontally, to reveal it |
| Cmd-Ctrl-Shift-D | New Row, below the focused row, in the focused column | vertically, to reveal it |
| Cmd-Ctrl-N | New Pane (Auto Layout), inside the row | never |

New Column moved to Ctrl-Cmd-D in 5c009fc9cbc (it replaces macOS's system Look Up chord in cmux
windows). Cmd-Ctrl-Shift-D is reserved for New Row (user decision 2026-10-02, relayed by the
action-surfaces lead); Open Diff Viewer moves to Cmd-Ctrl-Shift-G, and
`BrowserTabTitleTests.cmdCtrlShiftDIsReservedForNewRow` keeps the chord for action id `newRow`.

## Options

| Question | (a) 2D grid, both axes scroll | (b) vertical list of rows, each a horizontal strip of columns | (c) horizontal strip of columns, each a vertical strip of rows |
| --- | --- | --- | --- |
| Shape | cell (r, c); columns share x boundaries across rows | screen > rows > columns > split tree | screen > columns > rows > split tree |
| Every container non-empty | breaks: a new row needs a cell in every column (N terminals for one command) or holes | holds | holds |
| New row | adds a band to every column | adds a screen-wide band; every column scrolls away | adds a band below the focused row in its column only |
| Matches Cmd-Shift-D (split down inside the column) | no | no: the new band spans other columns | yes: the scrolling form of Split Down |
| Sticky columns | undefined across rows | per row (scrolls away with the row) or screen-level (breaks the recursion) | unchanged; a sticky column scrolls its own rows |
| Overlap with screens | some | high: full-height rows are screens stacked vertically | none |
| Scroll state per client | 2 offsets | 1 vertical + 1 horizontal per row | 1 horizontal + 1 vertical per column |
| Existing code kept | little | the strip moves under rows; sticky and strip state multiply | the strip, sticky columns and the column scroll reducer unchanged; a level is added below the column |
| Old clients | cannot render | lossy (one row, or rows flattened into one strip) | exact panes: rows fold into a vertical split chain in `columns[].layout` |
| Alignment | perfect | columns in a row align | columns scroll vertically on their own; neighbors can show different rows |

## Choice: (c), columns of rows

A column is a vertical band of the screen's horizontal strip. A row is a horizontal band of its
column's vertical strip. The row is to the column what the column is to the screen: the same
column scroll rules, transposed. Today's column is exactly a column with one row of full height, so
nothing changes until a column gets a second row.

Strongest objection: a "row" in (c) is not a screen-wide band. Two columns scroll vertically on
their own, so the screen can look ragged (column A shows its first row while column B shows its
third), and a user who expects a row that spans every column gets bands per column.
Answer: screen-wide vertical stacking already exists as screens; a screen-wide band would make
the new-row command move every column off screen, which is the "make room by squashing or
hiding everything else" behavior that Ctrl chords exist to avoid. The ragged look is a view
choice: a later "align rows" view (all columns scroll vertically together) needs no data model
change because offsets are client view state. Second objection: vertical scrolling inside a
terminal belongs to scrollback, so rows cannot take plain vertical wheel events (section V5).

## Data model (workspace store)

```
Screen { columns: [Column] }                          // horizontal strip, unchanged
Column { id, width_permille, sticky?, rows: [Row] }    // rows non-empty
Row    { id, height_permille, root: SplitTree, creation_order_auto_layout? }  // id never reused
SplitTree = Leaf(pane) | Split { id, dir, ratio_permille, a, b } | Stack { panes, expanded }
```

Columns mode holds while the screen has two or more columns, or one column with two or more
rows. A screen with one column and one row is a split tree, as today
(`Screen::collapse_single_layout_column`, model.rs). New Row on a split screen turns its tree
into one column with two rows (the tree becomes the first row, as `MoveTabToColumn.base_column`
does for columns). A removal that leaves one column with one row collapses to a split tree; one
column with two or more rows stays in columns mode. Daemon change: the collapse, the projection
check (`layout_column_projection_is_consistent`) and `validate_registry_viewport` accept one
column when it has two or more rows (today all three require two columns).

Invariants (added to layout-invariants.md I1 to I4 and checked by the reducer, proptest, TLC
and `debug.desync` in debug builds):

| Id | Invariant |
| --- | --- |
| R1 | Every pane is in exactly one row; every row is in exactly one column; every column in exactly one screen. |
| R2 | No empty containers: a pane has a tab, a row has a pane, a column has a row. A container that empties is removed in the same commit, bottom up (pane, row, column, screen). |
| R3 | Tab conservation (I1) holds for every row op; a row op that spawns a terminal adds exactly its one new tab. |
| R4 | `height_permille` and `width_permille` in 100..=1000. Row heights are the vertical twin of column widths: their sum per column is not fixed (at most 1000 fills, above scrolls, G2), so no remainder rule applies to them; `SetRowHeights` with `fit: true` (Equalize Rows, `fitScreen`) writes heights that sum to exactly 1000, the last row taking the remainder. Split ratios in a row sum to 1000 (column-sizing.md), checked once the reducer models ratios (a later reducer step). |
| R4b | Row, pane and column ids are never reused (the reducer refuses an id it has seen, `IdInUse`). |
| R4c | Units: `height_permille` is an integer in the store and on the wire. Column widths and split ratios stay `f32` in the daemon until the reducer models them (column-sizing.md wants permille there too). |
| R5 | Sticky consistency (sticky-column.md) holds after every row op, including a column removed because its last row emptied (`normalize_sticky_columns` in the same commit). Reserved for sticky rows: the same rules per column, and normalize clears row stickiness when only sticky rows remain. |
| R6 | Own place (I4): a new-row move without respawn whose result equals the current layout modulo fresh ids (same heights, same tabs) is no operation. Respawn never makes an op own place: Row, Split and Column with respawn always apply (the moved tab leaves, a new tab of the same kind stays); respawn onto `Pane{own pane}` is a reject. |
| R7 | The store never reads client view state: every op names its anchor (pane, column or row) and its size in permille. |

## Ownership

| State | Owner (role) | Written by | Persisted |
| --- | --- | --- | --- |
| rows, row order, `height_permille`, row split trees | workspace store | typed ops through `cmux-layout-reducer` | store (`resource_screens.viewport_json`), journal, layout undo |
| vertical offset per column, horizontal strip offset, focused pane, remembered pane per row | client (view state) | that client's scroll and focus reducers | no (memory, as the strip offset today) |
| divider drag between rows | client gesture | local until release; release sends one `SetRowHeights` intent | no |
| terminal grid size of a pane in a row | session host | viewport reports (smallest attached viewer) | memory |

No client keeps an optimistic copy: the app sends the intent through the intent log (ownership
step 4) and draws mirror + intents. Offscreen rows keep their layout height, so a row scrolled
out of view never resizes its terminals.

## Ops (reducer, store, protocol)

New `LayoutOpKind` variants in `cmux-layout-reducer` (no parallel path; ids of new entities are
caller-chosen, as for every op there):

| Op | Effect | Rejects |
| --- | --- | --- |
| `InsertRow { after_pane, height_permille, new_row, new_pane, new_tab, content: {host, terminal}, base_column }` | new row below `after_pane`'s row in its column, with one pane holding one new tab that references an existing terminal; the reducer never creates a terminal | unknown pane, height out of range, id in use, content already placed |
| `MoveTabToRow { tab, anchor, after_row: Option<RowId>, height_permille, new_row, new_pane, base_column }` | tab into a new row of `anchor`'s column (default: after `anchor`'s row; `None` with `before: true` for the top) | own place is `Ok` with no events (R6) |
| `SetRowHeights { column, heights: [(row, permille)], fit }` | sets every row height of one column at once (divider release, Equalize Rows); `fit` requires the sum to be 1000 | row set differs from the column's rows, height out of range, `fit` sum is not 1000 |
| `ClosePane { pane, sizing }` (column-sizing.md) | gains the row cascade (pane, row, column, sticky normalize), decided by the store in the same commit | |

These are variants of the one `LayoutOp` set of column-sizing.md (`Split`, `InsertColumn`,
`ClosePane`), never a parallel path. Agreed with the reducer owner: tab moves take one
`Destination = Pane{pane, index} | Split{pane, edge} | Column{anchor, after} | Row{anchor,
after} | NewWorkspace{..} | Workspace{..}` with `respawn: Option<NewTab>` (the spawn-same-kind
case: the source pane keeps a new tab of the moved tab's kind), and the existing `MoveTab*` ops
stay as thin constructors. `MoveTabToRow` above is `Destination::Row`; rows add no own-place or
spawn rule code. With respawn, conservation is "tabs after = tabs before + the respawned tab".
The drop resolver (`TabDragResolver`, pure, app) decides the destination (D2); the reducer only
validates it.

Terminal creation (ownership lead): today the `new-row` command creates the terminal and then
applies `InsertRow` with its id, one idempotency key and one `request-settled` for both. After the
session host / store split, the host creates the terminal detached and kept
(`create-terminal {detached: true}`, federation branch), the store places it with `InsertRow`,
and a rejected placement leaves a kept unplaced terminal that is reaped after the grace period.

Focus after close is client-only (close-focus lead; ownership lead decision 2026-10-01): the
client has the projected layout before and after the close, so `ClosePane` returns no neighbor
hint, for rows and for columns (column-sizing.md drops it too). Row heights store values only;
how a client fills its viewport (G2) is client rendering (ownership lead).

Reducer events: `RowCreated {row, column, index}`, `RowRemoved {row}`, `RowsResized {column}`,
plus the existing pane, column and screen events.

Daemon (cmux-tui) under capability `rows-v1`:

- Commands (legacy line protocol, each runs the reducer on a copy before commit and rejects
  with `layout-conservation-violation`): `new-row {pane, height_permille, cwd?, shell_args?,
  transaction}`, `move-tab-to-row {tab, anchor_pane, after_row?, before?, height_permille,
  transaction}` (tab-drag-v1 family), `set-row-heights {column, heights, transaction}`
  (coalesced like `set-viewport-pane-width`).
- v2 state ops (PR 16174's `cmux-tui-core::state`, idempotency key required): `pane.new_row`,
  `tab.move {to: {row: ...}}`, `column.set_row_heights`. Every event carries the request's
  transaction and the request ends with `request-settled` (mutation-echo-v1).
- Read shape: `columns[] {id, width, sticky?, layout, rows: [{id, height, layout}]}`. `layout`
  stays the compat projection: the rows folded into a vertical split chain whose split ids are
  the ids of rows 2..n and whose ratios follow the heights. A client without `rows-v1` sees every
  pane (squashed to the column height); a resize of a synthetic split is refused with
  `row-split-compat-readonly`. Every legacy write an old client can send on a screen with rows
  maps to a row-valid op or is refused with a typed reason (table "Legacy writes"), and a daemon
  proptest interleaves those legacy commands with row ops under the conservation check.
- Storage: `RegistryViewportColumn` and `RegistryViewport` use `deny_unknown_fields`, so a
  `rows` field inside `viewport_json` would make an older binary fail to load the screen. Rows
  go into their own table instead (own `CREATE TABLE IF NOT EXISTS`, like `kept_tabs`):
  `resource_screen_rows(screen_id, column_id, position, row_id, height_permille, layout_json,
  auto_layout_json)`, written in the same transaction as the screen. `viewport_json` keeps its
  shape, and each column's `layout` there is the compat chain. The rows table is authoritative;
  load rebuilds the chain from the rows and uses the rows only when it equals the stored
  `layout`, else it drops the column's row records (an older binary rewrote the screen) and
  loads the stored `layout` as one row. Row ids are allocated as split ids and registered as
  split resource identities, because the chain uses them as split ids and tombstoning and
  validation collect split ids. A column with one row of 1000 writes no row record.
  An id that only the rows table names (row 1, and the column of one column with rows, whose
  `viewport_json` stays empty) is parked: registered as a split identity, tombstoned in
  `resource_identities` (an older build requires the live split identities to equal the splits
  of `layout_json` and `viewport_json`), and flagged with its screen in
  `resource_parked_splits`. Only a flagged id is revived, when it enters its screen's projection
  again (a second column joins), so the column keeps its id; an id that leaves its screen loses
  the flag and its tombstone is final (R4b). Registry open parks side-table ids that have no
  identity yet (one-time repair for records of the first `rows-v1` build). The only column
  fills the screen width (1.0).
- Rollback: an older binary ignores the table and loads every pane from the compat chain as
  vertical splits: tab-safe but layout-lossy. If it writes the screen, a re-upgrade sees the
  mismatch and keeps the vertical splits as one row; the rows are gone.
- Legacy writes on a screen with rows (clients without `rows-v1`):

  | Command (cmux-tui `Command`) | Mapping |
  | --- | --- |
  | `split`, `new-pane`, `new-tab`, `new-browser-tab`, `new-frontend-browser-tab`, `run` with `pane`, `create-surface-with-receipt` split modes `split-right` / `split-down` | `Split` inside that pane's row tree, or a tab in that pane |
  | `new-pane-right`, `create-surface-with-receipt` mode `new-pane-right`, `move-tab-to-column`, `move-tab-group-to-column` | `InsertColumn` / `Destination::Column` (the new column has one row) |
  | `close-pane`, `close-surface`, `close-tabs`, `close-terminal`, `close-tab-group`, last tab exit | `ClosePane` / `CloseTab` with the row cascade |
  | `move-tab`, `move-terminal`, `move-tab-group`, `move-tab-to-split`, `move-tab-group-to-split` | `Destination::Pane` / `Destination::Split` inside the target row |
  | `move-tab-to-workspace`, `move-tab-to-new-workspace`, `move-tab-group-to-new-workspace` | unchanged; the source row cascades if it empties |
  | `reopen-saved-tab-group`, `create-terminal` when it places a tab | the tab or group goes into the named pane's row; detached creation places nothing |
  | `close-screen`, `new-screen` | unchanged (whole screens) |
  | `swap-pane` | allowed when both panes are live; swaps leaves across rows (rows keep their heights) |
  | `zoom-pane` | allowed; zoom is per screen and shows the pane over every row |
  | `set-ratio`, `set-split-ratio` on a real split inside a row | allowed |
  | `set-ratio`, `set-split-ratio` on a synthetic (row) split | refused, `row-split-compat-readonly` |
  | `set-viewport-pane-width`, `set-column-sticky` | allowed (column fields) |
  | `undo-layout` | allowed; snapshots carry rows, so undo restores rows even for an old client |
  | `apply-layout` with a `columns[].layout` tree (blueprints) | refused on a screen with rows, `rows-layout-replace-unsupported`, until layouts carry rows; `export-layout` exports rows only with `rows-v1` |
  | v2 state ops of PR 16174 (`pane.split`, `tab.move`, and the rest) | the same mapping through `Destination`; a v2 op that names a synthetic split is refused the same way |

- Undo: `ScreenLayoutSnapshot` holds the columns with their rows, so `undo-layout` covers rows.
- Model change in `model.rs`: `LayoutColumn.root` becomes `rows: Vec<LayoutRow>` (non-empty by
  construction, like `StackPanes`); `creation_order_auto_layout` moves to the row. `Screen::root` stays
  the compat projection for split-tree consumers. The TUI frontend renders rows as a vertical
  chain that fits the height until it gets row scrolling (step 6).

## Geometry

- G1. A row's height is a share of the column's viewport height, with gaps only between rows:
  `(height + gap) * p - gap`, so a row of 1000 is exactly today's column and two rows of 500 plus
  their gap fill it (decision, coordinator, 2026-10-04; it replaces `(view - gap) * p - gap`, which
  counted gaps above and below the column).
- G2. Fill under, scroll over: when a column's heights sum to at most 1000, its rows fill the
  column in proportion (as stacked panes fill a column today); above 1000 the rows keep their
  heights and the column scrolls vertically. One full-height row is today's column.
- G3. New Row height: `layout.newRowHeight` = `matchCurrent` (default: the focused row's stored
  height, so a full-height row gives a full-height new row) | `fitScreen` (the column's rows
  are made equal so all fit) | a fraction. Mirrors `layout.newColumnWidth`. A fit (`fitScreen`,
  Equalize Rows) needs every row at 100‰ or more, so it is refused with `rows-fit-too-many`
  when the column would have more than 10 rows.
- G4. The reducer enforces only the fixed 100‰ floor (the store never sees a screen). Each
  client converts its own `layout.minimumPaneHeight` (points) to
  `max(100, minimumPaneHeight x stacked panes / its column height)` and refuses locally with
  the RefusalHUD, as `SplitRoom` refuses splits today.
- G5. Sticky columns hold rows like any column and scroll them vertically on their own, with
  their own client vertical offset. The app keeps sticky panes in fixed view coordinates today
  (`ScreenGeometry.fixedPanes`, `DropZoneGeometry.target(atView:)`, `ScreenContentView.hitTest`,
  `navigationFrames`); these apply a sticky column's vertical offset the way `stripShift`
  applies the strip's. Docked and overlay covers stay full height. Sticky
  rows (a row pinned to its column's top or bottom edge, same rules as sticky columns) are not
  in `rows-v1`; the field name `sticky` on rows is reserved.

## Viewport (client view state; column scroll rules on the vertical axis)

The column scroll reducer (`ColumnScrollState.reduce`, the column scroll plan) becomes axis-generic
(`StripScrollState<Axis>`): the horizontal strip uses it as today, and each column with more
than 1000‰ of rows, sticky columns included, gets its own vertical instance keyed by column id.
`ColumnViewOffset.fit` keeps its semantics (stay if visible, else the nearer edge) so the
close-focus lead's strip model check stays valid. The close-focus lead's `ListViewport<ID>`
(one-axis anchor, minimal reveal, clamp; landed 7a9a7e573c1..6553984ff79 in
`CmuxNextDesign/CloseFocus`, with `FocusAfterClose` and `FocusTopology.screens`) is reused for
the row axis; the app step builds on 6553984ff79 or later.

- V1. Reveal (column scroll rules F1 to F7, transposed): the focused row plus padding fully visible means no
  motion; otherwise align the edge that needs less motion; `layout.centerFocusedRow` mirrors
  `layout.centerFocusedColumn` (default `never`).
- V2. Camera anchor (L1 to L7 transposed): inserting, removing or resizing a row keeps the
  focused row's on-screen y; closing the bottom row springs back without a jump; closing the
  focused row reveals its successor with V1.
- V3. New Row is the only command that scrolls vertically (as New Column is the only creating
  command that scrolls horizontally). Splits never scroll.
- V4. A horizontal scroll moves the strip; the vertical offsets of the columns stay.
- V5. Input: a plain vertical wheel or trackpad scroll over a pane goes to the terminal
  (scrollback, mouse reporting) as today. Rows scroll with the vertical gesture when it is over a
  gap between rows or over the column's row scrollbar, or anywhere in the column while
  `layout.rowScrollModifier` (default Command) is held. A column whose rows overflow (sticky or
  not) gets a vertical row scrollbar on its trailing edge, new UI that follows B1 to B5 of
  sticky-column.md on the vertical axis with its own setting `layout.rowScrollbar`: `auto`
  (default, fades in while the column scrolls or the pointer is over the band), `always` (while
  the rows overflow), `off`.
- V6. Multi-client: every client keeps its own offsets and may show different rows of the same
  column; the canonical terminal grid stays the session host's (smallest attached viewer).

## Focus and navigation (client)

- N1. Cmd-Opt-Up/Down: `FocusNavigation.neighbor` over on-screen frames inside the column, then
  across the row boundary to the adjacent row (most recently focused pane that overlaps on x,
  else largest overlap), revealing it with V1. No wrap, as today.
- N2. Cmd-Opt-Left/Right into another column: that column's most recently focused pane if it is
  in a visible row, else the geometric choice among the target column's visible rows; the target
  column does not scroll vertically unless nothing in it is visible.
- N3. Focus after close (`layout.closeFocus`, focus-after-close lead): previous pane in the row,
  else the next pane in the row, else the row above, else the row below, else the column's first
  pane, else the column to the left, else the first column. The client computes it
  from its projected layout before and after the close: `FocusAfterClose.pane` gains one nesting
  level (columns of rows of panes instead of columns of panes). `mostRecent` uses the screen's
  history unchanged; the reveal brings a scrolled-out row back.
- N4. History (focus.md 4a) unchanged: the screen's history covers panes in every row.

## Drag and drop

- D1. Drop targets: the gap between two rows and the band at a column's top or bottom edge give
  `TabDragOutcome.newRow(column, after:)` and send `move-tab-to-row`.
- D2. A top or bottom pane-edge drop with no room opens a row (axis rule); a left or right edge
  drop with no room still opens a column.
- D3. Own place (R6): dropping a pane's only tab, when the pane is its row's only pane, on that
  row's own boundaries is no operation, unless it is the spawn-same-kind variant, which keeps a
  new tab of the same kind in the source pane.
- D4. Dragging the last pane out of a row removes the row in the same commit; the last row out of
  a column removes the column (and normalizes sticky, sticky-column.md D3).
- D5. Drag autoscroll: near the top or bottom of a column with overflowing rows, the column
  scrolls vertically during the drag (gesture state, not an intent).

## Resize

- Z1. The divider between two rows follows the pointer: under G2 fill mode it trades height
  between the two rows; in scroll mode it changes the upper row only. The release sends one
  `SetRowHeights` for the column.
- Z2. Resize Pane Up/Down (Ctrl-Shift-K/J) at a row boundary changes the row height by the same
  step as a column edge.
- Z3. Equalize Splits (Ctrl-Shift-Cmd-=) also equalizes the focused column's rows when they fit
  (sum at most 1000); otherwise only the splits.

## Off switch (`layout.rows`)

Requirement (Lawrence): rows must be easy to turn off without affecting anything else.

- O1. Setting `layout.rows`: `true` (default, for dogfood) | `false`, in Settings (General >
  Columns), cmux.json and the palette (Toggle Rows). A test checks the default in the parser,
  the schema and the settings window, like the other layout defaults. It is client
  preference (config layer); the store and the daemon never read it.
- O2. Off hides every row entry point: `newRow` (shortcut, palette, menus, CLI answers
  `rows-disabled`), the new-row drop targets (D1), the row axis of D2 (a top or bottom edge
  drop with no room opens a column, as today), row scrolling (V5) and the row scrollbar.
  Cmd-Ctrl-Shift-D does nothing (it stays reserved for `newRow`).
- O3. Off, a column that already has two or more rows renders its rows as stacked panes that
  fit the column (heights in proportion, never scrolling), the same picture as the compat chain.
  The divider between two rows trades height between them (`SetRowHeights` with `fit`). Splits,
  closes, moves and focus work on the panes inside as on any stacked panes. Nothing flattens on
  its own: Flatten Rows (`column flatten-rows`, palette and column menu, shown in both modes) is
  the only path that folds rows into one row's vertical splits, through a reducer op
  `FlattenRows {column}` (conserves tabs and panes; row heights become split ratios).
- O4. With no column holding two or more rows, off and on behave the same: layout, sticky
  columns, close, focus, scrolling, drops and the wire are unchanged from today, because a
  column with one full-height row is today's column (G2) and no row op is ever sent while off.
  Tests: the column geometry, scroll, drop resolver and focus-after-close suites run with
  `layout.rows` off and on over layouts without rows and must give identical results.
- O5. A client may ignore `rows-v1` completely (older apps, the TUI, iOS): it reads the compat
  chain (step 3). An off client still decodes `rows` so it can draw O3 and refuse writes to
  synthetic splits correctly.

## Surfaces (action-surface rule)

| Action id | Title | Shortcut | Palette | CLI verb | Context menu | MCP |
| --- | --- | --- | --- | --- | --- | --- |
| `newRow` | New Row | Cmd-Ctrl-Shift-D | yes | `pane new-row` (`--height`, `--cwd`) | pane > create, after New Column | generated |
| `equalizeRows` | Equalize Rows | none | yes | `column equalize-rows` | column | generated |
| `flattenRows` | Flatten Rows | none | yes | `column flatten-rows` | column | generated |
| `layout.rows` toggle | Toggle Rows | none | yes | `settings toggle-rows` | none (exemption: setting) | generated |
| `centerFocusedRow` | Center Focused Row | none | yes | `pane center-row` | none (exemption: view command) | generated |
| `layout.centerFocusedRow.*` | Row centering modes | none | yes | `settings ...` | none (exemption: setting) | generated |

CLI verbs go to session feat-cmux-next-99 (Swift CLI freeze). `debug.rows` reports row frames,
offsets and scrollbars. All actions are disabled with the daemon's reason until the bundled
cmux-tui serves `rows-v1`; the capability lands in `optional` with its daemon half
(scripts/cmux-next/check-daemon-capabilities.sh fails a build whose daemon lacks it).

## Verification

- TLA+ `formal/LayoutRows.tla` (`formal/run-rows-tlc.sh`): owner structure (columns, rows,
  panes, tabs, heights, sticky), every row op plus split, new column, moves, close, clients
  choosing ops from stale mirrors, replay of a key, client view repair. Invariants R1 to R5, I1,
  R6 soundness, exactly-once, view validity, N3 locality; action property R6 completeness.
  TLC 2026-10-02: one client with three ops passes (22,804,256 distinct states, depth 12); two clients with two ops pass (6,793,112 distinct states, depth
  14); three columns with both outer columns sticky pass (1,508,296, depth 11); seven mutants
  each fail (emptied row kept, sticky not normalized, own place missing the boundary above, no
  dedup, focus not repaired, focus repair skipping rows, respawn dropping the moved tab).
  Details in formal/README.md.
- proptest in `cmux-layout-reducer`: random sequences that include the row ops, invariants R1 to
  R5 and idempotent replay; daemon sequences that compare the reducer with the live result.
- Swift: seeded property tests for the drop resolver with rows, the vertical strip reducer (column scroll
  tests transposed), geometry G1 to G4, decode of `rows` and the compat chain.
- Live (tagged no-activate build, screenshots): New Row reveal, row scroll with the modifier,
  drop between rows, close of the last pane of a row, rows inside a sticky column, an old app
  against a `rows-v1` daemon.

## Step 2 status (2026-10-02)

Reducer rows are implemented on branch `feat-cmux-next-layoutmodel` (5188b2e4f21, review
fixes 4da1547bf3e): `Column.rows` partitions the column's ordered panes into consecutive runs
(`Row { id, height_permille, len }`; empty = one implicit row, so the daemon projection and
every existing op are unchanged); ops `InsertRow` (refuses content already placed),
`MoveTabToRow` (respawn; own place per R6), `SetRowHeights` (stale row set refused, `fit` sums
to 1000), `FlattenRows`; invariant `Violation::RowLayout`. 23 crate tests including a property
test (5000 cases on nx-remote) pass, fmt and clippy are clean. Not landed: the hosted cmux-tui
verification could not be dispatched (GitHub API 403 on 2026-10-02 22:41 UTC); it lands when
that run is green. `Destination::Row` is `MoveTabToRow` (no Destination enum exists yet).

## Step 4 status (2026-10-04)

App half on branch `feat-cmux-next-rows-app`. Done: decode of `columns[].rows` and `rows-v1` in
`DaemonCapabilities.optional`; `LayoutColumn.rows` (the column's `root` stays the compat chain for
pane queries; split queries use the row trees); geometry G1 with gaps only between rows
(`(height + gap) * p - gap`, so a row of 1000 is today's column) and G2; rendering; a vertical
offset per overflowing column through the column scroll reducer behind the `RowScroll` adapter
(opaque strip slots, no row id in a column id); V5 input (gaps between rows, or Command); row
divider resize as one `set-row-heights` with a transaction through the store's intent log, settled
on the `screen-changed` echo; `layout.rows` in cmux.json, the Settings window, the settings schema
and the MDM export; New Row (Cmd-Ctrl-Shift-D, palette, View menu, `pane new-row`, MCP, pane
context menu New folder); no row op without `rows-v1`.

Left for a later step: Toggle Rows (palette), the row scrollbar and `layout.rowScrollbar`, Equalize
Rows (Z3) and Resize Pane Up/Down at a row edge (Z2), `layout.centerFocusedRow` (the reducer runs
with `never`), focus N1 to N3, `debug.rows`, `--height` and `--cwd` on `pane new-row` and its
`rows-disabled` code, row drop targets (D1 to D5), and a live tagged-build check.

## Steps (each lands alone; feat-cmux-next stays shippable)

1. This note, TLA+ model with TLC numbers.
2. Reducer: rows in the model, the row ops, proptest (on the reducer crate after its first
   landing, coordinated with its owner).
3. Daemon: `LayoutColumn.rows`, storage and compat projection, commands, `rows-v1`, journal and
   undo, through the reducer check; hosted verification green.
4. App: decode, `LayoutColumn.rows`, geometry, rendering, axis-generic strip reducer, row
   scrollbar, capability gating (no row op is sent to a daemon without `rows-v1`).
5. Surfaces: actions, drops, menus, palette, CLI request, `debug.rows`, settings.
6. cmux-tui TUI rendering of rows (scrolling).

## Decisions (Lawrence, 2026-10-02, through the coordinator)

1. Model (c), columns of rows: approved, with the off switch below as a hard requirement.
2. New Row is Cmd-Ctrl-Shift-D; Open Diff Viewer moves to Cmd-Ctrl-Shift-G.
3. Row scroll modifier: Command, plus plain scroll over the gaps between rows and on the row
   scrollbar (V5).
4. Sticky rows: decided later, not in `rows-v1`.
5. Legacy `apply-layout` (blueprints) on a screen with rows is refused
   (`rows-layout-replace-unsupported`) until blueprints carry rows.

## Agent review (2026-10-01)

| Reviewer | Objection | Resolution |
| --- | --- | --- |
| ownership lead | compat chain only if every legacy write maps or is refused with a type, with a proptest | table "Legacy writes"; daemon proptest in step 3 |
| ownership lead | the reducer must not create terminals | `InsertRow` takes `{host, terminal}`; today's command creates then places under one key |
| ownership lead | ids never reused; heights sum to 1000 with a remainder rule; rollback is layout-lossy | R4b; heights are column-width twins (sum free, G2), `fit` writes sum 1000 with the remainder on the last row; rollback note added |
| sticky-column lead | sticky columns need their own vertical offset, and the fixed-coordinate paths must apply it | G5 |
| sticky-column lead | the row scrollbar is new UI and needs an explicit setting | V5, `layout.rowScrollbar` |
| sticky-column lead | the store must not use a client's minimum pane height | G4: reducer 100‰ floor, client refuses locally |
| sticky-column lead | rows join the column-sizing.md `LayoutOp` set; Cmd-Ctrl-Shift-D is taken; New Column is now Ctrl-Cmd-D | done; decision 2 |
| reducer owner | base on `origin/feat-cmux-next` after the crate lands; one `Destination` + `respawn`; rows heights only for now; drop decisions in the resolver | done; split ratios in a later reducer step |
| reducer owner | respawn is never own place | R6 |
| close-focus lead | no store neighbor hint (duplicates the client rule); extend `FocusAfterClose.pane`; keep `ColumnViewOffset.fit` | N3, viewport section; ownership lead dropped the hint for columns too |
| review subagent | the daemon collapses a one-column screen; `deny_unknown_fields` breaks rollback; legacy commands missing; `FocusStaysLocal` unguarded; N3 order; sticky normalize branches unreachable; no top-boundary drop; stale row set; fit with more than 10 rows | columns-mode rule (one column with two or more rows); separate `resource_screen_rows` table; table completed; model: mutants `focusColumnFirst` and `respawnDropsTab`, `START = "sticky3"`, `b` (before) on row moves, whole-column `heights` op; N3 adds next-in-row; `rows-fit-too-many` |
