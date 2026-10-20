# New tab position (Cmd-T)

Lawrence 2026-10-20: "we need configurable cmd t behavior", then: "default should be make after
current tab, but need option to move it to end, need cmd shift p for new tab after current tab and
new tab at start and new tab at end (think of what other users would like)".

## What ships

- `tabs.newTabPosition` (Settings > General > Tabs, cmux.json, `cmux settings set`, agents may set it):
  - `afterCurrent` (new default, was `end`): right after the selected tab; after its tab group,
    never inside it; never among the pinned tabs.
  - `end`: after the last tab (Chrome and Edge do this).
  - `start` (new): first, right after the pinned tabs.
- It applies to a person's Cmd-T and the strip's +. A script's plain `cmux tab new` still appends,
  so scripts that read the last tab keep working.
- Three actions put one tab in a named place whatever the setting says, for a person or a script.
  They run Cmd-T's path (`TabLifecycle.newTabOfPaneKind`), so the tab is the same New Tab page
  (or terminal for a script), with the same focus and options:

  | Action | Palette title | CLI / MCP |
  |---|---|---|
  | `newTab.afterCurrent` | New Tab After Current Tab | `tab new-after-current` |
  | `newTab.atStart` | New Tab at Start | `tab new-at-start` |
  | `newTab.atEnd` | New Tab at End | `tab new-at-end` |

  No default keys; Settings > Keyboard Shortcuts
  can assign them.
- Right-click a tab: New > New Tab at Start and New Tab at End. New Tab to the Right stays (Chrome's name) and is the same as
  New Tab After Current Tab on that tab.

## How

One seam, `NewTabSlot.target(current:pane:explicit:user:setting:)`, turns the action's explicit
position, the person's setting, or a script's default (the end) into a `NewTabSlot.Target`
(`.after(tab)` or `.start(tab)`; nil is the end). `NewTabSlot.placing(_:)` shows the new tab in
that slot from its first frame (`NewTabSuccession`; the start is its existing "no anchor, first
unpinned slot") and then moves the daemon's tab there (`TabMoves.move`). The daemon still
appends; nothing changed on its side. No new animation: the strip's existing insert motion runs,
which already goes through the motion gate.

## Considered, not shipped (say the word to add one)

- New Tab to the Left / Before Current Tab: rare in other apps (no Chrome, Safari or VS Code
  command); the start covers "far left".
- Chrome's opener-aware placement for links (a tab opened from a page goes after the previous
  tab that page opened): cmux already does this for link tabs (`pageRequests.openers`); it is
  not about Cmd-T.
- Firefox's "open related tabs next to current" toggle: covered by `afterCurrent`.
- A "what Cmd-T opens" setting (terminal, browser, same kind, picker). Leo retired
  `tabs.newTabKind` on 2026-10-12 (Cmd-T always opens the New Tab page, where the kind is picked;
  `NewTabAlwaysPageSettingTests`). Not brought back without a call; New Tab of the Same Kind
  (Option-click on +) and New Terminal Tab (Ctrl-`) cover the direct opens.
- Opening Cmd-T's tab in the pane on the right: Cmd-T stays in the focused pane; links already
  go right (`layout.linkPlacement`).

## Tests

- `NewTabPositionSettingTests` (CmuxNextSettingsTests): default, each value, a bad value, the row.
- `NewTabPositionSlotTests` (CmuxNextAppTests): each setting value and each action lands at the
  right index; actions ignore the setting; scripts append; start is after pinned tabs.
- `NewTabPositionActionsTests` (CmuxNextActionsTests): the three palette rows and CLI verbs.
