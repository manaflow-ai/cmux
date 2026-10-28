# cmux-next input pipeline: input first, one frame per input, measured to the glass

Status: design, partly landed (2026-10-26, at perf/chrome-parity `0e7f91edad5`). Owner: PL-input, under the
Performance Lead ([OWNERS.md](OWNERS.md)). Program spec, task table and per-task acceptance:
[chrome-parity/p04-input.md](chrome-parity/p04-input.md). This page keeps the rules I1-I9, the Chromium file that
each rule copies, where the code is, and the written reasons where cmux does not copy Chromium.
Patterns: [PATTERNS.md](PATTERNS.md) P16 (input pipeline) and P15 (how main-thread work is posted).
Threads: [threading-model.md](threading-model.md) ("Input pipeline" rows, "Closed user-interactive list",
"Daemon threads").

## Goal

A person's input runs before all other main-thread work. Continuous input (moves, drags, scrolls) is applied at
most twice per display frame: at once for the first event, then once at the frame. Scroll and pan move layers,
not layouts. Prediction moves pixels and never makes a decision. A key does O(1) work before it reaches its
target. Every input is measured from its OS timestamp to the frame that shows it, as Chromium's EventLatency does.

Targets (fixed by the program): key to frame p50 <= 8.3 ms and p99 <= 16.7 ms at 120 Hz, STRESS included; main
turn p99 <= 4 ms in input windows; 0 dropped frames in scroll and drag; no priority inversion on the key and echo
path, in the app and in the daemon.

Paths below are relative to `Packages/macOS/CmuxNext/Sources/` unless they start with `Packages/`, `cmux-tui/`,
`scripts/`, `schemas/` or `plans/`. Chromium paths are in `chromium/src` at HEAD (read 2026-10-25).

## Packages

| Target | Layer | What it holds |
|---|---|---|
| `CmuxNextInputCore` | core (no AppKit) | Event kinds and records (`InputEventRecord`, `InputObserving`), latency stages, the slot table, ring, buckets, ledger and `ScrollJankTracker`, pointer merge rules (`PointerCoalescingQueue`), `InputResampler`, `IntentPrewarm` |
| `CmuxNextInput` | ui | `InputEventTap`, `InputLatencyTracker`, `InputTargetClassifier`, `IntentPrewarmService`, the AppKit adapters |
| `CmuxNextInputDiagnostics` | ui | `debug.input` (`CmuxNextInputDiagnostics/DebugInput.swift`) and its sources, `ScrollViewAudit` |
| `CmuxNextInputCoreTestSupport` | test support | `FakeInputTap` |

The frame-aligned parts live in `CmuxNextWakeups` beside the frame clock: `FrameInputCoalescer`,
`PointerFrameConsumer`, `SessionInputPending`, `PresentationClock` and the input-turn hop recorder. AppServices
builds every object once and passes it by `init` (P1). New input code does not go into `CmuxNextApp` beyond wiring
lines. Core and service packages never import `CmuxNextInput`; they subscribe through `InputObserving`
(`scripts/cmux-next/arch_rules/layer_gate.py` refuses an upward edge).

## Rules

### I1 One input tap

| cmux | Chromium |
|---|---|
| `CmuxNextApp/CmuxApplication.swift` `sendEvent` is the only code that sees raw `NSEvent`s. It calls `CmuxNextInput/InputEventTap.swift` in one dispatch scope: observe, intercept (declared order), dispatch, after dispatch, dispatch end. | `content/browser/renderer_host/render_widget_host_impl.cc` keeps typed `InputEventObserver` lists and `KeyPressEventCallback`s on the widget the event goes to. |
| A subscription names its event classes, phase, window and an optional live predicate. Delivery costs only the subscribers of that class, copies no list and allocates nothing. A subscription made in a handler hears the next event, not this one. | `components/input/input_router_impl.cc`: one router for each widget, no process-wide hooks. |
| Core and service owners get `InputEventRecord` values through `CmuxNextInputCore/InputObserving.swift`. Another app's events come through `globalObserve` (`CmuxNextInput/InputEventTap+GlobalMonitor.swift`). | - |
| A handler reads the event it answers (`CmuxNextFocusUI/InputDispatchContext.swift`), not `NSApp.currentEvent` or `NSEvent.modifierFlags`. A target-action handler that must read `currentEvent` says `// current-event: target-action`. No `nextEvent(matching:)` tracking loops. | `ui/base/cocoa/command_dispatcher.mm` hands each handler its event. |

Why one tap is enough: Apple's `addLocalMonitorForEvents` documentation says a local monitor sees only events
that pass through `-[NSApplication sendEvent:]`, so the tap sees the same set. The guardrail `input-monitor`
(`scripts/cmux-next/guardrails.py`, local only) refuses a new monitor outside `CmuxNextInput`.

State at `0e7f91edad5`: 0 `NSEvent.add(Local|Global)MonitorForEvents` outside `CmuxNextInput` (33 at the
program's base), 0 `inputObserver` in `CmuxNextApp`, 0 code reads of `NSApp.currentEvent` outside the allowed
files (28 at the base), 0 `nextEvent(matching:)` loops (3 at the base). Tasks 011-020, 067-069, 095.

### I2 Input first

| cmux | Chromium |
|---|---|
| `MainWorkClass` puts `.input` first, then the input-response pass, then frame work (`CmuxNextWakeups/MainWorkClass.swift`, [main-thread-budget.md](main-thread-budget.md) section 1). | `content/browser/scheduler/browser_task_queues.h`, `QueueType::kUserInput` above kUserBlocking, kDefault, kUserVisible and kBestEffort. |
| `MainFrameBudget` makes every budgeted class yield while `SessionInputPending` (`CmuxNextWakeups/SessionInputPending.swift`) says a key, a button, a scroll begin or a drag is on its way. The check is one window-server query in the common case. A stale event stops counting after `staleAfter`. | `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`: kDiscreteInputResponse defers non-user-blocking queues until the frame that shows the response. |
| No reorder of main-actor jobs: the main job gate (tasks 021, 076) and the priority-ordered executor hook (p06-scheduler-202) were deleted in sequence-manager S6 ([sequence-manager-DESIGN.md](sequence-manager-DESIGN.md) 2.7). Unposted main-actor jobs (await resumes, framework tasks) stay FIFO on the main queue; the app's own hops become posted tasks with a class (S4, S5). The one main-executor hook is the census's record-only `MainJobRing`. | Blink defers task queues; it does not reorder them. |
| The in-process Chromium pump waits while input for anything but a Chromium page is pending, at most one refresh, and runs one pass at once after input to a Chromium page (`CmuxNextBrowser/CEF/CEFPumpInputPolicy.swift`, feature `cefPumpInputPolicy`). | Chromium's browser-side input pipeline (`InputRouterImpl`, `MouseWheelEventQueue` acks) runs inside `CefDoMessageLoopWork` on main, so a page's input needs the pump. |

How work is posted to main (classes, owners, no `DispatchQueue.main.async`) is P15 and
[main-thread-budget.md](main-thread-budget.md), not this page.

State: the input-turn hop recorder is landed (task 022: `CmuxNextWakeups/InputTurnHopRecorder.swift`,
`CmuxNextControl/Diagnostics/InputTurnHops.swift`, `debug.input hops`, `scripts/cmux-next/input-turn-hops.py`).
The gate (tasks 021, 076, feature `mainJobGate`, setting `debug.mainJobGate`) was deleted in sequence-manager S6.
The unposted main jobs that ran between an input's arrival and its dispatch are measured by the main-job census's
input window (`CMUX_NEXT_MAIN_JOB_CENSUS=input`, `debug.main_jobs.input`), by enqueue site.

### I3 Continuous input once per frame

| cmux | Chromium |
|---|---|
| One `FrameInputCoalescer` per window (`FrameScheduler.input`, `CmuxNextWakeups/FrameInputCoalescer.swift`). A `PointerFrameConsumer` (`CmuxNextWakeups/PointerFrameConsumer.swift`) gets its first event of a frame interval at once (leading edge). The rest go out once at the frame tick, before the window's frame clients. | `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.h`: `IsRafAlignedEvent`, `DispatchRafAlignedInput(frame_time)`. |
| Merge rules (`CmuxNextInputCore/PointerCoalescingQueue.swift`): moves keep the latest point; scrolls are summed for each phase, momentum phase and precision; a drag keeps its newest 16 points for velocity. A merged delivery keeps the oldest generated time and a count. A change of kind, button, modifiers or scroll phase starts a new delivery. | `WebCoalescedInputEvent`: oldest timestamps, coalesced events kept. |
| A discrete event flushes all pending continuous input first (`FrameInputCoalescers.willDispatch`). | `ShouldFlushQueue()`. |
| When no frame comes (an occluded window), a one-shot fallback delivers: one refresh for a drag or a keyed post, 5 s otherwise. It is armed only while work is pending and the link is not running. | `raf_fallback_timer_`, kMaxRafDelay 5 s. |
| Opt out: native `NSScrollView`, WebKit and Chromium page views, and the Chromium host wire. A forward into an engine that coalesces by itself says `// input-coalesce: native`. | The browser does not frame-align input to a renderer (`components/input/mouse_wheel_event_queue.h` holds only the first wheel until its ack). |

Features (all default off): `pointerFrameDrags`, `pointerFrameHover`, `terminalPointerFrames`,
`pointerFrameRemoteInput` (`schemas/features/features.d/`). Tasks 030-038, 088-089 (088, 089 and 032 not landed).

### I4 Scroll and pan move layers

| cmux | Chromium |
|---|---|
| Sidebar and palette responsive scrolling and the strip pan's motion container are owned by p03-rendering (p03-110, p03-026). Rows and scroll areas pan by translation (task 050). Page scrolls leave `LayoutRootView` routing in O(1) (task 052). | `docs/how_cc_works.md`: `LayerTreeHostImpl` scrolls property trees without Blink. |
| A scroll view that cannot scroll responsively is reported by `CmuxNextInputDiagnostics/ScrollViewAudit.swift` (task 048). | `cc/input/main_thread_scrolling_reason.h`: each fall-back to main has a named reason. |

Not landed: the tab strip and saved bar by translation (087), sidebar swipe and wheel paging through the tap (100,
the input-side prerequisite of p03-110), and the spike that decides whether strip and rows scroll with main
stalled (102).

### I5 Prediction moves pixels, never decisions

| cmux | Chromium |
|---|---|
| `CmuxNextInputCore/InputResampler.swift` is an exact port of the linear resampler: sample time = frame time - 5 ms; prediction at most min(8 ms, last dt / 2); no result until two samples 2 ms apart; a gap over 20 ms starts again. cmux adds one rule: no extrapolation across a change of direction. | `ui/base/prediction/linear_resampling.cc`. Frame-ahead prediction stays off by default, as `kResamplingScrollEventsExperimentalPrediction` in `ui/base/ui_base_features.cc`. |
| Resampling moves only visuals: drag ghosts, divider position, strip pan (features `resampledDrags`, `stripPanResampling`). Drop targets, snaps and flings read real samples. | - |
| Intent prewarm (`CmuxNextInputCore/IntentPrewarm.swift`, `CmuxNextInput/IntentPrewarmService.swift`) wakes a sleeping page for a target that commits on release: on press, after a 200 ms hover, or one step ahead of next/previous keys (features `intentPrewarmPress`, `intentPrewarmHover`, `directionalPrewarm`). At most 2 are held; a third cancels the oldest. Never in Low Power Mode on battery or under memory pressure. No daemon write, no terminal attach. | Speculation rules: "conservative" on pointerdown, "moderate" after 200 ms hover, at most 2 for each eagerness, FIFO. |
| Terminal predictive echo (`CmuxNextTerminal/PredictiveEcho/`) uses mosh's rules and shows in an overlay layer, not in preedit. Setting `terminal.predictiveEcho`, off by default. A rollback is exact: the overlay draws nothing and the real grid shows through. | - (mosh). |

Nothing predicted writes to the daemon or the model.

### I6 Key routing does O(1) work

| cmux | Chromium |
|---|---|
| `CmuxNextFocusUI/KeyContextCache.swift` keeps the key context with a generation counter; `CmuxNextFocusUI/KeyRouterMode.swift` picks the plain-typing fast path once; the resolve allocates nothing and when-clauses are bit sets (tasks 053-055). | `ui/base/accelerators/accelerator_manager.h`: one map lookup. |
| A terminal chord makes no TIS call (task 096). The CEF pre-key hook asks an O(1) decided check first (task 062). | `ui/base/cocoa/command_dispatcher.mm`: the first responder gets the key first; no walk of the view tree. |
| `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/KeyRouterBench.swift` prints numbers and asserts no time (task 056). | - |

Not landed: key equivalents that skip AppKit's whole-tree `performKeyEquivalent` walk and the menu search (086).

### I7 Terminal key and echo lanes

| cmux | Chromium |
|---|---|
| `CmuxNextTerminal/TerminalInputLane.swift`: the main thread writes key bytes into a per-session ring with no wait and no allocation; the IO's queue `com.cmuxterm.next.terminal.attach-input` drains it, so a key reaches the attach socket's `write(2)` in one thread hop (task 058). | `cc/input/input_handler.h`: `ui::InputHandlerProxy` hands an event to the compositor thread in one post. |
| Socket QoS by role: the `terminal_attach` reader and writer run at user-interactive, every other role, `control` included, below it (`CmuxNextDaemon/Connection/SocketWriter.swift`, `DaemonWireStats.Role`, task 059). | IPC lands on a dedicated IO thread and goes to its bound sequence. |
| Daemon: `cmux-tui/crates/cmux-tui-core/src/thread_qos.rs` maps a `ThreadType` (InputCritical, Interactive, UnclassifiedClient, Utility, Background) to a QoS class in one place; `echo_thread::ECHO_PATH_QOS` is InputCritical (task 060). | `base/threading/platform_thread_apple.mm`: `ThreadTypeToQoSClass`. |

Not landed: the app-side echo lane with no `AsyncStream` or pool hop (083), Ghostty's key path that never waits on
`renderer_state.mutex` behind a parse slice (078, ghostty fork), the per-frame Ghostty action mailbox (079), the
QoS of the echo, TUI and remote threads and UTILITY for background threads (084), and input precedence in the
daemon's connection scheduler (085).

### I8 Chromium input

| cmux | Chromium |
|---|---|
| The Chromium host wire sends every input frame at once and coalesces latest-wins only while the socket is full (`CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostInputOutbox.swift`, task 038). It carries wheel phase, momentum and precise deltas (063), IME (064), user-input priority with OS timestamps (065) and the page's presented time (066). | `content/browser/renderer_host/input/`: the browser sends input as it comes; the renderer aligns it to its own frames. |

Not landed: Chromium's own EventLatency and ScrollJank histograms read through CDP `Browser.getHistograms` (091),
and passive listeners, rAF-coalesced moves and a key-to-paint probe in cmux's web pages (092). Fork items stay with
PL-cef-layer.

### I9 EventLatency for cmux

| cmux | Chromium |
|---|---|
| Each tracked input gets one fixed-size slot (`CmuxNextInputCore/InputLatencySlot.swift`) with a time for each stage, from `generated` (the oldest coalesced OS time) to `presented`. An empty stage was skipped. | `cc/metrics/event_metrics.h`: `DispatchStage` slots. |
| Open slots live in a 128-entry table (`InputLatencySlotTable.swift`); any thread writes a stage with one relaxed atomic store, once. The tracker (`CmuxNextInput/InputLatencyTracker.swift`) closes a slot on main and moves it into the 256-slot ring (`InputLatencyRing.swift`); each half ring goes to the ledger. | `ui/latency/latency_info.h` carries ids across processes. |
| Presented = the vsync of the commit plus one render-server frame, plus a per-OS offset set by the glass check (`CmuxNextWakeups/PresentationClock.swift`). The window's link stays on for 3 frames after a tracked input so the real target timestamp is used. Variable-refresh displays are labelled. | `CompositorFrameReporter` closes each event at the presentation feedback of the frame that shows it. |
| A slot with no frame update is dropped, except keys. | `caused_frame_update`. |
| `CmuxNextInputCore/InputLatencyLedger.swift` folds batches off main into histograms per kind, target, entrypoint and presentation source (edges 1, 2, 4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250 ms). `ScrollJankTracker.swift`: a frame is janky when the gap is over 1.5 vsync and input was available; missed vsyncs = round((gap + vsync/2)/vsync) - 1. | `cc/metrics/scroll_jank_dropped_frame_tracker.cc`; UMA `EventLatency.*`, `Event.ScrollJank.*`. |
| Outputs: the `input.latency` signpost (typed numbers, no `String`), `debug.input`, the EventLatency track of `scripts/cmux-next/trace.py`, opt-in nightly field data. Ground truth: `scripts/cmux-next/input-glass-check.py` (ScreenCaptureKit), per macOS version. | Field data is read as distributions, never as means. |

Not landed: Action Latency HUD rows (009), the input latency bench (070), the scroll jank bench (072),
cross-process terminal stages (094), INP-style interactions (097), the WebKit page presented stage (099), the text
input server stage (101) and the field report's wiring (103, 104).

## Rules for implementers

1. Read [PATTERNS.md](PATTERNS.md), [REVIEW-STANDARD.md](REVIEW-STANDARD.md), [threading-model.md](threading-model.md)
   and the owner row before you edit, and tell the owner your task names.
2. Per-event and per-frame paths take no lock, make no allocation, build no `String` and make no system call. Mark
   them `// perf-hot:`.
3. Escapes, each checked by the reviewer at its site: `// input-hop-allow: <why>` (a main job whose order is a
   correctness need), `// input-coalesce: native` (a forward into an engine that coalesces by itself),
   `// global-input-allow: <why>` (a global input read outside dispatch), `// current-event: target-action`.
4. New user-visible behavior goes behind a default-off feature in `schemas/features/features.d/`. Input settings
   are `SettingDescriptor`s in `CmuxNextSettings/Schema/SettingsSchema+Input.swift`.
5. Each fix gets a regression test that fails without it. Benches print numbers and assert no time. No CI gate,
   perf-gate row or budget is added: agents run every check on the fleet.

## Checks

The done checks DC1-DC14 and the machine queues are in [chrome-parity/p04-input.md](chrome-parity/p04-input.md)
sections 5 and 6. The static ones, which need no build:

```sh
git grep -nE 'NSEvent\.add(Local|Global)MonitorForEvents' -- Packages/macOS/CmuxNext/Sources ':!Packages/macOS/CmuxNext/Sources/CmuxNextInput/'
git grep -n 'nextEvent(matching' -- Packages/macOS/CmuxNext/Sources
```

Both print no code line at `0e7f91edad5` (the second prints one doc comment in the tap). The runtime ones (key to
presented frame, scroll jank, the glass check) run on fleet minis with a 120 Hz virtual display, light and STRESS,
on macOS 26 and 27. VM timing is not perf evidence.

## Owners

PL-input owns `CmuxNextInputCore`, `CmuxNextInput`, `CmuxNextInputDiagnostics` and this page. The frame-aligned
files in `CmuxNextWakeups` stay with the Performance Lead. Shared areas keep their owners: PL-typing (key router,
terminal key path), PL-ghostty (terminal pointer, echo, predictive echo), PL-cef-layer (Chromium host wire, CEF
pump), PL-motion-core and PL-motion-cef (drags, motion, overlays), PL-daemon (daemon QoS and scheduler), PL-switch
(intent prewarm).
