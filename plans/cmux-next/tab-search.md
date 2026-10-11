# cmux next: Search Tabs (Cmd-Shift-A)

Proposal, 2026-10-02 (tab search lead). One palette page over every tab
the user has, with recently closed tabs below.

## Behavior

- Opens with Cmd-Shift-A (action `tab.search`, Tab category, File menu,
  palette row "Search Tabs…"). The optional argument `query` opens it with
  text typed. "Go to Tab…" is the same page: `palette.goToTab` is an alias
  of `tab.search` (bindings and scripts keep working); with a tab target
  (`--target tab:<id>`, an app's `tab.focus`) it focuses that tab.
- Scopes: the scoped palette (plans/cmux-next/palette-scopes.md, lane 11)
  owns the scope chip and Backspace-to-full-palette. Search Tabs ports onto
  it; the page keeps its data source (`TabSearchSource`), ranking
  (`TabSearchPlan`, `TabSearchRanker`) and row actions apart from the page
  chrome for that.
- Lists every open tab of every kind (terminal, browser, remote terminal,
  other) in every pane, workspace, window and connected machine, then a
  Recently Closed section. Closed tabs stay below open tabs for every
  query (`PalettePageSpec.keepsSectionOrder`).
- Empty query: open tabs by last use (the location trail), the current tab
  first; the page selects the second row, so Return switches back to the
  previous tab. Ten closed tabs, newest first (up to 50 match a query).
- Fuzzy match on title (weight 100), then URL, full folder, process (the
  agent in the tab), workspace, machine and kind (80), then the row's
  subtitle (65) and accessory (50). The palette's own index and ranker;
  recent tabs get a small boost (16, minus 2 per rank).
- Return focuses and reveals the tab: its window comes forward, the
  workspace, screen and tab are selected and its pane takes focus
  (`AppServices.revealTab`, also used by history Go To). On a closed row
  Return reopens the tab where it was.
- Cmd-W closes the selected row's tab through Close Tab (same confirmations
  and refusals), or removes a closed row from the closed-items log. The
  palette stays open and the next row of the same section (else the
  previous one) is selected. A refusal keeps the row and shows why on it.
  The page owns Cmd-W: with no row, or with the Actions menu open, it never
  reaches the main menu's Close Tab. Pressed during a search, it waits for
  that search's results, like Return. The footer shows the row's close
  command with its keys.
- A focused Simulator keeps Cmd-Shift-A (its Toggle Appearance); Focus
  TextBox moved from Cmd-Shift-A to Cmd-Opt-A (Attach File stays
  Cmd-Opt-Shift-A).

## Ownership

No new state. Rows are a value snapshot of the App's mirror (every
machine's daemon store), the location trail (recency) and the closed-items
log. Every change goes to its owner through the existing path: Close Tab,
Reopen (HistoryRestorer), the closed-items log. After Cmd-W the page
re-reads its rows: a tab leaves when the strip's visible state drops it
(a shown tab at once, a hidden tab on the daemon's echo). The closed-items
log emits a change event (`ClosedTabTracker.changes`) after every update of
the tabs it watches and of the closed list, once the list is current;
`TabSearchLiveUpdates` re-reads a shown page on each event, so a closed tab
moves to Recently Closed at once, and stops when the page goes.

## Surfaces

| Surface | What |
| --- | --- |
| Keyboard | Cmd-Shift-A, `shortcuts.bindings["tab.search"]` in cmux.json, Settings shortcut editor |
| Palette | "Search Tabs…" pushes the page |
| Main menu | File > Search Tabs… |
| Right-click | exempt (`noObject`) |
| CLI | `cmux tab search` (Rust CLI request below) |
| MCP | `tab_search`, results only |
| Socket | `tabs.search {query?, limit?, closed?}` (read-only results, answered off the main actor from the published control snapshot: topology plus `ControlTabSearchFacts`) and `action.run tab.search {query?}` with `focus: true` (opens the page) |

`action.run tab.search` from automation without `focus: true` is refused:
the page takes the keyboard, and automation never changes focus.

## Prototypes (DEV and NIGHTLY)

Debug Settings > Palette and Panels > "Search Tabs layout"
(`palette.tabSearchStyle`), applied on the next open:

- `recent` (default): one list by last use; each row shows site or folder,
  workspace, machine, window, and the agent or "Current".
- `grouped`: sections per window and workspace in layout order.
- `compact`: titles with the site or folder name only; five closed tabs
  before typing.

## Code

- `CmuxNextPalette/TabSearch/`: `TabSearchEntry`, `TabSearchPlan` (rows,
  sections, order, pure), `TabSearchRanker` (pure, shared by the control
  method), `TabSearchPage` + `TabSearchSource`, `TabSearchStyle` +
  `PaletteTunables`, `MockTabSearchSource`.
- Palette: `PaletteItem.closeCommand`, `PaletteKeyCommand.closeItem`
  (Cmd-W, taken before the main menu while a row has one),
  `PalettePageSpec.keepsSectionOrder` / `emptyQuerySelection` /
  `initialQuery`.
- App `TabSearch/`: `AppTabSearchSource`, `TabSearchHandlers`,
  `TabSearchControl` (`tabs.search`), `AppServices.revealTab`.

## Not done

- Process names come from the agent in the tab and the terminal title; the
  mirror has no foreground process name. The session host field
  `foreground_process` (requested from the Rust owner through the
  coordinator) would make "process" match `vim`, `htop` and so on.
- `tabs.search` ranks with the `recent` layout whatever the Debug Settings
  prototype is, so scripts get stable results.
- Favicons in rows (the palette row draws SF Symbols only).
