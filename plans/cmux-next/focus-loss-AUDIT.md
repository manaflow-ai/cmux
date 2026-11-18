# Focus loss audit (cmux-next)

The symptom (user, 2026-11-15): the cmux window stays key, but the text input (agent composer,
terminal, Chief composer) stops getting keys, with no key or click that moved it.

This file lists every code path that can move the keyboard without the person's input, what each
one does now, and how to see a loss in a real session.

## Turn on the focus log

- CLI: `cmux settings set tunable.diagnostics.focusLog true` (DEV and NIGHTLY builds).
- Or Debug Settings > Focus and Scroll > "Record focus changes".
- Log: `~/Library/Logs/cmux-next/<tag or release>/focus-log.jsonl` (rolls to `focus-log.1.jsonl` at 4 MB).

Each line is one JSON object (`FocusLogEntry`): `kind` (`responder`, `refused`, `silent`, `key`,
`page_blur`), `window`, `from`, `to`, `input` (the event dispatched now), `since_input_ms`, `by`
(`focus-model` or `direct`), `run` (the action run, if any), `suspect` and a symbolicated `stack`.
`suspect: true` means: the keyboard left a text input with no key or click in the last 500 ms.
Find them with `jq -c 'select(.suspect)' focus-log.jsonl`.

What reports to it:

- `ShellWindow.makeFirstResponder` (the one choke point): every accepted and refused move.
- `ShellWindow.becomeKey` / `resignKey`: a key change; the resign stack names the code that made
  another window key (a Chromium page window, a panel).
- Every key-down (`InputVerificationService.inputObserver`): a first responder that changed with
  no `makeFirstResponder` (a focused view removed from its window) shows as `silent`.
- The agent page (`webviews/src/agent-session/acpmux/focusLossWatch.ts`): a page text input that
  loses focus with no key or click is a `page_blur` with `cause` = `removed` (remount), `script`
  (page code called `focus()`/`blur()`), `page` (the page lost the keyboard) or `moved`.

Off, each hook costs one tunable read.

## Guardrail G1: nothing unseen takes the keyboard

`ShellWindow.makeFirstResponder` asks `ResponderMoveGate`, which asks `UnseenKeyboardGuard`
(CmuxNextFocusUI). Outside an input event and outside a focus-model apply, a move from a shown view
to a view that is hidden, has a hidden ancestor, or has an empty visible rect (a page parked at
`PageOffscreenParking`) is refused and logged as `refused`. Every new focus path goes through this
one gate, so a background create, a prewarmed page or a parked spare cannot take the keys.

## Causes found and fixed

| # | Cause | Fix |
|---|-------|-----|
| 1 | A prewarmed or spare agent page parked offscreen (`PageOffscreenParking`, `AgentPageRetirer.park`, `AgentPaneSpareReturns`) asks for first responder by itself. `AgentPaneView.refusesSelfFocus` only refuses a page that is in a pane, so a page in no pane got the keys. Background agent creates make these pages. | G1 refuses it (`UnseenKeyboardGuardTests`). |
| 2 | The Chief panel re-syncs on every workspace delta. `ChiefPanelView.hold` of a new Chief view dropped the old one without moving the keys, so the Chief composer lost them. | `hold` gives the keys to the new view when the old one had them, and Home takes the old view back (`ChiefPanelHoldKeysTests`). |

## Reproduction (team Mac, 2026-11-16)

Build `focus-audit-v4` (fleet job cf0a6bcee2e84cdc1c67482c, head 2a2995ba) with the focus log on. A
terminal had the keys; 18 workspaces and 18 Claude agent tabs were created from the CLI in the
background. The log has one line:

```
refused  from: content(pane: …) TerminalSurfaceView typing  ->  to: windowOrNone PageWKWebView typing
input: programmatic, no key or click before it
stack: ResponderMoveGate.refuses <- ShellWindow.makeFirstResponder <- WebKit PageClientImpl::makeFirstResponder
       <- WebPageProxy::makeFirstResponder <- IPC dispatchMessage (the web process asked) <- run loop
```

So a WebKit page that is in no pane (a prewarmed or parked agent page) asked for the keyboard
by itself while the person typed in a terminal. Before G1 it got them (cause 1); now it is refused.

## Audit table

"Unprompted" = can it fire with no key or click by the person.

### Native (AppKit)

| Site | Trigger | Unprompted | Verdict |
|------|---------|-----------|---------|
| `ShellWindow.makeFirstResponder` | every move | n/a | Choke point. Now logs every move and runs G1. |
| `AgentPaneView.refusesSelfFocus` | page's own focus request | yes | Gap: a page in no pane passed. Closed by G1. |
| `AgentPageRetirer.park`, `AgentPaneSpareReturns.yieldKeyboard`, spare page prewarm | agent tab create/close (also from `cmux` CLI and other agents) | yes | Fixed by G1 (cause 1). |
| `ChiefPanelView.hold` / `WindowController.syncChiefPanel` / `removeChiefPanel` | any workspace delta | yes | Fixed (cause 2). |
| `WebKitRenderRate+Reshow` | render-rate change hides the focused WKWebView for 33 ms | yes | Hidden view keeps first responder in AppKit; log watches it. No fix needed unless the log shows it. |
| `FocusEffectApplier.resignPaneResponder` | focus-model apply | yes (daemon delta) | Drops focus inside an apply. Now logged with `by: focus-model`. Watch. |
| `TopHomePageView.show` + headless `createChiefForAction` (`pendingSelection`) | Chief created by an action | yes | Swaps the host view. Logged; keys follow the selection the action asked for. |
| `PaneController.handKeyboardToWindow` | daemon selection change | yes | By design for the selected pane; logged as `focus-model`. |
| `workspace create --focus` | CLI | yes (another agent) | Treats a terminal as "not typing". Explicit focus intent (socket focus policy); keep. |
| `BrowserChromeTabState.save` → `makeFirstResponder(nil)` | browser tab switch | no (person's switch) | Keep. |
| `DeclarativePopupHost` return responder | popup dismiss | no | Can restore a stale responder; logged. |
| Chromium spare / agent-host page windows becoming key | CEF focus request | yes | cmux refuses CEF's own requests (`chromiumRequestsFocus`); a key change is now logged with its stack. |
| `FocusEffectApplier` cannot restore `.textField` / `.sidebarField` | after an apply | yes | The Chief dock composer can stay unfocused after an apply. Logged; follow-up if seen. |
| `AgentBesidePlacement.selectWhenReportedKeepingFocus` | agent reported beside a tab | yes | No `viewChangeAllowed` check; a visible tab change, so not the silent symptom. Follow-up. |
| Chat docking `focusPane` | chat docks | yes | Forces pane focus. Follow-up. |
| Non-agent WebKit pages | page `focus()` | yes | No self-focus guard; G1 covers the unseen case. |
| Background modal dialogs | sheet on a non-key window | yes | Rare; logged as `key`. |
| `showRevealed` `selection.jump` | reveal | partly | `viewChangeAllowed` defaults to true outside a run. Follow-up. |
| Focused view removed from its window | any remount | yes | AppKit drops to the window, sometimes with no `makeFirstResponder`; the log catches it at the next key-down (`silent`). |

### Web (agent page, `webviews/`)

| Site | Trigger | Unprompted | Verdict |
|------|---------|-----------|---------|
| `composerFocus.ts` blur on window blur | window loses key | yes | Leo's design (#24896, `composer-caret-focus.test.ts`); recovers by the claim on window focus. Keep. |
| `QuestionCard` takes keys when the composer is empty | agent asks a question | yes | By design. Logged as `script`. |
| `PermissionCard` `permissionFocus` (App.tsx) | permission request | yes | No session check: a request of another session can take the keys. Follow-up fix. |
| `VirtualTranscript` `pendingFocus` | row mount | yes | A stale row can take the keys. Follow-up fix. |
| `ComposerQueue` refocus layout effect | queue change | yes | Can loop. Follow-up fix. |
| `popupHost` fake Escape on dismiss | popup dismiss | no | Keep. |
| `QuickSurface` / App.tsx branches that unmount the composer | view switch, reload | yes | Logged as `cause: removed`. |
| New Tab adoption `selectAll` | new tab | no | Keep. |

## Not done here

- a1185 owns "Markdown tab beside Home shows focus but keys go elsewhere".
- a1170 landed the Cmd+F fixes (d461abcc..5fb8acb1).
- The web follow-ups above need a repro from the focus log first.

## Focus route (the central choke point)

Every keyboard move goes through one route that names who started it, its caller and its reason:

- Swift: `FocusRoute(.person or .system, "reason").moveKeyboard(in:to:)`, `.makeKey(_:front:)`,
  `.activateApp()` (CmuxNextDesign/FocusRoute/FocusRoute.swift). The main window takes the route
  with the call (`FocusRouting`, CmuxNextDesign), so its gate and its key-change
  hooks see who asked and why; another window gets a plain AppKit call.
- Web: `focusRoute(element or handle, "person" | "system", "reason", options?)` and
  `blurRoute(...)` (webviews/src/ui/focusRoute.ts). The page's focus-loss records carry the route.

What it does:

- **Names the cause.** Each focus log line has `route`: `system CmuxNextApp/Focus/FocusEffectApplier.swift:110 focus model: pane content`,
  or `unrouted` for a direct call.
- **Refuses a steal.** A `.system` move outside a key or click and outside the focus model's own
  apply is refused when it would take the keys from the responder the person typed into (a key with
  no Command or Control) in the last second (`ResponderMoveGate.takesFromTyping`). The web route
  refuses a `system` move away from the input typed into in the last second the same way.
- **Lists recent changes.** `cmux app call debug.focus_log '{"limit": 50}'` (DEV and tagged builds)
  returns the newest 200 changes with their route, kept in memory while the file log is off.
- **Guardrail.** `scripts/cmux-next/check-focus-routes.py` (pre-push gate) refuses a new direct
  `makeFirstResponder` / `makeKey` / `makeKeyAndOrderFront` / `NSApp.activate` in product Swift and
  a new `.focus()` / `.blur()` / `autoFocus` in page code. The 515 calls from before the route are
  in `scripts/cmux-next/focus-routes-baseline.tsv`, which only goes down.

### Call sites moved onto the route (72)

All have no user gesture behind them (daemon delta, mount, layout, timer, page request):

- Swift (46): FocusEffectApplier (8), KeyRouter+NewTabInput (5), AgentPaneSessionInfoContent (2),
  NativeNewTabHostingView, AppServices+AgentShareHost, SleepyOverlayWindows (2), TopHomePageView
  (2), TopPageHost, WindowRootView, PageInfoController, ExtensionsMenuHoverButton (3),
  PromptBarView (2), WebKitTab (2), DeclarativePopupHost (2),
  NativePopupContent, OverlaySurface, ThemedField+SwiftUI (3), WebKitRenderRate+Reshow,
  FilesPaneView, HomeFirstRunView, HomeStarterChips, MacScreenTab, RemoteDesktopPaneView,
  SidebarNeedsYouTrayView, TerminalSession.
- Web (26): App.tsx (4: focusComposer, panel and dialog openers), Composer (2), ComposerQueue (3),
  MarkdownField, PermissionCard (2), VirtualTranscript (3), dictation (3), useNeedsYou,
  HatQuestions, QuestionCard (2), SubagentTray, ThreadMinimap (2),
  CustomizeLibraryCard (the Remove confirmation's Cancel, `person`).

### Left direct, and why

- The 511 baselined calls: almost all run inside a key or click handler of the person (menus,
  fields, lists, rename, palettes) or a debug/playground window. The window's gate still logs every
  one of them (`unrouted`), and G1 still refuses an unseen target. They move as their files change.
- `ShellWindow.makeFirstResponder` and the route itself: the choke point.
- CEF and `AppKitKeyWindows` / `CEFKeyWindows` adapters (`KeyWindowSwitching`): they already are
  the one key-window seam of Chromium pages; their callers name the reason.
- WebKit's own focus requests (IPC from the web process): they never pass through cmux code before
  `makeFirstResponder`; the gate sees them as `unrouted` and G1 refuses an unseen page.
- `AgentRenderWindows` (CmuxNextBrowserHost): an agent's offscreen render window, never a window
  the person types in; BrowserHost is a service and may not depend on CmuxNextDesign.
- JS `focus()` strings that Swift injects into web pages (BrowserPageScripts, LinkHintScript):
  page automation of a site's DOM, not cmux's keyboard.
