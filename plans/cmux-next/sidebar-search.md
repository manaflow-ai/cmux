# Sidebar Search: one search over everything

Status: v1 design, a247 (sidebar universal search), 2026-10-20. Binding inputs:
palette-scopes.md (the scope graph, built-in scopes, federation), palette-ranking.md
(the off-main ranker), sidebar-sections.md (the footer band), OWNERSHIP-PRINCIPLES.md.

Request (Lawrence, 2026-10-20, msg 4597): "in sidebar bottom left we should add a search
icon button for search and it should search through all types of stuff".

## 1. What the user gets

- A magnifying-glass button in the sidebar's bottom row, right after the profile avatar
  (the avatar stays the leading control; amendment 2 of SIDEBAR-FOOTER-AND-SPACE-MENU).
  It is always visible, the same 28 pt square hit target as the avatar, with a tooltip
  and an accessibility label ("Search").
- A click opens the palette on the **Search** scope, centered over the window like Cmd-P
  (amended 2026-10-25, Lawrence 12344: no popup over the button).
  It is the same panel, field, keys and rows as Cmd-P and Cmd-Shift-P.
- One query searches every kind of thing the app already indexes. Rows stay grouped by
  type (sections), not merged into one list, so "Workspaces", "Tabs", "History",
  "Settings" and "Commands" each read as a block. Up and Down move, Return focuses or
  runs the row, Cmd-K lists the row's other actions, Esc closes.
- An empty query shows the Recent section (palette frecency over all kinds), so the
  button is also "go back to what I used last".

## 2. One engine, not two

The Search scope is a palette scope (palette-scopes.md 3.5), id `search`, title "Search",
symbol `magnifyingglass`, keywords `search`, `everything`, `all`, no prefix (single
characters are scarce). Its page reuses the providers the other pages already have:

| Type | Source (existing) | What a row matches |
| --- | --- | --- |
| Workspaces | `WorkspacePaletteProvider` (Cmd-P) | name, folder, group |
| Groups, panes, tabs | `NavigationPaletteProvider` (Cmd-P) | terminal titles, browser tab titles and URLs, cwd, agent (ACP) chat tabs and their session ids, Markdown/file viewer tabs |
| Recent folders | `RecentDirectoriesPaletteProvider` | path |
| Settings | `SettingsPaletteProvider` | setting title, group, keywords |
| Commands | `RegistryPaletteProvider` | every catalog action (same rows as Cmd-Shift-P) |
| Apps | `sources.extraProviders` | installed apps and their commands |
| Browser History, Recently Closed, Command History, Agent Sessions | App contributions: the history store by kind (`HistoryPalettePages.searchContributions`), one section each | page visits (title, URL), closed tabs/screens/workspaces, terminal commands, agent sessions; the location trail is left out (the open tabs are listed themselves) |
| Agent chats | App contribution: `agentPane.searchChats` page providers | acpmux chats from the Recents feed (open or not) |

New code is only composition: `PaletteSources.searchContributions` (a list of the App's
pages that join Search, each under its own section) and `PaletteController.searchPage()`.
Every provider still returns its candidate set once; the palette's `PaletteSearcher` ranks
off the main actor per keystroke, as it does for every page. Nothing new runs on the main
thread per keystroke, and the search page opens from the last snapshot in the first frame.

A contributed row keeps its own section when it has one (Search Tabs' "Open" / "Closed");
otherwise it takes the contribution's section (its page title). Providers are shown only
once the user types (the empty query is Recent only), so the first frame stays short.

## 3. Entry points (one action, every surface)

There is no new action id: every surface runs the existing `palette.open` with
`scope: search`, whose handler centers the panel over the window, as for every palette scope.

| Surface | How |
| --- | --- |
| Sidebar button | runs `palette.open {scope: search}` with origin `user` |
| Palette | the "Search" row in the `?` scope list and the root's Search In rows; the `search` keyword plus Tab |
| CLI | `cmux palette open --arg scope=search --focus` |
| MCP / headless | `palette.query {scope: "search", query}` returns the ranked rows without UI; `palette.run` runs one |
| Shortcut | Cmd-Shift-A (`search.chats`, Search Everything); Cmd-P lists only open items |

## 4. Settings

`sidebar.showSearchButton` (bool, default true): Settings > Appearance > Sidebar > Show
Search Button, cmux.json, `cmux settings set`, Cmd-Shift-P through the schema. Off hides
the button only; the action, scope and CLI stay.

## 5. Layout

The button is fixed footer chrome placed by `SidebarFooterBand`, not a sidebar-layout item:
an item would need the Rust store default to change and a migration that adds it again each
time a user removes it (the migration can't tell "never had it" from "removed it"). The
setting is the off switch. Placement: after the footer band's first-row items (the avatar),
`Metrics.space2` apart; the spaces dots start after the button and stay centered. With the
avatar hidden it takes the leading slot. With the spaces dots on top it still sits there.

## 6. Tests (failing first)

- `PaletteSearchScopeTests` (CmuxNextPaletteTests): the `search` scope exists and opens a
  page titled Search; one query returns workspace, tab, setting, command and contributed
  history rows, each in its own section; Return on a workspace row selects it; Backspace
  on the empty query returns to the root.
- `SidebarSearchOpensCenteredTests` (CmuxNextAppTests): pressing the footer's Search button
  opens the panel centered over the window.
- `SidebarSearchButtonTests` (CmuxNextSidebarTests): the footer shows a search button
  after the avatar with a hit target at least 28 x 28 pt and an accessibility label;
  pressing it calls `onSearch`; `showsSearchButton = false`
  hides it.
- `SidebarShowSearchButtonSettingTests` (CmuxNextSettingsTests): the setting parses, is on
  by default, a bad value keeps the default with a diagnostic.

## 7. Not in v1 (next steps)

- **Home messages** and **terminal scrollback** need a per-query source: `HomeSource.search
  (query:limit:)` exists, and scrollback lives in the daemon. The palette's providers are
  snapshot-only today (palette-scopes.md 3.2 `query` sources are not built). Phase 2 adds a
  `PaletteQueryProvider` (async, generation-tagged, cancelled by the next keystroke) and
  plugs Home hits and a daemon scrollback search into this page.
- **Files on disk** beyond open viewer tabs and recent folders wait for the daemon file
  index (`files` scope, wave 3).
