# cmux-next: focus and scroll after a close

User request (2026-10-01): "we need to formally verify the correct behavior for when user
closes workspace/terminal/pane/etc. like what is the next thing to focus on, what is the
best way to handle scroll (in both horizontal column scroll, and workspaces left sidebar).
2 unrelated things, but both have buggy behavior today."

Focus, selection and scroll are client view state (OWNERSHIP-PRINCIPLES.md). Every rule
here runs in the client on the projected layout (mirror plus pending intents); no store op
or protocol changed.

## Bugs reproduced (tagged no-activate build of ef59984a2f1, debug socket)

| Id | Path | Observed | Expected |
| --- | --- | --- | --- |
| B1 | Cmd-W on the lower pane of a split, after focusing another column and back | focus jumped to the other column (most recently focused anywhere) | the pane above it |
| B2 | Cmd-W on the only pane of a middle column, strip scrolled; CLI `closePane` of the focused pane | focus went to the most recently focused column, here the right one | the column to the left, revealed with the least scroll |
| S1 | new workspace (or one selected by action) far below in the sidebar | selected row stayed out of view | revealed |
| S2 | CLI `closeWorkspace` of a row above the sidebar viewport | every visible row shifted up one row | rows stay put |
| S3 | close the selected workspace while its successor is at the viewport edge | successor selected but cut off | fully visible |

Checked and correct already: closing an unfocused column left of the strip viewport
(focused column kept its screen x), closing an unfocused visible column, the tab
successor (then right, else left; now left, else right), an unselected tab closed by the CLI, the workspace successor
order (next, else previous). Closing the last column springs back to the clamp, which is
forced (no empty space past the last column).

Not reproducible live on this build: docked columns (the pinned daemon lacks
`dock-columns-v1`); closing a window and the last workspace were not exercised.

## Rules

`FocusAfterClose` (CmuxNextDesign/CloseFocus) is the one successor function per close
kind; `ListViewport` is the sidebar's scroll function; `ColumnScrollState.reduce` stays
the strip's scroll function (column-scroll.md).

- C1 Focus changes only when the focused item itself leaves the projected topology,
  whoever removed it (user, CLI, MCP, another client, the daemon, a process exit). So a
  close by automation never moves this client's focus unless it closed the focused item,
  and closing an unfocused item never changes focus. No origin input is needed.
- C2/C3 The successor is a surviving item on the same screen (panes on hidden screens are
  used only when that screen emptied); focus is nil only when nothing is left.
- Pane (`layout.closeFocus`, default `mostRecent` since 2026-11-08, issue
  https://github.com/manaflow-ai/cmux/issues/38194: "the logic for this matches bonsplit stuff as
  we want in the cmux classic terminal"). `mostRecent` is cmux classic's Bonsplit rule
  (`SplitViewController.closePane`): the newest surviving pane of this window's history on that
  screen, as Zellij and tmux return to the pane used last; with no surviving pane in the history,
  the closed pane's sibling when the topology carries it (`CmuxFocusTopology.column_siblings`,
  `close_focus::pane_or_sibling`), else `previousNeighbor`. The app does not send siblings yet:
  the pinned FFI header predates the field, so after the repin `FocusMachine` must encode them
  (follow-up); until then the app falls back to `previousNeighbor` here. The daemon's own active pane follows the same rule (focus recency only,
  `Pane::focused_at`; with no focused survivor, the closed pane's sibling subtree's first pane, as
  Bonsplit's `closePaneRecursively`). `previousNeighbor` (opt-in): the previous pane in its column,
  else the next pane there, counting only panes still in that column after the change
  (column identity, not liveness: a neighbor moved to another column in the same snapshot
  does not count; found by the rows lead's LayoutRows.tla), else a pane that joined the
  column; when the column went, the nearest column to the left, else to
  the right, in visual order (left docked, strip, right docked; a split screen is one
  column), entering it at its most recently focused pane, else its first.
  Closing the right docked column focuses the strip's last column; the left one, the
  strip's first.
- Tab: Chrome's rule (Lawrence 2026-11-09: "ensure our cmd w behavior matches chrome, in
  terms of what's the next tab that should be focused to"; it replaces 2026-11-08's "always
  the tab before it", #38316). One rule for every tab kind (terminal, browser, agent, page,
  Markdown) and every way a tab closes (Cmd-W, the close button, a middle click, the context
  menu, Close Others, Close Tabs to the Right or Left, a group close, the CLI or MCP, a
  terminal that exits). In the app it is the one close-selection rule ("One close-selection
  rule" and "Tabs: the app's side" below): `cmux-focus-core::close_selection` through
  `TabCloseSelection`. The daemon's active tab (`tree_edit::remove_surface`) and the cmux-tui
  client call `close_focus::tab`: they keep no openers, so they run the positional steps only;
  the app's selection is the one the person sees. Close Others and Close Tabs to the Right or
  Left keep their own rule: the tab the person acted on, which survives. See "Chrome's tab
  close rule" below.
- Workspace: the one close-selection rule ("One close-selection rule" below): the workspace the
  person came from when he made the closed one, else the next row below, and the row above only
  when it was the last (`WindowRegistryStore.repairSelection` with the window manager's
  `WindowCloseSelection`). A row's group or section is not read.
- A rejected close (the tab or pane comes back) does not move focus back.

Scroll (strip and sidebar):

- V1 clamped to the content; V2 the focused item is fully visible after settle when it
  must be revealed; V3 a focused item that stays focused and visible keeps its screen
  position unless the clamp forces a move; the sidebar reveal-scrolls the focused row
  whenever focus changes, the focused row moves (a drop, Move to Top, a sort, a regroup, a
  keyboard move, a move from the CLI or another client), or a change pushes it out of view;
  V4 a reveal aligns
  the nearer edge; V5 items removed, added or moved before the visible ones do not move
  what the user sees (the strip anchors on the focused column; the sidebar list anchors
  on the first visible row that did not move); V6 the same geometry settled again does not scroll (one scroll per
  change; animations interpolate to the computed target with the `.move`/`.scroll`
  Motion tokens, instant under Reduce Motion).
  Rule changed 2026-10-16, chief approved, cx-ml98q; changed again 2026-10-19 (Lawrence:
  "if we focus on workspace, or our focused workspace moves, invariant is it needs to
  always be in user's sidebar, visible").
- Sidebar reveal happens when the active workspace changed, moved by itself, or was fully
  visible before. A new selection also opens a collapsed section (machine, Pinned, document
  section) that hides it; a collapsed group draws its active member as its one row. A user
  who scrolled the list away from the active row keeps that view through changes that do
  not move it.
- Docked columns are not in `ColumnStrip`, so they never enter strip scroll math.

## Entry points

Cmd-W, the tab close button, the pane and column close actions, the palette, the menus,
the CLI (`action.run` with any origin) and daemon-driven removals all end as a removal in
the daemon mirror. `WorkspaceContentController.sendTopology` feeds it to `FocusReducer`
(pane successor), `PaneController.apply` to `TabSelectionMemory` (tab successor),
`WindowManager.repairSelections` to `WindowRegistry.repairedSelection` (workspace
successor), the strip's model sync to `ColumnScrollState`, and the sidebar's
`reload` to `ListViewport`. The replaced ad hoc code: the history-first
`FocusReducer.successor`, the inline neighbor search in `TabSelectionMemory` and
`repairedSelection`, and `SidebarListView.revealActive`.

## Verification

- Swift model checks (exhaustive breadth-first, every step checked):
  `FocusAfterCloseModelCheckTests` (panes: every layout of up to 4 columns x 3 panes, up
  to 6 panes, closes of a pane or a column by anyone, focus moves, splits and new
  columns, depth 6, both policies; tabs: every strip of up to 5 tabs with every hidden
  subset, every close sequence to depth 5; workspaces: 5 workspaces, every close sequence),
  `ListViewportModelCheckTests` (up to 5 rows of heights 1-3, viewports 2/4/7, every offset
  and focus, removes, inserts and focus moves, depth 3), and
  `ColumnScrollCloseModelCheckTests` (strips of up to 4 columns of 30/55/100 percent width,
  two viewports, depth 6). Mutants that break each rule are caught. Numbers: see
  "Last results".
- TLA+: `formal/closefocus.tla`, `formal/run-closefocus-tlc.sh` (configs strip, strip with
  `mostRecent`, list; `--mutants`). Invariants Safety (focus live, never removed, target
  clamped, target shows focus); action properties UnfocusedCloseKeepsFocus, NoJump,
  MinimalReveal, SuccessorRule, NoSecondScroll; liveness Settles (after the last user step
  the view settles with the focus visible).
- Tab rule: cmux-focus-core `close_successor.rs` (one test per case id of the Chrome
  table), `model_check.rs` (`tab_close_like_chrome_*`), the C ABI's
  `close_focus_rules.rs`, the daemon's `tab_close_like_chrome_in_the_daemon`, the
  cmux-tui client's `tab_close_selection.rs`; app side `FocusAfterCloseTabTests`. Pane rule (issue 38194): `PaneCloseControllerTests`
  (`theDefaultCloseFocusIsClassicsMostRecentPane`, `theDefaultCloseFocusReturnsToTheLastUsedColumn`),
  `most_recent_without_history_focuses_the_closed_panes_sibling`, and the daemon's pane close
  tests in cmux-tui-core `mux/tests/tabs.rs`.
- Behavior tests: `CloseFocusReducerTests` (B1, B2, docked, screens, reject),
  `SidebarCloseScrollTests` (S1-S3, no jump), `FocusReducerTests`.

## Last results (2026-10-01, Debug build, shared Mac under load)

| Check | Bound | States / sequences | Transitions | Time |
| --- | --- | --- | --- | --- |
| `FocusAfterClose.pane` previousNeighbor | up to 4 columns x 3 panes, 6 panes, depth 6, incl. close + move to another or a new column in one snapshot | 49,341 states | 822,006 (557,595 closes) | ~60 s at load 600+ |
| same, `CMUX_MODELCHECK_PANES=7` | 7 panes | 341,004 states | 4,024,915 | 63 s |
| `FocusAfterClose.pane` mostRecent | as above | 48,180 states | 810,480 | |
| `FocusAfterClose.tab` (now removed: tabs pick with `TabCloseSelection`; not run again) | 5 tabs, every hidden subset, depth 5 | 10,449 close sequences | | <1 s |
| `CloseSelection.workspace` with no relation held (the run was of its predecessor `FocusAfterClose.workspace`, now removed; not run again) | 5 workspaces, depth 5 | 600 close sequences | | <1 s |
| `ListViewport` | 5 rows, 3 viewports, depth 3 | 1,025,508 states | 3,365,334 | 150 s |
| `ColumnScrollState` (strip) | 4 columns, 3 widths, 2 viewports, depth 6 | 12,100 states | 73,766 | 5 s |
| TLA+ strip / strip-recent / list | see formal/README.md | 23,057 / 23,229 / 93,149 distinct | | 20 s |

Mutants caught: 7 pane (incl. liveness instead of column membership), 2 tab, 6 list, 4 strip, 7 TLA+ runs. The strip check found a real
bug: the restore point fired on an unfocused close of the just-opened column (fixed;
`ColumnScrollRestoreTests`).

## Live check after the fix (tagged no-activate build of 076a9b988a2, debug socket)

B1 (lower split pane closed after visiting the right column: focus went to the pane above),
B2 (middle column closed by Cmd-W: the left column took focus and was revealed; the CLI
closing the focused pane: its left neighbor, no scroll), C1 (CLI close of an unfocused
column: focus kept), S1 (new workspace revealed), S2 (CLI close above the viewport: rows
unchanged pixel for pixel), S3 (selected workspace closed: successor fully visible, no
jump) all pass. `debug.focus`: `app_active` false, `key_window` null throughout.
UNVERIFIED live: docked columns (pinned daemon lacks `dock-columns-v1`; covered by
`CloseFocusReducerTests`), closing the last workspace, closing a window, a selected
workspace closed while scrolled out of view (covered by `SidebarCloseScrollTests`), the
pill and animation smoothness (screenshots are settled frames).

## Decisions for the user

1. Pane successor when the closed pane was the first of a column that keeps other panes:
   the next pane in that column (stays in the column) rather than the column to the left.
2. Entering the left column after a column closes lands on that column's most recently
   focused pane, else its first (each column keeps an active tile), not the
   geometrically nearest pane.
3. Tabs keep their own rule (Chrome's, 2026-11-09) and do not follow
   `layout.closeFocus`.
   Workspaces follow the one close-selection rule (below), not `layout.closeFocus`.
4. The sidebar reveals the active row only when it changed or was visible; it does not
   pull a manually scrolled list back on unrelated closes.
5. The restore point stays: closing a column that was just opened right of the focused
   one returns the strip to the offset it had before the open, only when that column was
   focused when it closed.
6. Inside a column (and on a split screen) "previous pane" is the previous pane in layout
   order, not the split sibling that takes the space: in `H(A, V(B, C))` closing B
   focuses A, not C. Alternative: the sibling subtree's nearest pane.
7. A sidebar row that is wholly in view never scrolls, even when it is closer to the edge
   than the 8 point reveal padding (no movement under a click or double-click).

## Chrome's tab close rule

Source: Chromium `chrome/browser/ui/tabs/tab_strip_model.cc` on `main` (read 2026-11-09):
`TabStripModel::DetermineNewSelectedIndex`, `GetIndexOfNextWebContentsOpenedBy`,
`GetIndexOfNextWebContentsOpenedByOpenerOf`, `GetNextExpandedActiveTab`, `FixOpeners`,
`OnActiveTabChanged`, `TabNavigating`, `AddWebContents` and `InsertTabAtImpl`.

`DetermineNewSelectedIndex` tries, over tabs that are not in a collapsed group:

1. a tab the closed tab opened, the nearest after it, else before it;
2. a tab the closed tab's opener opened (a sibling), nearest after, else before;
3. the closed tab's opener;
4. in the closed tab's group, the tab right after it, else right before it;
5. the nearest tab after it, else before it, outside collapsed groups;
6. else the tab after it, unless it was last, then the tab before it.

Openers (`TabModel::opener`) come and go by these rules, which the app keeps in
`BrowserTabOpeners` (`openerOf`, keyed by surface, any tab kind):

- a link's tab (Cmd-click, a page's new tab, `ADD_INHERIT_OPENER`) records the active tab as
  its opener; a foreground one first forgets every relation (`InsertTabAtImpl`);
- a new tab the person makes (Cmd-T, the +; Chrome: a typed tab at the end of the strip)
  records the active tab too, and that relation goes as soon as the person switches away
  from the new tab (`reset_opener_on_active_tab_change`), so Cmd-T then Cmd-W returns to the
  tab you were on, but not after you looked elsewhere;
- a person's switch between two tabs that are not opener and child or siblings forgets every
  relation (`OnActiveTabChanged`, user gesture);
- a typed navigation forgets every relation, except in a new tab page at the end of the
  strip (`TabNavigating`);
- a tab that leaves hands its children its own opener (`FixOpeners`).

| Id | Case | Strip, selected tab closed | Selected after | Chrome step |
| --- | --- | --- | --- | --- |
| P1 | middle tab | A **B** C | C | 6 (5) |
| P2 | last tab | A B **C** | B | 6 (5) |
| P3 | only tab in a pane | **A** | nothing; the pane closes (pane rule) | none |
| P4 | a tab that is not selected | **A** B C, close C | A (no move) | the active tab stays |
| P5 | pinned tabs | P1 **P2** U1 | U1 (pins are not special) | 5 |
| O1 | the opener closes | X **A** Y B, B opened by A | B | 1 |
| O2 | a link tab with a sibling | A **B** C D, B and D opened by A | D | 2 |
| O3 | a link tab, no sibling | A **B** X, B opened by A | A | 3 |
| O4 | opener closed in the same batch | A B C X, C opened by B opened by A, close B and C | A | `FixOpeners`, 3 |
| O5 | Cmd-T then Cmd-W at once | A **N** B, N made by Cmd-T on A | A | 3 (reset on switch) |
| O6 | Cmd-T, switch away and back, Cmd-W | A **N** B | B | 6 (opener forgotten) |
| O7 | link tab after an unrelated switch | A **B** X, B opened by A, person went to X and back | X | 6 (`OnActiveTabChanged`) |
| G1 | last tab of an open group | A [B **C**] D | B | 4 |
| G2 | collapsed group beside | A [B C collapsed] **D** | A | 5 |
| B1 | Close Tabs to the Right of A, C selected | A [B **C** D closed] | A | 6 |
| B2 | Cmd-W four times from C | A B **C** D | D, B, A, nothing | 6 each time |
| R1 | Cmd-Shift-T after closing B | A C D | A B C D, B selected | daemon `closed.reopen` |

P3: the pane's last tab closing closes the pane, and focus follows the pane rule above.
R1 is the daemon's (`tab_close_like_chrome_r1_reopen_puts_the_tab_back_in_its_slot`); Chrome's reopen does
not restore the opener, and neither does cmux.

Rollout: the app links a pinned FFI build. `cmux_close_focus_tab` (the pinned symbol) keeps
2026-11-08's rule (`close_focus::tab_before`), so the automatic re-pin changes nothing the app
shows; the app then moves to `cmux_close_focus_tab_chrome` (openers and groups) together with
its Swift tests in one change, with no red window between.

## One close-selection rule

Tabs in a pane and workspaces in a window's sidebar follow the same rule after a close: Chrome's
(the section above), with one decided difference. The state and the pick are one Rust module,
`cmux-focus-core::close_selection` (`Openers`), behind the C ABI `cmux_close_selection_*` of
`cmux-layout-reducer-ffi`. A strip is one pane's tabs or one window's workspaces.

- R0: closing an item that is not selected never moves the selection.
- R1: closing the selected item selects, first match: an item it opened (the first after it,
  else the nearest before it), an item its opener opened, its opener, else the next item, and
  the previous one only when it was the last. A pane's tabs read their group first, as Chromium's
  `DetermineNewSelectedIndex` does (its fourth preference, read 2026-11-11): after the opener, the
  tab right after the closed one in its group, else the one right before it in its group (G1). This
  replaces the 2026-11-10 decision "no group is read", which the source contradicts for the last tab
  of a group (Lawrence via Chief 2026-11-11: match Chrome inside groups). A window's workspaces still
  pass no group or section map.
- R2: a new item the person makes (Cmd-T, the plus button, New Workspace) keeps the item he came
  from as its opener. Its lifetime follows where it is put (below): after the selected item, until
  R3 or R4 ends it, as a link's tab; at the end or the start, until the selection leaves the new
  item (the quick look-up). A link's or a tab action's new tab keeps its opener until R3 or R4
  ends it. Nothing else has an opener: not an item made by automation, a restore, a move or a
  drag. A quick look-up in the foreground first forgets every older relation of its strip.
- R3: a selection the person makes forgets every relation of the strip, unless the two items
  have the same opener (or both have none) or one is the other's opener. A typed navigation
  forgets them too, except the first one in a tab the person just made.
- R4: a relation holds inside one strip. An item that closes or moves hands the items it opened
  its own opener, and its own relation ends.
- R5: where a new item is put changes none of this.

R2's lifetime follows Chrome as observed (decision 2026-11-10; it replaces "one lifetime
wherever the item is put"). Chromium ends a new tab's opener when the selection leaves the tab
only for a tab at the end of the strip (`AddTab`); a tab it puts in the middle ("New Tab to the
Right") keeps its opener as a link's tab does. cmux puts a new item after the selected one by
default, so the default is the middle-tab lifetime: the caller passes a task opener, not
reported as foreground. Observed on Chrome 156 for a tab in the middle, and the same in cmux:
closed at once it returns to the tab the person came from; after a visit to that tab and back
it still returns there; after a visit to an unrelated tab and back it selects the next item;
with link tabs of the same opener beside it, it selects the first of them. A new item at the
end or the start is the quick look-up (`quick`, foreground). The caller chooses the lifetime
(`kind`, `foreground`), so this needs no change of the module.

| Case | Strip, selected item in bold | Steps | Selected after |
| --- | --- | --- | --- |
| 1 | A **B** C D | new item N (after B), close N | B |
| 2 | A **B** C D | the same with new items at the end | B |
| 3 | A **B** C D | new item N, select D, select N, close N | C |
| 4 | A **B** C D | close B | C |
| 5 | A B C **D** | close D | C |
| 6 | A **B** C D | B opens X and Y in the background, select X, close X | Y |
| 7 | A **B** C | B opens X and Y in the background, close B | X |
| 8 | A **B** C D | close C | B (no move) |

The table test is `cmux-tui/crates/cmux-focus-core/tests/close_selection.rs`: each row runs as
tabs and as workspaces. The module lands with no caller; the workspaces move to it first, the
tabs after.

### Tabs: the app's side

- State: one `TabCloseSelection` (CmuxNextBridge) for each window, owned by the window's
  `TabSelectionMemory` (`closeRule`). One pane's tabs are one strip; a relation never crosses
  panes. It holds the handle through `CloseSelection` (CmuxNextDesignTokens). A tab that takes
  another's place (a stand-in's daemon tab, what a New Tab page turns into) is the same item.
- `made`, a person's new tab: `NewTabSlot.target` reports the press (`expect`: the pane, the tab
  it shows, the tabs it lists) only for a person's own run that may change the view. The pane's
  next selection of a tab that was not listed, while it still shows the opener, makes the
  relation: put after the current tab (the default) it is a task opener, not reported as
  foreground; put at the end or the start it is the quick opener. Known gap: the expectation
  ends at the pane's next selection change that is not a close's own, or when the pane no
  longer lists the opener, so a create that fails or lands in another strip leaves it until then.
- `made`, a link's tab or a tab an action inside another tab opens: `BrowserPageRequests`
  (`inheritsFromOpener`), a task opener, when the two tabs are in one pane.
- `selected`: every change of `TabSelectionMemory` reports to the state. A person's gesture is
  marked before the change: `PaneController.select` (a click, a shortcut, the palette) and
  `TabSelectionMemory.jump` (tab search, a pinned row, a notification, a link to a tab,
  `tab.focus`). A run whose origin is not `user` (the CLI, MCP, a script, a remote client, a
  page) makes no gesture (`ActionRunScope.isPersonsAction`; `PaneController.select` also needs a
  source that is not the CLI). A run with the origin `user` counts as the person's, and so does
  code with no action run around it (a click). A `cmux://` link runs as `link.open` with the
  origin `user`, so it is a gesture; a socket request that names the origin `user` is one too.
  A pinned row of the sidebar always counts as a click. A gesture can only end relations, so a
  call that counts as one by mistake gives the pick by position.
  The selection a close causes is not a gesture
  and the rule does not hear of it (`closeSelects`).
- A typed navigation in a browser tab forgets the pane's relations, except the first one in a
  quick look-up tab (Chromium's code: a New Tab page at the end of the strip). A new tab after
  the current one forgets on its first typed navigation, as Chromium's code does for a tab in
  the middle; this row was not observed on Chrome.
- `left`: when the close is committed (`TabSelectionMemory.resolve`, then `settle`). The press of
  a close keeps the relation, so a cancelled or refused close keeps the tab's opener.
- The pick: `TabSelectionMemory.resolve` asks `TabCloseSelection.successor` for every way a tab
  leaves a pane. The strip's own pick at the press (`TabStripModel.closeSuccessor`), Cmd-W's
  target and a group close ask the same state. Members of a collapsed group are not shown and
  are skipped.
- Cost: with no relation held and no new tab expected, a selection change is emptiness checks
  and a close picks by position over the pane's tabs. With some held, a call asks about the tabs
  of those relations and the pane's own tabs. No call walks a window or the session.
- Tests: `TabCloseSelectionTests` (the table, both placements), `TabCloseEntryPointsTests` (each
  way to close a tab, through the app), `TabCloseSelectsBeforeTests`, `CmdWTargetTests`.

### Workspaces: the app's side

- State: Rust's (cmux-focus-core `close_selection::windows::WindowCloseSelection`, the C calls
  `cmux_window_close_selection_*` of cmux-layout-reducer-ffi): the creates a window waits to show,
  the window of each relation, the repairs that run, the relations, when one ends, and the pick.
  Swift's `WindowCloseSelection` (CmuxNextLayout; one for every window, owned by the window
  manager's `WindowRegistryStore`, as a workspace has one owner window) owns the handle, numbers
  the app's string ids for it and passes each fact on. It decides nothing.
- `made`: `WorkspaceSpawner.start` reports each create into a window (`WindowCloseSelection.expect`)
  before the window can show it, with the relation Rust gives for the create's facts
  (`WorkspaceSpawn.closeRelation`, one `cmux_window_close_selection_relation` call): the spawn
  opens the New Tab page, the run is the person's own (action origin `user`), it may change the
  view, and the placement setting puts the row after the current one. Only a person's own New
  Workspace gets one; a duplicate, a template, a session transfer, an import and a tab moved to a
  new workspace get none. The relation is made when that window shows the new workspace; its
  opener is the workspace shown before. With `workspaces.newPlacement` `afterCurrent` (the default)
  it is a task opener, not reported as foreground (Chrome 156's observed rows for a new tab in the
  middle: a visit to the opener and back still returns to the opener); with `top` or `bottom` it
  is the quick opener.
- `selected`: every change of `WindowState.workspaceID` (`WindowCloseSelection.watch`). A selection a
  repair makes is not a gesture; a selection in a script's, the CLI's or MCP's run is not one.
- `left`: when the close is committed (`WindowCloseSelection.settle`, after the pick of each repair).
  Rust asks about the workspaces and windows it holds (`_settle_questions`), Swift answers with the
  registry's facts (the owner window, a waiting create, a registered window), and Rust ends what
  is gone: a workspace no window lists any more (the daemon's delta took it), one that moved to
  another window, one whose create failed.
- The press of a close (`InstantClose.begin`, `repair(pressed: true)`) can still be cancelled or
  refused. A quick relation of the hidden row lasts through that repair only; a cancelled close
  shows the row again inside `WindowCloseSelection.repairing`, so that selection is the close's and
  the row has its opener as before the press. A repair that is no press (a daemon delta, a move, a
  room change) ends a quick relation as every selection that leaves the workspace does.
- A selection that a daemon delta causes is never a gesture: the reconcile caller says so itself
  (`repairSelection(gesture:)`), because no action run surrounds a delta. Whose selection a repair
  makes is Rust's answer (`_repair_begin`): the person's only for a workspace they just moved in.
- An opener that no sidebar order lists (a pinned layout tile) and a closed workspace that no order
  lists yet are the Rust pick's own steps (the opener goes first; the window's members before the
  close are the last order). Swift passes the orders as they are.
- A person's close of several rows in one gesture (a multi-selection, Close Others, Close Below,
  Close Above, a group close) is the same pick as a close of one row: the opener rank over the rows
  that survive, so an opener that closes with it is no candidate. There is no batch flag.
- The pick: `WindowManager.repairSelections` calls `WindowRegistryStore.repairSelection` (CmuxNextLayout)
  for every close entry point: the pick, the selection, then the settle. No group map is passed
  (decision 2026-11-10, Chrome 156 as observed: the next row, whatever its group). The app's
  sidebar sends a close as an intent and never picks; a sidebar model alone (the mock, a test)
  picks by position with `SidebarCloseSuccessor`.
- Cost: while Rust holds no id (no create is waited for, no relation), a selection change, a close,
  a settle and a repair read one flag (`cmux_window_close_selection_holds_ids`): no id is numbered
  and nothing is allocated. With some held, a call numbers its own ids, and the settle asks about
  the held workspaces only. No hook walks a window's members
  (`WorkspaceCloseSelectionTests.aSwitchAndACloseNeverWalkTheMembers`). A selection that is still
  a member, and a preferred workspace, need no pick: that one line stays in Swift
  (`WindowRegistry.repairedSelection`) so that most membership changes make no call.
