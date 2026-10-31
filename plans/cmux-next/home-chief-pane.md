# cmux next: the Home Chief pane cannot close and shows no tab strip

Status: implemented 2026-10-20; H1 and H4 changed 2026-10-21. User request (Lawrence 2026-10-20):
"make it impossible to close home chief left hand side. should not even show tabs UI for left hand
side chief." Leo 2026-10-21 took back the second half: "JUST MAKE THE TAB THING SHOW UP ON THE
MAIN PANE TOO" (Austin and Lawrence: tabs showing up on the main agent pane). Lawrence 2026-10-23
took the strip back off: "for chief home page, i see tabbar now which is bad. home chief should have
no tabbar." Tabs still drag in (`allow_tabs`); the strip shows only while one is there.

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

- H1. No tab strip. While the Home Chief pane holds only Home's tab it shows no tab bar
  (`DockColumn.hidesTabBar`, PaneController; Lawrence 2026-10-23), and Show/Hide Tab Bar is refused
  there (`PaneTabBarHandlers.noToggleReason`). A tab dragged in brings the strip back while it is
  there (Home's tab first with no close x), so it stays reachable. The strip has no +: what Home opens (New Tab,
  Cmd-D, a new chat, Split Browser, a link, a file, an app page) still goes beside it
  (`ChatColumnPlacement`, `NewChatPlacement`, `LinkOpener`). Only a drag puts a tab in the dock:
  every tab creator (`newTerminalTab`, `PaneBrowserTabOpener` (its stand-in included, 2026-10-29), `InternalPageTabStore.openStoreTab`,
  the actions in `TabLifecycle`) moves a tab it made there to a new column right of it
  (`HomeDockOpens`), and an open in the background keeps the focus in Home. The session-local
  (WebKit) fallback opens in the pane right of Home, and with Home alone is refused. With a dragged-in tab, the person's Hide Tab Bar
  hides the strip, as in any pane (`PaneTabBarChoices`); New Horizontal Tab stays hidden for that pane
  in menus and the palette.
- H2. Cmd-W. With focus in Home, the person's Cmd-W does nothing and shows no notice
  (`TabKeyboardClose.ignore`). The person's Close Pane does the same. With Home and other tabs
  (only with `allow_tabs`), Cmd-W on Home selects the next tab, as before.
- H3. Bulk closes. Close Other Tabs, Close Tabs to the Left/Right never list a tab that cannot
  close. Close Other Panes leaves out the panes of a pinned dock. Closing the Home workspace is
  refused by `HomeRules` (`home_not_closable`) as before.
- H4. Drops. A tab dragged over Home's dock joins it wherever it is dropped (every zone is the
  center: the pinned dock never splits), whatever its kind (`ChatDockRules.takesOnlyChats`: other
  chat docks still take only chats). Home's tools (Split Browser, a link, a file) are made in the
  dock and moved to a column on its right (`LinkOpener.moveBeside`). A tab in the dock other than Home's own page and Chief
  tabs drags out again like any tab: to the strip, the sidebar (a new workspace) or a new window
  (`HomeDock.keepsTab`). Over a pinned dock closed to tabs there is no drop target at all. A
  window-edge dock drop on the left edge is not offered, since the left dock is taken.
- H5. CLI and MCP (`cmux tab close`, `pane close`, `screen close`, `pane split`, `set-column-dock`
  undock/move, layout undo) reach the daemon and get the `dock-column-pinned` refusal, which the app
  shows as "Home stays open in its column." A new tab the app's actions open in Home's pane for the
  CLI, MCP or a script (New Tab, Open Browser, `file open`) opens beside it (H1). A daemon op that
  names the dock's pane itself (`tab.create_*`, `tab move`) is a move the dock takes while
  `allow_tabs` is on, as a drag is.

## Tests

- App: `Tests/CmuxNextAppTests/HomeChiefPaneHasNoTabBarTests.swift` (H1),
  `HomeChiefPaneUncloseableTests.swift` (H2, H3, H4), `PinnedHomeDockTests.swift` (close x, Cmd-W,
  new-chat placement, which tabs a chat dock takes, refusal text), `HomeLoneDockTests.swift` (opens
  beside the dock, a dragged-in tab drags out) and, against the same-tree daemon,
  `HomeSplitKeysTests.homesDockShowsNoTabStripAndTakesTabs` (`allow_tabs`, drag in and back out),
  `HomeDockOpensTests` (script, file, page and session-local opens beside Home; focus kept).
- Daemon: `cmux-tui/crates/cmux-tui-core/src/server/pinned_columns_tests.rs` (close-surface,
  `tab.close`, close-pane, `pane.close`, `screen.close`, `pane.split`, new tabs, moves in and out,
  undock and edge changes).

## Coordination

a244 (tab-bar buttons on hover) works on the strip's buttons; the Home pane's strip has the same
buttons as any pane's, without +. a233 (Cmd-D/Cmd-W) owns Cmd-W in Settings; this changes only the
`.ignore` case. a173 (Home sticky) owns the sidebar Home row, not this pane.
