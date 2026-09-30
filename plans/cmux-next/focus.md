# cmux next focus and keyboard routing

Status: phase 1 (root causes) written 2026-09-29; phase 2 implements the design below.
Scope: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/` plus small hooks in Layout,
Browser and Actions. Dogfood reports: the caret or focused terminal gets out of sync,
keyboard interactions are weird, webview focus is jank, dragging splits gives focus
and blank-pane problems.

## 1. Verdict

The hypothesis holds. Focus has no owner. Seven places hold a copy of "what has the
keyboard", and they sync through side effects in both directions: the model pushes
AppKit (`makeFirstResponder`), AppKit pushes the model (`ShellWindow.makeFirstResponder`
override), and guards such as `containsFirstResponder` stop the loop. Content is shown on
the next display frame, but focus is applied synchronously, so a focus request that
arrives before its view exists is dropped. Nothing repairs it later. Daemon deltas and
command responses arrive in either order, and the one-slot `pending*` fields that bridge
them are overwritten or fire after the user moved on.

## 2. Every owner of focus today (evidence at `feat-cmux-next` 1a5995358b6)

Paths are under `Packages/macOS/CmuxNext/Sources/`.

| # | Copy | Where | Written by |
| --- | --- | --- | --- |
| 1 | AppKit first responder per window | AppKit | `PaneController.focusContent` (`CmuxNextApp/PaneController.swift:208-211`), `TerminalSurfaceView.mouseDown` (`CmuxNextTerminal/TerminalSurfaceView+Mouse.swift:23`), `TerminalSession.focus` (`TerminalSession.swift:105-107`), `WebKitTab.setFocused` (`CmuxNextBrowser/WebKit/WebKitTab.swift:99-106`), `AddressBarView.focus` (`UI/AddressBarView.swift:99-101`), `FindBarView.focus` (`UI/FindBarView.swift:69-71`), `PromptBarView` (`:98`), sidebar list/search/rename (`CmuxNextSidebar/Views/SidebarListView+Mouse.swift:21`, `SidebarListView+Rename.swift:53,72`, `SidebarView.swift:75,80`), palette field (`CmuxNextPalette/PaletteContentView.swift:66`) |
| 2 | Key window | AppKit | `PaletteController.present/hide` (`CmuxNextPalette/PaletteController.swift:104,115,132`), `AppCompatFrontend.focusWindow` (`CmuxNextApp/Compat/AppCompatFrontend.swift:62-67`), CEF child window when the page takes focus (browser.md: fork commits `a7bcbc0`, `377a33a`), sheets |
| 3 | `WindowState.focusedPane[workspace]` | `CmuxNextApp/WindowState.swift:30` | `WorkspaceContentController.apply` (`WorkspaceContentController.swift:79`), `paneDidFocus` (`:111`), layout `.focus` intent (`WorkspaceContentController+Intents.swift:13`), `AppCompatFrontend.focus` (`:103`), `TabHandlers` (`Handlers/TabHandlers.swift:86`) |
| 4 | `LayoutModel.focusedPane` | `CmuxNextLayout/Model/LayoutModel.swift:21` | `focus(_:)` (`:169-175`), silently by `apply(screens:)` (`:100-103`) and `selectScreen` (`:190-192`) |
| 5 | Ghostty surface focus | `TerminalSurfaceView.lastFocus`, `TerminalModel.isFocused` | `updateFocus` = first responder AND key window (`CmuxNextTerminal/TerminalSurfaceView.swift:325-332`), driven by responder callbacks and window key notifications (`:130-161`) |
| 6 | CEF page focus | `CEFTab.pendingFocus`, Chromium widget, child `NSWindow` key state | `CEFTab.setFocused` (`CmuxNextBrowser/CEF/CEFTab.swift:141-144`), only from `BrowserChromeView` (`UI/BrowserChromeView.swift:94,209,211`) |
| 7 | Registry context bits `terminalFocused`/`browserFocused` | `ActionRegistry.context` (app-global) | `WorkspaceContentController.publishContext` (`WorkspaceContentController.swift:122-127`) from the focused pane's content kind, not from the responder |
| - | Tab selection (focus follows it) | `WindowState.selection`, `TabStripModel.selectedID` | `PaneController.apply/select` (`PaneController.swift:127-145`, `PaneController+Intents.swift:50-57`), `AppCompatFrontend.selectTab` (`:52-57`) |
| - | Pending focus slots | `WorkspaceContentController.pendingFocusSurface`, `pendingAddressBarFocus` (`WorkspaceContentController.swift:26-29`), `PaneController.pendingSelectSurface`, `pendingSelectTab`, `pendingAddressBarFocus` (`PaneController.swift:29-34`) | split, new column, new tab, new browser, empty-workspace repair, reopen |
| - | Snapshot focus for the CLI | `ControlSnapshotPublisher.buildTopology` (`Control/ControlSnapshotPublisher.swift:96-102`) | reads `WorkspaceContentController.focusedPane`, whose fallback is `panes.values.first` (dictionary order, `WorkspaceContentController.swift:105-107`) |

The daemon's `activeTab`/`focused_at` are a shared compatibility default
(`CmuxNextDaemon/Tree/PaneSnapshot.swift:8-10`). The app never writes them and reads
`activeTab` only as the selection fallback. They do not cause the bugs.

## 3. Root causes and concrete races

R1. **Content shows a frame later, focus is applied now.** `PaneController.apply` defers
`showSelected` to the next display frame (`PaneController.swift:143-145`,
`ContentPresentationScheduler.swift:25-63`). `showSelected` never moves the responder
(`:155-169`). `PaneContentView.show` removes the old content; if it was first responder,
AppKit makes the window first responder, and `show` only calls `onFocus` (a model write),
not `makeFirstResponder` (`PaneContentView.swift:50-63`). Results:
- Cmd-W on the selected tab: the neighbor is shown, the window is first responder,
  typing goes nowhere, every Ghostty cursor is hollow until a click.
- A tab closed by the daemon (process exit, CLI close), a selected tab dragged away, and
  a pane closed under the focus all end the same way.
- Workspace switch and relaunch: `WindowController.show` calls `focusCurrentPane`
  before any pane controller exists (`WindowController.swift:110`, panes are created in
  `makeContentView` during layout), and `onWindow`/`makeContentView` call `focusContent`
  before the deferred content is shown (`PaneController.swift:59-62`,
  `WorkspaceContentController.swift:148`). The new workspace has no keyboard target.
- CEF pages are created asynchronously (`TabContentCache.swift:84-96`); focus requested
  before the page exists is lost the same way.

R2. **Silent model fallbacks.** `LayoutModel.apply` and `selectScreen` replace a removed
focused pane with the first pane of the active screen without emitting `.focus`
(`LayoutModel.swift:100-103,190-192`), so `WindowState.focusedPane`, the responder and the
context keep the dead pane. The successor is "first pane", not the neighbor.
`WorkspaceContentController.focusedPane` falls back to `panes.values.first`, so the CLI
snapshot and every "focused pane" action target a random pane when the layout focus is
missing (`WorkspaceContentController.swift:105-107`).

R3. **Responder changes outside panes are invisible.** `ShellWindow.makeFirstResponder`
reports only responders inside a `PaneContentView` (`WindowController.swift:143-150`).
Clicking the sidebar, its search field, or a rename field leaves the model, the focus
ring and the context on the terminal. With `terminalFocused` still set, the registry
runs first in `ShellWindow.performKeyEquivalent` (`WindowController.swift:138-141`), so
Cmd-C and Cmd-V typed in the sidebar search or rename field copy from and paste into
the terminal (`terminalCopy`/`terminalPaste` require only `terminalFocused`,
`CmuxNextActions/ActionCatalog+Terminal.swift:111-124`). `textBoxFocused` is declared but
never set anywhere in the App.

R4. **Model changes that do not move the responder, and the reverse.** `LayoutRootView`
focuses the pane under every mouse-down through a local monitor, before the view gets
the event (`CmuxNextLayout/Views/LayoutRootView+Scroll.swift:14-22`). The `.focus` intent then calls
`focusContent` unless the pane already holds the responder
(`WorkspaceContentController+Intents.swift:12-15`); `PaneHandlers.focus` calls
`layoutModel.focus` and `focusContent` again (`Handlers/PaneHandlers.swift:32-35`);
`PaneController.select` writes selection, shows, focuses and reports focus in four steps
(`PaneController+Intents.swift:50-57`). Each path owns a different subset of the steps.
The CLI `focusPane`/`selectTab` writes `WindowState` and then acts on the old
workspace's panes, because the workspace switch it just requested lands on a later turn
(`Compat/AppCompatFrontend.swift:49-57,100-107`, `WindowController.swift:60-73`).

R5. **CEF is outside the model.** The CEF focus target is `CEFTabContentView`, which does
not accept first responder (`CmuxNextBrowser/CEF/CEFHostView.swift:42-68`), so
`focusContent` never focuses a CEF page, and nothing calls `CEFTab.setFocused` from the
pane focus path. A click in a CEF page lands in Chromium's child `NSWindow`; the layout
mouse monitor ignores events of other windows (`LayoutRootView+Scroll.swift:15`), so the
pane does not become focused, and the child window becomes key: the model says terminal
A, the keys go to page B. Clicking back into the parent never blurs the page, and
Cmd-L (`AddressBarView.focus`) moves the parent's responder while the child window keeps
key. `keyRouter` is never assigned in the App (`CEFTab.swift:22`,
`CEFRuntime+Events.swift:63-67`), so with a CEF page focused, app shortcuts without a
main-menu item never run.

R6. **One-slot pending focus with no staleness.** `pendingFocusSurface` is one value per
workspace; two quick splits keep only the last, and a CLI split and a user split clobber
each other (`WorkspaceContentController+Intents.swift:49-59`). A pending focus lands
whenever the daemon reports the surface, even if the user clicked another pane in the
meantime (focus steal). `PaneController.newTerminalTab/newBrowserTab` have the same shape
(`PaneController+Intents.swift:71-118`).

R7. **Drag has no focus rules.** `TabDragSession` never states where focus goes
(`Drag/TabDragSession+Commit.swift:28-66`, `TabDragSession+Ghost.swift:73-104`).
`TabMoves.move` does not select the dropped tab in the target pane, so the target pane
keeps its old selection (`Drag/TabMoves.swift:14-31`); a split drop creates the pane
unfocused; if the source pane empties, R2 picks the first pane and R1 leaves the window
as first responder. A cancel does not restore anything. A reused terminal view that
moves panes can still be the old pane's `content`; the old pane's next `show` removes it
from the new pane (`PaneContentView.swift:50-54`). That blank pane is owned by the
drag-panes work; this document only requires that focus never targets a stale pane.

R8. **Overlays do not restore.** Sidebar rename ends by making the sidebar list first
responder (`SidebarListView+Rename.swift:72`); the terminal the user came from is not
restored. Palette `hide` makes its parent key (`PaletteController.swift:131-133`); when a
CEF child window was key at open, the palette's parent is that child window.

R9. **Key routing has no order.** `ShellWindow.performKeyEquivalent` runs every registry
shortcut before any view, regardless of what has the keyboard (`WindowController.swift:138-141`).
Text fields lose editing chords to content-scoped actions (R3). A web page can never
receive a chord that any registry action claims, so web apps (Figma, Linear, Docs) lose
their shortcuts. `TerminalSurfaceView.performKeyEquivalent` then asks the main menu
before a Ghostty keybind (`TerminalSurfaceView+Keyboard.swift:93-108`), and CEF skips
the registry completely (R5). `toggleBrowserFocusMode` is declared but refused as
unavailable (`Handlers/BrowserHandlers.swift:89`).

R10. **App-global context.** `ActionRegistry.context` is one value for the process.
Only the active window may publish (`WorkspaceContentController.swift:123`), and
`WindowManager.active` falls back to `lastActive` when a palette panel or a CEF child
window is key (`WindowManager.swift:26-29`), so the published bits can belong to a
window that no longer has the keyboard.

## 4. Design: one `FocusCoordinator` per window

`WindowState.focus` (one per window, PR 15773's per-window state) is the coordinator. It
reads the selected workspace and tab selection from `WindowState` (topology snapshots are
inputs, not a second owner) and itself owns the focused pane, the last focused pane per
workspace and browser focus mode; `WindowState.focusedPane` is gone. A pure state machine
owns focus. AppKit, Ghostty, WebKit, CEF, `LayoutModel` and the
registry context become outputs. Nothing else writes focus.

State (`FocusState`, value type, never persisted, never sent to the daemon):
- `windowKey`, `appActive`
- `topology`: shown workspace, panes in layout order, each with its tabs (id, surface,
  kind) and selected tab. Built from daemon state and client selection.
- `pane`: focused pane, `target`: `content | addressBar | findBar | sidebar(keyboard) |
  sidebarField | textField | none`
- `overlays`: stack of `palette | sheet | rename | groupEditor`
- `remembered[workspace]`: last focused pane per workspace (client-local)
- `expectation`: at most one pending focus (surface or tab id, target, intent generation)
- `drag`: source pane and the pane and target to restore on cancel
- `browserFocusMode`: tab ids in browser focus mode (this window only)
- `generation`: bumped by every user intent

`resolved` is a pure function of the state and yields exactly one keyboard target:
`terminal(pane, tab) | browserPage(pane, tab) | addressBar(pane, tab) | findBar(pane, tab)
| sidebar | sidebarField | textField | overlay(kind) | none`.

Events (`FocusEvent`): `topology` (daemon delta, workspace switch, selection change),
`focusPane(pane, workspace?, source)` (mouse down in a pane, keyboard navigation, CLI,
palette), `selectTab(pane, tab, source)`, `focusTarget(target)` (Cmd-L, find),
`responder(report, source)` (the first responder AppKit actually chose, including a CEF
child window becoming key), `windowKey`, `appActive`, `overlayOpened/Closed`,
`expect(expectation, generation)`, `dragBegan(tabs, pane)`, `dragEnded(cancelled |
dropped(tabs) | movedAway)`, `contentPresented(pane)`, `toggleBrowserFocusMode`.

Reducer `(FocusState, FocusEvent) -> (FocusState, [FocusEffect])`, pure, rules:
- Initial placement and workspace switch: remembered pane if it exists, else the first
  pane. The target becomes `content`, except that keyboard navigation in the sidebar
  keeps `sidebar(keyboard: true)`.
- The focused pane disappears: successor is the most recently focused surviving pane
  (closing a split you just made returns to where you were), else the next surviving pane
  after it in the old layout order, else the previous one. Deterministic, never a
  dictionary order.
- A tab moved to another pane by a shortcut, menu or CLI verb is followed: focus lands
  on it in its new pane once the daemon reports the move.
- The focused pane's selected tab changes: focus follows it; `addressBar`/`findBar` of
  the old tab fall back to `content`.
- A user intent (mouse, keyboard, CLI, palette) bumps `generation`. An expectation with an
  older generation is dropped when it would land: no focus steal.
- An expectation lands when its surface or tab appears in the topology: that pane is
  focused, the tab selected, the target applied (`content` or `addressBar`).
- `responder(windowOrNone)` never changes state: it means a view left the window, and the
  reducer re-applies the current target. Other reports are accepted as user intent
  (a click in a page, a text field, the sidebar), except while an overlay is open.
- Overlays push and pop. `resolved` is the top overlay while one is open; closing it
  restores the live target, which intents may have changed meanwhile.
- Drag: `dragBegan` records the restore point; `cancelled` restores it; `dropped` sets an
  expectation on the dropped tab in the drop window (the tab is selected in its new pane
  and focused); `movedAway` in the source window is an ordinary topology repair.
- Browser focus mode entries are pruned when their tab leaves the window.

Effects (`FocusEffect`), applied by one `FocusEffectApplier` per window after the reducer
returns, never inside it: `select(pane, tab)`, `revealPane(pane)` (mirror into
`LayoutModel` without emitting an intent, update `remembered`), `moveResponder(resolved)`,
`publishContext(bits)`. The applier is idempotent: it compares the current responder,
CEF focus and layout focus before acting. When the target content is not presented yet
it waits; `contentPresented` re-applies. Responder reports caused by the applier's own
`makeFirstResponder` are dropped (echo suppression). Events raised while effects run are
queued and reduced afterwards (FIFO), so the reducer is never re-entered. Ghostty focus
keeps its rule (first responder and key window) and therefore follows the responder the
applier sets; `debug.focus` checks it.

Entry points: layout mouse-down and keyboard navigation (`PaneHandlers`,
`ColumnHandlers`), tab strip clicks and `TabHandlers`, the CLI (`AppCompatFrontend`),
palette commands, `WindowController` key notifications, `ShellWindow.makeFirstResponder`,
the tab drag session, and creation paths (split, column, new tab, new browser, empty
workspace repair) all send events. The `pending*Focus` fields are removed. Tab selection stays client state in `WindowState.selection`, but
user selection goes through `selectTab` and the applier performs it.

Context: the coordinator of the key (else last active) window publishes
`terminalFocused`/`browserFocused` from `resolved`. The sidebar, its fields, other text
fields, sheets and rename prompts clear both, so content-scoped actions cannot run while
the user types there. The address bar and find bar keep `browserFocused` (browser chrome),
and the palette keeps the bits of the target below it, because its commands act on that
content. The registry context stays one process-wide value (the registry is shared); the
state behind it is per window.

## 5. Keyboard routing (one router, `KeyRouter`)

Every action has a key tier (`ActionKeyTier`), default from the catalog, overridable in
`cmux.json` at `shortcuts.tiers.<actionID>` (`system`, `navigation`, `content`).

| Tier | Meaning | Default members |
| --- | --- | --- |
| 0 system | Always runs, no content can capture it, also in browser focus mode and text fields | quit, closeTab, closeWorkspace, closeWindow, newWindow, commandPalette, toggleBrowserFocusMode, openSettings, showHideAllWindows, toggleFullScreen |
| 1 navigation | Beats terminal keybinds, page shortcuts and text fields | window, workspace, pane, tab, sidebar, notification and cloud categories without a content requirement: focus pane (Cmd-Opt-arrows), next/previous tab, Cmd-1..9, Ctrl-1..9, workspaces, sidebar toggle, new tab, split, column focus, Cmd-L (`focusBrowserAddressBar`) |
| 2 content | Runs only when its content has the keyboard; never in a text field | actions that require a content context (`terminalFocused`, `browserFocused`, viewer contexts): Copy, Paste, reload, back/forward, zoom |
| 3 raw | Not a registry action | the focused view: Ghostty keybinds and input, the page, the text field |

Order in `ShellWindow.performKeyEquivalent` (and in the CEF pre-key hook, which now has
the same router):
1. Tier 0 registry actions.
2. Browser focus mode on the focused page: stop, the page gets the key (then AppKit menus).
3. Tier 1 registry actions.
4. A text input has the keyboard (address bar, find bar, sidebar search or rename, sheet
   field): stop; the field and the Edit menu get editing chords.
5. Tier 2 registry actions whose context matches.
6. The focused view: Ghostty keybinds (`TerminalSurfaceView.performKeyEquivalent`), the
   page, then the main menu.

The registry picks the most specific performable action for a chord first (Cmd-R in a
page is `browserReload`, not `renameTab`), then the tier decides whether it may run now.
A Ghostty keybind that collides with a tier 1 or tier 2 action loses, unless the user
unbinds the action (`shortcuts.bindings.<id>: null`) or moves it to a lower tier in
`cmux.json`. `focusBrowserAddressBar` (Cmd-L) is tier 1 although it needs a browser tab.
Main-menu key equivalents run the same check: `ActionRegistry.menuKeyEquivalentGate`
(the App's `KeyRouter`) refuses a menu item's chord during a key-down when its tier may
not take the key from the key window's focus, so a chord the router gave to a page in
focus mode or to a text field cannot fire the menu item afterwards. A panel or sheet
over the window (palette, rename sheet) counts as a text field. Clicks in an open menu
are not gated.

Sidebar inline rename: Return, Escape or Tab ends it and gives the keyboard back to the
focused content through the coordinator; a click elsewhere keeps the clicked target.
Closing the find bar or ending address bar editing also goes through the coordinator
(`BrowserChromeView.onReturnFocusToPage`), so a Chromium page gets focus back and no
field editor keeps a caret in the parent window while the page window has the keys.

DEBUG builds add `debug.key` (a key-down dispatched into one of the app's own windows
like `NSApplication.sendEvent`: window key equivalents, then the main menu, then the
responder chain) and `debug.sidebar_rename`, for verification on windows that are
never key. The palette panel and
sheets are other windows: their own key handling runs, and the published context has no
content bits while they are open.

Browser focus mode: per browser tab, per window, in `FocusState.browserFocusMode`.
`toggleBrowserFocusMode` (Cmd-Opt-Return, tier 0) toggles it for the focused page. While
on, only tier 0 runs before the page; the page shows a thin gray inset outline. It ends
when toggled off or when the tab closes or leaves the window.

## 6. Verification contract

- Table tests for every rule and for the races in section 3, plus a random event stress
  test that checks the invariants after each step: exactly one resolved target; a
  pane-scoped target names a pane in the topology and that pane's selected tab; an
  overlay target while overlays are open; no expectation survives a newer user intent.
- `debug.focus` (control socket, main actor): per window the coordinator state and
  resolved target, the actual first responder and its classification, key window, CEF
  child key state, `LayoutModel.focusedPane`, tab ids whose Ghostty surface is focused,
  the published context, and `consistent` (model == AppKit == Ghostty, where Ghostty
  focus is expected only in the key window).
- Events for other agents: `WindowController.focus` (a `FocusCoordinator`) takes
  `send(.dragBegan)`, `send(.dragEnded(.cancelled | .dropped(tabs:awayFrom:) | .movedAway))`,
  `expect(.surface | .tab, target:, generation:)` after `beginIntent()`, and
  `send(.contentPresented(pane:))`; `PaneController.showSelected` already sends the last.
  `debug.surfaces` (drag-panes) and `debug.focus` use the daemon pane id and tab id
  (`debug.focus.windows[].topology`).
- Out of scope here, owned by drag-panes: `PaneContentView.show` removes its previous
  content view even after another pane adopted it (R7 blank pane).

## 7. Omnibar

Status: implemented 2026-09-29 (`CmuxNextBrowser/Omnibox/Omnibar*`, `UI/OmnibarController.swift`,
`UI/OmnibarEffectApplier.swift`, `UI/OmnibarFieldEditor.swift`). It replaces `OmniboxEditModel`
and the flags in `AddressBarView` (`isApplying`, `pendingDeletion`, `keepCaret`). Those flags
caused the reversed typing of #15796: a suggestion result rewrote the caret that a keystroke
had just moved.

The omnibar is one state machine inside the pane's keyboard target `addressBar(pane, tab)`.
The `FocusCoordinator` decides *whether* the omnibar has the keyboard. The omnibar machine
decides what the field shows and what each key and click means.

### State (`OmnibarState`, one value, never persisted)

| Phase | Field shows | Entered by |
| --- | --- | --- |
| `idle` | compact page URL (host at full strength), or `retainedText` (plain) | start, focus lost, second Escape |
| `focused` | full page URL, all selected on entry; page URL changes replace it | focus gained, first Escape, undo to the untouched text |
| `editing` | `userText + inlineCompletion`, or the arrowed row's text | any edit, focus gained with retained text |
| `committing(display)` | compact URL of `display` while focus returns to the page | Enter, row click, Paste and Go |

`editing` data: `userText` (marked IME text included), `inlineCompletion` (the selected suffix),
`selection` (UTF-16, as `NSTextView` reports it), `marked` (the IME composition range),
`suppressCompletion`. Popup data: `rows`, `selected` (keyboard highlight: this row drives the field text and
Enter), `hover`, `source` (keyboard or mouse), `pointer` (last pointer location over the rows),
`stale` (rows belong to older text). There is one query `generation`, a focusing-click
count, and an undo and a redo stack owned by the machine. The field editor's AppKit undo is off.

### Events (`OmnibarInput`)

- Focus: `focusGained(mouse | keyboard | programmatic)`, `focusLost`. They come from AppKit
  responder changes. Only the coordinator moves the responder
  (`FocusEffectApplier` calls `AddressBarView.focus()`; a click in the field is AppKit's own
  mouse-down, which the coordinator observes through `ShellWindow.makeFirstResponder`).
- Field editor: `fieldChanged(text, selection, marked, kind)`. `kind` is `insert`, `delete` or `paste`
  for a text edit (typing, Backspace and Delete, cut, paste, IME composition start, update and
  commit). It is nil for a selection-only change (caret moves, drag selections, Cmd-A). If you type the next
  character of a selected inline completion, the text does not change, but the event is still an edit and re-queries.
- Keys taken before the field editor's default: `up`, `down`, `tab`, `backTab`,
  `enter(currentTab | newBackgroundTab (Cmd) | newForegroundTab (Shift-Cmd, Option) | newWindow (Shift))`,
  `escape`, `selectAll` (Cmd-L when the field already has focus), `undo`, `redo`.
- Mouse: `fieldMouseDown(clickCount)`, `fieldMouseUp`, `rowHover(row?, pointer)`,
  `rowClick(row, disposition)`, `popupScroll`.
- Async and page: `suggestions(generation, rows)`, `pageURLChanged`, `searchEngineChanged`,
  `pasteAndGo(text)`.

### Rules

- Focus shows the full URL, all selected. A single click that focuses the field selects
  everything on mouse-up, unless the click dragged its own selection. Later clicks place the caret.
  A double-click selects a word and a triple-click selects all (the field editor does this; the
  machine records the selection). Cmd-L while focused selects all again.
- Focus lost (a click outside, Tab, another pane) never commits. It closes the card and keeps
  the typed text in the idle field (Chrome). The next focus restores it, all selected. A page
  navigation replaces the retained text.
- Typing asks for suggestions with a new generation. Results with any other generation, or
  results that arrive after editing ended, are dropped. The popup rows stay on screen but are `stale` until fresh
  rows arrive. If rows are stale, Enter resolves the typed text and does not pick a stale row.
- Inline completion only follows an insertion at the end of the text, never a deletion, a
  paste, an edit in the middle, or IME composition. If you type the next characters of a shown
  completion, the rest of the completion stays on screen at once. Any caret move (Right, Left, End, a click, Cmd-A)
  makes the completion typed text.
- Up and Down move the keyboard highlight, clamp at the ends, and show the row's text. Row 0
  shows the typed text again. Tab and Shift-Tab move the same way, but past either end they are not handled,
  so focus leaves the field. When the card is closed, arrows and Tab belong to the field editor.
- The mouse and keyboard highlights are one highlighted row. A hover takes the highlight only after the
  pointer moves: a card that opens, or rows that update, under a pointer that does not move
  take nothing. A keyboard move takes the highlight back until the pointer moves again. A hover never changes the
  field text, and Enter commits what the field shows. A row click commits that row with the
  click's modifiers. The card has at most 8 rows and never scrolls; the wheel over it is swallowed.
- If results arrive while the user arrows through rows, the chosen row stays selected. If the chosen
  row is not in the new results, the machine keeps the old rows.
- Escape once reverts to the page URL (`focused`, all selected; Cmd-Z brings the text back).
  Escape with nothing to revert ends editing (`.cancel`) and the chrome returns focus to the
  page through the coordinator (`onReturnFocusToPage`).
- IME: while marked text is pending, suggestions still update, but nothing completes. Arrows, Tab,
  Enter and Escape go to the input method, and the applier never writes the field. A row
  click or Paste and Go first commits the marked text (`unmarkText`).
- Page URL changes: `focused` follows them (all-selected stays all-selected), `editing` never
  changes the typed text (Escape reverts to the new URL), and `committing` shows the new page.
- Undo: consecutive edits of one kind share an entry, paste and IME composition each start one,
  and the first entry is the untouched URL. Undo and redo re-query.
- Paste turns line breaks into spaces. Paste and Go resolves the clipboard and commits.
- A search engine switch re-queries and keeps an arrowed row.
- Enter with modifiers reports `.open(url, disposition)`, and the page stays. The chrome calls
  `onOpenURL` (the App must wire it; until then, the current tab loads the URL).

### Effects and the applier

`OmnibarReducer.reduce(state, input, resolver) -> (state, effects, handled)` is pure. `handled`
false lets the field editor run its default. The effects are `query(generation, text)`, `cancelQuery`,
`beep`, `began` and `ended(commit | open | cancel | blur)`. `OmnibarController` reduces inputs
first in, first out (inputs raised while a step runs are queued). It then applies
`OmnibarPresentation(state)` through `OmnibarEffectApplier` and runs the effects. The applier is the only
writer of the field and the card. It writes text, style and selection only when they differ from
the field. It never writes while the field editor has marked text. Its own writes are echoes
and are dropped (`isApplying`). The field editor reports selection changes only when a drag
ends and outside an edit, so an edit reaches the machine as one event with its final text and caret.

### Verification

- `OmnibarKeyboardTests` and `OmnibarMouseAndAsyncTests`: table tests through the reducer and
  the real applier on a fake field. They include the reversed-typing regression (with and without
  suggestions between keys), mouse-then-keyboard highlight conflicts, stale results, Japanese
  IME with completion suppressed, and navigation during an edit.
- `OmnibarStressTests`: 8 seeds x 3,000 random events. After every step the test checks:
  field text == model text, the caret is within bounds, the field selection == the model selection, at most one
  highlighted row, suggestions are closed when not editing, and no completion and no field write
  happen while composing.
- `OmnibarTypingTests`, `OmnibarViewTests` and `OmnibarFieldEditorTests` use the real
  `BrowserChromeView` offscreen and the omnibar's own field editor. They cover marked text, undo, Cmd-Return,
  row hover and click, focus loss and navigation while typing.
