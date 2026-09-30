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
| `focusPane`, `selectTab`, `focusTarget` (user sources) | pane and target, bumping the generation |
| `responder` | pane and target to what AppKit chose, unless an overlay is open; `windowOrNone` only re-applies |
| `expect` | lands at once or when its surface/tab appears, only in its generation |
| `dragBegan` / `dragEnded` | cancel restores pane and target; drop focuses the dropped tab away from its source pane |
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

A window whose focused pane does not present the targeted tab yet is unsettled: W1-W4 wait.

## 3. Input journal

`InputJournal.shared`: a ring of 4,096 `InputJournalEntry` values with a sequence number and
`CLOCK_UPTIME_RAW` nanoseconds. It records every event `CmuxApplication.sendEvent` receives
(before the key router can consume it: key down/up/flags with key code and modifier classes;
mouse down/up/drag/scroll in window-local top-left points, drags and scrolls merged per run),
every focus reduction with the resulting `FocusDigest` plus a full `FocusState` checkpoint every
64 reductions per window, suppressed responder echoes, page focus the applier gives or takes
(WebKit, Chromium, Chromium key window), every attach reduction (event, link, byte count, phase
after), desync markers, and automation markers.

Recording is on in debug and tagged (dogfood) builds, off in release builds;
`CMUX_NEXT_INPUT_JOURNAL=0|1` overrides. Disabled, each hook is one relaxed atomic load and
builds no payload. Key characters are recorded only with `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1`
(explicit opt-in, any build); attach records carry byte counts, never bytes.

## 4. Invariant monitor and desync reports

`InputInvariantMonitor` runs after any focus reduction, key-down, mouse down/up or content
presentation, once 12 display frames pass without another. It checks section 2.5 (which includes
2.1) on `InputObservationBuilder.observe`. A violation seen once is checked again one settle later;
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

## 6. Limits and follow-ups

- The model assumes Chromium's `SetFocus` does not make the page window key (the fork's
  "counts as active while the parent is key", browser.md). If the page window does become key,
  W5 in the live monitor reports it.
- Key-router decisions are not journaled yet; the app-wide key interception work
  (`KeyRouter.interceptKeyDown`) is the place to add a `route` record, then K1/K2 can be checked
  live per key-down.
- The omnibar rule F8 is checked in the model; the live monitor covers the responder side (W1).
- `debug.key` takes key names, not key codes; live replay maps journaled key codes of letters,
  digits and named keys only.
