# Snippets sidebar

A right-sidebar tool that lists every `type: "text"` action (snippet) from the
loaded cmux config, filters it as you type, and pastes the chosen snippet into
the focused terminal. Fork feature on `fork/snippets`, stacked on the
`type: "text"` actions PR (#12871) and the Snippets context menu (#16172).

## Decisions

- **Select pastes.** Choosing a snippet behaves like the right-click menu: the
  text lands at the cursor through the same trust gate; Enter is pressed only
  when the snippet sets `submit: true`. No preview step, no clipboard.
- **Keyboard-first.** A shortcut shows the tool; `/` focuses search; Up/Down,
  j/k and Ctrl+N/P move; Enter pastes the selected row (or the top result while
  typing); Esc returns focus to the terminal without pasting.
- **Flat list.** Rows sorted by title. Each row shows the title, a category tag
  when the snippet has one, and the first line of its text. Search matches
  title, category, keywords and the full text, case-insensitively.
- **Optional like every other tool.** No new config key. The tool is a
  `RightSidebarMode` and is shown, hidden and reordered from Settings > Sidebar
  tabs through the existing `RightSidebarTabPreferences`.

## Architecture

### Package: search over snippets (Foundation only, unit-tested)

In `Packages/macOS/CmuxTextActions`:

- `CmuxSnippetMenuEntry` gains `keywords: [String]` with a defaulted init
  parameter so existing callers compile unchanged.
- New `CmuxSnippetSearch.swift`: `CmuxSnippetSearch.filter(_ entries:
  [CmuxSnippetMenuEntry], query: String) -> [CmuxSnippetMenuEntry]`.
  Trims the query; an empty query returns all entries sorted by title (then
  action id). A non-empty query is split on whitespace into terms; an entry
  matches when every term is a case- and diacritic-insensitive substring of
  the title, category, any keyword, or the text. Results are ranked: title
  matches first, then category/keyword matches, then text-only matches; ties
  keep title order. The ranking is a stable sort over a small tuple, no scoring
  framework.

### App: store

`Sources/SnippetsSidebarStore.swift` (`@MainActor final class
SnippetsSidebarStore: ObservableObject`):

- `@Published private(set) var entries: [CmuxSnippetMenuEntry]`
- `@Published var query: String`
- `var results: [CmuxSnippetMenuEntry]` computed through `CmuxSnippetSearch`.
- `@Published var selectedActionID: String?`, clamped to results whenever
  results change; `moveSelection(by:)`, `selectTop()`.
- `attach(configStore: CmuxConfigStore)`: reads
  `configStore.snippetMenuEntries()` (extended to carry keywords) and
  re-reads on every `configStore.$configRevision` change. Owned lazily by
  `RightSidebarToolPanel` like `sessionIndexStore`.

### App: view

`Sources/SnippetsSidebarView.swift` and `Sources/SnippetsSidebarRow.swift`:

- Header: `SidebarSearchFieldView` in the same chrome as `VaultAllSessionsBar`
  (height, paddings, `titlebarInteractiveControl`), placeholder "Search
  snippets…", `onSubmit` pastes the selected or top result.
- Body: a `List`-free `ScrollView` + `LazyVStack` of rows (the Vault view's
  pattern), selection highlight on the selected row, click pastes, scroll keeps
  the selection visible.
- Empty states: "No snippets configured" with a one-line hint pointing at
  `type: "text"` actions in cmux.json; "No matches" while filtering.
- Keyboard: the view installs the existing `RightSidebarKeyboardNavigation`
  handling for move and `/`; Esc calls the focus-return path.

### App: wiring

- `RightSidebarMode.snippets` ("Snippets", symbol `text.badge.plus`, shortcut
  action `switchRightSidebarToSnippets`), appended after `.dock` in
  `availableModes`; not a pane mode.
- `RightSidebarPanelView.contentForMode` mounts `SnippetsSidebarView`;
  `RightSidebarToolPanel` owns the store and attaches it to the window's
  `cmuxConfigStore`; `syncWorkspaceRoot` has nothing to do for this mode.
- `KeyboardShortcutSettings.Action.switchRightSidebarToSnippets` with label
  "Show Sidebar Snippets"; no default key, positional Ctrl+digit comes free.
- Localization: `rightSidebar.mode.snippets`,
  `shortcut.switchRightSidebarToSnippets.label`, the placeholder, and both
  empty-state strings, in all nine locales.

### Delivery

On select the view resolves the window's config store action by id
(`resolvedAction(id:)`) and calls `CmuxConfigExecutor.deliverTextActionIfAuthorized`
with the panel from `tabManager.selectedWorkspace?.focusedTerminalInputTarget()`,
exactly as the command palette's `executeTextAction` does. The sidebar holding
key focus does not change that target. A refused paste beeps and keeps the
sidebar focused; a delivered paste moves focus back to the terminal. If the
workspace has no terminal input target, the row click beeps and nothing is
sent.

## Error handling

- Config reload removes the selected snippet: selection clamps to the top
  result.
- Project-local snippets: the trust dialog appears over the window; a denied
  dialog leaves the sidebar as it was.
- Store attaches to a window with no config store (tests, early launch):
  entries stay empty and the view shows the empty state.

## Testing

- Package: `CmuxSnippetSearchTests` for empty query ordering, term matching
  across each field, multi-term AND, ranking tiers, diacritic/case folding.
- App (`cmuxTests`): `SnippetsSidebarStoreTests` for entry loading from a
  decoded config, selection clamping on reload, `moveSelection` bounds;
  `RightSidebarModeTests` additions for the new mode's availability, label and
  positional digit.
- Verification: `python3 scripts/verify-local.py`, the two existing text-action
  suites plus the new ones through `cmux-unit`, then dogfood in the tagged
  `snippets` build: show the tool, type, Enter, confirm the paste lands in the
  right terminal and focus returns.

## Out of scope

Editing snippets from the sidebar (the Settings editor branch covers that),
category grouping or chips, drag-to-reorder, previews, clipboard mode.
