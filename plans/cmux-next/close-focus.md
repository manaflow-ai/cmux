# cmux-next: focus and scroll after a close

User request (2026-10-01): "we need to formally verify the correct behavior for when user
closes workspace/terminal/pane/etc. like what is the next thing to focus on, what is the
best way to handle scroll (in both horizontal niri scroll, and workspaces left sidebar).
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
(focused column kept its screen x), closing an unfocused visible column, Chrome's tab
successor (right, else left), an unselected tab closed by the CLI, the workspace successor
order (next, else previous). Closing the last column springs back to the clamp, which is
forced (no empty space past the last column).

Not reproducible live on this build: sticky columns (the pinned daemon lacks
`sticky-columns-v1`); closing a window and the last workspace were not exercised.

## Rules

`FocusAfterClose` (CmuxNextDesign/CloseFocus) is the one successor function per close
kind; `ListViewport` is the sidebar's scroll function; `ColumnScrollState.reduce` stays
the strip's scroll function (niri.md).

- C1 Focus changes only when the focused item itself leaves the projected topology,
  whoever removed it (user, CLI, MCP, another client, the daemon, a process exit). So a
  close by automation never moves this client's focus unless it closed the focused item,
  and closing an unfocused item never changes focus. No origin input is needed.
- C2/C3 The successor is a surviving item on the same screen (panes on hidden screens are
  used only when that screen emptied); focus is nil only when nothing is left.
- Pane (`layout.closeFocus`, default `previousNeighbor`): the previous pane in its column,
  else the next pane there; when the column went, the nearest column to the left, else to
  the right, in visual order (left sticky, strip, right sticky; a split screen is one
  column), entering it at its most recently focused pane, else its first. `mostRecent`:
  the newest surviving pane of this window's history on that screen, else the default.
  Closing the right sticky column focuses the strip's last column; the left one, the
  strip's first.
- Tab: the next shown tab, else the previous shown one (Chrome); members of a collapsed
  group are skipped while a shown tab survives.
- Workspace: the next workspace below, else the one above (`WindowRegistry.repairedSelection`).
- A rejected close (the tab or pane comes back) does not move focus back.

Scroll (strip and sidebar):

- V1 clamped to the content; V2 the focused item is fully visible after settle when it
  must be revealed; V3 a focused item that stays focused and visible keeps its screen
  position unless the clamp forces a move; V4 a reveal aligns the nearer edge; V5 items
  removed or added before the visible ones do not move what the user sees (the strip
  anchors on the focused column, the sidebar on the focused row when visible, else the
  first visible row); V6 the same geometry settled again does not scroll (one scroll per
  change; animations interpolate to the computed target with the `.move`/`.scroll`
  Motion tokens, instant under Reduce Motion).
- Sidebar reveal happens when the active workspace changed, or when it was fully visible
  before. A user who scrolled the list away from the active row keeps that view through
  unrelated closes.
- Sticky columns are not in `ColumnStrip`, so they never enter strip scroll math.

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
- Behavior tests: `CloseFocusReducerTests` (B1, B2, sticky, screens, reject),
  `SidebarCloseScrollTests` (S1-S3, no jump), `FocusReducerTests`.

## Last results (2026-10-01, Debug build, shared Mac under load)

| Check | Bound | States / sequences | Transitions | Time |
| --- | --- | --- | --- | --- |
| `FocusAfterClose.pane` previousNeighbor | up to 4 columns x 3 panes, 6 panes, depth 6 | 39,626 states | 608,785 (369,664 closes) | 8 s |
| same, `CMUX_MODELCHECK_PANES=7` | 7 panes | 341,004 states | 4,024,915 | 63 s |
| `FocusAfterClose.pane` mostRecent | as above | 39,626 states | 608,785 | 8 s |
| `FocusAfterClose.tab` | 5 tabs, every hidden subset, depth 5 | 10,449 close sequences | | <1 s |
| `FocusAfterClose.workspace` | 5 workspaces, depth 5 | 600 close sequences | | <1 s |
| `ListViewport` | 5 rows, 3 viewports, depth 3 | 1,025,508 states | 3,365,334 | 150 s |
| `ColumnScrollState` (strip) | 4 columns, 3 widths, 2 viewports, depth 6 | 12,100 states | 73,766 | 5 s |
| TLA+ strip / strip-recent / list | see formal/README.md | 23,057 / 23,229 / 93,149 distinct | | 20 s |

Mutants caught: 6 pane, 2 tab, 6 list, 4 strip, 7 TLA+ runs. The strip check found a real
bug: niri's restore point fired on an unfocused close of the just-opened column (fixed;
`ColumnScrollRestoreTests`).

## Live check after the fix (tagged no-activate build of 076a9b988a2, debug socket)

B1 (lower split pane closed after visiting the right column: focus went to the pane above),
B2 (middle column closed by Cmd-W: the left column took focus and was revealed; the CLI
closing the focused pane: its left neighbor, no scroll), C1 (CLI close of an unfocused
column: focus kept), S1 (new workspace revealed), S2 (CLI close above the viewport: rows
unchanged pixel for pixel), S3 (selected workspace closed: successor fully visible, no
jump) all pass. `debug.focus`: `app_active` false, `key_window` null throughout.
UNVERIFIED live: sticky columns (pinned daemon lacks `sticky-columns-v1`; covered by
`CloseFocusReducerTests`), closing the last workspace, closing a window, a selected
workspace closed while scrolled out of view (covered by `SidebarCloseScrollTests`), the
pill and animation smoothness (screenshots are settled frames).

## Decisions for the user

1. Pane successor when the closed pane was the first of a column that keeps other panes:
   the next pane in that column (stays in the column) rather than the column to the left.
2. Entering the left column after a column closes lands on that column's most recently
   focused pane, else its first (niri keeps an active tile per column), not the
   geometrically nearest pane.
3. Tabs keep Chrome's rule (right, else left) and do not follow `layout.closeFocus`.
   Workspaces keep next-below, else above.
4. The sidebar reveals the active row only when it changed or was visible; it does not
   pull a manually scrolled list back on unrelated closes.
5. niri's restore point stays: closing a column that was just opened right of the focused
   one returns the strip to the offset it had before the open, only when that column was
   focused when it closed.
6. Inside a column (and on a split screen) "previous pane" is the previous pane in layout
   order, not the split sibling that takes the space: in `H(A, V(B, C))` closing B
   focuses A, not C. Alternative: the sibling subtree's nearest pane (tmux-like).
7. A sidebar row that is wholly in view never scrolls, even when it is closer to the edge
   than the 8 point reveal padding (no movement under a click or double-click).
