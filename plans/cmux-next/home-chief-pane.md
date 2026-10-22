# cmux next: the Home Chief pane cannot close and shows its tab strip

Status: implemented 2026-10-20; H1 and H4 changed 2026-10-21. User request (Lawrence 2026-10-20):
"make it impossible to close home chief left hand side. should not even show tabs UI for left hand
side chief." Leo 2026-10-21 took back the second half: "JUST MAKE THE TAB THING SHOW UP ON THE
MAIN PANE TOO" (Austin and Lawrence: tabs showing up on the main agent pane).

## Model

The Home Chief pane is the Home workspace's left dock column with the `agent_chat` role, pinned
(`pinned-dock-v1`, HomeDock.pin, since 2026-10-18). The column kind decides every rule below, never
a title or a page name. The daemon owns the rule (cmux-tui `mux/pinned_columns.rs`): the pinned
first tab never closes, never leaves the column, keeps the first place, and the column takes no
other tab or pane while `allow_tabs` is off. Every client and path gets the same refusal,
`reason_code` `dock-column-pinned`. The app turns `allow_tabs` on for Home's dock
(`HomeDock.allowTabs`, `column.update`): when it makes or pins the dock, and once for a dock pinned
before (`cmuxNext.home.dockTakesTabs`), so a person's later `allow_tabs: false` stays. The app does
not ask for what the daemon would refuse, and shows no control for it.

## Rules

- H1. Tab strip. Home's dock takes tabs, so its pane shows its tab strip by default, like any pane:
  Home's tab first with no close x, and the tabs dragged in. The strip has no +: what Home opens
  (New Tab, Cmd-D, a new chat, a link) still goes beside it (`ChatColumnPlacement`,
  `NewChatPlacement`, `LinkOpener`). Hide/Show Tab Bar and New Horizontal Tab are offered there.
  Only a pinned dock the person closed to tabs (`allow_tabs` off), showing at most one tab, has
  no strip and hides those two actions (`DockColumn.hidesTabBar`).
- H2. Cmd-W. With focus in Home, the person's Cmd-W does nothing and shows no notice
  (`TabKeyboardClose.ignore`). The person's Close Pane does the same. With Home and other tabs
  (only with `allow_tabs`), Cmd-W on Home selects the next tab, as before.
- H3. Bulk closes. Close Other Tabs, Close Tabs to the Left/Right never list a tab that cannot
  close. Close Other Panes leaves out the panes of a pinned dock. Closing the Home workspace is
  refused by `HomeRules` (`home_not_closable`) as before.
- H4. Drops. A tab dragged over Home's dock joins it wherever it is dropped (every zone is the
  center: the pinned dock never splits). A tab in the dock other than Home's own page and Chief
  tabs drags out again like any tab: to the strip, the sidebar (a new workspace) or a new window
  (`HomeDock.keepsTab`). Over a pinned dock closed to tabs there is no drop target at all. A
  window-edge dock drop on the left edge is not offered, since the left dock is taken.
- H5. CLI and MCP (`cmux tab close`, `pane close`, `screen close`, `pane split`, `tab move`,
  `tab.create_*` into the pane, `set-column-dock` undock/move, layout undo) reach the daemon and
  get the `dock-column-pinned` refusal, which the app shows as "Home stays open in its column."

## Tests

- App: `Tests/CmuxNextAppTests/HomeChiefPaneUncloseableTests.swift` (H1, H2, H3, H4),
  `PinnedHomeDockTests.swift` (close x, Cmd-W, new-chat placement, refusal text),
  `HomeLoneDockTests.swift` (opens beside the dock, a dragged-in tab drags out) and, against the
  same-tree daemon, `HomeSplitKeysTests.homesDockShowsItsTabStripAndTakesTabs` (H1, `allow_tabs`).
- Daemon: `cmux-tui/crates/cmux-tui-core/src/server/pinned_columns_tests.rs` (close-surface,
  `tab.close`, close-pane, `pane.close`, `screen.close`, `pane.split`, new tabs, moves in and out,
  undock and edge changes).

## Coordination

a244 (tab-bar buttons on hover) works on the strip's buttons; the Home pane's strip has the same
buttons as any pane's, without +. a233 (Cmd-D/Cmd-W) owns Cmd-W in Settings; this changes only the
`.ignore` case. a173 (Home sticky) owns the sidebar Home row, not this pane.
