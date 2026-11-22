# cmux next: split, new column and close sizing (planned)

Status (2026-10-02): app side implemented with existing daemon commands; the store ops below are
not started. They wait for the tab-loss agent's pure crate `cmux-tui/crates/cmux-layout-reducer`
(LayoutOp, first tab ops); these ops become variants of that same `LayoutOp` enum, never a parallel
path. The ownership lead owns the crate after its first landing and reviews field names.
`layout.closeFocus` belongs to the focus-after-close lead (feat-cmux-next-closefocus).

## Implemented (app, existing commands)

- Split actions (Cmd-D, Cmd-Shift-D, Split Left/Up, the layout split intent) never open a column:
  when the column has no room at the minimum pane size they refuse, and keyboard and menu
  refusals now show their reason in a short Liquid Glass HUD at the bottom of the window
  (`RefusalHUD`) instead of a beep. Tab drops onto a pane edge still open a column when there is
  no room (a drag is not a split command).
- `layout.splitSizing` even: before the split the app computes the ratios that equalize the
  same-axis chain holding it (`EvenSplitRatios`, the split pane counting as two) and sends them as
  ended divider intents once the split succeeded. Interim: two undo entries until `Split` carries
  the sizing policy.
- `layout.newColumnWidth` (matchCurrent default, fitScreen, fixed; a number means fixed at that
  share) through `NewColumnWidth.plan(mode:)`; fixed keeps column-scroll.md W4 (a lone full-width column
  shrinks), the other modes never resize except fitScreen's visible scrolling columns.
- `layout.dockColumnEdge` (nearest: Dock Column's nearest-edge rule; or right, left, top,
  bottom), `layout.dockColumnMode` (docked); when set they are Dock Column's defaults too, `layout.minimumPaneWidth`
  (200 pt), `layout.minimumPaneHeight` (64 pt): Settings window (General > Columns) and cmux.json;
  `ColumnLayoutSettingsTests` checks each default in the parser, the schema and `DesignSettings`.
  The pre-R87 keys `layout.stickyColumnEdge` and `layout.stickyColumnMode` (nightly-next only) are
  read for one release when the dock key is absent; the dock key wins.
- New Pane (Auto Layout) (Ctrl-Cmd-N, CLI `pane new-auto-layout`) is Zellij's new pane
  (`PanePlacement.autoSplit`): the largest shown pane of a scrolling column splits along its longer
  side (right on a tie, the other axis when only it has room); equal areas prefer the most recently
  focused pane. A docked column (side dock or band) never splits. The new pane starts in the
  focused terminal's folder (NEW-TERMINAL-INHERITS-CWD). A run that names a pane splits that pane.
- `layout.newPanePlacement` (tab default, split) and `layout.tileBrowsers` (false): with split, a
  person's New Terminal (and New Browser, with tileBrowsers) takes the Auto Layout path; a browser
  opens as a tab, then moves into its own pane. CLI, MCP and scripts always get a tab. Settings
  window (General > Columns) and cmux.json; `PanePlacementSettingsTests` checks the defaults.
- New Column is Ctrl-Cmd-D (user decision 2026-10-02; no other cmux action has it, macOS's
  text Look Up uses it only in text views). It replaces Cmd-Shift-Opt-N; rebind under
  `shortcuts.bindings.newColumn` in cmux.json or in Settings > Shortcuts. Cmd-Opt-D stays macOS's
  Dock shortcut and Split Browser Right.
- The refusal HUD stays for every action refused from the keyboard or menu (user decision).
- Not done: `layout.closeSizing` (even/neighbor). The app cannot apply it to closes it does not
  initiate (the last tab exiting, other clients) without inferring from its mirror, which the
  ownership principles forbid; it needs `ClosePane {sizing}` in the store.

## User decisions (coordinator, 2026-10-01)

- Cmd-D / Cmd-Shift-D always split the focused pane inside its own column: never create a column,
  never scroll. Too narrow at the minimum pane width: refuse with a short HUD message.
- New Column (default Ctrl-Cmd-D) appends a column right after the
  current one and scrolls to reveal it; the only creating command that scrolls.
- `layout.splitSizing`: `even` (default; every pane along the split axis in that column gets equal
  size) | `halve` (only the split pane halves).
- `layout.newColumnWidth`: `matchCurrent` (default; no existing column resizes) | `fitScreen` |
  a fraction.
- `layout.closeSizing`: `even` (default) | `neighbor`. Closing a column's last pane removes the
  column; other columns keep their widths; the viewport keeps the newly focused column visible
  without a jump when possible.
- `layout.closeFocus`: previous-in-column, else the column to the left (default) | `mostRecent`. Owned by the close-focus work (client view state, not a store op): see close-focus.md.
- Every default (also minimum pane and column widths, docked defaults) is a setting in Settings and
  cmux.json, documented, with a test that the default matches the documented value. Docked columns
  follow the same rules.

## Agreed op shapes (ownership lead review)

- `Split {pane, axis, sizing: even|halve, new_pane: caller id, idempotency_key}`
- `InsertColumn {after_pane, width_permille, new_column: caller id, new_pane: caller id,
  idempotency_key}`; the client resolves `matchCurrent`, `fitScreen` or a fraction to permille
  (viewports are per client, so the store never sees a screen size).
- `ClosePane {pane, sizing: even|neighbor, idempotency_key}`; it carries and returns no focus or
  neighbor hint: each client computes focus from its own before/after projections
  (`FocusAfterClose`, the focus-after-close lead; ownership lead decision 2026-10-02).
- No floats on the wire or in the reducer: ratios and widths are integer permille; ratios in a
  column sum to 1000 with a defined remainder rule.
- Reducer invariants with tests: tab conservation, every column has a pane, ratios sum to 1000,
  other columns' widths unchanged (InsertColumn, ClosePane), idempotent replay. Destructive policy
  (removing an emptied column) in the same commit. COORDINATION.md line per op.
