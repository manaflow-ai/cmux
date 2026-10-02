# cmux next: rows (each column a vertical strip of rows)

Status: design 2026-10-01, not implemented. Owner: rows lead (branch `feat-cmux-next-rows`).
User request (verbatim): "potentially we want to support rows in addition to columns so we go
beyond niri. so potentially we want D and shift d. but then we'll need new shortcut for the
zellij equivalent of cmd ctrl n? wait we won't right?? u should start agent on niri-like rows
(in addition to columns) remember to be careful about ownership, same way that columns stuff
lives in rust right? well need pretty big rust changes for this, make sure to design it to be
perfectly cohesive".

Binding: OWNERSHIP-PRINCIPLES.md, layout-invariants.md, column-sizing.md, sticky-column.md,
niri.md. Formal model: `formal/LayoutRows.tla`.

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

Facts found in the code that need a decision (section "Decisions"): New Column is bound to
Cmd-Shift-Opt-N today (`PaneActionCatalog.swift`), not Cmd-Ctrl-D. Cmd-Ctrl-Shift-D is taken by
Open Diff Viewer (`BrowserActionCatalog.swift`). Cmd-Ctrl-D is free in cmux but is macOS's
system Look Up chord; a cmux key equivalent wins in cmux windows.

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
niri rules, transposed. Today's column is exactly a column with one row of full height, so
nothing changes until a column gets a second row.

Strongest objection: a "row" in (c) is not a screen-wide band. Two columns scroll vertically on
their own, so the screen can look ragged (column A shows its first row while column B shows its
third), and a user who expects a spreadsheet row that spans every column gets bands per column.
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
Row    { id, height_permille, root: SplitTree, zellij_auto_layout? }
SplitTree = Leaf(pane) | Split { id, dir, ratio_permille, a, b } | Stack { panes, expanded }
```

A split screen (no niri columns, `columns_active` false) has no rows. New Row on it first turns
its tree into one column (as `MoveTabToColumn.base_column` does today), then inserts the row.

Invariants (added to layout-invariants.md I1 to I4 and checked by the reducer, proptest, TLC
and `debug.desync` in debug builds):

| Id | Invariant |
| --- | --- |
| R1 | Every pane is in exactly one row; every row is in exactly one column; every column in exactly one screen. |
| R2 | No empty containers: a pane has a tab, a row has a pane, a column has a row. A container that empties is removed in the same commit, bottom up (pane, row, column, screen). |
| R3 | Tab conservation (I1) holds for every row op; a row op that spawns a terminal adds exactly its one new tab. |
| R4 | `height_permille` and `width_permille` in 100..=1000; split ratios in a row sum to 1000 (column-sizing.md remainder rule). |
| R5 | Sticky consistency (sticky-column.md) holds after every row op, including a column removed because its last row emptied. |
| R6 | Own place (I4): a new-row move whose result equals the current layout modulo fresh ids is no operation. |
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
| `InsertRow { after_pane, height_permille, new_row, new_pane, new_tab, base_column }` | new row below `after_pane`'s row in its column, with one pane and one new tab (the session host spawns the terminal) | unknown pane, height out of range, id in use |
| `MoveTabToRow { tab, anchor, after_row: Option<RowId>, height_permille, new_row, new_pane, base_column }` | tab into a new row of `anchor`'s column (default: after `anchor`'s row; `None` with `before: true` for the top) | own place is `Ok` with no events (R6) |
| `SetRowHeights { column, heights: [(row, permille)] }` | sets every row height of one column at once (divider release, Equalize Rows) | row set differs from the column's rows, height out of range |
| `ClosePane { pane, sizing }` (column-sizing.md) | gains the row cascade; its result names the neighbor hint `{previous_in_row, row_above, row_below, column_left}` | |

`MoveTabToSplit`, `MoveTabToColumn` and the pending "split own only tab and spawn the same
kind" op take the same destination set. Proposal to the reducer owner: one
`Destination = Pane{pane, index} | Split{pane, edge} | Column{anchor, after} | Row{anchor,
after} | NewWorkspace{..} | Workspace{..}` with `respawn: Option<NewTab>` (the spawn-same-kind
case: the source pane keeps a new tab of the moved tab's kind), so every target gets the own
place rule and the spawn variant once.

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
  `row-split-compat-readonly`.
- Storage: rows go into `viewport_json` per column; a column without `rows` loads as one row of
  1000 holding the column's `layout`. No table changes. The column's `layout` field is written
  as the compat chain, so an older binary after a rollback loads every pane as vertical splits:
  layout is degraded, no tab is lost.
- Undo: `ScreenLayoutSnapshot` holds the columns with their rows, so `undo-layout` covers rows.
- Model change in `model.rs`: `LayoutColumn.root` becomes `rows: Vec<LayoutRow>` (non-empty by
  construction, like `StackPanes`); `zellij_auto_layout` moves to the row. `Screen::root` stays
  the compat projection for split-tree consumers. The TUI frontend renders rows as a vertical
  chain that fits the height until it gets row scrolling (step 6).

## Geometry

- G1. A row's height is a share of the column's viewport height, gaps included like niri W3:
  `(view - gap) * p - gap`.
- G2. Fill under, scroll over: when a column's heights sum to at most 1000, its rows fill the
  column in proportion (niri windows in a column fill its height); above 1000 the rows keep their
  heights and the column scrolls vertically. One full-height row is today's column.
- G3. New Row height: `layout.newRowHeight` = `matchCurrent` (default: the focused row's stored
  height, so a full-height row gives a full-height new row) | `fitScreen` (the column's rows
  are made equal so all fit) | a fraction. Mirrors `layout.newColumnWidth`.
- G4. A row is at least `max(100‰, layout.minimumPaneHeight x its stacked panes)` high; the
  client checks the pixel bound, the reducer the permille bound.
- G5. Sticky columns hold rows like any column and scroll them vertically on their own. Sticky
  rows (a row pinned to its column's top or bottom edge, same rules as sticky columns) are not
  in `rows-v1`; the field name `sticky` on rows is reserved.

## Viewport (client view state; niri rules on the vertical axis)

The column scroll reducer (`ColumnScrollState.reduce`, niri.md) becomes axis-generic
(`StripScrollState<Axis>`): the horizontal strip uses it as today, and each column with more
than 1000‰ of rows gets its own vertical instance keyed by column id. The focus-after-close lead
shares the same reveal functions.

- V1. Reveal (niri F1 to F7 transposed): the focused row plus padding fully visible means no
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
  `layout.rowScrollModifier` (default Command) is held. The row scrollbar follows B1 to B5 of
  sticky-column.md on the column's trailing edge (`layout.rowScrollbar`, default auto).
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
  else the row above, else the row below, else the column to the left. The client picks from
  `ClosePane`'s neighbor hint; the store decides nothing about focus.
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

## Surfaces (action-surface rule)

| Action id | Title | Shortcut | Palette | CLI verb | Context menu | MCP |
| --- | --- | --- | --- | --- | --- | --- |
| `newRow` | New Row | Cmd-Ctrl-Shift-D (decision) | yes | `pane new-row` (`--height`, `--cwd`) | pane > create, after New Column | generated |
| `equalizeRows` | Equalize Rows | none | yes | `column equalize-rows` | column | generated |
| `centerFocusedRow` | Center Focused Row | none | yes | `pane center-row` | none (exemption: view command) | generated |
| `layout.centerFocusedRow.*` | Row centering modes | none | yes | `settings ...` | none (exemption: setting) | generated |

CLI verbs go to session feat-cmux-next-99 (Swift CLI freeze). `debug.rows` reports row frames,
offsets and scrollbars. All actions are disabled with the daemon's reason until the pinned
cmux-tui serves `rows-v1` (awaitingPin until the pin owner cuts a pin).

## Verification

- TLA+ `formal/LayoutRows.tla`: owner structure (columns, rows, panes, tabs, heights, sticky),
  every row op plus split, new column, moves, close, two clients choosing ops from stale mirrors,
  replay of a key, client view repair. Invariants R1 to R5, I1, view validity; action properties
  R6 and replay. Mutants that must fail: an emptied row kept, focus not repaired.
- proptest in `cmux-layout-reducer`: random sequences that include the row ops, invariants R1 to
  R5 and idempotent replay; daemon sequences that compare the reducer with the live result.
- Swift: seeded property tests for the drop resolver with rows, the vertical strip reducer (niri
  tests transposed), geometry G1 to G4, decode of `rows` and the compat chain.
- Live (tagged no-activate build, screenshots): New Row reveal, row scroll with the modifier,
  drop between rows, close of the last pane of a row, rows inside a sticky column, an old app
  against a `rows-v1` daemon.

## Steps (each lands alone; feat-cmux-next stays shippable)

1. This note, TLA+ model with TLC numbers.
2. Reducer: rows in the model, the row ops, proptest (on the reducer crate after its first
   landing, coordinated with its owner).
3. Daemon: `LayoutColumn.rows`, storage and compat projection, commands, `rows-v1`, journal and
   undo, through the reducer check; hosted verification green.
4. App: decode, `LayoutColumn.rows`, geometry, rendering, axis-generic strip reducer, row
   scrollbar, awaitingPin gating (until the pin, no row op is ever sent).
5. Surfaces: actions, drops, menus, palette, CLI request, `debug.rows`, settings.
6. cmux-tui TUI rendering of rows (scrolling).

## Decisions for the user

1. Model (c), columns of rows (recommended), against (b), screen-wide rows of columns.
2. Shortcuts: New Column moves from Cmd-Shift-Opt-N to Cmd-Ctrl-D (gives up macOS Look Up in
   cmux), New Row takes Cmd-Ctrl-Shift-D, and Open Diff Viewer moves off Cmd-Ctrl-Shift-D (to
   be chosen). Alternative: New Row on Cmd-Shift-Opt-N's slot pattern (Cmd-Shift-Opt-M).
3. Row scroll modifier: Command (recommended) | Option | none (scroll only over gaps and the
   scrollbar).
4. Sticky rows in a later capability, or never.

## Agent review

Sent to the sticky-column lead, the reducer and tab-drag agent, the focus-after-close agent and
the ownership lead on 2026-10-01; objections and their resolution are recorded here.
