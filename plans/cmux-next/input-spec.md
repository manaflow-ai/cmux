# cmux next input: specification and verification

Status: implemented 2026-09-29. Code: the value checks (`InputObservation`, `InputInvariants`: the model,
transition and world checks) are in `Packages/macOS/CmuxNext/Sources/CmuxNextFocus/` (moved there in #31265).
The key routing checks and `step` (`InputInvariants+Routing.swift`, which read `KeyRouter`), the journal, the
monitor and replay are in `Packages/macOS/CmuxNext/Sources/CmuxNextApp/InputVerification/`. The model and
fuzzer tests (`Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/InputModel/`, `InputModelFuzzTests`) were
deleted in 36f2381bf1a6 (2026-10-09); sections 6 and 7 describe them as they were.

The state machines own their parts: `FocusCoordinator` and `KeyRouter` (focus.md), the omnibar
(focus.md section 7), `TerminalAttachMachine` (state-audit.md T3-T5). This document states what
must hold for all of them together, and how every build proves or catches it: a journal of all
input, a monitor that checks the live app after each settle, replay against the pure reducers,
and model-based fuzzing of the composed system. It adds no second owner of any state.

## 1. Combined state

Per cmux window: the `FocusState` (topology, focused pane, target, overlay stack, expectation,
drag restore, browser focus mode, generation), AppKit's first responder (classified by
`FocusResponderClassifier`), whether the window is key, `LayoutModel.focusedPane`, the tabs whose
Ghostty surface has focus, the page the applier gave Chromium focus to, and the tab each pane
presents (`currentTabKey`). App-wide: `NSApp.keyWindow` and what owns it, `paletteOpen`, the active
window (`WindowManager.active`) and the published registry context. Per browser tab: the
`OmnibarState`. Per terminal view: its `TerminalAttachMachine`.

`InputObservation` is this state as a value. `InputObservationBuilder` reads it from the live app;
the fuzzer's world model produces the same value, so both are checked by one `InputInvariants`.

## 2. Invariants

Ids are stable: reports, logs and tests use them.

### 2.1 Model (every reduction; replay; fuzzer)

| Id | Rule |
| --- | --- |
| F1 | While an overlay is open it is the keyboard target (`resolved == .overlay(top)`). |
| F2 | Focus names a pane in the topology; a pane-scoped target names that pane's selected tab. Focus is never on a removed pane, tab or window. |
| F3 | A window with panes has a focused pane (for pane-scoped targets). |
| F4 | The target fits the selected tab: terminal on a terminal, page, address bar and find bar on a browser tab. The state never keeps `addressBar`/`findBar` off a page. |
| F5 | No expectation survives a newer user intent (no focus steal). |
| F6 | Browser focus mode names only tabs the window shows. |
| F8 | The omnibar has focus exactly when AppKit's responder is its field, and then the model targets `addressBar(pane, tab)` (outside overlays). |

Exactly one keyboard target per window holds by construction: `resolved` is a single value of
`FocusState`.

### 2.2 Transitions (T)

| Id | Rule |
| --- | --- |
| T1 | An `expect` from an older generation changes nothing. |
| T2 | `windowKey`, `appActive`, `overlayOpened/Closed` and `contentPresented` never move focus; a responder report under an overlay never moves focus. |
| T3 | The intent generation never decreases. |

Allowed transitions, by event (the reducer, `FocusReducer.swift`):

| Event | May change |
| --- | --- |
| `topology` | workspace switch: remembered or first pane, target `content` (keyboard sidebar kept), drag dropped; focused pane removed: most recently focused survivor, else next, else previous; selection change on the focused pane: chrome target falls back to `content`; expectation lands |
| `focusPane`, `selectTab`, `focusTarget` (user sources) | pane and target, bumping the generation; `selectTab` selects only a tab its pane holds (B1) |
| `responder` | pane and target to what AppKit chose, unless an overlay is open; `windowOrNone` only re-applies |
| `expect` | lands at once or when its surface/tab appears, only in its generation |
| `dragBegan` / `dragEnded` | cancel restores pane and pane-scoped target unless a keyboard, CLI or palette intent happened during the drag (B6); drop focuses the dropped tab away from its source pane |
| `overlayOpened/Closed`, `windowKey`, `appActive`, `contentPresented` | nothing but re-applying effects |
| `toggleBrowserFocusMode` | focus mode of a shown page |

### 2.3 Attach (A, per terminal view; `AttachOracle`)

| Id | Rule |
| --- | --- |
| A1 | Input is neither lost, duplicated nor reordered: the bytes sent (all links, in order) followed by the queue equal the accepted input; input is dropped only after close or over the 4 MiB queue cap. |
| A2 | Input and geometry go only to the live link, never before its replay or after its detach. |
| A3 | Every opened link is detached exactly once. |
| A4 | A closed attachment holds no queue and sends nothing. |

### 2.4 Key routing (K; `KeyRouter`)

| Id | Rule |
| --- | --- |
| K1 | Tier 0 keys always reach the router, whatever has the keyboard. |
| K2 | Tier 1 keys reach the router unless the focused page is in browser focus mode. |
| K3 | Tier 2 never runs while a text input (address bar, find bar, sidebar field, sheet, rename) has the keyboard or in browser focus mode. |
| K4 | Main-menu key equivalents follow the same tier rules (`allowsMenu`); over a text panel tier 2 never runs. |

### 2.5 World (live AppKit, after settle; monitor and fuzzer)

| Id | Rule |
| --- | --- |
| W1 | AppKit's first responder is what the model targets: the terminal or WebKit page view, the address bar, find bar, sidebar or field; for a Chromium page the parent window keeps no responder; for an empty pane no view inside a pane. |
| W2 | `LayoutModel.focusedPane` equals the model's pane. |
| W3 | Ghostty focuses exactly the model's terminal, and only in the key window. |
| W4 | Chromium focus is on exactly the model's page (checked outside overlays). |
| W5 | Only the window AppKit made key has `windowKey`; a Chromium page window has the keys only when its page is the target; a panel or sheet has the keys only over a window whose overlay stack has it. |
| W6 | The palette is open exactly when one window's stack has `.palette`; a window has a sheet exactly when its stack has `.sheet`. |
| W7 | The window that owns the keyboard (itself, its page window, panel or sheet) is `WindowManager.active`, and its context is the published one. |
| W8 | Every shown pane shows its selected tab, and that tab is in the pane. |
| W9 | The focused pane presents the targeted tab within a settle (monitor only: a window unsettled at a check and at its confirmation is stuck). |

A window whose focused pane does not present the targeted tab yet is unsettled: W1-W4 wait, and
the monitor reports W9 when it stays so.

### 2.6 Geometry (G, live AppKit, after settle; monitor)

| Id | Rule |
| --- | --- |
| G1 | Every visible Chromium page window covers its pane's page area in screen coordinates, within 1 point, and no visible page window covers no pane, after every window move or resize from any source: a drag, an Accessibility client such as Rectangle, a display, Space or fullscreen change. |

G1 is `ChildPageGeometry` (owned by the browser child-window work, also reported by `debug.layers`
and checked by `debug.window.ax_set_frame`); the monitor samples it per window so each violation
names its window, and skips a window in a live resize (the check runs after the resize ends). The
frame-sync code owns the geometry; G1 only observes it.

## 3. Input journal

`InputJournal.shared`: a ring of 4,096 `InputJournalEntry` values with a sequence number and
`CLOCK_UPTIME_RAW` nanoseconds. It records every event `CmuxApplication.sendEvent` receives
(before the key router can consume it: key down/up/flags with key class and modifier classes, see privacy below;
mouse down/up/drag/scroll in window-local top-left points, drags and scrolls merged per run),
every focus reduction with the resulting `FocusDigest` plus a full `FocusState` checkpoint every
64 reductions per window, suppressed responder echoes, page focus the applier gives or takes
(WebKit, Chromium, Chromium key window), every attach reduction (event, link, byte count, phase
after), cmux window frames after a move or resize (a run merged into one entry), desync markers,
and automation markers.

Recording is on in debug and tagged (dogfood) builds, off in release builds;
`CMUX_NEXT_INPUT_JOURNAL=0|1` overrides. Disabled, each hook is one relaxed atomic load and
builds no payload.

Privacy: typed text never reaches the journal, `debug.journal` or a desync report on disk. A key
record carries its phase, class (`letter`, `digit`, `punctuation`, `space`, `named`, `modifier`,
`other`) and modifier classes. The key code is kept only for shortcuts (Command or Control held),
named keys (Return, Tab, Escape, Delete, arrows, function keys) and modifiers, whose code is not
text; plain typing, with or without Shift or Option, has no key code and no characters. This
covers terminal and omnibar typing, which reach the journal only as these key records; attach
records carry byte counts, never bytes, and omnibar text is not journaled. The one opt-in is
`CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1` in a debug build: it records characters and key codes for
that launch only, and nothing persists it. `InputPrivacyTests` checks the redaction.

## 4. Invariant monitor and desync reports

`InputInvariantMonitor` runs after any focus reduction that changed the focus or had effects,
key-down, mouse down/up, content presentation, or cmux window move, resize, screen change or
deminiaturize, at one deadline 200 ms after the last of them (no display link, no per-frame
step). It checks sections 2.5 and 2.6 (which include 2.1) on `InputObservationBuilder.observe`.
A violation seen once is checked again one settle later; only a violation present in both
checks is reported, once until it clears. The check walks every window and pane, so it runs by
itself only in debug builds; in any build `debug.desync` (`check`, `report: true`) runs it on
demand. Release builds keep the automatic check off (lead decision 2026-10-18, perf-focus cx-8w027.2):
no scan of every window per input in a release build.

A report is written to `~/Library/Logs/cmux-next/<tag or release>/desync/desync-<UTC>-<n>.json`
(newest 50 kept, written off the main thread): the violations, the observation, the last 512
journal entries, journal stats, and `debug.focus` and `debug.surfaces` at capture time. Debug
builds log a fault per violation, release builds (on demand only) an error.

Control socket:

| Method | Does |
| --- | --- |
| `debug.desync` | counts, report paths and summaries; `check: true` runs the world check now; `report: true` captures a report when something is broken (`force: true` always); `full: true` returns the latest report; `clear: true` |
| `debug.journal` | stats and the last `last` entries (default 200); `marker: "<text>"` appends a marker; `clear: true` |
| `debug.replay` | replays the in-memory journal (`source: "report"`: the latest report's) against the reducers (section 5) |
| `debug.mouse` (DEBUG) | synthesized mouse input (below) |

`debug.mouse` posts mouse events to the app's own event queue, so they take the real path:
`CmuxApplication.sendEvent` (journal), local monitors (the layout's focus-on-mouse-down), the
window's `sendEvent`, hit testing and tracking loops. Params: `window`, a point as `x`,`y`
(window-local top-left points, as journaled) or `pane` (its content's center), `action`
(`click`, `double_click`, `down`, `up`, `drag` with `to_x`,`to_y`,`steps`, `scroll` with `dx`,`dy`),
`button` (`left`, `right`), `modifiers`. The user's pointer never moves. A click lands in a
Chromium page window only when the page window is under the point in AppKit's hit test; clicks
at a page's position in the parent reach the parent's host view.

## 5. Replay

`InputReplay.replay(entries)` starts each window's focus machine at its first checkpoint and each
terminal's attach machine at its journaled `start`, reduces every journaled event, and reports the
first divergence: a different recorded outcome (`outcome`), a checkpoint that disagrees with the
replayed state (`checkpoint`), or a step that breaks section 2.1-2.4 (`invariant`). Replaying a
desync report on a newer build shows whether the reducers still produce the recorded outcome.

`scripts/cmux-next/input-replay.py <report.json> --socket <path>` replays the report's key and
mouse entries into a tagged app through `debug.key` and `debug.mouse` and compares `debug.focus`
after each input with the next recorded digest. It is best effort: the live layout differs from
the recorded one unless the tagged app was prepared with the same topology.

## 6. Model-based fuzzing

`InputWorld` composes the real `FocusCoordinator` per window (its queue and echo suppression),
the real omnibar reducer per browser tab, a real `TerminalAttachMachine` per terminal view with
`AttachOracle`, and the `KeyRouter` tier rules, around a simulated daemon tree and AppKit:
first responders, key window, frame-deferred presentation, Chromium page windows, the palette,
sheets and the group editor. `SimWindow` follows `FocusEffectApplier`, `PaneController` and
`WorkspaceContentController` step by step; `InputWorld.setKey` follows AppKit's resign-then-become
order and the app's key notifications.

`FuzzAction` covers daemon tab/pane create, close and move; deltas and command responses
delivered in any order or rejected; user splits, new tabs, closes and moves; clicks in panes,
tabs, pages, the sidebar and fields; keyboard navigation, Cmd-L, find, Escape, Enter and typing;
CLI focus and (stale) tab selection; key window and app activation changes; the palette,
sheets and the group editor; workspace switches; drags with every outcome; browser focus mode;
frames; and attach opens, failures, replays, overflows, late opens and ends. Parameters are
indices resolved at run time, so any subsequence is a valid run: a failure is shrunk by delta
debugging to a minimal sequence that still breaks the same invariant.

CI (`swift test`) runs seeds 1-24, 500 steps each, alternating 1-3 windows and silent or reported
responder removal. Locally: `CMUX_NEXT_FUZZ_RUNS=1000 CMUX_NEXT_FUZZ_STEPS=1500 swift test --filter
InputModelFuzzTests/longRandomRun` (`CMUX_NEXT_FUZZ_SEED` picks the first seed). 1,000 seeds of
1,500 steps passed at landing.

## 7. Bugs the fuzzer found

B1-B9, B11 and B13b had tests in `InputBugRegressionTests`; the others name their suites in the table.
Commit 36f2381bf1a6 (2026-10-09) deleted that suite and most of the other tests the tables name. "Tests now", after the tables, says which tests still cover each bug.

| Id | Found as | Bug | Fix |
| --- | --- | --- | --- |
| B1 | The corpus replay: 59 `selectTab` steps name a pane of the shown workspace that does not hold the tab, each recorded with no `select` effect; 159 name another workspace, 92 of which change `remembered`. |
| B2 | Only `WindowManager.owner(of:)` for a child window, which `active` uses (`MultiWindowInputRoutingTests.aKeyTypedInOneWindowNeverReachesAnother`, through `CrossWindowInputGuard`). No test checks `active` with a sheet, page window or panel as the key window, or the republish. |
| B3 | W4, switch to an empty workspace | With no target (`.none`), Chromium focus stayed on the old page. | `.none` blurs the page, as `.emptyPane` did. |
| B4 | W5, open the group editor | The tab group editor bubble took the keys but the window had no overlay: content shortcuts and focus effects still targeted the pane below. | A key panel over the window other than the palette is a `.groupEditor` overlay until it resigns key. |
| B5 | W5/W7, click another window while the palette is open | The palette closed on resign key and then made its parent key again, taking the keys from the clicked window. | Closing because of a resign no longer re-keys the parent. |
| B6 | The corpus replay: 46 cancelled drags; 4 follow an intent during the drag and keep the pane and target, and 3 began on a sidebar, sidebar field or text field target. No test names the chrome-target rule. |
| B7 | Parts only: the decision for a page window that becomes key without a click (`focus_rules.rs` `a_child_window_that_becomes_key_is_decided_as_the_swift_rule_did`) and the synchronous palette report (`PaletteOverlayWindowTests.theOverlayGoesOnTheWindowThePaletteOpensOver`: the overlay is on the window right after `show` and gone right after `hide`). No test checks that the click that closes the palette is kept. |
| B8 | The corpus replay: 16 `toggleBrowserFocusMode(tab:)` steps name a tab no pane holds, each recorded with no change. |
| B9 | live, a `CMUX_NEXT_NO_ACTIVATE=1` session (the model never opened the palette in an inactive app) | The palette panel is nonactivating; made key while the app was not active (a CLI request, a no-activate run) it took the system keyboard from the user's frontmost app, whose keystrokes then ran in cmux. | One rule for every key panel (palette, tab group editor, Page Info), `ActiveAppKeyPanel` in CmuxNextDesign: it takes the keys only while the app is active; otherwise it shows without them and closes when another window of the app takes the keys (a click or Cmd-Tab into the app). The palette gives the keys back only when it has them. The model opens the palette in an inactive app, and only the active app has a key window. |
| B11 | The decision only: `focus_rules.rs` `a_child_window_that_becomes_key_is_decided_as_the_swift_rule_did` checks the child-window rule for all 192 cases (3 parent kinds, 64 combinations of the other facts). A Chromium page window that becomes key without a click is `unchosenPage`, placed or not. `ChildPageFocusKeyChangeTests` checks the key change of `ChildPageFocus.reclaim`, which the give-back calls. No test checks that the applier gives the keys back. |
| B12 | No test. No corpus step reports the expected tab in the `awayFrom` pane, so the replay does not reach the bug. `HomeDockOpensTests.aHomePlacementKeepsCreationInputPendingAfterTheCreateReply` checks an `awayFrom` expectation for a Home placement, not for Split Browser. |
| B13 | dogfood nxdog13 ("after new browser, the address bar gets focus but then loses focus"); the user's desync reports (W5, page window key 53 ms after attach, `pendingFocus=false`) | CEF focuses a page after every navigation it starts: `ChromeBrowserHostImpl::Create` calls `OnSetFocus(FOCUS_SOURCE_NAVIGATION)` after a new browser's first load (`chrome://newtab/`), and every `LoadURL` does the same. The shim had no `CefFocusHandler`, so the request won and the fork's child-window `SetFocus` activated the page window, which took the keys from the omnibar. The applier journaled no `chromium-unchosen-key` for it, so the B11 give-back never ran. A no-activate app never becomes active, so no test saw it. | The shim's `CefFocusHandler::OnSetFocus` asks cmux (`cmux_shim_set_focus_request_handler`). Only cmux's own `SetFocus(true)` (`CEFTab.grantFocus`, used by `setFocused(true)` and `attach`) is allowed; every other request is refused and journaled as `content` `focus-refused source=<navigation\|system>` (`CEFFocusRequestTests`). Chrome's rule holds: a new tab's omnibar keeps focus until the user clicks the page. |
| B13b | nxdog13 desync reports 2 and 3: no `chromium-unchosen-key` record when the page window became key after attach; after a reactivation the record appeared but W5 stayed | `ChildWindowKeyRule` answered only for a key window whose parent is the cmux window. The fork's tracker hides and unparents a page whose parent view has no bounds or is hidden, and an activation then shows and keys it parentless, so the applier ignored it and `reclaimKeyFromPageWindow` skipped it. On reactivation AppKit re-keys the window that was key at deactivation, and a give-back inside that didBecomeKey does not hold. | A parentless Chromium page window counts as the active cmux window's own (decide and reclaim; inactive windows ignore it). After `didBecomeActive` the applier gives the keys back from a page window unless the target is a page or DevTools (`ChildWindowKeyRuleTests`, `InputBugRegressionTests.b13ParentlessPageWindowKeyAfterAttachNeverKeepsTheOmnibarKeys`). |
| B14 | Keyboard Shortcuts or Debug Settings in Chromium (the default engine since cmux pages follow `browser.defaultEngine`), type in the search field: nothing | A cmux page in Chromium shows in a child window, but the `.page` effect ran `blurChildWindowPage`, which takes the keys back from any page window, then made a view in that child window first responder of the parent. The keys stayed in the parent and reached no field. | A page whose `PageWebView` runs in Chromium takes the keys like a Chromium browser tab (`focusPage` with its CEF tab); a click into its window chooses it, and a reactivation leaves it the keys. The monitor counts it as a child-window page for W1, W5 and the chromium check, by its tab key (`ChromiumPageFocusInvariantTests`). |
| B15 | #24913: fuzz seed 21 on macOS 14.8.7 and 15.7.7, a 10 s main-thread stall inside `-[NSWindow makeKeyWindow]` (`_windowChangedKeyState` over the cmux window's tree) | Focusing a Chromium page made two key changes: `blurChildWindowPage` gave the keys to the cmux window (`reclaimKeyFromPageWindow`), then the grant gave them to the page window. Each change walks the whole view tree of the cmux window, with every parked workspace in it (hidden). A right-click on a tab also selected it while the menu was built, which focused the page inside the right-click. | One key change per focus request (`ChildPageFocus`): the old page blurs without a key change and the grant moves the keys to the new page window; the cmux window takes the keys back only when another window has them. Building the tab menu selects nothing (`ChildPageFocusKeyChangeTests`, `TabSelectionActionsTests.theTabMenuOfAnotherTabSelectsNothing`). Page focus with the cmux window key needs fork API 30 (`cmux_browser_set_embedder_active`). |

B10, found in dogfood (nxdog9), not by the fuzzer; tests in `PaletteInputStepTests` (deleted in 36f2381bf1a6):

| Id | Found as | Bug | Fix |
| --- | --- | --- | --- |
| B10 | Cmd-Shift-P, Rename Tab Group, a name, Return: the system beep, no rename | The palette closed and then ran the action, which resolved its target from the focus after the close; a handler that could not act (the selected tab is not in a group) called `refuse`, and the App's refusal observer beeps for every run without a capturing caller, so the reason went only to the log. Separately, a palette key with nothing to do (Return with no row, Backspace at the root, Tab with no Actions menu) was not consumed: the field editor ended editing or beeped, and later keys reached `noResponder(for:)`, the system beep. | Actions that ask for input target the objects captured when the palette opened (`PaletteSources.context`: tab, tab group, pane, screen, workspace, window). The palette runs closing and keep-open commands through `ActionRegistry.reportingRefusal`: a refusal does not beep, the palette opens again on the same page and shows the reason as the row's subtitle (`PaletteModel.notice`), and destructive actions still ask for confirmation (a capturing run refuses them). The palette consumes every key it maps. `debug.key` with `"target": "palette"` drives the panel and reports `palette_unhandled_key_downs` (key-downs that reached `noResponder(for:)`). |

B2, B4, B5, B7, B9 and B11 are wiring in `FocusEffectApplier`, `WindowManager` and `PaletteController`.
Their regression tests ran the fuzzer's minimal sequence through the model, which mirrored the
fixed wiring; the live monitor (W5, W7, W1) is what catches a regression there in dogfood.

### Tests now

Commit 36f2381bf1a6 (2026-10-09) deleted these tests that the tables name: `InputBugRegressionTests`
(B1-B9, B11, B13b, and F4), `FocusReducerTests` (B12), `CEFFocusRequestTests` (B13),
`ChildWindowKeyRuleTests` (B13b), `PaletteInputStepTests` (B10) and the fuzzer (`InputModelFuzzTests`,
`Tests/CmuxNextAppTests/InputModel/`). These tests exist now (added after it): `ChromiumPageFocusInvariantTests` (B14),
`ChildPageFocusKeyChangeTests` (B15) and `TabSelectionActionsTests.theTabMenuOfAnotherTabSelectsNothing` (B15).

The focus rules moved to Rust (`cmux-focus-core`). `focus_rules.rs` (in `cmux-tui/crates/cmux-layout-reducer-ffi/tests/`)
replays a corpus recorded from the Swift reducer: seeded random event sequences, each step checked for the
same state and effects (`the_rust_focus_rules_reproduce_every_recorded_swift_step`). Some steps hit a bug's
exact condition, so a reducer that brought the bug back would fail the replay; the table gives the counts.

| Bug | Covered now by |
| --- | --- |
| B1 | The corpus replay: 59 `selectTab` steps name a pane of the shown workspace that does not hold the tab, each recorded with no `select` effect; 159 name another workspace, 92 of which change `remembered`. |
| B2 | Only `WindowManager.owner(of:)` for a child window, which `active` uses (`MultiWindowInputRoutingTests.aKeyTypedInOneWindowNeverReachesAnother`, through `CrossWindowInputGuard`). No test checks `active` with a sheet, page window or panel as the key window, or the republish. |
| B3 | No test. |
| B4 | No test. |
| B5 | No test. |
| B6 | The corpus replay: 46 cancelled drags; 4 follow an intent during the drag and keep the pane and target, and 3 began on a sidebar, sidebar field or text field target. No test names the chrome-target rule. |
| B7 | Parts only: the decision for a page window that becomes key without a click (`focus_rules.rs` `a_child_window_that_becomes_key_is_decided_as_the_swift_rule_did`) and the synchronous palette report (`PaletteOverlayWindowTests.theOverlayGoesOnTheWindowThePaletteOpensOver`: the overlay is on the window right after `show` and gone right after `hide`). No test checks that the click that closes the palette is kept. |
| B8 | The corpus replay: 16 `toggleBrowserFocusMode(tab:)` steps name a tab no pane holds, each recorded with no change. |
| B9 | No test. |
| B10 | No test. |
| B11 | The decision only: `focus_rules.rs` `a_child_window_that_becomes_key_is_decided_as_the_swift_rule_did` checks the child-window rule for all 192 cases (3 parent kinds, 64 combinations of the other facts). A Chromium page window that becomes key without a click is `unchosenPage`, placed or not. `ChildPageFocusKeyChangeTests` checks the key change of `ChildPageFocus.reclaim`, which the give-back calls. No test checks that the applier gives the keys back. |
| B12 | No test. No corpus step reports the expected tab in the `awayFrom` pane, so the replay does not reach the bug. `HomeDockOpensTests.aHomePlacementKeepsCreationInputPendingAfterTheCreateReply` checks an `awayFrom` expectation for a Home placement, not for Split Browser. |
| B13 | No test. |
| B13b | The rule only: the same `focus_rules.rs` test covers a parentless Chromium page window (`parent: none`): only the active cmux window takes it back. No test covers the give-back after `didBecomeActive`. |
| B14 | `ChromiumPageFocusInvariantTests` (the monitor counts a Chromium cmux page as a child-window page for W1, W5 and the chromium check). No test covers the `focusPage` path. |
| B15 | `ChildPageFocusKeyChangeTests` (one key change per focus request), `TabSelectionActionsTests.theTabMenuOfAnotherTabSelectsNothing`. |

## 8. Limits and follow-ups

- The model assumes Chromium's `SetFocus` does not make the page window key (the fork's
  "counts as active while the parent is key", browser.md). If the page window does become key,
  W5 in the live monitor reports it.
- Key-router decisions are not journaled yet; the app-wide key interception work
  (`KeyRouter.interceptKeyDown`) is the place to add a `route` record, then K1/K2 can be checked
  live per key-down.
- The omnibar rule F8 is checked in the model; the live monitor covers the responder side (W1).
- `debug.key` takes key names, not key codes; live replay maps journaled key codes of letters,
  digits and named keys only.
