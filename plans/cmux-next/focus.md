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
receive a chord that any registry action claims, so web apps (design tools, issue trackers, document editors) lose
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
dropped(tabs) | movedAway)`, `contentPresented(pane)`, `toggleBrowserFocusMode`,
`sidebarVisibility(hidden)` (sent synchronously when Toggle Sidebar or an edge drag hides the
sidebar: a sidebar or sidebar-field target returns to `content`, and while hidden sidebar
responders and targets are refused).

Reducer `(FocusState, FocusEvent) -> (FocusState, [FocusEffect])`, pure, rules:
- Initial placement and workspace switch: remembered pane if it exists, else the first
  pane. The target becomes `content`, except that keyboard navigation in the sidebar
  keeps `sidebar(keyboard: true)`.
- The focused pane disappears: successor per `layout.closeFocus` (close-focus.md):
  default the previous pane in its column, else the next one there, else the column to the
  left (its most recently focused pane), else the column to the right, on the same screen;
  `mostRecent` takes the newest surviving pane of the history first. Deterministic, never
  a dictionary order.
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

## 4a. Directional focus with history

Dogfood report (nxdog9): "left then right" must return to the pane you came from, not to
the geometrically nearest pane.

Rule: a directional move picks among the panes adjacent in that direction, and the most
recently focused one wins. Every focus source updates the history (a click, the CLI, the
palette, a directional move, a script). A pane position breaks a tie.

- History: `FocusState.history[workspace]`, newest first, at most 64 panes per workspace, per
  window, in memory, never persisted. `FocusReducer.finish` records the focused pane after
  every reduction, whatever the source (mouse, keyboard, CLI, palette, a responder report, a
  landed expectation, app-driven repair); a `focusPane` or `selectTab` for a workspace the
  window does not show records into that workspace. A topology for the shown workspace drops
  panes it no longer holds (closed or moved away), after the closed-pane successor is chosen.
- `FocusNavigation.neighbor` (CmuxNextLayout): candidates lie entirely past the current
  pane's edge (1.5 pt tolerance). The adjacent ones overlap it on the other axis at the
  smallest distance, which allows the gaps between panes. Among them the most recently
  focused wins. Without history among them: the largest overlap, the nearest center, then
  the top-left pane (first in pane order). When nothing overlaps, the nearest edge,
  then the nearest center. History never skips a pane: in A | B | C, left from C is B even
  if A was focused after B.
- strip columns: a left or right move that lands in another column goes to that column's
  most recently focused pane (each column keeps an active tile), else to the geometric
  choice. `column.focusLeft` and `column.focusRight` pick the column's most recently focused
  pane, else its first.
- Screens: every screen switch (switcher click, `screen.next`, `screen.previous`,
  `screen.select`) sends `LayoutIntent.selectScreen`; the window focuses that screen's most
  recently focused pane, else its first (a screen keeps its active pane).
- Entry points: `focusLeft`/`focusRight`/`focusUp`/`focusDown` (Cmd-Opt-arrows, the palette,
  the CLI, Ghostty `goto_split:*` keybinds such as Cmd-Ctrl-HJKL through
  `TerminalHostActionRoute`) and the tab moves to a neighbor pane, all through
  `PaneHandlers.neighbor`.
- No wrap at the window edge (cmux refuses with "no pane left of the focused pane"). A pane
  never focused has no history, so position decides.

Tests: `FocusHistoryNavigationTests` (reducer plus navigation in several split layouts,
strip columns, screens, workspaces, closed panes, every source), `FocusNavigationTests`.

## 5. Keyboard routing (one router, `KeyRouter`)

Every action has a key tier (`ActionKeyTier`), default from the catalog, overridable in
`cmux.json` at `shortcuts.tiers.<actionID>` (`system`, `navigation`, `content`).

| Tier | Meaning | Default members |
| --- | --- | --- |
| 0 system | Always runs, no content can capture it, also in browser focus mode and text fields | quit, closeTab, closeWorkspace, closeWindow, newWindow, commandPalette, toggleBrowserFocusMode, openSettings, showHideAllWindows, toggleFullScreen |
| 1 navigation | Beats terminal keybinds, page shortcuts and text fields | window, workspace, pane, tab, sidebar, notification and cloud categories without a content requirement: focus pane (Cmd-Opt-arrows), next/previous tab, Cmd-1..9, Ctrl-1..9, workspaces, sidebar toggle, new tab, split, column focus, Cmd-L (`focusBrowserAddressBar`) |
| 2 content | Runs only when its content has the keyboard; never in a text field | actions that require a content context (`terminalFocused`, `browserFocused`, viewer contexts): Copy, Paste, reload, back/forward, zoom |
| 3 raw | Not a registry action | the focused view: Ghostty keybinds and input, the page, the text field |

Order (steps 1-3 run app-wide in `CmuxApplication.sendEvent`, before any window or
responder sees the key, for every window of the process: the cmux window, a WebKit
page, the address bar, or a Chromium page window that is key itself; panels and
sheets keep their keys. Step 5 runs in `ShellWindow.performKeyEquivalent` and in the
CEF pre-key hook, which run tier 2 only, so nothing runs twice. Only Command or
Control chords are candidates, so typing, Option characters and IME input pass):
1. Tier 0 registry actions.
2. Browser focus mode on the focused page: stop, the page gets the key (then AppKit menus).
3. Tier 1 registry actions. When the registry has no action for the chord and no
   terminal has the keyboard, the user's Ghostty keybinds for window, tab and split
   actions (`cmd+ctrl+h=goto_split:left`, read with `ghostty_config_trigger`, one chord
   per action) run the registry action the terminal path maps them to
   (`TerminalHostActionRoute`); a focused terminal runs its own Ghostty keybinds.
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

Leader key (Cmd-J, `LeaderLayer`). Before step 1, a two-key chord's first key arms it
(`ChordTracker`). Cmd-J is the leader: it arms whenever some binding sits under it, even
one that cannot run in this focus, and a which-key overlay (`WhichKeyController`,
`WhichKeyPanel`) lists every key under it, bottom center of the window, until the next
key. That key runs its action, or, when it completes nothing (Escape, an unbound key,
Cmd-J again), dismisses the overlay and reaches no view. Defaults: Cmd-J J Scroll to
Selection (`terminal.scrollToSelection`, Ghostty's macOS Cmd-J, so cmux loads
`keybind = super+j=unbind` before the user's Ghostty files), Cmd-J S New Agent Chat
(which keeps Shift-Cmd-I), Cmd-J ? (Shift-/) Search Keyboard Shortcuts. Each is an
ordinary chord in `cmux.json` (`"terminal.scrollToSelection": ["cmd+j", "k"]`); a single
key or `null` for an action drops its leader chord, and a user's own single-key `cmd+j`
binding for any action makes the default leader chords step aside, so that action runs. A chord of the user's own under `cmd+j` keeps the leader armed, so a single-key `cmd+j`
binding next to it never runs; pick one.
The leader arms before a terminal sees the key, so cmux cannot tell that a Ghostty
config binds `super+j` (a later `keybind` line only replaces cmux's unbind inside
Ghostty's config); to give Cmd-J back to Ghostty, unbind the three leader chords in
`cmux.json` (`terminal.scrollToSelection`, `palette.newAgentChat`,
`palette.searchShortcuts` set to `null`). Where it arms (`KeyRouter.canArm`): Cmd-J is
the app leader everywhere content shortcuts run (a terminal, a page, an agent chat, the
sidebar list), never in a native text field, DevTools or browser focus mode, and never
while an input method has marked text. In a page this shadows the site's own Cmd-J (VS
Code for the web's Toggle Panel, for one); rebind or unbind the leader chords in
`cmux.json` to give it back. Holding Cmd-J keeps the leader armed (repeats are
ignored); a focus change in its window, a click or a window closing ends it.

Browser context (a page, the address bar or the find bar has the keyboard). A chord
resolves in this order: a cmux registry action (catalog default or `cmux.json`; the
most specific performable one, so Cmd-[ is `browserBack` with a browser focused),
then the tier decides; only when the registry has no action for the chord may the
Ghostty keybind fallback run, and in a browser context never for a standard browser
chord (`BrowserChordTable.chromeReserved`). The standard browser chords: Cmd-[ / Cmd-] and Cmd-Left / Cmd-Right
(Back, Forward), Cmd-R, Cmd-Shift-R, Cmd-. (reload, hard reload, stop), Cmd-L, Cmd-T,
Cmd-Shift-T, Cmd-W, Cmd-Shift-W, Cmd-N, Cmd-Shift-N, Cmd-F, Cmd-G, Cmd-Shift-G, Cmd-E,
Cmd-D, Cmd-Shift-D, Cmd-Shift-B, Cmd-Opt-B, Cmd-Y, Cmd-Shift-J, Cmd-P, Cmd-S, Cmd-O,
Cmd-Opt-U, Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C, Cmd-= / Cmd-+ / Cmd-- / Cmd-0, Cmd-1..9,
Cmd-Opt-Left / Right, Cmd-Shift-[ / ], Ctrl-Tab, Ctrl-Shift-Tab, and the edit chords
Cmd-A/C/V/X/Z, Cmd-Shift-Z, Cmd-Shift-V, Cmd-Opt-Shift-V. Where cmux binds one of
these itself (Cmd-D split, Cmd-T new tab, Cmd-W close, Cmd-1..9 tab, Cmd-Opt-arrows
pane focus, Cmd-L address bar), cmux's action wins, as before. A chord in the list
without a cmux action goes to the page (or the field), except the browser tab-switching
chords (Ctrl-Tab, Ctrl-Shift-Tab, Ctrl-PageDown, Ctrl-PageUp, and Cmd-Opt-Right/Left
and Cmd-Shift-]/[ when cmux does not bind them): cmux tabs are the browser's tabs, so
`BrowserChordTable.tabNavigation` runs cmux's next/previous tab (tier 1) for them;
unbinding `nextSurface`/`prevSurface` in `cmux.json` removes these aliases. The Ghostty fallback applies
only to chords that are neither cmux actions nor standard browser chords (for example `cmd+ctrl+h`). In a
terminal the terminal runs its own Ghostty keybinds, still after cmux's registry.

Browser-only chords (user 2026-09-30: "cmd[] in terminal should do nothing.
should only do stuff in browsers. consistency is most important for keyboard
shortcuts"): the effective chords of `browserBack` and `browserForward`
(Cmd-[ / Cmd-] by default, or the user's rebinding) act only in a browser
context. Anywhere else (a terminal, the sidebar, a text field of the window)
the app-wide interceptor consumes them and runs nothing: no Ghostty keybind
(`super+[` is `goto_split:previous` by default), no shell input, no menu
item (`BrowserChordTable.browserOnlyActions`, `KeyRouter.consumesBrowserOnlyChord`;
`BrowserOnlyChordTests`). A cmux action the user binds to the same chord in
another context still runs first. The location trail's Go Back / Go Forward
are Ctrl-Cmd-Left / Ctrl-Cmd-Right in every context (history.md 4.2).

Sidebar inline rename: Return, Escape or Tab ends it and gives the keyboard back to the
focused content through the coordinator; a click elsewhere keeps the clicked target.
Closing the find bar or ending address bar editing also goes through the coordinator
(`BrowserChromeView.onReturnFocusToPage`), so a Chromium page gets focus back and no
field editor keeps a caret in the parent window while the page window has the keys.

DEBUG builds add `debug.key` (a key-down dispatched into one of the app's own windows
like `NSApplication.sendEvent`: the app-wide interceptor, window key equivalents, then
the main menu, then the responder chain; `"target": "page"` sends it to a pane's
Chromium page window) and `debug.sidebar_rename`, for verification on windows that are
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
| `focused` | page URL, all selected on entry: elided (steady state) after a click, programmatic focus or Escape, full after Cmd-L or any other selection; page URL changes replace it | focus gained, the revert Escape, undo to the untouched text |
| `editing` | `userText + inlineCompletion`, or the arrowed row's text | any edit, focus gained with retained text |
| `committing(display)` | compact URL of `display` while focus returns to the page | Enter, row click, Paste and Go |

`editing` data: `userText` (marked IME text included), `inlineCompletion` (the selected suffix),
`selection` (UTF-16, as `NSTextView` reports it), `marked` (the IME composition range),
`suppressCompletion`. `focused` data: `elided` (the field shows `BrowserURLDisplay.displayText`
instead of the full URL). Mouse data: `mouse` (the press being tracked: click count, button,
`selectAllOnRelease`, the word under a click on the elided URL) and `doubleClickWord`. Popup data: `rows`, `selected` (keyboard highlight: this row drives the field text and
Enter), `hover`, `source` (keyboard or mouse), `pointer` (last pointer location over the rows),
`stale` (rows belong to older text). There is one query `generation`, and an undo and a redo stack owned by the machine. The field editor's AppKit undo is off.

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
  `escape`, `selectAll` (Cmd-A), `focusLocation` (Cmd-L when the field already has focus),
  `home(extend)` (Home, Shift-Home), `deleteSuggestion` (Shift-Delete), `undo`, `redo`.
- Mouse: `fieldMouseDown(clickCount, button, word)`, `fieldMouseUp`, `rowHover(row?, pointer)`,
  `rowClick(row, disposition)`, `popupScroll`.
- Async and page: `suggestions(generation, rows)`, `pageURLChanged`, `searchEngineChanged`,
  `pasteAndGo(text)`.

### Rules

- Selection and focus follow the table below.
- Focus lost (a click outside, Tab, another pane) never commits. It closes the card and keeps
  the typed text in the idle field. The next focus restores it, all selected. A page
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
- Escape does one step per press (table below). The revert step goes to `focused`, all
  selected, and Cmd-Z brings the text back. Escape on untouched text ends editing (`.cancel`) and
  the chrome returns focus to the page through the coordinator (`onReturnFocusToPage`).
- IME: while marked text is pending, suggestions still update, but nothing completes. Arrows, Tab,
  Enter and Escape go to the input method, and the applier never writes the field. A row
  click or Paste and Go first commits the marked text (`unmarkText`).
- Page URL changes: `focused` follows them (elided, all selected), `editing` never
  changes the typed text (Escape reverts to the new URL), and `committing` shows the new page.
- Undo: consecutive edits of one kind share an entry, paste and IME composition each start one,
  and the first entry is the untouched URL. Undo and redo re-query.
- Paste turns line breaks into spaces. Paste and Go resolves the clipboard and commits.
- A search engine switch re-queries and keeps an arrowed row.
- Enter with modifiers reports `.open(url, disposition)`, and the page stays. The chrome calls
  `onOpenURL` (the App must wire it; until then, the current tab loads the URL).

### Selection and focus

Reference: Chromium `main`, fetched 2026-09-30. `OVV` is
chrome/browser/ui/views/omnibox/omnibox_view_views.cc, `OEM` is
chrome/browser/ui/omnibox/omnibox_edit_model.cc, `SC` is ui/views/selection_controller.cc,
`OTU` is components/omnibox/browser/omnibox_text_util.cc. Tests: `OmnibarSelectionTests`
(reducer) and `OmnibarSelectionViewTests` (real field editor).

| Rule | Chromium source |
| --- | --- |
| A left or right press on the unfocused field arms select-all-on-release. The release selects all, unless the press dragged a selection of its own. | `OVV` `OnMousePressed`, `OnMouseDragged`, `OnMouseReleased` (`select_all_on_mouse_release_`) |
| A focusing click keeps the steady-state (elided) URL: select-all never unelides. | `OVV` `UnapplySteadyStateElisions` ("If everything is selected ...") |
| Any other selection shows the full URL and maps the selection by the elided text's offset. Keys and caret moves unelide at once; mouse selections unelide on release. | `OVV` `OnAfterPossibleChange` (`!is_mouse_pressed_`), `OnMouseReleased` (`kMouseRelease`) |
| A drag that starts at the start of a URL-like selection keeps the scheme: `google.com/maps` becomes `https://www.google.com/maps`. A selection that reads as a search only shifts. | `OVV` `UnapplySteadyStateElisions` (`kMouseRelease`, `selection_classifes_as_search`) |
| A click in the focused field places the caret; a double-click selects a word; a triple-click selects all (field editor granularity). | `SC` `OnMousePressed` (`aggregated_clicks_` 0, 1, 2) |
| A double-click whose first click unelided selects the word under the first click, not the word now under the pointer. | `OVV` `OnMousePressed` (`next_double_click_selection_*`, crbug.com/40693090) |
| A right-click on the unfocused field focuses it and selects all at the press, before the menu. On a focused field the field editor selects the word under the pointer unless the click is in the selection or all is selected. | `SC` `OnMousePressed`, `PlatformStyle::kSelectAllOnRightClickWhenUnfocused` and `kSelectWordOnRightClick` (both Mac only) |
| Cmd-L focuses, shows the full URL and selects all, also while focused (then typed text is all selected). A programmatic focus selects all and stays elided. | `OVV` `SetFocus` (`OEM` `Unelide`, `select_all`) |
| Cmd-A selects all and keeps the elided URL. | `OVV` `IsSelectAll`, `UnapplySteadyStateElisions` |
| Home unelides even from select-all and puts the caret at 0 (Shift-Home selects to 0). | `OVV` `HandleKeyEvent` `VKEY_HOME` (`kHomeKeyPressed`) |
| Typing replaces the selection. An inline completion is a selected suffix; Backspace removes it; Right arrow or any caret move accepts it. Tab moves to the next row (it does not accept). | `OEM` `OnAfterPossibleChange`, `OnTabPressed` |
| Shift-Delete removes the keyboard-selected history row and moves the selection to the next row; on other rows the field deletes forward. | `OVV` `HandleKeyEvent` `VKEY_DELETE`, `OEM` `TryDeletingPopupLine` |
| Escape: (1) an arrowed row reverts to the typed text, the card stays; (2) an open card closes, the text stays; (3) revert to the display text, all selected; if the user had not typed, focus also returns to the page in the same press. | `OEM` `OnEscapeKeyPressed` |
| Blur clears the selection and shows the elided URL from its start. Typed text stays, unless it equals the display text. | `OVV` `OnBlur` |
| A navigation while focused and untyped shows the new display text, all selected. Typed text never changes. | `OVV` `Update`, `OEM` `ResetDisplayTexts` |
| Copy of the whole untouched URL, elided or full, copies the full page URL (also as a URL). Other text from the start that reads as a URL on the page's host gets the page's scheme; anything else copies as is. | `OEM` `AdjustTextForCopy`, `OTU` `AdjustTextForCopy`, `OVV` `OnBeforeCutOrCopy` |

Differences: Chromium's Opt-Cmd-F (`IDC_FOCUS_SEARCH`, `LocationBarView::FocusSearch`) enters
keyword mode for the default search engine; cmux has no keyword mode and binds nothing to it.
Focus by Tab traversal does not restore the selection saved at blur (`OVV` `OnFocus`); it
selects all. A drag that exceeds Chromium's drag threshold but ends with an empty selection
still selects all (AppKit reports no threshold). Selection color is `Palette.textSelection` and
the caret `Palette.textPrimary`, both derived from the Ghostty theme (`ThemeTokens`); both
engines use this one omnibar (`BrowserChromeView` for every `BrowserTab`).

Debug: `debug.omnibar` reports the machine next to the field editor (`consistent`), and
`debug.mouse` (DEBUG builds) presses, drags and releases over a character index of the text.

### Effects and the applier

`OmnibarReducer.reduce(state, input, resolver) -> (state, effects, handled)` is pure. `handled`
false lets the field editor run its default. The effects are `query(generation, text)`, `cancelQuery`,
`beep`, `began`, `ended(commit | open | cancel | blur)` and `deleteSuggestion(url)`. `OmnibarController` reduces inputs
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

## 8. Focus ring

Status: implemented 2026-09-30. The ring is an overlay: `PaneOverlayView` in the layout's
`OverlayPlane` (above Chromium page windows), stroked inside the pane's content area, so
it never changes a pane frame, inset or the hosted view's frame
(`FocusRingNoShiftTests` moves focus across splits and strip columns under every ring
style, width and corner setting). cmux.json `focusRing.{enabled, style (ring | glow |
none), color (default: the Ghostty theme's focus gray), width, cornerRadius (default: the
pane radius), showWhenSinglePane, contrast (subtle | standard | strong)}`; palette: Toggle Focus Ring, Use Ring / Glow Focus
Style, Toggle Focus Ring for a Single Pane. The glow is a stroke with a shadow clipped to
the content rect, so it falls inward only. The attention ring of an unread notification
shares the overlay (plans/cmux-next/notifications.md). Column scrolling:
plans/cmux-next/column-scroll.md.

Contrast (2026-10-02, user: "we need focus ring to be subtler by default somehow. color
subtler"): `focusRing.contrast` sets the pane ring's share of the theme focus color (the
Ghostty foreground; it replaces the token's own alpha): subtle 0.20 (the default),
standard 0.55 (the previous look), strong 0.85. `FocusRingSettings.ringColor(in:override:)`
is the one rule the overlay draws (`Palette.paneFocusRing`) and `FocusRingContrastTests`
checks: subtle stays at least 1.4 times a pane border's visibility in every fixture theme,
so the focused pane is still findable. No accent hue. The accent uses of `Palette.focusRing`
(Settings tint, omnibar and page info rings) do not change. Settings: Appearance > Focus
Ring > Contrast; Debug Settings: Focus > Focus ring alpha overrides it.

Focus indicator and tab bar background (2026-10-02, user: "ensure bg of tabbar negative
space is same as rest of app. also we should visually differ the focused pane's tabs from
unfocused panes tabs by making the latter more subtle. all this should be configurable by
the user."):
- `appearance.tabBarBackground`: `window` (default) paints no strip fill, so the space
  around and between the tabs is the window's own background (the titlebar and pane gaps,
  whatever the backdrop: opaque, translucent or glass); where the sheet shows another color
  (a workspace theme of the other lightness than its space) the strip paints the pane's
  window color instead (`TabBarBackground.paintsStripFill`). `darker` is the previous
  shaded strip (`Palette.stripBackground`). The sidebar has its own vibrancy backdrop, so in
  a translucent or glass window it differs from the sheet (as before this change).
- `appearance.focusIndicator`: `border` (the ring only), `tabs` (no ring; the other panes'
  tabs draw subtler), `both` (default, with the subtle ring), `none`. With one pane nothing
  is marked. The tabs cue needs no border, so it works with `appearance.borders` none.
- Mechanism: `ScreenContentView.updateChrome` computes `ChromeEmphasis.forPane` per pane
  and gates the ring on `marksBorder`; `PaneContentChrome.setChromeEmphasis` reaches
  `PaneContentView`, whose strip roots its own child `ThemeScope`; `ThemeScope.setEmphasis`
  applies `ThemeTokens.emphasized` to that scope's own views only (children and the content
  keep the plain colors), and the scope repaint is the same path a theme change uses.
  No Tabs code changes; no accent hue.
- Debug Settings (Focus): `focus.indicator` and `focus.tabBarBackground` override the
  settings; `focus.inactiveTabStyle` overrides the cmux.json key of the same name (`fade` default: text, icons
  and pills fade toward the background; `tonal`: every text tier steps down, the selected
  pill takes the hover fill; `quiet`: no pill, the selection is the text tier);
  `focus.inactiveTabStrength` (0.35). Subtle text never drops below 3.5:1 (selected),
  2.5:1 and 2:1 against the page (`ThemeTokens.subtle*Floor`). Panels and hover cards
  opened from a subtle strip adopt `ThemeScope.fullStrength`, so they draw at full strength.
- With `appearance.borders` none the unfocused panes' dim stands in for the ring only when
  `focusIndicator` is `border`; with `tabs` or `both` the tab cue is the focus cue.
- Chrome lane (WindowBackdrop, cc-pane-chrome) reads `DesignSettings.shared
  .effectiveFocusIndicator` and `.effectiveTabBarBackground`.

Resize rule (2026-09-30): the ring's layers move in the same call that sets the overlay's
frame (`PaneOverlayView.setFrameSize`), so the pass that places the panes places the ring,
even when the plane lives in the overlay panel above Chromium pages, whose own layout pass
runs later (`FocusRingResizeTests`; `debug.layers` `ring_in_sync`, DEBUG `ring_lag_passes`).
A page window the fork adds goes below the overlay inside `ShellWindow.addChildWindow`, so
no frame shows a new page over the ring (`OverlayPageOrderTests`).
