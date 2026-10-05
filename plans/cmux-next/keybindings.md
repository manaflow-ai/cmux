# Keybindings: key ordering, binding table and customization

Status: step 1 (map and root cause) written 2026-10-03 at `feat-cmux-next` 0e15d7d4059;
step 2 (one dispatcher, binding table, Ctrl-Tab fix) implemented the same day.
Spec: cmux-next-spec `spec/keybindings-and-palette.md` (R59). Scope: one key dispatcher,
a binding table with `when` clauses, then the customization slices. Default bindings do
not change (K1). Paths are under `Packages/macOS/CmuxNext/Sources/` unless noted.

## 1. Every key-down path today

A key-down passes these owners in this order. Each row says who decides and where.

| # | Owner | Where | What it takes |
| --- | --- | --- | --- |
| 0 | Input journal | `CmuxApplication.sendEvent` -> `inputObserver` | observes only |
| 1 | Shortcut recorder of a Settings pane | `KeyRouter.interceptKeyDown` -> `settingsWindow.handlePaneRecorderKey` | every key while recording |
| 2 | Popup panel (or its Chromium page) | `popups.interceptKeyDown` | Cmd-W closes the popup |
| 3 | Link hints | `linkHints.interceptKeyDown` | letters, Backspace, Escape |
| 4 | Armed chord / Cmd-J leader | `KeyRouter.routeChord` -> `ChordTracker.step` -> `registry.resolveChord`, `LeaderLayer.chordPrefix` | first key of a two-key chord, the key after it |
| 5 | Tier 0 and tier 1 registry actions | `KeyRouter.interceptKeyDown` -> `candidate(for:focus:)` -> `registry.resolveShortcut` (global `registry.context`) | Cmd/Ctrl chords only; cmux content windows and Chromium page windows only (`KeyWindowKind.content`) |
| 5a | Browser tab-switch aliases | `candidate` -> `BrowserChordTable.tabNavigation` | Ctrl-Tab, Ctrl-Shift-Tab, Ctrl-PageDown/Up, Cmd-Opt-Left/Right, Cmd-Shift-[/] in a browser context only |
| 5b | Ghostty host keybind fallback | `candidate` -> `GhosttyRuntime.hostAction(forKeyDown:)` -> `TerminalHostActionRoute` | one trigger per Ghostty action (see 3.1); skipped when a terminal has the keyboard |
| 5c | Browser-only chords outside a browser | `consumesBrowserOnlyChord` | Cmd-[ / Cmd-] consumed, nothing runs |
| 6 | AppKit `NSApplication.sendEvent` | AppKit | key window gets the event |
| 7 | Window key equivalent, tier 2 | `ShellWindow.performKeyEquivalent` -> `routeContentKeyEquivalent` (again `registry.resolveShortcut`, global context) | content actions, extension shortcuts (`chrome.commands`) |
| 7a | Chromium pre-key hook, tier 2 | `KeyRouter.browserTab(_:keyEquivalent:)` (page window is key) | same as 7 |
| 7b | DevTools pre-key hook | `browserTab(_:devToolsKeyEquivalent:)` | Cmd-Opt-I/J/C only |
| 8 | Views' `performKeyEquivalent` | `TerminalSurfaceView` (Ghostty binding check, then the main menu, then `keyDown`), `BrowserChromeView` (`BrowserChromeCommand`), `TerminalFindBarView`, `RemoteInputCaptureView` | per view |
| 9 | Main menu key equivalents | AppKit, gated by `ActionRegistry.menuKeyEquivalentGate` = `KeyRouter.allowsMenuKeyEquivalent` (tier re-check) | menu items with a key equivalent |
| 10 | First responder `keyDown` | `TerminalSurfaceView.keyDown` (copy mode first, then IME, then Ghostty), `WebKitWebView.keyDown` (Escape leaves fullscreen), `OmnibarFieldEditor`, `SidebarListView.keyDown`, `HomeFieldView`, field editors (`doCommandBy`) | the rest |
| 11 | `NSWindow.keyDown` | AppKit | Tab / Ctrl-Tab move the key view loop when nothing took the key |

Other windows: the palette panel takes keys in its own `sendEvent` and
`performKeyEquivalent` (`PalettePanel.keyHandler`); the Settings and Debug Settings
windows, the quick composer, page info, notifications, feed and onboarding panels
have their own `performKeyEquivalent` / `keyDown` / `cancelOperation`. For all of
them `KeyRouter.focus(for:)` returns `textPanel` or `other`, and steps 4-5 do not run.
Local event monitors (`TabDragSession`, `ScreenDragSession`, `TabStripView+Drag`,
`HoverCardCoordinator`, `AppControl`, `ChromiumWarmup`) watch Escape and input for
their own state and never route shortcuts.

Facts that steps 5 and 7 read:
- the focus of the window (`FocusCoordinator.state.resolved`, per window), and
- the registry context (`ActionRegistry.context`, one value for the process), which
  `FocusEffectApplier` publishes from the focus of the active window. `canPerform`
  checks `requires` against this global value, not against the window the key goes to.

## 2. Ctrl-Tab and Ctrl-Shift-Tab per surface (code reading, 0e15d7d4059)

| Surface | Focus `resolved` | Path that sees Ctrl-Tab | Result |
| --- | --- | --- | --- |
| Terminal | `terminal` | 5: no registry binding; 5b refused (terminal); 8: Ghostty `ctrl+tab=next_tab` is a binding, main menu has none, `keyDown` -> Ghostty -> `gotoTab(.next)` -> `nextSurface` | next tab, only while the terminal view is first responder and copy mode is off |
| Terminal, alt screen | `terminal` | same as terminal (the binding is not `performable`) | next tab |
| Terminal, copy mode | `terminal` | 10: `copyMode.handleKeyDown` takes every non-Command key | FAILS: copy mode eats it |
| Page (WebKit) | `browserPage` | 5a alias -> `nextSurface` (tier 1) | next tab |
| Page (Chromium) | `browserPage` (page window is key) | 5a alias | next tab |
| Text field in a page | `browserPage` | 5a alias | next tab |
| Address bar, find bar | `addressBar`, `findBar` | 5a alias | next tab |
| Page in browser focus mode | `browserPage` + focus mode | tier 1 refused, the page gets it | page (by design) |
| Agent chat composer | `agentPage` | 5: no binding; 5a refused (not a browser context); 5b: Ghostty reverse map has `super+shift+]` for `next_tab`, not `ctrl+tab`; 7: nothing; 10: `WKWebView`; 11: key view loop | FAILS |
| Settings, App Store, Tasks, Inbox | `page` (`LocalPageTab`) | as agent chat | FAILS |
| Home (conversation tab) | `emptyPane`: `FocusTopology.Kind.of` maps `.conversation` to `.other` | as agent chat | FAILS |
| Empty or loading pane | `emptyPane` | as agent chat | FAILS |
| Sidebar list | `sidebar` | as agent chat; `SidebarListView.keyDown` passes it on | FAILS |
| Sidebar search or rename field | `sidebarField` | as agent chat | FAILS |
| Other text field (terminal find bar) | `textField` | as agent chat | FAILS |
| Palette open | `overlay(palette)`, key window = palette panel | steps 4-5 skip panels; palette `keyHandler` | palette keeps it (by design) |
| Diff, Markdown | none: cmux-next has no diff or Markdown viewer yet (`MiscHandlerStrings.diffViewer`, `.markdownViewer`) | not applicable | rows wait for the viewers |

Ctrl-PageDown / Ctrl-PageUp have the same table, except that the terminal has no
Ghostty default for them on macOS, so the shell gets them.

UNVERIFIED in a live app: step 11 (whether AppKit moves the key view on an unhandled
Ctrl-Tab in a `WKWebView` or a native page, which would also move focus). The fix
consumes the key before AppKit, so the outcome does not depend on it.

## 3. Root causes

3.1 **Ctrl-Tab is not a binding.** No registry entry binds Ctrl-Tab. Three side tables
stand in for it, each for some surfaces:
- Ghostty's own keybind inside a focused terminal (step 8);
- `BrowserChordTable.tabNavigation`, only in a browser context (step 5a);
- the Ghostty host keybind fallback (step 5b). It reads Ghostty's reverse map
  (`ghostty_config_trigger`), which keeps one trigger per action: the last one bound.
  Ghostty binds `ctrl+tab` for every platform first and `super+shift+]` for macOS
  after it (`ghostty/src/config/Config.zig`, "Tabs common to all platforms"), so the
  fallback knows only Cmd-Shift-], which is already cmux's own `nextSurface` key.
So every surface that is neither a terminal nor a browser has no owner for Ctrl-Tab.

3.2 **Resolution has several copies.** `registry.resolveShortcut` (steps 5 and 7),
`registry.resolveChord` (step 4), `registry.resolve(Shortcut)` (`routePageKey`), the
aliases, the Ghostty fallback and the menu gate each decide part of "which action owns
this key". Each copy has its own order and its own exceptions.

3.3 **The context is global.** `canPerform` reads the process-wide `registry.context`,
not the focus of the window the key goes to (focus.md R10). A key in a Chromium page
window or a second window can resolve against another window's bits.

3.4 **Tiers are split across places.** Tiers 0-1 run in `sendEvent`, tier 2 in the
window hook and the Chromium hook, and the menu gate re-derives the tier rule. The
three places must agree by convention.

3.5 **IME is checked only for chords.** Tiers 0-2 run while an input method composes
(marked text). Spec step 1 gives every key to the input method then.

3.6 **Home has no surface kind.** A conversation tab resolves to `emptyPane`, so no
binding can target Home and no context key can name it.

## 4. Target: one dispatcher

`KeyDispatcher` (in `KeyRouter`) decides every key-down of every cmux window in
`CmuxApplication.sendEvent`, before any window, view or menu:

1. Input method composing (marked text in the key window's first responder): deliver.
2. An armed chord: the key completes or cancels it.
3. Resolve against the binding table with the live context keys of the window the key
   goes to: layers default < app < user, the last matching entry wins (VS Code rule).
   An entry whose action cannot run now (no handler, disabled, unavailable) is skipped,
   as today, so a disabled action never eats a key.
4. If an action resolves and its tier may take the key from this focus, run it and
   consume the key.
5. Else deliver the key to the focused surface (terminal, page, text field, agent
   composer), which may use its own keys (Ghostty keybinds, page shortcuts).
6. The main menu is display only for keys: a key-down the dispatcher delivered never
   runs a registry menu item.

`KeyBindingTable` (CmuxNextActions, pure): entries `{keys (1-4 Shortcut), command,
args, when, source}`. Defaults come from the catalog (`defaultShortcut`,
`defaultChord`, digit families) with `when` derived from `requires`, ordered so the
more specific entry comes later (this reproduces today's "most specific wins"). The
side table 5a becomes default entries with `when` clauses (section 5). The Ghostty
fallback (5b) stays a separate, last source for chords no entry claims.

`KeyContext` (pure): context keys of one window, built from its `FocusState` and the
global facts that do not depend on focus (signed in, Cloud workspace, canvas layout).
Built-in keys: `surfaceKind`, `focus`, the legacy bits (`terminalFocused`,
`browserFocused`, `agentPaneFocused`, ...), later `terminal.altScreen` and the rest of
spec section 2.

`WhenClause` (pure): `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`, parentheses over context
keys. The AST lands with the fix; the text grammar is the next slice.

### 4.1 As built (step 2)

- `KeyRouter.interceptKeyDown` is the dispatcher; `KeyRouter.decide(_:focus:keyWindow:facts:)`
  is its pure decision (`run`, `deliver`, `consume`, `panel`) that tests call.
- `RegistryKeyBindings.table` builds the table (cached with the shortcut index);
  `KeyBindingDefaults` holds the tab-switch entries; `KeyRouter.keyContext(for:appContext:facts:)`
  builds the context keys; `ActionInvocation.keyContext` carries the key window's bits into
  `perform`, so availability is checked against that window.
- A Chromium pane's keys also reach Chromium's pre-key hook (`CEFTab.keyRouter` ->
  `KeyRouter.browserTab(_:keyEquivalent:)`). A key the dispatcher decided in `sendEvent`
  goes to the page there; a key that reached Chromium without passing `sendEvent` runs
  the whole dispatcher in the hook (same order). The window hook runs content actions
  only for a key the dispatcher never saw (a synthetic event). `KeyRouter.decided` is a
  weak set of decided events; the menu gate refuses every registry menu item for one.
- The popup Cmd-W step is a window-kind rule: in a browser popup (`windowKind ==
  browserPopup`) a key whose binding is a close action closes the popup.
- Step 1 (IME): while an input method composes, every key it can use reaches it
  undecided (every key but a Command chord; Kotoeri converts with Ctrl-J/K/L); a Command
  chord (Cmd-W, Cmd-Q) still resolves. Decided as K-T3.
- Decided keys are matched by identity and by signature (timestamp, key code,
  modifiers, characters; `DecidedKeyEvents`), so a copy of the key that Chromium hands
  to its pre-key hook never runs an action twice.
- The popup rule uses every close action (`WindowKeyTable.isClose`), which matches lane
  20's window key table: a close action run from the menu or palette while a popup is
  key closes the popup too.
- Home conversation tabs are `FocusTopology.Kind.conversation` and resolve to
  `.conversation(pane:tab:)` (the Home lead's 8ae1c9c1914; the applier gives the message
  box the keyboard, and with no Home view yet it blurs a Chromium page and resigns the
  pane responder); the context key is `surfaceKind == home`.
- Removed: `BrowserChordTable.tabNavigation` (now default entries), the popup key step,
  the `chordMismatch` slot (a decided event is never re-run).

### 4.2 Pages and the dispatcher (coordinator, 2026-10-03)

A page (a React page at `cmux-page://<id>/`: Settings, History, App Store; any web page)
handles only the keys the dispatcher delivers to it: plain navigation (arrows, Return),
typing, and Escape when no binding resolves. A page never handles a Command or Control
chord itself; chords resolve in the dispatcher, and a chord no binding claims reaches
WebKit or Chromium (editing chords through the Edit menu). Test:
`KeyOwnershipMatrixTests.reactPageGetsNavigationKeysAndChordsResolveInTheDispatcher`.

### 4.3 Primary input (R65, coordinator 2026-10-03)

Every app surface may declare a primary input (Home: the message box; the agent pane:
the composer; an app: manifest `presentation.primaryInput`). When Home, an agent chat or
an internal app screen has the keyboard and none of its text fields has focus, a
printable key (no Command or Control; not a control character, arrow, Return, Tab,
Escape or Delete) goes to that primary input and starts typing there; the first key is
not lost. Chords resolve first; IME composition keeps every key. A surface opts in by
conforming its content view to `PrimaryInputTarget` (`acceptsRedirectedTyping`,
`beginTyping(with:)`); the dispatcher decision is `.primaryInput`. Typing in a
terminal never looks the window up. Home's and the agent composer's conformances belong
to those lanes (the agent composer needs a page message to focus and insert).

## 5. Ctrl-Tab after the fix

Default entries that replace `BrowserChordTable.tabNavigation` (same keys, same actions):

| Key | Command | when |
| --- | --- | --- |
| Ctrl-Tab | `nextSurface` | `surfaceKind != terminal` |
| Ctrl-Shift-Tab | `prevSurface` | `surfaceKind != terminal` |
| Ctrl-PageDown | `nextSurface` | `surfaceKind != terminal` |
| Ctrl-PageUp | `prevSurface` | `surfaceKind != terminal` |
| Cmd-Opt-Right, Cmd-Shift-] | `nextSurface` | `surfaceKind == page` |
| Cmd-Opt-Left, Cmd-Shift-[ | `prevSurface` | `surfaceKind == page` |
| Ctrl-Tab | `nextSurface` | `surfaceKind == terminal && terminal.copyMode` |
| Ctrl-Shift-Tab | `prevSurface` | `surfaceKind == terminal && terminal.copyMode` |

The terminal keeps Ctrl-Tab through its Ghostty keybind (`ctrl+tab=next_tab`, same
action), so a user's Ghostty config still decides what Ctrl-Tab does in a terminal, and
Ctrl-PageDown/Up still reach the shell. Copy mode takes every other key before
Ghostty sees it, so it gets its own entries (K-T1). Unbinding `nextSurface` / `prevSurface` in
cmux.json removes these entries, as it removed the aliases.

## 6. Test matrix

`KeyOwnershipMatrixTests` (CmuxNextAppTests): each surface kind x each key -> expected
owner (`action(id)`, `surface`, `panel`). Ctrl-Tab and Ctrl-Shift-Tab rows first, then
Ctrl-PageDown/Up, then every default tier 0/1 binding without a required context
(it must resolve to its own action, or to a more specific default on the same key,
wherever its tier allows).

## 7. Decisions and open questions

- K-T1 (coordinator, 2026-10-03): in a terminal, Ctrl-Tab and Ctrl-Shift-Tab stay
  with Ghostty (`ctrl+tab=next_tab`, the same action), so the user's Ghostty config
  decides. Exception: terminal copy mode takes every key before Ghostty, which left
  Ctrl-Tab with no owner; default entries with `surfaceKind == terminal &&
  terminal.copyMode` give it to `nextSurface` / `prevSurface` there.
- K-T2 (coordinator, 2026-10-03): Home is its own surface kind (`home`), not an empty
  pane, and the dispatcher resolves with the key window's context, never the
  process-wide one.
- `surfaceKind` values follow the spec: `page` is a web page (WebKit or Chromium);
  internal pages are `settings` (Settings, Debug Settings), `appStore`, or their page
  id (`tasks`, `inbox`). Outside a pane (sidebar, its fields, other text fields)
  `surfaceKind` is absent and `focus` names the target.
- K-T3 (coordinator, 2026-10-03): an input method that composes gets every key but a
  Command chord (the coordinator edits spec section 3).
- K-T4 (coordinator): `surfaceKind` values as listed above.
- K-T5 (coordinator): in a browser popup every close action closes the popup.
- K-T6 (coordinator): keybindings.json is parsed by the Rust `cmux-config` (one config
  owner); that slice needs a cmux-tui landing window.
- R59 is done only after a live Ctrl-Tab proof on cmux-lawrence-2 (never the laptop).
- R85 (Lawrence, 2026-10-04): Ctrl-1...9 = Select Tab N (the common editor default), Spaces on
  Ctrl-Opt-1...9, Cmd-1...9 Select Workspace N; all rebindable. #17182 had given Ctrl-digits to
  Spaces, so with one Space they did nothing. macOS Mission Control "Switch to Desktop N" uses
  Ctrl-1...9 when a user turns it on (System Settings > Keyboard > Keyboard Shortcuts > Mission
  Control); the system then takes those keys before cmux sees them.

## 8. Customization slices (keys lead v2, 2026-10-04)

8.1 **Chords of up to four keys.** `ChordTracker` keeps the armed key list. The shared
sequence rules live in `KeyBindingTable.step(after:readings:in:isRunnable:)` (pure, in
CmuxNextActions) so every client resolves the same way:
- a key that leads to a longer entry whose action can run arms (extends) the chord, and
  wins over an entry the same key completes (VS Code rule, as at the first key);
- else the key completes the entry that wins for the whole sequence; else nothing;
- the Cmd-J leader arms as a first key whenever any entry sits under it;
- a fifth key never arms (`KeyBindingTable.maxSequenceLength` = 4).
The which-key overlay shows for every armed prefix (`KeyBindingTable.nextKeys`): each
next key once, what it runs now, "more keys…" for a key that only leads on, dimmed when
pressing it does nothing here; a numbered family shows once as `1…9`. Escape cancels at
any depth and reaches no view; a click, a focus change, another window or the app
resigning active cancels too. After the leader an unbound key is consumed; after another
prefix it goes on to the view (unchanged).

8.2 **Arguments.** `KeyBindingLoader.load` loads app and keybindings.json
entries through `validated(_:)`: canonical id, each argument exists in the schema and fits
its kind (text that fits is parsed), at most four keys, first key with Command or Control
(only those reach the dispatcher). A bad entry is left out with a `KeyBindingIssue`
(layer, position, kind); the others load (K4). A missing required argument loads: running
the binding asks for it, as the palette does.

8.3 **Negative entries.** `KeyBindingLayers.removals` (`KeyBindingRemoval`): removes the
default and app entries of the command on the keys (every key when omitted) whose `when`
is structurally equal (any `when` when omitted). User entries are never removed.

8.4 **Conformance vectors.** `schemas/keybindings/keybinding-vectors.json`: context, key
sequence, user entries, removals and the expected outcome (an action with its args, armed,
or none). `KeybindingVectorTests` (CmuxNextSettingsTests) runs them against the real
catalog through `KeyBindingTable.outcome(of:in:isRunnable:)`; other clients run the same
file.

8.5 **Read ops.** Socket methods `keybinding.list` (entries in precedence order with `id`,
keys in keybindings.json syntax, `when` text, args, source, `conflicts`: other entries on the
same keys whose `when` can hold together, `WhenClause.canOverlap`; defaults a removal took out
are listed with `removed: true`), `keybinding.resolve {keys, window?}` (outcome run/armed/none
and every candidate's verdict) and `context.keys {window?}`. CLI and MCP verbs need a cmux-tui
slot (Rust `cli/app.rs`).

8.6 **Keyboard Shortcuts editor.** React page `webviews/src/pages/keybindings` on
CmuxNextPages (`cmux-page://cmux.keybindings/`, internal page tab `keybindings`), opened by
`keybindings.open` (palette, CLI `cmux settings keyboard-shortcuts`, MCP; no default key, K1).
`KeybindingsPageProvider` serves `cmux.keybindings.list`, `record.start` / `record.stop` with
the `recorded` stream (the key dispatcher gives the page window's keys to a `KeyRecorder`:
Return or the fourth stroke ends, Escape cancels; the page never reads key events) and the
`changed` stream. `set`, `remove` and `reset` answer `cmux.keybindings.unsupported` until
keybindings.json has its owner (slice 4, cmux-config).

8.7 **Ghostty keybinds in the table (GHOSTTY-CONFIG).** The routed Ghostty keybinds
(`TerminalHostActionRoute`) are table entries, not a lookup after the table
(`GhosttyKeyBindingLayer`, loaded by `GhosttyKeybindSync` at launch, on every Ghostty
config change and on a keyboard layout change). Order: `.ghosttyFallback` (every routed
keybind, below all cmux entries) < cmux defaults < app entries < `.ghostty` (a keybind that
differs from a config without user files, only `surfaceKind == terminal && !terminal.copyMode`)
< cmux.json and keybindings.json. A winning Ghostty entry goes to a focused terminal, which runs
the keybind itself; elsewhere its routed action runs, never a content action from a hook and
never a browser chord in a browser context. Removals never take out a Ghostty entry; the
shortcut recorder notes Ghostty entries instead of listing them as owners; `keybinding.list`
lists them (`source` `ghostty` / `ghostty-fallback`), the Keyboard Shortcuts page does not yet.
Limits: one chord per action (Ghostty's reverse map), so a default chord rebound to another
action reads as a default; unrouted Ghostty actions are not entries (filling the routes closes it).
Test: `GhosttyKeybindPrecedenceTests`.

### Modifier hold hints

`shortcuts.showModifierHoldHints` defaults to `true` and is editable in Keyboard
Shortcuts. Hold Command or Control by itself for 0.30 seconds to show the current
workspace, space, focused pane tab, and titlebar shortcuts beside their targets.
Hints use the resolved default and user binding table, so a rebind or unbind
changes the hints too. Typing, releasing the modifier, disabling the setting,
or leaving the key window hides them immediately. The hints use small rectangles
and appear without a fade; they never handle clicks or consume terminal input.

DEBUG capture tooling can call `debug.shortcut_hints` with `modifier: "cmd"`
or `"ctrl"`. This posts a synthetic flagsChanged event through the production
window monitor and waits for its own intentional-hold callback before returning
`ready: true`. Capture the real window, then call with `modifier: "release"`.
Label this evidence **modifier held via debug event injection**. The hook is
excluded from Release builds and never raises or activates a window.
