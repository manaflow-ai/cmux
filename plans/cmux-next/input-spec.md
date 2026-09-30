# cmux next input: specification and verification

Status: implemented 2026-09-29. Code: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/InputVerification/`,
model and fuzzer in `Tests/CmuxNextAppTests/InputModel/`.

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

`InputInvariantMonitor` runs after any focus reduction, key-down, mouse down/up, content
presentation, or cmux window move, resize, screen change or deminiaturize, once 12 display frames
pass without another. It checks sections 2.5 and 2.6 (which include 2.1) on
`InputObservationBuilder.observe`. A violation seen once is checked again one settle later;
only a violation present in both checks is reported, once until it clears. An idle app runs no
display link.

A report is written to `~/Library/Logs/cmux-next/<tag or release>/desync/desync-<UTC>-<n>.json`
(newest 50 kept, written off the main thread): the violations, the observation, the last 512
journal entries, journal stats, and `debug.focus` and `debug.surfaces` at capture time. Debug
builds log a fault per violation, release builds an error.

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

Each has a test in `InputBugRegressionTests`.

| Id | Found as | Bug | Fix |
| --- | --- | --- | --- |
| B1 | W8, `cliSelectTab(stalePane)` | `selectTab` for a tab its pane no longer holds (stale CLI snapshot, a moved tab) emitted `select`; the pane showed a tab it does not hold (blank, or took the tab's view from its real pane). | The reducer selects only a tab the shown pane holds; panes the window does not show still remember the selection. |
| B2 | W7, click into a Chromium page / a sheet of another window | `WindowManager.active` fell back to the last key cmux window while a page window, sheet or panel of another window had the keys, and nothing republished the context: menus and Copy/Paste acted on the other window's terminal. | `active` resolves owned windows (sheet, child, panel) to their cmux window; the applier activates and republishes when an owned window becomes key. |
| B3 | W4, switch to an empty workspace | With no target (`.none`), Chromium focus stayed on the old page. | `.none` blurs the page, as `.emptyPane` did. |
| B4 | W5, open the group editor | The tab group editor bubble took the keys but the window had no overlay: content shortcuts and focus effects still targeted the pane below. | A key panel over the window other than the palette is a `.groupEditor` overlay until it resigns key. |
| B5 | W5/W7, click another window while the palette is open | The palette closed on resign key and then made its parent key again, taking the keys from the clicked window. | Closing because of a resign no longer re-keys the parent. |
| B6 | W1 and F4, drag cancel | A cancelled drag restored a text-field or sidebar target the applier cannot re-apply (model on the field, AppKit on the terminal), a chrome target on a tab that changed, and overrode a keyboard intent made during the drag. | Cancel restores the pane and pane-scoped targets only, chrome targets only on the same tab, and not after a keyboard, CLI or palette intent. The reducer also normalizes chrome targets (F4). |
| B7 | W1, click the sidebar or a Chromium page while the palette is open | The palette's close reached focus a run-loop turn late (an `Observations` loop), so the click that closed it was dropped as a report under an overlay; the window ended with no target. A Chromium page window made key by AppKit (not a click) was also taken as a user click. | The palette reports visibility synchronously before its key change; the palette's parent is the document window, never a page window; a page window becoming key without a mouse-down re-applies the model instead of retargeting. |
| B8 | F6 (the earlier stress test excused it) | `toggleBrowserFocusMode(tab:)` could name a tab the window does not show. | The reducer toggles only shown tabs. |
| B9 | live, a `CMUX_NEXT_NO_ACTIVATE=1` session (the model never opened the palette in an inactive app) | The palette panel is nonactivating; made key while the app was not active (a CLI request, a no-activate run) it took the system keyboard from the user's frontmost app, whose keystrokes then ran in cmux. | One rule for every key panel (palette, tab group editor, Page Info), `ActiveAppKeyPanel` in CmuxNextDesign: it takes the keys only while the app is active; otherwise it shows without them and closes when another window of the app takes the keys (a click or Cmd-Tab into the app). The palette gives the keys back only when it has them. The model opens the palette in an inactive app, and only the active app has a key window. |

B2, B4, B5, B7 and B9 are wiring in `FocusEffectApplier`, `WindowManager` and `PaletteController`.
Their regression tests run the fuzzer's minimal sequence through the model, which mirrors the
fixed wiring; the live monitor (W5, W7, W1) is what catches a regression there in dogfood.

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
