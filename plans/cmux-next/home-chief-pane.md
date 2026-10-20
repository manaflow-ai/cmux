# cmux next: the Home Chief pane cannot close and shows no tab bar

Status: implemented 2026-10-20. User request (Lawrence 2026-10-20): "make it impossible to close
home chief left hand side. should not even show tabs UI for left hand side chief."

## Model

The Home Chief pane is the Home workspace's left dock column with the `agent_chat` role, pinned
(`pinned-dock-v1`, HomeDock.pin, since 2026-10-18). The column kind decides every rule below, never
a title or a page name. The daemon owns the rule (cmux-tui `mux/pinned_columns.rs`): the pinned
first tab never closes, never leaves the column, keeps the first place, and the column takes no
other tab or pane while `allow_tabs` is off. Every client and path gets the same refusal,
`reason_code` `dock-column-pinned`. The app does not ask for what the daemon would refuse, and
shows no control for it.

## Rules

- H1. No tab bar. A pane of a pinned dock that takes no other tab, showing at most one tab, has no
  strip: no tab, no close x, no + or ··· (`DockColumn.hidesTabBar`, PaneController). With
  `allow_tabs` on, or with extra tabs left from before, the bar shows so they stay reachable.
  Hide/Show Tab Bar and New Tab are hidden for that pane in menus and the palette.
- H2. Cmd-W. With focus in Home, the person's Cmd-W does nothing and shows no notice
  (`TabKeyboardClose.ignore`). The person's Close Pane does the same. With Home and other tabs
  (only with `allow_tabs`), Cmd-W on Home selects the next tab, as before.
- H3. Bulk closes. Close Other Tabs, Close Tabs to the Left/Right never list a tab that cannot
  close. Close Other Panes leaves out the panes of a pinned dock. Closing the Home workspace is
  refused by `HomeRules` (`home_not_closable`) as before.
- H4. Drops. A dragged tab finds no drop target over a pinned dock that takes no tabs (center or
  edge), so nothing previews a join or split there; the strip beside it takes drops as usual. A
  window-edge dock drop on the left edge is not offered, since the left dock is taken.
- H5. CLI and MCP (`cmux tab close`, `pane close`, `screen close`, `pane split`, `tab move`,
  `tab.create_*` into the pane, `set-column-dock` undock/move, layout undo) reach the daemon and
  get the `dock-column-pinned` refusal, which the app shows as "Home stays open in its column."

## Tests

- App: `Tests/CmuxNextAppTests/HomeChiefPaneUncloseableTests.swift` (H1, H2, H3, H4), and
  `PinnedHomeDockTests.swift` (close x, Cmd-W, new-chat placement, refusal text).
- Daemon: `cmux-tui/crates/cmux-tui-core/src/server/pinned_columns_tests.rs` (close-surface,
  `tab.close`, close-pane, `pane.close`, `screen.close`, `pane.split`, new tabs, moves in and out,
  undock and edge changes).

## Coordination

a244 (tab-bar buttons on hover) works on the strip's buttons; the Home pane shows no strip at all,
so the two do not overlap. a233 (Cmd-D/Cmd-W) owns Cmd-W in Settings; this changes only the
`.ignore` case. a173 (Home sticky) owns the sidebar Home row, not this pane.
