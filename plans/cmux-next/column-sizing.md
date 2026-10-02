# cmux next: split, new column and close sizing (planned)

Status: not started; agreed op shapes only (2026-10-01). Owner: sticky-column lead. Blocked on the
tab-loss agent's pure crate `cmux-tui/crates/cmux-layout-reducer` (LayoutOp, first tab ops) landing;
these ops become variants of that same `LayoutOp` enum, never a parallel path. The ownership lead
owns the crate after its first landing and reviews field names.

## User decisions (coordinator, 2026-10-01)

- Cmd-D / Cmd-Shift-D always split the focused pane inside its own column: never create a column,
  never scroll. Too narrow at the minimum pane width: refuse with a short HUD message.
- New Column (default Cmd-Opt-D, follow cmux-keyboard-shortcuts) appends a column right after the
  current one and scrolls to reveal it; the only creating command that scrolls.
- `layout.splitSizing`: `even` (default; every pane along the split axis in that column gets equal
  size) | `halve` (only the split pane halves).
- `layout.newColumnWidth`: `matchCurrent` (default; no existing column resizes) | `fitScreen` |
  a fraction.
- `layout.closeSizing`: `even` (default) | `neighbor`. Closing a column's last pane removes the
  column; other columns keep their widths; the viewport keeps the newly focused column visible
  without a jump when possible.
- `layout.closeFocus`: previous-in-column, else the column to the left (default) | `mostRecent`.
- Every default (also minimum pane and column widths, sticky defaults) is a setting in Settings and
  cmux.json, documented, with a test that the default matches the documented value. Sticky columns
  follow the same rules.

## Agreed op shapes (ownership lead review)

- `Split {pane, axis, sizing: even|halve, new_pane: caller id, idempotency_key}`
- `InsertColumn {after_pane, width_permille, new_column: caller id, new_pane: caller id,
  idempotency_key}`; the client resolves `matchCurrent`, `fitScreen` or a fraction to permille
  (viewports are per client, so the store never sees a screen size).
- `ClosePane {pane, sizing: even|neighbor, idempotency_key}`; the result carries a neighbor hint;
  each client picks its own focus (focus is client view state).
- No floats on the wire or in the reducer: ratios and widths are integer permille; ratios in a
  column sum to 1000 with a defined remainder rule.
- Reducer invariants with tests: tab conservation, every column has a pane, ratios sum to 1000,
  other columns' widths unchanged (InsertColumn, ClosePane), idempotent replay. Destructive policy
  (removing an emptied column) in the same commit. COORDINATION.md line per op.
