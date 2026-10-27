# p04-input: the input pipeline (input first, frame-aligned, scroll on layers, safe prediction, O(1) key routing, EventLatency)

Program spec, final (fixer pass over the design and 3 reviews). Base: perf/chrome-parity at 772cdfc45ac
(= origin/feat-cmux-next). Counts come from `rg` over `Packages/macOS/CmuxNext/Sources` at that commit unless a
line names another path. Fixer re-checks (2026-10-25) are marked "(checked)".

Scope in one sentence: a person's input runs before all other main-thread work, continuous input is applied at
most once per display frame (leading edge plus one trailing delivery), scroll and pan move layers and not layouts,
prediction moves only pixels and never decisions, a key does O(1) work before it reaches its target, and every
input is measured from the OS event to the presented frame, as Chrome's EventLatency does.

Goals owned (fixed targets): key->frame p50 <= 8.3 ms and p99 <= 16.7 ms at 120 Hz including STRESS (input half);
main-thread turn p99 <= 4 ms in input windows; 0 dropped frames in scroll and drag; input QoS with no priority
inversion on the key and echo path (app and daemon).

Shared with other programs (dedupe by file path before dispatch, see section 7):

- p03-rendering owns: one DisplayClock per display (p03-010/012), Ghostty present off main (p03-080/081, which
  replaces this design's old task 061), strip pan on a motion container (p03-026, which replaces old task 049),
  `.inVisibleRect` tracking areas added once (p03-109, which replaces review 1's MQ-tracking-rebuild tasks),
  responsive scrolling for sidebar, palette and terminal scroller (p03-110, which replaces old task 047), CEF pump
  slices (p03-116) and Ghostty wakeup tick coalescing (p03-119). p04 depends on those tasks and gives them input-side
  inputs (task 100 for p03-110, the pump input policy for p03-116).
- Owners (plans/cmux-next/OWNERS.md, checked): row 27 PL-typing (KeyRouter*, terminal key path), row 25
  PL-motion-core (ScreenContentView+Motion*), row 24 PL-motion-cef (overlays, catchers), row 21 PL-cef-layer
  (Chromium hosting, fork items), row 29 PL-ghostty (CmuxNextTerminal, Ghostty), row 30 PL-daemon (cmux-tui-core),
  row 33 PL-holder (cmux-holder*), row 34 PL-telemetry (hang reports). Each task names its owner; tell the owner.

## 1. Chrome reference

Paths are in chromium/src at HEAD (read or confirmed on chromium.googlesource.com, 2026-10-25).

1. Input outranks other UI-thread work. `content/browser/scheduler/browser_task_queues.h`, `QueueType::kUserInput`:
   "For tasks directly related to handling input events. This is higher priority than kUserBlocking. This also
   changes the priority of yielding to native (to get the user input events faster)." Order: kUserInput >
   kUserBlocking == kDefault > kUserVisible > kBestEffort; kBestEffort "can theoretically be starved". The priority
   comes from the queue the task is posted to (BrowserTaskTraits), never from the posting thread. All of it runs on
   `base/task/sequence_manager`. The renderer main thread does the same
   (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.{h,cc}`): after a discrete
   input, UseCase kDiscreteInputResponse defers non-user-blocking queues until the rendering task that shows the
   response has run (RenderingPrioritizationState kWaitingForInputResponse). Chrome's next step is InputVizard
   (`components/input/README.md`): input handling leaves the browser main thread for the viz compositor thread.
2. Continuous events coalesce and align to the frame. `third_party/blink/renderer/platform/widget/input/
   main_thread_event_queue.h`: coalesces through WebCoalescedInputEvent, decides with IsRafAlignedEvent() (mouse
   move, wheel, touch move only), flushes in DispatchRafAlignedInput(frame_time), and keeps raf_fallback_timer_
   ("A safe guard timer to ensure input is always processed", kMaxRafDelay 5 s) for when no frame comes. Discrete
   events go through PostTaskToMainThread; ShouldFlushQueue() drains coalesced events first, so order holds. A
   coalesced event keeps the oldest event's timestamps (worst latency) plus a coalesced count. The browser side does
   not frame-align input that goes to a renderer: `components/input/mouse_wheel_event_queue.h` holds only the first
   wheel of a sequence until its ACK, then sends the rest at once.
3. Scroll runs on the compositor. `docs/how_cc_works.md`: input reaches `ui::InputHandlerProxy`; `LayerTreeHostImpl`
   changes property trees and scrolls "without involving Blink"; it falls back to main only for a reason in
   `cc/input/main_thread_scrolling_reason.h` (for example a non-passive wheel handler).
4. Prediction only where safe. `ui/base/prediction/linear_resampling.cc`: sample time = frame_time + kResampleLatency
   (-5 ms, so it mostly interpolates behind the frame), prediction capped at min(8 ms, last_dt/2), needs
   last_dt >= kResampleMinDelta (2 ms), resets after kMaxTimeDelta. Frame-ahead prediction is
   kResamplingScrollEventsExperimentalPrediction, disabled by default (`ui/base/ui_base_features.cc`). Speculation
   rules: "conservative" = pointerdown, "moderate" = 200 ms hover on desktop; at most 2 per eagerness, FIFO, the
   oldest cancelled; no preloading under Energy Saver with low battery or under memory limits.
5. Key routing. One accelerator map lookup (`ui/base/accelerators/accelerator_manager.h`), then an async send to
   the renderer. On Mac, `ui/base/cocoa/command_dispatcher.mm` prePerformKeyEquivalent gives the key to the first
   responder first; there is no whole-view-tree walk. Nothing on the UI thread waits for the renderer.
6. End-to-end latency. `cc/metrics/event_metrics.h`: DispatchStage slots (kGenerated, kArrivedInBrowserMain,
   kArrivedInRendererCompositor, kRendererCompositorStarted/Finished, kRendererMainStarted/Finished); an empty slot
   means the stage was skipped. Events that cause no frame update are dropped (caused_frame_update), except listed
   kinds. CompositorFrameReporter closes each event at the presentation feedback of the frame that shows it; the
   feedback has flags (kVSync, kHWClock, kHWCompletion). UMA EventLatency.<Type>.TotalLatency, with
   EventLatency.KeyPressed and a separate FirstGestureScrollUpdate. `ui/latency/latency_info.h` carries ids across
   processes. `cc/metrics/scroll_jank_dropped_frame_tracker.cc`: a presented frame is janky when the gap to the
   previous presentation is > 1.5 vsync AND input was available; missed vsyncs = round((gap + vsync/2)/vsync) - 1;
   histograms Event.ScrollJank.DelayedFramesPercentage / MissedVsyncsSum / MissedVsyncsMax for FixedWindow (64
   frames) and PerScroll. The page-level field metric is INP (web.dev/articles/inp): events are grouped into
   interactions, an interaction takes its longest event, and the reported value ignores one for each 50. Field
   data is read as distributions, never as means.
7. Threads have types. `base/threading/platform_thread_apple.mm` maps ThreadType (kDisplayCritical, kCompositing,
   kBackground) to QoS in one place. IPC lands on a dedicated IO thread and goes to the bound sequence; it never
   waits for a general worker pool.
8. Hangs and blocking: `base/threading/hang_watcher.h`, `base/threading/scoped_blocking_call.h`. cmux has
   MainThreadWatchdog and the blocking seams in threading-model.md.

## 2. cmux today

All file:line at 772cdfc45ac.

KEY DOWN. `CmuxApplication.sendEvent` (Sources/CmuxNextApp/CmuxApplication.swift:81, 253 lines) wraps
InputDispatchContext.dispatching and route():

- KeyFrameSignpost().begin formats a String with String(format:) on every key in every build
  (CmuxNextSignposts/KeyFrameSignpost.swift:36).
- inputObserver: a chain of 3 closures (InputVerificationService.swift:31, InputVerificationService+NoActivateGuard
  .swift:70, AppBrowserHost.swift:155).
- crossWindowKeyGuard, dispatchScope, hideShortcutHintsForKeyDown on every key.
- keyDownInterceptor -> KeyRouter.interceptKeyDown (Focus/KeyRouter.swift:186, perf-hot 0.5 ms): about 14 ordered
  checks; a chord builds Facts with about 15 lookups (KeyRouter+Context.swift:134); KeyBindingTable.resolve appends
  a Candidates array per resolve (CmuxNextActions/KeyBindingTable.swift:112).
- super.sendEvent: 32 `NSEvent.addLocalMonitorForEvents` sites plus 1 `addGlobalMonitorForEvents`
  (TabClosingModeWatch.swift:42) (checked); 39 keyDown, 15 performKeyEquivalent, 9 sendEvent overrides.
- Every Command/Control chord also gets AppKit's depth-first performKeyEquivalent walk over all subviews, then a
  main-menu search that runs validateMenuItem -> ActionTargetReasons.canPerform (ActionRegistry+Menus.swift:79).
- Terminal chords: 2 TISCopyCurrentKeyboardInputSource calls per Control/Option/Command/Fn chord
  (TerminalSurfaceView+Keyboard.swift:45, 50) (checked); copy mode does TIS + UCKeyTranslate per key
  (TerminalCopyMode.swift:105); GhosttyKeyBindingLayer.isUsersKeybind scans linearly (line 76).

TERMINAL KEY TO ECHO. keyDown -> interpretKeyEvents -> ghostty_surface_key (locks renderer_state.mutex for every
non-modifier press; Surface.zig keyCallback near 3288, ghostty-next) -> io_write_cb on main (one Data per key,
TerminalSurfaceBridge.swift:95) -> AsyncStream(.unbounded) -> Task.detached (TerminalSession.swift:158) -> actor
DaemonTerminalIO.write (DaemonTerminalIO.swift:152) -> TerminalAttachDriver Mutex -> SocketWriter DispatchQueue
with no QoS (CmuxNextDaemon/Connection/SocketWriter.swift:33) -> daemon. The output lane parses 64 KiB per lock
hold (embedded.zig near 2513), so under STRESS a key waits for a parse slice. Echo back: LineTransport reader
thread (.userInteractive, LineTransport.swift:166) (checked) -> AsyncStream -> a `for await` Task.detached
(TerminalAttachDriver.swift:214) (checked) on the cooperative pool -> a second AsyncStream -> TerminalOutputLane ->
Ghostty renderer -> dispatch_async main -> IOSurfaceLayer.contents -> CA commit. Ghostty actions reach main as 5
DispatchQueue.main.async sites (GhosttyRuntimeCallbacks.swift:21, 43, 124, 154, 160) (checked).

DAEMON. 0 `pthread_set_qos_class_self_np` in cmux-tui/crates (checked). Key path threads: mux-conn (listen.rs:416),
mux-control-dispatch (connection_scheduler.rs:209, runs Send), terminal-host-client-input (host_serve.rs:440, PTY
write). Echo path: terminal-host-pty (host_start.rs:174, PTY read), terminal-host-parser (host_start.rs:162),
terminal-host-client (host_accept.rs:81), mux-render-attach-out (cmd_attach.rs:274), mux-attach-out
(cmd_attach.rs:392, 522), mux-resource-terminal-attach (resource_attach.rs:434), mux-line-out
(line_connection.rs:46). TUI/remote: mux-pty-input (pty_input.rs:370), remote-input-writer (remote.rs:1340),
relay-input (main.rs:2077), holder-link (cmux-holder/src/link.rs:164, cmux-holder-v3/src/link.rs:90) (all checked).
ConnectionSurfaceScheduler can queue a Send behind another surface's slow read.

PRIORITY. MainWorkClass, MainFrameBudget (4 ms) and SessionInputPending exist but govern only budgeted
FrameClient/FrameBatchQueue/FrameBatcher work. Bypassing them: 1643 `Task {` (482 `Task { @MainActor`), only 3
`Task(priority:` (checked), 69 withObservationTracking (45 hop through `Task {`) (checked), 202
MainActor.assumeIsolated, and non-Swift main work: 153 hits in 79 files for
`DispatchQueue.main.(async|asyncAfter|sync)|CFRunLoopPerformBlock|performSelector(onMainThread|RunLoop.main.perform|
queue: .main|DispatchSource.make…queue: .main` with comments removed (checked; 161 `queue: .main`, 15
`DispatchQueue.main.`, 9 CFRunLoopPerformBlock, 2 RunLoop.main.perform). A Task created on main inherits
userInteractive QoS (WorkPriority.swift:47-48 says so) (checked). The CEF pump fires with no input check
(CEFMessagePump.swift:105-128); passes of 10 ms and more (perf-lead row 10).

CONTINUOUS INPUT. No cmux coalescing. 53 pointer-drag/move overrides in 40 files (checked), 11 scrollWheel
overrides (checked), 45 files with updateTrackingAreas of which 38 remove and re-add areas (checked; p03-109 owns),
17 resetCursorRects (checked), 75 hitTest overrides (checked), 39 reads of NSEvent.modifierFlags/mouseLocation/
pressedMouseButtons (checked). Divider drags write the model per event (ScreenContentView+DividerDrag.swift:63);
canvas drags write setCanvasFrame per event (ScreenContentView+Canvas.swift:131); TabStripView.scrollWheel runs
applyFrames per wheel event (TabStripView+Pointer.swift:288). The Chromium host prototype sends one wire frame per
event, drops wheel phase and momentum, sends only the first UTF-16 unit, and closes on a short write
(ChromiumHostPageView.swift:123-160, ChromiumHostConnection.swift:63-75).

SCROLL. SidebarScrollView.scrollWheel feeds every event of a gesture to ProfileSwipeTracker and SpaceWheelPager
(SidebarScrollView.swift:20-46) (checked), so responsive scrolling cannot be turned on by a flag alone. A strip pan
relayouts every pane per frame (ScreenContentView+Motion.swift:94-117; p03-026 owns the fix).

PREDICTION. 0 sites. The sidebar already switches on press (SidebarListView+Mouse.swift press.deferredClick); only
the multi-view prototype commits on release (checked).

EVENT IDENTITY. 33 `NSApp.currentEvent` reads outside InputDispatchContext.swift, 28 of them code and 5 doc
comments (checked). 3 `nextEvent(matching:)` loops (checked).

MEASUREMENT. key.frame and key.scroll_frame end at the CA commit, not at presentation. No click, drag or move
latency signpost. No input field histogram. TypingLatencyProbe is opt-in. Fleet numbers (perf-lead rows 5-6):
Home composer key->frame p95 42 ms idle, 284-400 ms under load; omnibar 32-34 / 163-179 ms; terminal at a prompt
under STRESS 48-59 ms; typing while the sidebar churns 143 ms at 400 workspaces. Existing benches:
typing-frame-bench.py, home-perf.py, activation-perf.py, input-replay.py, strip-scroll-check.py,
sidebar-scroll-floor.swift (checked).

## 3. Target design

Two new targets. `CmuxNextInputCore` (layer core: pure, no AppKit; event kinds, stages, slots, ledger, coalescing
math, resampler, prewarm state machine, InputEventRecord and the InputObserving protocol for core and service
consumers). `CmuxNextInput` (layer ui: InputEventTap, PointerFrameCoalescer, InputLatencyTracker, debug.input,
IntentPrewarmService, audits). Both are built once in AppServices (P1) and listed in architecture-layers.json. New
code does not go into CmuxNextApp beyond wiring lines (the app-size and app-type guardrails refuse it).

(A) ONE INPUT TAP. CmuxApplication.sendEvent is the only place that sees raw NSEvents. InputEventTap holds typed
subscriptions: class (key, flags, button, pointerMove, drag, scroll, gesture), phase (observe, intercept with a
declared order, afterDispatch), window scope and a live predicate. Dispatch is O(subscribers of that class in that
window), with no array copy. Core and service packages (Wakeups, ChromiumWarmup) subscribe through InputObserving
with InputEventRecord values (type, timestamp, window id, location, flags, key code); only ui packages see NSEvent.
Other apps' events (TabClosingModeWatch) use a `globalObserve` API inside CmuxNextInput. Local monitors see only
events that pass through `-[NSApplication sendEvent:]` (Apple's addLocalMonitorForEvents documentation: events
consumed by nested tracking loops are not passed), so the tap sees the same set; a regression test proves it.

(B) INPUT FIRST (Chrome kUserInput and kDiscreteInputResponse).

- MainJobGate installs the Swift runtime's `swift_task_enqueueMainExecutor_hook` (dlsym, as AlternateSignalStacks
  does for pthread hooks). It lands first in record-only mode (task 021): pass-through, plus a recorder of jobs
  enqueued while input is pending or dispatching. Holding lands later behind `debug.mainJobGate` (task 076).
- Classification is by declared origin, not by TaskPriority (a Task created on main inherits userInteractive).
  Pass through: jobs enqueued inside the input dispatch (a main-thread flag set by route), and jobs stamped by the
  explicit `MainWork.input { }` / `MainWork.frame { }` API. Hold all others while input is pending or dispatching.
- Pending-input state is an atomic the hook reads with one relaxed load. It is refreshed once per run-loop turn
  (afterWaiting) and by the tap. The hook makes no system call.
- Held jobs drain in strict FIFO. While the FIFO is not empty, new non-exempt jobs append to it (no reordering
  across the hold boundary; SE-0431 order is kept). The FIFO drains after the input's frame commit, through
  `CmuxNextWakeups/AfterFrameCommit.swift` (beforeWaiting, after CA's commit), with a one-refresh deadline as the
  starvation bound. A nested run loop (menu tracking, runModal, drag session) releases the FIFO at mode entry and
  suspends holding until it exits.
- Non-Swift main work (153 hits) gets a declared class through `MainWorkScheduler.post(class:)` and
  `MainNotificationObserver(name:class:)` (tasks 080-082); Ghostty actions go to a per-surface mailbox drained once
  per frame (079).
- The CEF pump defers while input for a non-Chromium target is pending; input for a Chromium page runs one pump
  pass at once after its dispatch, because Chromium's browser-side input pipeline (InputRouterImpl,
  MouseWheelEventQueue acks) runs inside CefDoMessageLoopWork on main. Slicing is p03-116.
- Observation onChange hops become FrameObservation deliveries with an explicit delivery: `.visible(window)`,
  `.automation` (no display link) or `.sameTurn` (allow comment).

(C) FRAME-ALIGNED CONTINUOUS INPUT. PointerFrameCoalescer per window and consumer.

- Leading edge plus trailing coalescing: the first event in a frame interval is delivered at once; later events in
  the same interval collapse to one delivery at the tick (at most 2 per frame). Moves: latest wins. Scroll: summed
  per (phase, momentumPhase, precise). Drags: latest point plus 16 samples for velocity. A coalesced slot keeps the
  oldest generated time and a count.
- Delivery on the window's frame tick (DisplayClock, p03-010) as a frame-class client before budgeted work. A
  fallback one-shot DemandTimer is armed only while entries are pending and the link is not running (occluded
  window): one refresh interval for drags, 5 s otherwise (Chrome kMaxRafDelay).
- Any discrete event flushes first (Chrome ShouldFlushQueue).
- Opt out: native NSScrollView, WKWebView/Chromium page views, and the Chromium host wire, which sends at once and
  collapses to latest-wins only under socket back-pressure (Chrome does not frame-align input to a renderer).

(D) PREDICTION WHERE SAFE.

- InputResampler is an exact port of Chrome's LinearResampling constants (-5 ms, min(8 ms, dt/2), 2 ms min dt,
  reset on gap), plus one written cmux addition: no extrapolation across a direction change. Frame-ahead
  prediction only behind a default-off debug setting. Visuals only (drag ghosts, divider position, strip pan);
  drop targets, snaps and flings read real samples.
- Intent prewarm only for targets that commit on release (tab cells, multi-view rows, palette rows), after a
  click-to-commit trace shows a gap of 30 ms or more. pointerdown (conservative) and 200 ms hover (moderate);
  FIFO of 2, oldest cancelled; skipped in Low Power Mode on battery and under memory pressure. Side-effect free
  only: no daemon write, no terminal attach.
- Terminal predictive echo (mosh rules) behind `terminal.predictiveEcho` (off by default), shown by a cmux overlay
  layer (not preedit, which cannot show backspace over cells). Last in the queue.

(E) SCROLL ON LAYERS. Sidebar and palette responsive scrolling is p03-110; p04 first moves profile swipe and wheel
paging to a tap observer (100) so the flag does not break them. Strip pan is p03-026 (sublayerTransform); rows and
scroll areas follow the same technique (050). Tab strip and saved-groups bar scroll by translation (087). Page
scrolls leave LayoutRootView routing in O(1) (052). A spike decides whether strip and rows can scroll with main
stalled (102).

(F) KEY ROUTING OFF THE HOT PATH. KeyContextCache (generation counter), precomputed KeyRouterMode switch,
allocation-free resolveWinner with when-clauses compiled to bit sets, O(1) CEF pre-key decided check, a key
equivalent path that skips AppKit's whole-tree walk and the menu search (086), no TIS per terminal chord (096).
KeyRouterBench prints numbers; it asserts no time in CI.

(G) TERMINAL KEY AND ECHO LANES.

- Key: io_write_cb copies bytes into a per-session SPSC record ring; one userInteractive writer drains it to the
  attach socket (058). SocketWriter QoS: attach userInteractive, control userInitiated, and the control reader
  thread lowered to userInitiated so automation events do not share typing's CPU class (059).
- Echo: the link reader hands output bytes straight to TerminalOutputLane with no AsyncStream or pool hop (083).
- Ghostty: a key never waits on renderer_state.mutex behind a parse slice (078); present off main is p03-080/081.
- Daemon: a ThreadType-style enum maps to QoS in one place (060); all key and echo threads USER_INTERACTIVE,
  background threads UTILITY (084); Send/SendKey get precedence over other surfaces' slow reads (085).

(H) CHROMIUM INPUT. O(1) pre-key; helper wire with wheel phase, momentum, precise flags, IME (NSTextInputClient,
caret rects pushed by the host); user-input priority task with OS timestamps; presented feedback. Fork items stay
with PL-cef-layer. Chromium's own EventLatency and ScrollJank histograms are read through CDP
Browser.getHistograms (091). cmux web pages: passive listeners, rAF-coalesced moves and an in-page key-to-paint
probe (092).

(I) EVENTLATENCY FOR CMUX.

- InputLatencySlot: fixed-size POD. Stages: generated (oldest coalesced), lastGenerated, arrivedMain,
  dispatchStart, textInputStart/End, dispatchEnd, mainCommit, contentSubmitted, daemonReceived, ptyWritten,
  echoRead, echoSent, presented. Fields: kind (with scrollFirstUpdate), target, entrypoint, coalescedCount,
  presentationSource (estimatedVsync, metalPresented, hostFeedback, pageEstimated), causedFrameUpdate.
- Open slots live in a fixed table indexed by token; each stage is one relaxed atomic store, written once, from any
  thread. The closing thread moves a closed slot into the single-writer ring.
- Presented estimate = the vsync of the commit + one render-server frame, with a constant offset per macOS version
  calibrated by the glass check (DC3). While a slot is open, the window link stays running up to 3 frames after
  the input (input-driven, no idle cost) so the real targetTimestamp is used. VRR displays are labelled.
- Slots with no frame update are dropped except keys (Chrome caused_frame_update).
- InputLatencyLedger folds off main into histograms per kind x target x entrypoint x presentationSource (edges 1,
  2, 4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250 ms, over), Chrome's scroll jank formula and histogram names, and
  INP-style interactions (097). Cross-process stages for terminal keys use the existing SendParams.flow id (094).
- Outputs: signpost input.latency (typed fields), debug.input, trace.py track, Action Latency HUD rows, opt-in
  nightly input_latency[] / scroll_jank / interaction_latency.
- Ground truth: input-glass-check (ScreenCaptureKit) per macOS version.

No CI gates, budgets, perf-gate rows or CI tests are added (CLAUDE.md, Lawrence 2026-10-23). Every check is a
script that agents run on the fleet. The input-monitor guardrail is local-only (prepush-gate.py:52: guardrails run
"never under GitHub Actions") (checked).

## 4. Rules for implementers

1. Read CLAUDE.md, PATTERNS.md, REVIEW-STANDARD.md, threading-model.md and the owner row before you edit. Tell the
   owner named in your task.
2. No new code in CmuxNextApp except wiring lines in AppServices/AppControl/CmuxApplication. New types go to
   CmuxNextInputCore (core) or CmuxNextInput (ui), or the owning package.
3. CmuxApplication.swift and AppServices.swift edits go through one integrator agent, in task order 011 first.
4. Core and service packages never import CmuxNextInput; they use InputObserving/InputEventRecord from
   CmuxNextInputCore (layer_gate.py refuses upward edges).
5. Per-event and per-frame paths: no String, no lock, no allocation, no system call. Mark them `// perf-hot:`.
6. A main-thread job whose order is a correctness need keeps its hop with `// input-hop-allow: <why>`; a per-event
   pointer forward into a self-coalescing engine carries `// input-coalesce: native`; a global-state read outside
   dispatch carries `// global-input-allow: <why>`; a target-action handler that reads currentEvent carries
   `// current-event: target-action`. Reviewers check each site, not the pattern.
7. Prediction never writes to the daemon or the model. Decisions (drop target, snap, fling, selection) read real
   samples.
8. Each fix gets a regression test that fails without it; commit the red test first and record red and green with
   the same command (CLAUDE.md). Benches print numbers and assert no time.
9. Settings are SettingDescriptors (CmuxNextSettings/Schema/SettingsSchema+*.swift); new debug and input settings
   go to a new SettingsSchema+Input.swift; terminal.predictiveEcho goes to SettingsSchema+Terminal.swift (checked).
   Never hand-edit settings-schema.json.
10. Before dispatch, run a path check: every non-new path in a task exists at the base sha.
11. Ghostty fork changes go through the cmux-ghostty skill and p03-079's Ghostty integrator lane; the cmux pointer
    bump is a separate commit.
12. Order of work in the 72 h window: hour 0-6 land 001, 007, 011, 021 (record-only), 022, 077; by hour 12 publish
    MQ-input-turn-hops and MQ-input-hotspots from the base; then the key path (053-058, 076, 078-083, 086); then
    pointer and scroll queues; prediction (039-046) last.

## 5. Done checks

Abbreviations. UNIT(F) = `cmux-ci run --class isolated --ref SHA --script scripts/ci/package-test-lane.sh
--arg=suite --arg=Packages/macOS/CmuxNext --arg=F`. GUI(cmd) = `nx-remote --needs gui --app-from-fleet cmux --tag
p04-<task> --ref SHA --timeout 3600 -- <cmd>` on a perf-lead pool host with a 120 Hz virtual display
(split-spring --vdisplay=120). STRESS = scripts/cmux-next/perf-stress-session.py. Each GUI check runs light and
STRESS, on macOS 26 and 27 minis. VM timing is not perf evidence.

- DC1 key to presented frame, real HID keys: GUI(`python3 scripts/cmux-next/input-latency-bench.py --app "$NX_APP"
  --input real --surfaces terminal,home,omnibar,agent-pane,chromium-page,webkit-page,palette --sessions
  light,stress --keys 400`). Pass: every surface p50 <= 8.3 ms and p99 <= 16.7 ms on generated->presented
  (presented = calibrated estimate, DC3); terminal echo frame p99 <= 16.7 ms; ghostty.lock_wait p99 < 0.5 ms on the
  terminal row with a sibling pane running `yes | head -c 500000000`; 0 main stalls > 8 ms in key windows
  (debug.hangs). webkit-page counts only with presentationSource=pageEstimated (after 099); before that it is
  reported and not judged.
- DC2 input outranks automation: DC1 with `--storm cli=10hz,sidebar-churn=400`. Pass: terminal and Home key p99 <=
  16.7 ms; debug.input gate.max_input_wait_behind_jobs_ms <= 1.0; gate.nonswift_blocks_while_input_pending == 0
  (after 080-082); cef.pump_passes_while_input_pending (non-Chromium target) == 0; cef.pass_ms p99 reported (target
  <= 2 ms, which needs p03-116).
- DC3 glass check: GUI(`python3 scripts/cmux-next/input-glass-check.py --app "$NX_APP" --surfaces
  terminal,home,omnibar --samples 200`) on a capture mini. Pass: |glass - internal presented| p95 <= one refresh
  after the per-OS offset is set; glass p99 <= 25 ms.
- DC4 scroll jank: GUI(`python3 scripts/cmux-next/scroll-jank-bench.py --app "$NX_APP" --targets
  sidebar,strip,rows,tabstrip,terminal-scrollback,chromium-page,webkit-page,home --sessions light,stress --stall
  none,50ms/100ms`). Metrics use Chrome's names (DelayedFramesPercentage, MissedVsyncsSum/Max, FixedWindow 64 and
  PerScroll). Pass: with --stall none, DelayedFramesPercentage == 0 and dropped frames == 0 in every row. With
  --stall 50ms/100ms: sidebar, chromium-page and webkit-page 0 delayed frames; strip, rows and terminal-scrollback
  report numbers and the written decision of task 102.
- DC5 coalescing: debug.input coalescer.deliveries_per_frame max <= 2 (leading + trailing) per (window, consumer)
  during DC4 and a 1000 Hz synthetic drag (`input-latency-bench.py --drag divider,tab,pane-swap,canvas-pane,
  strip-scrollbar --rate 1000`). Divider and tab-drag frame p99 <= 8.33 ms main time; 0 window cursor-rect
  rebuilds per drag frame (after 090).
- DC6 single input tap: `rg -n 'NSEvent\.add(Local|Global)MonitorForEvents' Packages/macOS/CmuxNext/Sources -g
  '!**/CmuxNextInput/**'` returns 0 lines (33 today). `rg -n 'inputObserver'
  Packages/macOS/CmuxNext/Sources/CmuxNextApp` returns 0 lines.
- DC7 event identity: `rg -n 'NSApp(lication\.shared)?\.currentEvent' Packages/macOS/CmuxNext/Sources -g
  '!**/InputDispatchContext.swift' -g '!**/CmuxNextInput/**' | rg -v ':\s*//' | rg -v 'current-event: target-action'`
  returns 0 lines (28 today). `rg -n 'nextEvent\(matching' Packages/macOS/CmuxNext/Sources` returns 0 (3 today).
- DC8 key routing: `CMUX_BENCH=1` UNIT(KeyRouterBench) in Release prints JSON. The agent checks: plain printable
  key in a terminal p99 <= 20 us and 0 allocations on the calling thread; chord resolve (Cmd-T, Cmd-D, a when-clause
  binding, Ctrl-C in a terminal) p99 <= 150 us and 0 allocations; 0 String allocations in KeyFrame/InputLatency
  signposts; Ctrl-C in a 30-pane window visits 1 view in performKeyEquivalent and 0 TIS calls.
- DC9 terminal lanes: GUI(`python3 scripts/cmux-next/typing-frame-bench.py --surfaces terminal --phases idle,load
  --input real`) with CMUX_NEXT_TRACE_FLOWS. Pass: key.flow app.key.dispatch -> app.send <= 2 thread handoffs, p99
  <= 0.3 ms; echo socket read -> process_output <= 1 handoff, p99 <= 0.3 ms. `taskinfo --threads` on the daemon and
  on one terminal host shows USER_INTERACTIVE on every key and echo thread named in section 2 and UTILITY on the
  background threads of task 084.
- DC10 main-thread job gate: debug.input after DC2: held jobs with origin main > 0, held jobs with origin offMain >
  0, jobs_deferred_over_one_frame == 0, input commit happened before the first held job in 100% of turns. The
  input-turn hop list (Swift jobs and non-Swift callouts) has 0 unallowed sites in the key path of terminal, Home,
  omnibar and palette.
- DC11 prediction: UNIT(InputResamplerTests,PredictiveEchoTests,IntentPrewarmTests). GUI drag check:
  ghost-to-pointer distance at presentation p95 <= 2 pt at 120 Hz with resampling vs the measured before value.
  Predictive echo at 100 ms RTT: predicted glyph p99 <= 16.7 ms, 0 wrong glyphs left after the echo.
- DC12 field data: a Nightly-config build with the opt-in report on, after 10 min of the STRESS storm, writes
  input_latency[] {kind, target, entrypoint, presentation_source, count, buckets, max_ms}, scroll_jank, and
  interaction_latency {count, worst_ms, high_pct_ms, kind_of_worst}; buckets sum to count; PrivacyLeakScanner
  passes; KeyPressed/terminal p99 in the same bucket as DC1; VRR rows labelled.
- DC13 Chromium helper input (browserHost.helper on): GUI(`python3 scripts/cmux-next/chromium-host-bench.py
  --app "$NX_APP" --input real --ime --stall 50ms/100ms`). Pass: key-to-page-paint p95 <= in-process + 1 ms; wheel
  momentum (rubber-band); Japanese and Korean IME commits; 0 connection ends under a 1000 Hz pointer flood; no wire
  frame waits for a cmux display tick.
- DC14 queues closed: MQ-main-nonswift 0 unallowed hits; MQ-pointer-per-event script reports every hit with a
  coalescer call or `input-coalesce: native`; MQ-observation-hop 0 unallowed; MQ-global-input-state 0 hits inside
  NSEvent handlers; MQ-cursor-rects 0 unallowed.

## 6. Machine queues

- MQ-monitors: `rg -n 'NSEvent\.add(Local|Global)MonitorForEvents' Packages/macOS/CmuxNext/Sources -g
  '!**/CmuxNextInput/**'`. 33 hits (32 local, 1 global) (checked). Tasks 012-019.
- MQ-current-event: `rg -n 'NSApp(lication\.shared)?\.currentEvent' Packages/macOS/CmuxNext/Sources -g
  '!**/InputDispatchContext.swift' | rg -v ':\s*//'`. 28 code hits (checked). Tasks 067-068.
- MQ-tracking-loops: `rg -n 'nextEvent\(matching' Packages/macOS/CmuxNext/Sources`. 3 hits. Task 069.
- MQ-pointer-per-event: `rg -n 'override (public |open |package )?func (mouseMoved|mouseDragged|rightMouseDragged|
  otherMouseDragged)\(' Packages/macOS/CmuxNext/Sources`. 53 hits in 40 files (checked). Tasks 031-038, 088, 089.
  Closing check: every hit has a coalescer call or `// input-coalesce: native`.
- MQ-scroll-overrides: `rg -n 'func scrollWheel\(' Packages/macOS/CmuxNext/Sources` (11) plus `rg -n 'class
  \w+\s*:\s*NSScrollView'` (3). Tasks 034, 052, 087, 100; sidebar/palette/terminal scroller via p03-110;
  forwarders (DividerMouseCatchers.swift:170, OmniboxSuggestionPanel.swift:196) get `// input-coalesce: native`
  in 088/089.
- MQ-observation-hop: `rg -n -A4 'withObservationTracking' Packages/macOS/CmuxNext/Sources | rg 'Task \{'`. 45
  hits (checked). Tasks 026-029.
- MQ-main-nonswift: `rg -n 'DispatchQueue\.main\.(async|asyncAfter|sync)|CFRunLoopPerformBlock|performSelector\(
  onMainThread|RunLoop\.main\.perform|queue: *(\.main|OperationQueue\.main)|DispatchSource\.make.*queue: \.main'
  Packages/macOS/CmuxNext/Sources | rg -v ':\s*//'`. 153 hits in 79 files (checked). Helpers in 080; batches 081,
  082; every remaining package with hits becomes one generated task of the same shape.
  GhosttyRuntimeCallbacks.swift belongs to 079.
- MQ-global-input-state: `rg -n 'NSEvent\.(modifierFlags|mouseLocation|pressedMouseButtons)'
  Packages/macOS/CmuxNext/Sources`. 39 hits (checked). Task 095, then one task per package.
- MQ-cursor-rects: `rg -n 'func resetCursorRects' Packages/macOS/CmuxNext/Sources`. 17 hits (checked). Task 090.
  Allowed: a hit with `// cursor-rects-allow: <reason>` on the line above (`rg -n -B1 'func resetCursorRects'
  Packages/macOS/CmuxNext/Sources | rg -c 'cursor-rects-allow'` equals the hit count). After 090: 5 hits, all allowed.
- MQ-daemon-input-qos: `for n in mux-conn mux-control-dispatch terminal-host-client-input terminal-host-pty
  terminal-host-parser terminal-host-client holder-link mux-attach-out mux-render-attach-out
  mux-resource-terminal-attach mux-line-out mux-pty-input remote-input-writer relay-input; do rg -n "\"$n" cmux-tui/crates
  --type rust; done` (17 spawn sites, checked) plus the background list of 084. `rg -n
  'pthread_set_qos_class_self_np' cmux-tui/crates` = 0 today. Tasks 060, 084.
- MQ-input-turn-hops (runtime, after 021+022): `debug.input hops --since-launch` on a Debug build after
  input-latency-bench.py --input real (or typing-frame-bench.py before 070). Each unique call site (Swift job or
  non-Swift callout) is one task: remove the hop or justify it with `// input-hop-allow:`. Published by hour 12.
- MQ-input-hotspots (runtime, task 077): artifacts/input-hotspots.json, one row per dominant main-thread stack over
  4 ms in key windows (Home, omnibar, sidebar churn, terminal STRESS). Each row is one fix task.
- MQ-input-dirty-views (runtime, task 093): views dirtied outside the event target during an input turn.
- MQ-hittest (runtime, task 098): hitTest overrides with p99 > 20 us or > 32 views per event (75 overrides today).
- MQ-responsive-scroll (runtime, task 048): live scroll views not compatible with responsive scrolling; rows go to
  p03-110's owner.
- MQ-input-latency-rows (bench, tasks 070/072/075): each (surface, session, stage) row over its share (p99 total >
  16.7 ms; dispatch 2 ms, commit 4 ms, content 4 ms) is one investigation-and-fix task named by the dominant stage.

## 7. Risks

1. MainJobGate uses `swift_task_enqueueMainExecutor_hook` through dlsym; nothing in cmux uses it today, and Swift
   6.2 executor changes or a future OS can change it. Mitigations: record-only first (021), holding behind
   `debug.mainJobGate` (default on in DEV/NIGHTLY, off in Release until DC2 A/B), os-matrix 14/15 launch smoke,
   exact fallback (hook not installed). Strict FIFO across the hold boundary and release at nested run-loop entry
   keep SE-0431 order and menu tracking.
2. Prediction can show wrong pixels: resampling moves only visuals, predictive echo is default off with exact
   rollback, and nothing predicted writes to the daemon.
3. Intent prewarm costs memory and CPU on cancelled intents and can mask other regressions in switch benches.
   Bounds: FIFO 2, Low Power and memory-pressure skips, separate hit counters in benches. It lands only if the
   click-to-commit trace shows a gap.
4. Overlap with p03-rendering (DisplayClock, p03-026 strip pan, p03-109 tracking areas, p03-110 responsive scroll,
   p03-116 pump slices, p03-119 Ghostty ticks, p03-080 present off main) and with any QoS program (059, 060, 084).
   Run a cross-program dedupe by file path before dispatch; the first program to claim a file owns it, the other
   takes a dependency.
5. Ghostty fork work (078) is in the ghostty-next submodule, which is not checked out in this worktree
   (`git submodule status` shows `-723c4ab93e7 ghostty-next`) (checked). It needs PL-ghostty review and may land
   after 72 h; DC1's terminal STRESS row may not pass without it.
6. Chromium host items (063-066) depend on PL-cef-layer fork items; only cmux and shim sides can land in 72 h.
   DC13 is conditional on browserHost.helper. CDP histograms (091) may not include renderer histograms
   in this CEF build; the reader says so and a fork item follows.
7. Converting 45 observation hops and 153 non-Swift main hops delays some updates by up to one frame. A same-turn
   correctness need keeps its hop with an allow comment. Automation-class sites must not need a display link.
8. Measurement truth: the presented time is an estimate (vsync + one render-server frame) calibrated per OS by the
   glass check; the glass check needs a Screen Recording grant and a lit or 120 Hz virtual display.
9. Merge conflicts on CmuxApplication.swift, AppServices.swift, KeyRouter*.swift with many agents. One integrator
   agent serializes the first two; KeyRouter tasks (053-057, 086) run in order under PL-typing.
10. No CI tests, perf-gate rows or budgets are added; regressions after the push are caught by the perf cron and the
    nightly field histograms (010) only.
11. Old benches (typing-frame-bench.py, home-perf.py, strip-scroll-check.py, sidebar-scroll-floor.swift) and new ones
    can drift. 070 and 072 reuse their HID posters and parsers through one shared module; 075 records that old and
    new rows agree within noise on the base sha.
12. Notice to PL-typing from p05-ipc-032 (2026-10-26): the typing path's `send` line changes type. p05-ipc-032
    replaces the hand-written `SendInputRequest` (CmuxNextDaemon/Requests/TerminalIO/Input.swift) with the type
    CmuxNextWireGen's RequestEmitter generates. Its nullable members `surface`, `text`, `bytes` and `flow` become
    `FieldUpdate`, so `TerminalAttachment.swift` (the `sendNoReply` of `SendInputRequest`, key-press path) passes
    `.set(surface)`, `.set(data)` and `flow.map(FieldUpdate.set) ?? .unchanged`; a nil maps to `.unchanged`, which leaves the key
    out as today. The bytes stay the same and two tests pin them: `TerminalIORequestWireGoldenTests`
    (CmuxNextDaemonTests, over cmux-tui/spec/fixtures/terminal-io-requests/lines.json) and the daemon's echo test
    `server::cmd_terminal_io::wire_tests::every_echo_line_writes_its_input_bytes_to_the_pty` (cmux-tui-core).
    p05-ipc-032 waits on p05-ipc-025 (DaemonRequest in a leaf target) and on RequestEmitter output in the build.

## 8. Task table

### Summary

| ID | Title | Owner/coord | Size | Depends on | Queue |
| --- | --- | --- | --- | --- | --- |
| 001 | CmuxNextInputCore: kinds, stages, slot table, ring, buckets | p04 | M | - | - |
| 002 | InputLatencyLedger + reporter (Chrome jank formula) | p04 | M | 001 | - |
| 003 | PresentationClock on DisplayClock | p04 / p03 | M | p03-010, p03-012 | - |
| 004 | CmuxNextInput target, tracker, input.latency signpost | p04 | M | 001, 003 | - |
| 005 | Tracker wiring in sendEvent | p04 | M | 004, 011 | - |
| 006 | Terminal contentSubmitted stage | PL-ghostty | M | 004 | - |
| 007 | debug.input | p04 | S | 002 | - |
| 008 | trace.py EventLatency track | p04 | S | 004 | - |
| 009 | HUD input rows | p04 | S | 002 | - |
| 010 | Field data input_latency[] | PL-telemetry | S | 002 | - |
| 011 | InputEventTap | p04 | M | 001 | MQ-monitors |
| 012 | Tap: Wakeups, ChromiumWarmup, NewTabSparePool, AppControl | p04 | S | 011 | MQ-monitors |
| 013 | Tap: CmuxNextDesign | PL-motion-cef | M | 011 | MQ-monitors |
| 014 | Tap: CmuxNextTabs (incl. global) | p04 | S | 011 | MQ-monitors |
| 015 | Tap: drag sessions | p04 | S | 011 | MQ-monitors |
| 016 | Tap: focus, inspector, control | p04 | S | 011, 012 | MQ-monitors |
| 017 | Tap: AgentPane | p04 | M | 011 | MQ-monitors |
| 018 | Tap: Browser | PL-cef-layer | S | 011 | MQ-monitors |
| 019 | Tap: Layout, Sidebar, TerminalModifierMonitor | p04 | M | 011 | MQ-monitors |
| 020 | Guardrail input-monitor (local-only) | p04 | S | 019 | MQ-monitors |
| 021 | MainJobGate hook, record-only + pending atomic | p04 | M | 007 | MQ-input-turn-hops |
| 022 | Input-turn hop recorder (Swift + non-Swift) | p04 | M | 021 | MQ-input-turn-hops |
| 023 | SessionInputPending: scroll-begin, drag, refresh-based staleness, atomic snapshot | p04 | S | - | - |
| 024 | CEF pump input policy (target-aware) | PL-cef-layer | M | 023, p03-116 | - |
| 025 | FrameObservation with delivery kinds | p04 | S | - | MQ-observation-hop |
| 026 | Observation hops: CmuxNextApp | p04 | M | 025 | MQ-observation-hop |
| 027 | Observation hops: Sidebar, Layout, Terminal | p04 | M | 025 | MQ-observation-hop |
| 028 | Observation hops: MacScreen, Home | p04 | M | 025 | MQ-observation-hop |
| 029 | Observation hops: remaining | p04 | M | 025 | MQ-observation-hop |
| 030 | PointerFrameCoalescer (leading+trailing, fallback) | p04 | M | 011, p03-010 | MQ-pointer-per-event |
| 031 | Divider and resize handles | PL-motion-cef | M | 030 | MQ-pointer-per-event |
| 032 | Drag sessions once per frame | p04 | M | 030, 015 | MQ-pointer-per-event |
| 033 | Sidebar and tab-strip hover | p04 | M | 030 | MQ-pointer-per-event |
| 034 | Terminal pointer | PL-ghostty | M | 030 | MQ-pointer-per-event |
| 035 | Remote view and remote browser | p04 | S | 030 | MQ-pointer-per-event |
| 036 | Overlay host, hover cards, tooltips | PL-motion-cef | M | 030, 013 | MQ-pointer-per-event |
| 037 | Palette, popup, suggestion, bookmark, menu header | p04 | S | 030 | MQ-pointer-per-event |
| 038 | Chromium host wire: immediate send, back-pressure slot | PL-cef-layer | M | 011 | MQ-pointer-per-event |
| 039 | InputResampler (exact Chrome constants) | p04 | S | 001 | - |
| 040 | Resampled drag visuals | p04 | M | 039, 031, 032, 003 | - |
| 041 | Strip pan resampled at frame time | PL-motion-core | S | 039, p03-026 | - |
| 042 | Intent prewarm on pointer-down (release-commit targets) | p04 | L | 011, 077, 043 | - |
| 043 | Hover-dwell prewarm (200 ms, FIFO 2) | p04 | M | 033 | - |
| 044 | Directional prewarm for next/previous keys | p04 | S | 042 | - |
| 045 | Predictive echo engine | PL-ghostty | L | - | - |
| 046 | Predictive echo overlay + setting | PL-ghostty | M | 045 | - |
| 048 | Responsive-scroll audit | p04 | S | 007 | MQ-responsive-scroll |
| 050 | Rows and scroll areas pan by translation | PL-motion-core | M | p03-026 | - |
| 051 | TerminalScroller knob once per frame | PL-ghostty | S | p03-039 | MQ-scroll-overrides |
| 052 | Page scrolls leave LayoutRootView in O(1) | p04 | S | 019 | MQ-scroll-overrides |
| 053 | KeyContextCache | PL-typing | L | 056 | - |
| 054 | Plain-typing fast path (KeyRouterMode) | PL-typing | M | 053, 056 | - |
| 055 | Allocation-free resolve, compiled when-clauses | PL-typing | M | 056 | - |
| 056 | KeyRouterBench (prints, no time asserts) | PL-typing | S | - | - |
| 057 | sendEvent per-key trims | PL-typing | S | 011 | - |
| 058 | TerminalInputLane (key) | PL-ghostty | L | 059 | - |
| 059 | App socket QoS (attach UI, control UInit, control reader lowered) | p04 / QoS | S | - | MQ-daemon-input-qos |
| 060 | cmux-tui thread_qos (ThreadType) + key path threads | PL-daemon / QoS | M | - | MQ-daemon-input-qos |
| 062 | CEF pre-key O(1) decided check | PL-cef-layer | S | - | - |
| 063 | Chromium host wire: wheel phase, momentum, precise | PL-cef-layer | M | 038 | - |
| 064 | Chromium host IME | PL-cef-layer | L | 063 | - |
| 065 | Chromium host user-input priority, OS timestamps | PL-cef-layer | M | 063 | - |
| 066 | Chromium page presented stage | PL-cef-layer | M | 005, 065 | - |
| 067 | Event identity A | p04 | M | 011 | MQ-current-event |
| 068 | Event identity B | p04 | M | 011 | MQ-current-event |
| 069 | Remove nextEvent(matching:) loops | p04 | S | - | MQ-tracking-loops |
| 070 | input-latency-bench.py (shared HID module) | p04 | M | 005, 007 | MQ-input-latency-rows |
| 071 | input-glass-check | p04 | M | 005 | - |
| 072 | scroll-jank-bench.py (Chrome metric names) | p04 | M | 002, 005 | MQ-input-latency-rows |
| 073 | perf-hot markers | p04 | S | 011, 021, 030, 058 | - |
| 074 | Design doc, threading rows, PATTERNS P15, OWNERS row | p04 | S | - | - |
| 075 | Test phase | p04 | M | 070, 071, 072 | MQ-input-latency-rows |
| 076 | MainJobGate holding (origin classes, FIFO, after-commit drain) | p04 | L | 021, 023 | - |
| 077 | Day-1 input hotspots on the base | p04 | S | - | MQ-input-hotspots |
| 078 | Ghostty fork: key never waits on renderer_state.mutex | PL-ghostty | L | - | - |
| 079 | Ghostty actions mailbox once per frame | PL-ghostty | M | 025, p03-119 | MQ-main-nonswift |
| 080 | Classed main-work helpers | p04 | M | 076 | MQ-main-nonswift |
| 081 | MQ-main-nonswift A | p04 | M | 080 | MQ-main-nonswift |
| 082 | MQ-main-nonswift B | p04 | M | 080 | MQ-main-nonswift |
| 083 | Terminal echo lane in the app | PL-ghostty | L | 058, 006 | - |
| 084 | cmux-tui QoS: echo path, TUI/remote, background UTILITY | PL-daemon / QoS | M | 060 | MQ-daemon-input-qos |
| 085 | Daemon scheduler: input precedence | PL-daemon | M | - | - |
| 086 | Key equivalents skip the tree walk and menu search | PL-typing | M | 053 | - |
| 087 | Tab strip and saved bar scroll by translation | p04 | M | 030 | MQ-scroll-overrides |
| 088 | Layout pointer sites (canvas, strip scrollbar, hover focus) | PL-motion-core | M | 030 | MQ-pointer-per-event |
| 089 | Remaining pointer sites | p04 | S | 030 | MQ-pointer-per-event |
| 090 | resetCursorRects to cursorUpdate | p04 | M | p03-109 | MQ-cursor-rects |
| 091 | Chromium EventLatency/ScrollJank through CDP | PL-cef-layer | M | 002, 007 | - |
| 092 | cmux web pages: passive listeners, rAF moves, probe | p04 | M | - | - |
| 093 | Input-turn dirty-view recorder | p04 | M | 007, 011 | MQ-input-dirty-views |
| 094 | Cross-process terminal stages | p04 / PL-daemon | L | 005, 006 | - |
| 095 | Handlers read their event, not global state | p04 | M | 011 | MQ-global-input-state |
| 096 | No TIS/UCKeyTranslate per terminal key | PL-typing | S | - | - |
| 097 | Interaction latency (INP) | p04 / PL-telemetry | S | 002, 010 | - |
| 098 | Hit-test cost audit | p04 | S | 007 | MQ-hittest |
| 099 | WebKit page presented stage | p04 | M | 005 | - |
| 100 | Sidebar swipe and wheel paging through the tap | p04 / p03 | S | 011 | - |
| 101 | Text input server stage | p04 | S | 005 | - |
| 102 | Spike: strip and rows scroll with main stalled | PL-motion-core | L | p03-026, 072 | MQ-responsive-scroll |
| 103 | Web (main): schema 3 accepts the input latency fields | PL-telemetry | S | 010, p09-064 | - |
| 104 | Wire the input latency field report (default-off feature) | PL-telemetry | S | 010, 103, 003, p09-063 | - |

Task count: 101 (design 001-075 minus 047, 049, 061; plus 076-104).

### Review disposition (fixer)

- Accepted as new tasks: review 1's 076 (Ghostty lock) -> 078; 077 (Ghostty mailbox) -> 079; 078/079 (non-Swift main)
  merged with review 3's 077 (helpers) -> 080, 081, 082; 080 (echo lane) merged with review 3's 078 -> 083; 081 -> 084;
  082 -> 085; 083 -> 086; 084 -> 087; 085 -> 088; 086 -> 089; 089 -> 090; 090 -> 091; 091 -> 092; 092 -> 093;
  093 -> 094; 094 -> 095; 095 -> 096; 096 merged with review 3's 079 (INP) -> 097; 097 -> 098. Review 2's 076
  (record-only first) -> rewrites 021; 077 -> 077; 078 -> 099; 079 -> 100; 080 merged into 080-082; 081 -> 101.
  Review 3's 076 (class not priority) -> 076; 080 -> 102 (spike, because p03-026 already chose sublayerTransform).
- Merged into p03-rendering (dropped here with reason): design 047 (sidebar responsive scrolling) = p03-110, with
  p04's 100 as its input-side prerequisite; design 049 (strip pan container) = p03-026, which uses
  sublayerTransform and avoids AppKit's visibleRect/tracking/cursor-rect recompute; design 061 (Ghostty present off
  main) = p03-080/081; review 1's 087/088 (tracking areas rebuilt) = p03-109 (count 38 files, checked, not 40).
- Dropped with reason: review 1's problem "the tap must be a local monitor because sendEvent misses tracking-loop
  events": Apple's addLocalMonitorForEvents documentation says the handler is not called for events consumed by
  nested tracking loops, and only events dispatched through sendEvent: reach it, so the sendEvent tap sees the same
  set. Kept as a regression test in 015. Review 2's problem on risk 2: the risk was wrong (guardrails are
  local-only, prepush-gate.py:52, checked); the risk is removed.
- Problems fixed in place: 021/076 classify by origin, pending atomic, strict FIFO, nested-loop release, drain
  after commit (all three reviews); 022 also times non-Swift callouts; 024 target-aware and depends on p03-116; 060
  thread list corrected (terminal-host-pty is the PTY reader) and ThreadType enum; 012/018/067 layering through
  InputCore and Actions doc comments dropped from 067; DC7 regex filters comments (28 code hits) and allows
  target-action handlers; 014 global monitor through globalObserve; 020 local-only and counts the global as base
  debt; 030 leading+trailing and fallback timer; 038 immediate send; 039 exact constants; 002/072 Chrome jank
  formula; 001/004 slot fields and multi-thread stage stores; 003 presented = vsync + 1 render-server frame and
  link kept 3 frames; 042-044 targets, 200 ms, FIFO 2, no terminal attach; 025-029 delivery kinds; 056 no time
  asserts, 053-055 depend on it; 059 control reader lowered; new files out of CmuxNextApp; paths that did not exist
  fixed (TerminalSettings.swift, DebugSettings.swift, WorkspaceNavigationHandlers.swift, CmuxNextControl/InputBudget
  is new); DC1 adds agent-pane and the ghostty lock row, webkit-page judged only with a page-estimated presented;
  045/046 last with an overlay layer; owners named per task.

### Task details

Paths: `S/` = `Packages/macOS/CmuxNext/Sources/`, `T/` = `Packages/macOS/CmuxNext/Tests/`.

#### p04-input-001 CmuxNextInputCore: kinds, stages, slot table, ring, buckets
- Files: `Packages/macOS/CmuxNext/Package.swift`, `S/CmuxNextInputCore/InputEventKind.swift`, `InputStage.swift`,
  `InputLatencySlot.swift`, `InputLatencySlotTable.swift`, `InputLatencyRing.swift`, `InputLatencyBuckets.swift`,
  `T/CmuxNextInputCoreTests/InputLatencyRingTests.swift`, `plans/cmux-next/architecture-layers.json`.
- Change: new core target (depends on CmuxNextCompat for its `Atomic` counters, and on swift-atomics for the table's
  packed `UnsafeAtomic` storage, which Compat's `Atomic` cannot lay out). Kinds: keyPress, keyRelease, flags, mousePress,
  mouseRelease, pointerMove, drag, scrollBegin, scrollFirstUpdate, scrollUpdate, scrollMomentum, scrollEnd,
  magnify. Targets: terminal, textView, chromiumPage, webkitPage, agentPane, layout, sidebar, palette, other.
  Stages: generated, lastGenerated, arrivedMain, dispatchStart, textInputStart, textInputEnd, dispatchEnd,
  mainCommit, contentSubmitted, daemonReceived, ptyWritten, echoRead, echoSent, presented. Slot: POD with kind,
  target, entrypoint, coalescedCount, presentationSource (estimatedVsync, metalPresented, hostFeedback,
  pageEstimated), causedFrameUpdate, UInt64 ns per stage (0 = skipped). Open slots live in a fixed 128-entry table
  indexed by token; each stage is a relaxed atomic store written once, from any thread. The closing thread moves a
  closed slot into a 256-slot single-writer ring with half-ring hand-off (as ActionSampleRing). Bucket edges 1, 2,
  4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250 ms, over.
- Acceptance: target and test target declared; layers file lists both as core; no AppKit/SwiftUI import;
  `_isPOD(InputLatencySlot.self)` test; ring tests (half-ring, wrap, dropped count); a TSan test writes stages from
  3 threads and closes on a 4th with no race; full table drops and counts.
- Test phase: UNIT(InputLatencyRingTests) with TSan.
- Size M.

#### p04-input-002 InputLatencyLedger and reporter
- Files: `S/CmuxNextInputCore/InputLatencyLedger.swift`, `InputLatencyHistogram.swift`, `ScrollJankTracker.swift`,
  `S/CmuxNextControl/InputBudget/InputLatencyReporter.swift` (new directory, next to ActionBudget),
  `T/CmuxNextInputCoreTests/InputLatencyLedgerTests.swift`.
- Change: fold ring batches off main into histograms per (kind, target, entrypoint, presentationSource): total and
  each stage delta, p50/p95/p99/max. Drop slots with causedFrameUpdate == false except keys. ScrollJankTracker is a
  port of cc's ScrollJankDroppedFrameTracker: janky when the presentation gap > 1.5 vsync and input was available;
  missed vsyncs = round((gap + vsync/2)/vsync) - 1; DelayedFramesPercentage, MissedVsyncsSum, MissedVsyncsMax for
  FixedWindow (64 frames) and PerScroll; first frame excluded. The reporter follows ActionBudgetReporter (never
  blocks, full buffer counts as dropped, Codable snapshot).
- Acceptance: value batches only, no UI types; no lock held on main; tests: bucket sums equal count; zero stages
  skipped; Chrome's jank cases (gap 1.4 vsync not janky, 2.6 vsync = 2 missed); no-update non-key slots dropped;
  dropped batch counted.
- Test phase: UNIT(InputLatencyLedgerTests).
- Size M. Depends: 001.

#### p04-input-003 PresentationClock on DisplayClock
- Files: `S/CmuxNextWakeups/PresentationClock.swift`, `S/CmuxNextSignposts/CommitBoundary.swift`,
  `T/CmuxNextWakeupsTests/PresentationClockTests.swift`.
- Change: `presented(commitEnd:, window:) -> (ns, source)`: the vsync of the commit plus one render-server frame,
  plus a per-OS constant offset (default 0, set from DC3). Reads the window display's last DisplayClock tick
  (p03-010/012). `holdForInput(window:)` keeps the window's link subscribed for up to 3 frames after a tracked input
  so the real targetTimestamp is used; with no input it extrapolates the phase with no link. VRR displays (min !=
  max refresh) are labelled. CommitBoundary.after gains commitEndNanos (CLOCK_UPTIME_RAW). p03-004 uses this
  function for its presented estimate (tell p03).
- Acceptance: no new link creation (only DisplayClock subscribe); the link is released 3 frames after the last
  input (fake clock test); 60 and 120 Hz fake tests give commit vsync + 1 frame + offset; VRR label test.
- Test phase: UNIT(PresentationClockTests).
- Size M. Depends: p03-010, p03-012.

#### p04-input-004 CmuxNextInput target, InputLatencyTracker, input.latency signpost
- Files: `Packages/macOS/CmuxNext/Package.swift`, `S/CmuxNextInput/InputLatencyTracker.swift`,
  `S/CmuxNextSignposts/SignpostName.swift`, `Signposter.swift`, `KeyFrameSignpost.swift`,
  `T/CmuxNextInputTests/InputLatencyTrackerTests.swift`, `plans/cmux-next/architecture-layers.json`.
- Change: target CmuxNextInput (ui; depends on CmuxNextInputCore, CmuxNextWakeups, CmuxNextSignposts,
  CmuxNextFocusUI). Tracker: begin(event:target:entrypoint:) -> token, mark(token, stage) from any thread, close at
  presented through CommitBoundary + PresentationClock (one boundary per turn). SignpostName.inputLatency
  'input.latency' with typed numeric fields. KeyFrameSignpost.begin stops using String(format:).
- Acceptance: `rg 'String\(format' S/CmuxNextSignposts/KeyFrameSignpost.swift` = 0; per-event path has no
  allocation, lock or String (allocation-counting hook); fake boundary test reads stage order.
- Test phase: UNIT(InputLatencyTrackerTests); UNIT(ActionBudgetMonitorBench) no regression.
- Size M. Depends: 001, 003.

#### p04-input-005 Tracker wiring in sendEvent
- Files: `S/CmuxNextApp/CmuxApplication.swift` (wiring only), `S/CmuxNextInput/InputTargetClassifier.swift`,
  `S/CmuxNextApp/AppServices.swift`, `T/CmuxNextInputTests/InputLatencyWiringTests.swift`.
- Change: route() begins one slot for keyDown, mouse down/up, scroll began/changed/momentum (first changed after
  began = scrollFirstUpdate), and the first drag of each frame. Classifier: TerminalSurfaceView -> terminal; agent
  pane page -> agentPane; NSTextInputClient -> textView; CEF host -> chromiumPage; WKWebView -> webkitPage; layout
  scroll take -> layout. dispatchEnd after super.sendEvent; KeyFrameSignpost and ScrollFrameSignpost move into the
  tracker. causedFrameUpdate from the commit (any layer or contents change). SyntheticInput -> entrypoint
  automation, excluded from person histograms. The tracker's emit also publishes each closed slot to
  `AppServices.inputLatencyFeed` (`InputLatencySlotFeed`, the latency HUD's input rows, 009).
- Acceptance: exactly one tracker call per tracked event; a plain mouseMoved is not tracked; key, click and scroll
  each give one closed slot with the right kind and target; synthetic labelled automation; a key with no visible
  change still closes (key kinds kept); each closed slot reaches `inputLatencyFeed` once.
- Test phase: UNIT(InputLatencyWiringTests); GUI smoke input-latency-bench.py --surfaces terminal --keys 50.
- Size M. Depends: 004, 011.

#### p04-input-006 Terminal contentSubmitted stage, cheap in every build
- Files: `S/CmuxNextTerminal/TypingFrameProbe.swift`, `TerminalSurfaceView+Keyboard.swift`,
  `TerminalOutputLane.swift`, `T/CmuxNextTerminalTests/TerminalEchoStageTests.swift`.
- Change: per surface an atomic awaiting-echo token set at keyDown; the first parsed chunk after it marks echoParsed;
  the first IOSurfaceLayer contents set after that marks contentSubmitted (from any thread, so it keeps working
  after p03-080). Install the setContents hook on every terminal layer class (one relaxed load per frame when no key
  is pending). No echo within 500 ms closes as noEcho.
- Acceptance: no String/lock/allocation per frame; idle cost one relaxed load (read in the diff); ScriptedTerminalIO
  test: key -> echo -> contents gives contentSubmitted > dispatchEnd; no output closes noEcho. Owner PL-ghostty.
- Test phase: UNIT(TerminalEchoStageTests); GUI typing-frame-bench.py --surfaces terminal: |contents_ms - new
  stage| < 0.5 ms.
- Size M. Depends: 004.
- Decisions (review of cp/p04-input-006):
  - Each surface keeps a fixed ring of 8 waiting keys. Every key armed before a chunk reached the lane takes
    that chunk as its echo and the next frame as its contentSubmitted (Chromium gives each coalesced event its
    frame); a key past the ring is superseded. One deadline per surface, cancelled when the last key ends.
  - One contents gate per process (`GhosttyRuntime.shared.echoStages.contentsGate`); every
    `TerminalEchoStages` is built on it.
  - The setContents hook is on every terminal layer class only in DEBUG and bench builds (p09-observability-019).
    Release makes no echo stage until 049's Ghostty hook calls `TerminalEchoStage.contentsSet()` at the
    IOSurface handoff and lifts the guard in `TerminalEchoStages.makeStage()`.
  - No sink is installed here: 094 installs it. The GUI bench comparison runs after 094.

#### p04-input-007 debug.input
- Files: `S/CmuxNextInputDiagnostics/DebugInput.swift`, `S/CmuxNextApp/Control/AppControl.swift` (one
  registration line), `T/CmuxNextInputTests/DebugInputTests.swift`.
- Change: JSON sections latency, interactions, gate (held_by_origin{main,offMain}, exempt_by_rule,
  max_input_wait_behind_jobs_ms, jobs_deferred_over_one_frame, nonswift_blocks_while_input_pending), coalescer,
  tap, pump (passes_while_input_pending by target, deferred_for_input, pass_ms p99), scroll_views, chromium
  (091). Each section optional until its producer lands. Subcommands: reset, hops --since-launch, dirty, hittest.
- Acceptance: registered like debug.action_budget (DEV and bench builds); off main except one snapshot copy; test
  decodes every section key.
- Test phase: UNIT(DebugInputTests).
- Size S. Depends: 002.

#### p04-input-008 trace.py EventLatency track
- Files: `scripts/cmux-next/trace.py`, `scripts/cmux-next/trace_fixtures.py`.
- Change: parse input.latency; one slice per event from generated to presented with child slices per stage
  (including the cross-process stages when present) on track 'input latency'; link key.flow hops by flow id;
  summary p50/p95/p99/max per kind x target x presentation source.
- Acceptance: `trace.py --self-test` case 'input latency slices' passes on a fixture with skipped stages.
- Test phase: python3 scripts/cmux-next/trace.py --self-test.
- Size S. Depends: 004.

#### p04-input-009 Action Latency HUD input rows
- Files: `S/CmuxNextFocusUI/ActionLatency/ActionLatencyHUD.swift`, `S/CmuxNextInputCore/InputLatencySlotFeed.swift`
  (the closed-slot fan-out; 005's tracker publishes to it), `S/CmuxNextApp/AppServices.swift` (one line),
  `S/CmuxNextApp/Control/CaptureSceneRegistry.swift` (scene `latency-hud`).
- Change: newest 16 input events: kind, target, total ms, dominant stage; rows over 8.3 ms in the danger color;
  no reader while the HUD is closed.
- Acceptance: subscribe in show, unsubscribe in hide (diff); strings in the localization catalog.
- Test phase: cmux-ci capture <sha> --state scene:latency-hud.
- Size S. Depends: 002.

#### p04-input-010 Opt-in nightly field data
- Files: `S/CmuxNextHangReports/HangReport.swift`, `HangReportBuilder.swift`,
  `S/CmuxNextControl/InputBudget/InputLatencyReporter.swift`, `plans/cmux-next/hang-reports-DESIGN.md`,
  `T/CmuxNextHangReportsTests/InputLatencyReportTests.swift`.
- Change: input_latency_bucket_edges_ms, input_latency[] {kind, target, entrypoint, presentation_source, count,
  display {refresh_hz, vrr}, buckets, max_ms} (one row per display class), scroll_jank (Chrome names); schema 3
  only (server 103, wiring 104). Numbers only. Tell PL-telemetry.
- Acceptance: PrivacyLeakScanner passes; field names documented in hang-reports-DESIGN.md in the same diff; bucket
  sums equal count.
- Test phase: UNIT(InputLatencyReportTests,PrivacyLeakScannerTests).
- Size S. Depends: 002.

#### p04-input-011 InputEventTap
- Files: `S/CmuxNextInputCore/InputEventRecord.swift`, `S/CmuxNextInputCore/InputObserving.swift`,
  `S/CmuxNextInput/InputEventTap.swift`, `S/CmuxNextInput/InputSubscription.swift`,
  `S/CmuxNextApp/CmuxApplication.swift`, `S/CmuxNextApp/AppServices.swift`,
  `S/CmuxNextApp/InputVerification/InputVerificationService.swift`,
  `S/CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift`, `S/CmuxNextApp/BrowserHost/AppBrowserHost.swift`,
  `T/CmuxNextInputTests/InputEventTapTests.swift`.
- Change: subscribe(class:, phase: .observe | .intercept(order:) | .afterDispatch, window:, while:, handler) ->
  token (unsubscribes on deinit). Per-class arrays filtered by window id; no copy per event. Observe runs before the
  key router; intercepts run in declared order before super.sendEvent; afterDispatch replaces mouseDownObserver.
  InputObserving (core protocol) delivers InputEventRecord values to core and service packages. globalObserve wraps
  addGlobalMonitorForEvents inside CmuxNextInput. The tap keeps lastDispatched and lastPointer records and a
  'hints showing' / 'find pill open' flag set by owners. The inputObserver chain becomes 3 subscriptions. Built once
  in AppServices (P1).
- Acceptance: CmuxApplication has no inputObserver; `rg 'inputObserver' S/CmuxNextApp` = 0; tests: other classes
  and windows not called; intercept order honored; a consuming intercept stops later intercepts but not observers;
  no allocation per dispatch.
- Test phase: UNIT(InputEventTapTests,InputJournalTests,NoActivateGuardTests).
- Size M. Depends: 001.

#### p04-input-012 Tap migration: Wakeups, ChromiumWarmup, NewTabSparePool, AppControl
- Files: `S/CmuxNextWakeups/WindowServerInputEvents.swift`, `S/CmuxNextWakeups/SessionInputEvents.swift`,
  `S/CmuxNextChromiumWarmup/ChromiumWarmup.swift`, `S/CmuxNextApp/NewTab/NewTabSparePool.swift`,
  `S/CmuxNextApp/Control/AppControl.swift`.
- Change: Wakeups (core) and ChromiumWarmup (service) take an InputObserving injected by init (no import of
  CmuxNextInput). NewTabSparePool and AppControl take observe subscriptions limited to the classes the old mask had.
- Acceptance: MQ-monitors drops by the monitors in these files; layer_gate.py passes; SessionInputPending,
  ChromiumWarmup and spare pool tests unchanged and pass.
- Test phase: UNIT(SessionInputPendingTests,ChromiumWarmupTests,NewTabSparePoolTests).
- Size S. Depends: 011.

#### p04-input-013 Tap migration: CmuxNextDesign
- Files: `S/CmuxNextDesign/Tooltip/TooltipPresenter.swift`, `HoverCards/HoverCardCoordinator.swift`,
  `Overlay/WindowOverlayHost+Mouse.swift`, `Overlay/WindowOverlayHost+Modal.swift`, `Overlay/NativePopupHost.swift`.
- Change: 7 monitors become subscriptions; show-only monitors subscribe on show and unsubscribe on hide with a
  `while:` guard; nil-returning monitors become intercepts (modal escape before popup escape). Tell PL-motion-cef.
- Acceptance: 0 monitors in these files; order documented in InputSubscription's order table; existing tests pass.
- Test phase: UNIT(HoverCardCoordinatorTests,TooltipPresenterTests,NativePopupHostTests,WindowOverlayHostTests).
- Size M. Depends: 011.

#### p04-input-014 Tap migration: CmuxNextTabs
- Files: `S/CmuxNextTabs/TabStripView+MultiSelection.swift`, `TabDragEscapeMonitor.swift`,
  `TabClosingModeWatch.swift`, `Demo/DemoDragSession.swift`.
- Change: local monitors become window-scoped subscriptions active only in their mode; the global monitor at
  TabClosingModeWatch.swift:42 uses the tap's globalObserve.
- Acceptance: 0 add(Local|Global)MonitorForEvents in these files; subscriptions window-scoped; tab tests pass.
- Test phase: UNIT(TabStripMultiSelectionTests,TabClosingModeTests).
- Size S. Depends: 011.

#### p04-input-015 Tap migration: drag sessions
- Files: `S/CmuxNextApp/Drag/TabDragSession.swift`, `Drag/LinkDragSession.swift`, `Screens/ScreenDragSession.swift`,
  `PaneSwapDrag.swift`, `T/CmuxNextAppTests/DragTapTrackingLoopTests.swift`.
- Change: drag monitors become intercepts that live for the drag; moves go to the coalescer in 032.
- Acceptance: 0 monitors in these files; Escape and mouse-up end every drag; the tap's subscriber count returns to
  base on every end path; regression test: a mouseUp consumed by an NSButton tracking loop behaves as before the
  migration (proves the tap sees the same events as the old monitor).
- Test phase: UNIT(TabDragSessionTests,LinkDragSessionTests,PaneSwapDragTests,DragTapTrackingLoopTests).
- Size S. Depends: 011.

#### p04-input-016 Tap migration: focus, inspector, control
- Files: `S/CmuxNextApp/Focus/WindowScopedShortcutHintModifierMonitor.swift`, `S/CmuxNextApp/UIInspectorController.swift`,
  `S/CmuxNextApp/Control/AppControl.swift`.
- Change: one window-scoped flags+key subscription per window for shortcut hints (sets the tap's hints flag); the
  inspector subscribes while open; AppControl's second monitor merges into 012's subscription.
- Acceptance: 0 monitors in these files; hint tests pass; inspector closed = no subscription (test).
- Test phase: UNIT(ShortcutHintTests,UIInspectorControllerTests).
- Size S. Depends: 011, 012.

#### p04-input-017 Tap migration: AgentPane
- Files: `S/CmuxNextAgentPane/AgentPaneView.swift`, `AgentSubagentPanes.swift`, `AgentPaneDictation.swift`.
- Change: the per-pane app-wide monitor becomes one subscription per window that resolves the hit or focused pane
  and calls only its gesture grant; watchUser and dictation key-up are scoped subscriptions.
- Acceptance: 0 monitors; with 50 panes a key-down invokes at most 1 pane handler (counter); frame-grant tests pass.
- Test phase: UNIT(AgentPaneGestureGrantTests,AgentSubagentPanesTests,AgentPaneDictationTests).
- Size M. Depends: 011.

#### p04-input-018 Tap migration: Browser
- Files: `S/CmuxNextBrowser/CEF/CEFSwipeNavigation.swift`, `CEF/CEFLinkClickTracker.swift`,
  `UI/MouseSideButtons.swift`, `S/CmuxNextApp/AppDelegate.swift`.
- Change: subscriptions; the swipe-navigation scroll subscription is active only while a page view is under the
  pointer (O(1) predicate on the layout hover target). The tap reaches CmuxNextBrowser by init. Tell PL-cef-layer.
- Acceptance: 0 monitors; swipe-back and side-button tests pass; no global.
- Test phase: UNIT(CEFSwipeNavigationTests,CEFLinkClickTrackerTests,MouseSideButtonsTests).
- Size S. Depends: 011.

#### p04-input-019 Tap migration: Layout, Sidebar, TerminalModifierMonitor
- Files: `S/CmuxNextLayout/Views/LayoutRootView.swift`, `LayoutRootView+Scroll.swift`,
  `S/CmuxNextSidebar/Views/SidebarListView+PointerEnd.swift`, `SidebarListView.swift`,
  `S/CmuxNextTerminal/TerminalModifierMonitor.swift`, `TerminalLinkPointer.swift`.
- Change: LayoutRootView's scroll/magnify/button monitor becomes a window-scoped intercept (order: layout, after
  modal); the sidebar pointer-end monitor a window-scoped observe; the terminal modifier monitor one flags
  subscription per window that notifies only the terminal under the pointer.
- Acceptance: MQ-monitors = 0 after 012-018; LayoutScrollModifierTests (19), PaneHorizontalScrollClaimTests, link
  pointer tests pass.
- Test phase: UNIT(LayoutScrollModifierTests,PaneHorizontalScrollClaimTests,TerminalLinkPointerTests,SidebarListViewTests).
- Size M. Depends: 011.

#### p04-input-020 Guardrail input-monitor (local-only)
- Files: `scripts/cmux-next/guardrails.py`.
- Change: rule 'input-monitor' in guardrails.RULES (local-only, never --commits or GitHub Actions): in added lines
  under Packages/macOS/CmuxNext/Sources outside CmuxNextInput, refuse addLocalMonitorForEvents,
  addGlobalMonitorForEvents and new event-observer closure properties on CmuxApplication. Escape `//
  input-monitor-allow: <why>`. Base debt per file as action-wait.
- Acceptance: `guardrails.py --list` shows it; self-test: added monitor refused, escape passes; nothing added to
  the CI path (diff).
- Test phase: python3 scripts/cmux-next/guardrails.py --self-test.
- Size S. Depends: 019.

#### p04-input-021 MainJobGate hook, record-only, and the pending-input atomic
- Files: `S/CmuxNextWakeups/MainJobGate.swift`, `MainJobGateHook.swift`, `InputPendingState.swift`,
  `S/CmuxNextApp/CmuxApplication.swift` (wiring), `S/CmuxNextApp/AppDelegate.swift` (install/uninstall),
  `T/CmuxNextWakeupsTests/MainJobGateHookTests.swift`.
- Change: at launch (DEV and bench builds), dlsym `swift_task_enqueueMainExecutor_hook` and install a pass-through
  hook. InputPendingState is an atomic (pending kinds bitset + dispatching flag) refreshed once per run-loop turn
  (afterWaiting observer, from SessionInputPending) and by the tap at dispatch begin/end. The hook reads it with
  one relaxed load; when input is pending or dispatching it hands the job's identity, origin (main or off-main
  thread) and priority to the recorder (022) and forwards. Holding is task 076.
- Acceptance: pass-through path = one atomic load + original call (perf-hot marker); no system call, String, lock
  or allocation in the hook; order unchanged (test); installed once, uninstalled at terminate; Release compiles out
  the recorder call.
- Test phase: UNIT(MainJobGateHookTests); os-matrix.sh --os 14,15 launch smoke.
- Size M. Depends: 007.

#### p04-input-022 Input-turn hop recorder (Debug)
- Files: `S/CmuxNextWakeups/MainJobGate+Diagnostics.swift`, `S/CmuxNextInputDiagnostics/DebugInput.swift`,
  `scripts/cmux-next/input-turn-hops.py`.
- Change: records each main-actor job enqueued while input is pending or dispatching (8 return addresses, resolved
  off main with the existing image+offset resolver, first frame outside the Swift runtime and libdispatch), plus a
  main run-loop observer that times each non-Swift callout (GCD main block, run-loop source, timer) during an input
  turn. `debug.input hops` returns unique sites with counts, kinds and origin. input-turn-hops.py runs the existing
  typing-frame-bench.py --input real (070 when it lands) and writes artifacts/input-turn-hops.json with file:line
  from dSYM symbolication.
- Acceptance: `#if DEBUG || CMUX_BENCH_HOOKS`; resolution off main; bounded 128 sites, 64 pending; rows have site,
  count, kinds, origin, swift|nonswift.
- Test phase: UNIT(MainJobGateDiagnosticsTests); GUI run on the base publishes MQ-input-turn-hops by hour 12.
- Size M. Depends: 021.

#### p04-input-023 SessionInputPending: scroll-begin, drag, refresh-based staleness
- Files: `S/CmuxNextWakeups/SessionInputPending.swift`, `WindowServerInputEvents.swift`,
  `T/CmuxNextWakeupsTests/SessionInputPendingTests.swift`.
- Change: pending scroll-begin (phase began or a non-phase notch) and an active left drag count; steady ticks do
  not. staleAfter = two refresh intervals of the main screen. Publishes into InputPendingState (021) when it lands.
- Acceptance: tests: pending scroll-begin; mid-gesture tick not pending; drag pending at most once per frame (a
  batch yielded in one frame does not yield in the next); 16.7 ms staleness at 120 Hz.
- Test phase: UNIT(SessionInputPendingTests,MainFrameBudgetTests).
- Size S.

#### p04-input-024 CEF pump input policy (target-aware)
- Files: `S/CmuxNextBrowser/CEF/CEFPumpInputPolicy.swift`, `CEFMessagePump.swift` (one call site),
  `CEFPumpStats.swift`, `T/CmuxNextBrowserTests/CEFPumpInputYieldTests.swift`.
- Change: the policy takes InputPendingState and the tap's dispatch-ended signal by init. Pending input for a
  non-Chromium target: no pass; re-arm at the end of the input dispatch, frame deadline as fallback, never more than
  one refresh in a row. Input for chromiumPage: run one pass at once after its dispatch (Chromium's InputRouter and
  wheel acks run inside the pump). Counters: passes_while_input_pending by target, deferred_for_input, pass_ms
  p99. Slicing and the deadline stay p03-116; land after it and edit only the policy call site.
- Acceptance: no new timer; ManualClock tests for the one-refresh bound and the chromium-target immediate pass;
  nested-run-loop reentrancy tests unchanged; stats in debug.cef and debug.input.
- Test phase: UNIT(CEFPumpInputYieldTests,CEFPumpScheduleTests); GUI DC2 cef counters and DC4 chromium-page with
  --stall.
- Size M. Depends: 023, p03-116.

#### p04-input-025 FrameObservation with delivery kinds
- Files: `S/CmuxNextWakeups/FrameObservation.swift`, `T/CmuxNextWakeupsTests/FrameObservationTests.swift`.
- Change: FrameObservation(owner:, delivery: .visible(window) | .automation | .sameTurn(reason), track:, onChange:)
  re-arms withObservationTracking. .visible marks one FrameBatcher(.visible) client dirty; .automation uses
  MainWorkScheduler's automation class with no display link; .sameTurn keeps the hop. N changes per frame -> 1 apply.
- Acceptance: no Task per change (count); 1 apply per frame; apply in the frame after the change (ManualClock,
  FakeLink); .automation works with a nil link factory; yields to pending input like visible batches.
- Test phase: UNIT(FrameObservationTests).
- Size S.

#### p04-input-026 Observation hops: CmuxNextApp (15 sites)
- Files: `S/CmuxNextApp/UIInspectorController.swift`, `Themes/TerminalColorSync.swift`, `SpaceSectionsCache.swift`,
  `Settings/DebugSettingsPage.swift`, `Screenshots/ScreenshotsPageService.swift`, `Projects/ProjectsImport.swift`,
  `Pages/PageConnectionWatch.swift`, `Handlers/BrowserDownloadsPopup.swift`, `Control/ControlSnapshotPublisher.swift`,
  `ClipboardReads/TerminalClipboardReadService.swift`, `BrowserHost/AppBrowserHost.swift`, `AgentChatHeaderWatch.swift`.
- Change: each hop becomes FrameObservation with a delivery chosen per site and written in the diff. Model caches
  that a key may read in the same turn (SpaceSectionsCache, TerminalClipboardReadService) are .sameTurn with a
  reason; ControlSnapshotPublisher is .automation.
- Acceptance: MQ-observation-hop count in these files = 0 unallowed; each site's delivery named; tests pass.
- Test phase: UNIT(CmuxNextAppTests filters for the touched services).
- Size M. Depends: 025.

#### p04-input-027 Observation hops: Sidebar, Layout, Terminal (11 sites)
- Files: `S/CmuxNextSidebar/Views/UnreadBadgeView.swift`, `SidebarGroupLineViews.swift`,
  `Sections/SidebarItemRowView.swift`, `GroupHeaderRowView.swift`, `S/CmuxNextSidebar/Store/SidebarTunablesWatch.swift`,
  `S/CmuxNextLayout/Views/PaneOverlayView.swift`, `DropHighlightView.swift`, `S/CmuxNextTerminal/TerminalHostView.swift`,
  `TextBox/TextBoxView.swift`, `TerminalFindBarView.swift`.
- Change: same conversion; sidebar rows keep one observer per visible row, applies batched per frame.
- Acceptance: 0 unallowed hits in these files; SidebarScrollCostTests and row tests pass.
- Test phase: UNIT(SidebarScrollCostTests,SidebarRowTests,TerminalHostViewTests).
- Size M. Depends: 025.

#### p04-input-028 Observation hops: MacScreen and Home (10 sites)
- Files: `S/CmuxNextMacScreen/MacScreenToolbar.swift`, `MacScreenPane.swift`, `MacScreenHomeView.swift`,
  `MacScreenCardView.swift`, `MacScreenApprovalPanel.swift`, `S/CmuxNextHome/NativeTranscript/HomeNativeTranscriptView.swift`,
  `HomeNativeTranscriptView+FirstRun.swift`, `HomeNativeTranscriptView+TopFade.swift`,
  `S/CmuxNextHome/Sidebar/HomeSidebarSplitView.swift`.
- Change: same conversion; transcript streaming applies once per frame.
- Acceptance: 0 unallowed hits; Home streaming tests pass; home.typing rows do not regress (test phase).
- Test phase: UNIT(HomeNativeTranscriptTests,MacScreenTests); GUI home-perf.py home.typing before/after.
- Size M. Depends: 025.

#### p04-input-029 Observation hops: remaining packages (about 12 sites)
- Files: `S/CmuxNextServer/AddDevice/AddDeviceView.swift`, `S/CmuxNextPalette/PaletteContentView.swift`,
  `S/CmuxNextOnboarding/Views/OnboardingMetrics.swift`, `S/CmuxNextFeed/Views/ReportsBasketView.swift`,
  `S/CmuxNextControl/RegistryControlBridge.swift`, `S/CmuxNextBrowserHost/BrowserHostProvider+Tabs.swift`,
  `S/CmuxNextBrowserAutomation/TabWatcher.swift`, `DialogBroker.swift`, `S/CmuxNextBrowser/UI/ObservationLoop.swift`,
  `UI/AddressBarView+Display.swift`, `S/CmuxNextBookmarks/UI/BookmarkEditBubble.swift`.
- Change: same conversion; TabWatcher, DialogBroker, RegistryControlBridge use .automation (they must keep working
  for occluded windows); RegistryControlBridge's re-arm order (lines 103/117) is kept; ObservationLoop is rebuilt
  on FrameObservation so its callers convert together.
- Acceptance: MQ-observation-hop returns 0 unallowed hits across Sources; no .automation site needs a link (test).
- Test phase: UNIT(BrowserAutomationTests,PaletteTests,AddressBarTests).
- Size M. Depends: 025.

#### p04-input-030 PointerFrameCoalescer
- Files: `S/CmuxNextInputCore/PointerCoalescing.swift`, `S/CmuxNextInput/PointerFrameCoalescer.swift`,
  `T/CmuxNextInputCoreTests/PointerCoalescingTests.swift`, `T/CmuxNextInputTests/PointerFrameCoalescerTests.swift`.
- Change: core math (latest-wins moves, scroll sums per phase/momentum/precise with a new entry at a phase change,
  drag latest + 16 samples, oldest generated + count). UI: per window, registers one frame-class client on the
  window's DisplayClock subscription only while entries are pending. Leading edge: the first event in a frame
  interval is delivered at once; later events collapse to one trailing delivery at the tick. flushNow() from the
  tap's intercept phase for buttons and keys. Fallback DemandTimer only while pending and the link is not running
  (one refresh for drags, 5 s otherwise). Consumers can be lowLatency (never coalesced).
- Acceptance: no timer or link while idle; deliveries per frame per consumer <= 2; a single move after an idle
  frame is delivered in the same turn; a button flushes pending moves first; scroll sums keep phase boundaries;
  occluded fake link still delivers; coalescedCount and oldest generated reach the tracker.
- Test phase: UNIT(PointerCoalescingTests,PointerFrameCoalescerTests).
- Size M. Depends: 011, p03-010.

#### p04-input-031 Divider and resize-handle drags once per frame
- Files: `S/CmuxNextLayout/Views/DividerHandleView.swift`, `ScreenContentView+DividerDrag.swift`,
  `DividerMouseCatchers.swift`, `S/CmuxNextSidebar/Views/SidebarResizeHandle.swift`,
  `S/CmuxNextApp/RightSidebar/RightSidebarResizeHandle.swift`, `S/CmuxNextBrowser/CEF/CEFDevToolsDivider.swift`.
- Change: mouseDragged hands the point to the coalescer; every sample still feeds DividerDragState.sample;
  applyDrag and setSplitRatio run at most twice per frame (leading + trailing) with the latest point; mouseUp
  flushes then ends. DividerMouseCatchers.scrollWheel (line 170) gets `// input-coalesce: native`. Tell
  PL-motion-cef.
- Acceptance: 8 drag events in one frame -> setSplitRatio <= 2 (FakeLink); release velocity unchanged; divider
  tests pass.
- Test phase: UNIT(DividerDragTests,SidebarResizeHandleTests); GUI DC5 --drag divider.
- Size M. Depends: 030.

#### p04-input-032 Drag sessions once per frame
- Files: `S/CmuxNextApp/Drag/TabDragSession.swift`, `Drag/LinkDragSession.swift`, `Screens/ScreenDragSession.swift`,
  `PaneSwapDrag.swift`, `S/CmuxNextLayout/Views/LayoutRootView+DragAutoscroll.swift`.
- Change: moves go to the coalescer; ghost position, drop hit test and autoscroll target per delivery; mouse-up
  flushes and drops at the real release point.
- Acceptance: hit tests per frame <= 2 per drag; drop result equals the old one for the same sequence; drag-frame
  perf-hot marker kept.
- Test phase: UNIT(TabDragSessionTests,PaneSwapDragTests,DragAutoscrollTests); GUI DC5 --drag tab,pane-swap;
  drag-lag-live.py.
- Size M. Depends: 030, 015.

#### p04-input-033 Sidebar and tab-strip hover once per frame
- Files: `S/CmuxNextSidebar/Views/SidebarListView.swift`, `SidebarListView+Mouse.swift`, `SidebarRailView.swift`,
  `ProfileBarView.swift`, `Sections/SidebarItemRowView.swift`, `Sections/SidebarSectionHeaderView.swift`,
  `S/CmuxNextTabs/TabStripView+Pointer.swift`, `S/CmuxNextTabs/Groups/SavedBar/SavedGroupsBarView.swift`.
- Change: mouseMoved to the coalescer; hover resolved per delivery; enter/exit discrete; buttons flush first.
- Acceptance: updateHover <= 2 per frame; a click after fast moves hits the row under the click point; sidebar
  scroll cost tests pass.
- Test phase: UNIT(SidebarScrollCostTests,TabStripPointerTests,SidebarHoverTests).
- Size M. Depends: 030.

#### p04-input-034 Terminal pointer
- Files: `S/CmuxNextTerminal/TerminalSurfaceView+Mouse.swift`, `TerminalLinkPointer.swift`,
  `T/CmuxNextTerminalTests/TerminalPointerCoalescingTests.swift`.
- Change: moves and drags -> ghostty_surface_mouse_pos per delivery with the latest point; link hover per delivery;
  buttons flush first. Local scrollback scroll stays immediate; mouse-reporting scroll sums per frame and phase
  into one ghostty_surface_mouse_scroll. Tell PL-ghostty.
- Acceptance: counting fake surface: N moves -> <= 2 mouse_pos; button after moves = mouse_pos(latest) then
  mouse_button; mouse-reporting scroll <= 1 call per frame per phase; local scroll unchanged.
- Test phase: UNIT(TerminalPointerCoalescingTests,TerminalMouseTests).
- Size M. Depends: 030.

#### p04-input-035 Remote view and remote browser pointer coalescing
- Files: `S/CmuxNextRemoteView/Input/RemoteInputCaptureView.swift`,
  `S/CmuxNextRemoteBrowser/Pane/RemoteBrowserContentView.swift`, `S/CmuxNextPhone/Live/PhoneScreenView.swift`.
- Change: moves and drags sent per delivery (latest); scroll summed per phase; buttons and keys flush first.
- Acceptance: move messages per frame <= 2 (fake controller); button order kept.
- Test phase: UNIT(RemoteInputCaptureTests,RemoteBrowserInputTests).
- Size S. Depends: 030.

#### p04-input-036 Overlay host, hover cards, tooltips
- Files: `S/CmuxNextDesign/Overlay/WindowOverlayHost+Mouse.swift`, `Overlay/WindowOverlayHost+AgentCursor.swift`,
  `HoverCards/HoverCardCoordinator.swift`, `Tooltip/TooltipPresenter.swift`, `HoverReveal.swift`,
  `ThinScrollerProximity.swift`.
- Change: routeMouse, hover-card and tooltip move checks, hover reveal and scroller proximity per delivery.
- Acceptance: <= 2 calls per frame each; hover and tooltip timing tests pass.
- Test phase: UNIT(WindowOverlayHostTests,HoverCardCoordinatorTests,TooltipPresenterTests).
- Size M. Depends: 030, 013.

#### p04-input-037 Palette, popup, suggestion, bookmark, menu-header hover
- Files: `S/CmuxNextPalette/PaletteListView.swift`, `PaletteActionsMenuView.swift`,
  `S/CmuxNextDesign/Overlay/PopupRowView.swift`, `S/CmuxNextBrowser/UI/SuggestionRowView.swift`,
  `UI/ArrowCursorView.swift`, `S/CmuxNextBookmarks/UI/BookmarkBarItemView.swift`,
  `S/CmuxNextDesign/MenuIdentityHeaderView.swift`.
- Change: hover selection per delivery; keyboard selection immediate; a click flushes first.
  OmniboxSuggestionPanel.scrollWheel (line 196) gets `// input-coalesce: native`.
- Acceptance: <= 2 hover updates per frame; palette open and keyboard tests pass.
- Test phase: UNIT(PaletteListViewTests,PopupRowViewTests,SuggestionRowTests).
- Size S. Depends: 030.

#### p04-input-038 Chromium host wire: immediate send, back-pressure slot
- Files: `S/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostPageView.swift`, `ChromiumHostConnection.swift`,
  `T/CmuxNextBrowserTests/ChromiumHostInputCoalescingTests.swift`.
- Change: moves, drags and wheels are sent at once (no cmux frame alignment; the renderer aligns, as in Chrome).
  On EAGAIN a coalescible frame goes to one pending slot (latest wins, wheel deltas summed per phase) and a writable
  DispatchSource flushes it. While a first-of-sequence wheel waits for the host ACK, later wheels collapse into the
  slot. Discrete frames go to a bounded 4096-frame queue drained by the same source; only a full discrete queue or
  a mid-frame short write ends the connection.
- Acceptance: 1000 Hz move flood with a stopped reader does not close the connection (socketpair test); the pending
  slot holds <= 1 move; discrete order kept; no frame waits for a display tick (diff).
- Test phase: UNIT(ChromiumHostInputCoalescingTests,ChromiumHostSessionTests); GUI DC13.
- Size M. Depends: 011.

#### p04-input-039 InputResampler (exact Chrome constants)
- Files: `S/CmuxNextInputCore/InputResampler.swift`, `T/CmuxNextInputCoreTests/InputResamplerTests.swift`.
- Change: port of linear_resampling.cc: sample_time = frame_time - 5 ms; prediction capped at min(8 ms, dt/2);
  needs dt >= 2 ms; reset after the max time delta and at gesture begin. cmux addition (written, own test): no
  extrapolation across a direction change. A frameAheadMs parameter (default 0) for the debug setting only.
- Acceptance: tests port Chromium's linear_resampling_unittest cases; the direction-change test is marked as a cmux
  addition; no AppKit import.
- Test phase: UNIT(InputResamplerTests).
- Size S. Depends: 001.

#### p04-input-040 Resampled drag visuals
- Files: `S/CmuxNextInput/PointerFrameCoalescer.swift`, `S/CmuxNextLayout/Views/ScreenContentView+DividerDrag.swift`,
  `S/CmuxNextApp/Drag/TabDragSession.swift`, `S/CmuxNextApp/PaneSwapDrag.swift`,
  `S/CmuxNextSettings/Schema/SettingsSchema+Input.swift` (new; input.resampleDrags, input.resampleFrameAheadMs).
- Change: drag consumers get a resampled point at the frame time and the latest real point. Divider and ghost layer
  positions use the resampled point; drop zone, snap and release velocity use real points. Off under Reduce Motion
  and with input.resampleDrags=false.
- Acceptance: decisions read realPoint only (diff); drop result equal with resampler on and off (test).
- Test phase: UNIT(PointerFrameCoalescerTests,DividerDragTests); GUI DC11 ghost distance.
- Size M. Depends: 039, 031, 032, 003.

#### p04-input-041 Strip pan resampled at the frame time
- Files: `S/CmuxNextLayout/Scroll/ColumnScrollState.swift`, `Scroll/ColumnScrollReducer.swift`,
  `S/CmuxNextLayout/Views/ScreenContentView+Scrolling.swift`.
- Change: gestureChanged records (delta, time); the per-frame pan value given to p03-026's motion container is the
  cumulative offset resampled with InputResampler; the fling projection uses real samples. Tell PL-motion-core.
- Acceptance: reducer tests: presented offset between real samples or within the cap; fling target unchanged.
- Test phase: UNIT(ColumnScrollReducerTests,LayoutScrollModifierTests); GUI DC4 strip row.
- Size S. Depends: 039, p03-026.

#### p04-input-042 Intent prewarm on pointer-down (release-commit targets)
- Files: `S/CmuxNextInputCore/IntentPrewarm.swift`, `S/CmuxNextInput/IntentPrewarmService.swift`,
  `S/CmuxNextTabs/TabStripView+Pointer.swift`, `S/CmuxNextPalette/PaletteListView.swift`,
  `T/CmuxNextInputCoreTests/IntentPrewarmTests.swift`.
- Change: only if MQ-input-hotspots/activation-perf.py shows a click-to-commit gap >= 30 ms for the target. State
  machine: FIFO of 2, oldest cancelled; kinds: hibernated page cover decode and hidden renderer start, target
  geometry precompute. No daemon write and no terminal attach. Targets: tab cells, palette rows, multi-view sidebar
  rows (the normal sidebar switches on press, checked). A prewarm is kept after a release elsewhere until evicted or
  the hibernation grace ends. 043 landed first and owns the surface: 042 extends `IntentPrewarmService` and the
  InputCore `IntentPrewarmQueue` (FIFO 2) with the press call sites (`prewarm(_:trigger: .pointerDown)`) and its
  kinds; it adds no second FIFO.
- Acceptance: no visible state change, no daemon write (store unchanged, no focus change); FIFO 2 (test); counters
  in debug.input; the commit message cites the measured gap.
- Test phase: UNIT(IntentPrewarmTests,IntentPrewarmServiceTests); GUI activation-perf.py input_to_commit p95
  before/after, prewarm hits reported apart.
- Size L. Depends: 011, 077, 043.

#### p04-input-043 Hover-dwell prewarm
- Files: `S/CmuxNextInputCore/IntentPrewarm.swift`, `S/CmuxNextInput/IntentPrewarmService.swift`,
  `S/CmuxNextSidebar/Views/SidebarListView.swift`, `S/CmuxNextApp/Hibernation/BrowserHibernation.swift`. The strip
  already reports its hovered tab (`TabStripView.onHoverTab`, `BrowserHibernation.noteHover`), so
  `TabStripView+Pointer.swift` needs no change.
- Change: 200 ms dwell (Chrome moderate) on a row or tab whose page is frozen or hibernated wakes it in the
  background. Skipped in Low Power Mode on battery and at memory pressure warn or worse (MemoryPressureEvents).
  Owns the prewarm surface (service, InputCore FIFO, the hibernation as warmer); 042 extends it.
- Acceptance: no prewarm under memory pressure or Low Power on battery (tests); one DemandTimer only while the
  pointer rests, cancelled on move; FIFO 2.
- Test phase: UNIT(IntentPrewarmTests,IntentPrewarmServiceTests); GUI bench_hibernation.py wake after hover vs click.
- Size M. Depends: 033.

#### p04-input-044 Directional prewarm for next/previous keys
- Files: `S/CmuxNextInput/IntentPrewarmService.swift`, `S/CmuxNextApp/Handlers/TabHandlers.swift` and the
  next/previous workspace handler (resolve with `rg -n 'bindEffect' S/CmuxNextApp/Handlers` for the workspace
  step ids before dispatch).
- Change: after a next/previous action from a key, prewarm the following item at idle class; the other direction
  cancels.
- Acceptance: scheduled as MainWorkClass.background, never on the key's turn (diff); three presses prewarm items 2,
  3, 4 in order with FIFO 2.
- Test phase: UNIT(IntentPrewarmServiceTests); GUI activation-perf.py Ctrl-Cmd-] p95 before/after.
- Size S. Depends: 042.

#### p04-input-045 Terminal predictive echo engine (last in queue)
- Files: `S/CmuxNextTerminal/PredictiveEcho/PredictiveEcho.swift`, `PredictionEpoch.swift`,
  `T/CmuxNextTerminalTests/PredictiveEchoTests.swift`.
- Change: mosh terminaloverlay rules: printable ASCII and backspace at the cursor, only when remote or RTT >= 30 ms,
  primary screen, secure input off, not at the right margin; epochs confirmed by matching echo; mismatch, escape or
  cursor jump drops all (exact rollback).
- Acceptance: pure; tests for confirm, rollback, alternate screen, secure input, backspace, RTT threshold.
- Test phase: UNIT(PredictiveEchoTests).
- Size L.

#### p04-input-046 Predictive echo overlay and setting
- Files: `S/CmuxNextTerminal/PredictiveEcho/PredictiveEchoOverlay.swift`, `TerminalSurfaceView+Keyboard.swift`,
  `TerminalSurfaceView+TextInput.swift`, `S/CmuxNextSettings/Schema/SettingsSchema+Terminal.swift`, the terminal
  strings catalog.
- Change: a cmux overlay layer (not preedit, which cannot show backspace over cells), dim and underlined, never
  while marked text exists. Setting terminal.predictiveEcho: off (default), remote, always; strings in every locale.
- Acceptance: setting off = no engine object (test); IME marked text = no prediction (test); schema regenerated by
  tooling; localization audit in the commit.
- Test phase: UNIT(PredictiveEchoDisplayTests); GUI DC11 remote 100 ms RTT fixture.
- Size M. Depends: 045.

#### p04-input-048 Responsive-scroll audit
- Files: `S/CmuxNextInputDiagnostics/ScrollViewAudit.swift`, `S/CmuxNextInputDiagnostics/DebugInput.swift`.
- Change: `debug.input scroll_views` walks live windows on request and lists each NSScrollView: class, document
  view class, isCompatibleWithResponsiveScrolling for both, SwiftUI hosting, window, and whether a scrollWheel
  override exists. Rows go to p03-110's owner.
- Acceptance: on request only; Debug/bench only; stable JSON schema (test).
- Test phase: UNIT(ScrollViewAuditTests); GUI run on STRESS publishes MQ-responsive-scroll.
- Size S. Depends: 007.

#### p04-input-050 Rows and scroll areas pan by translation
- Files: `S/CmuxNextLayout/Scroll/RowScroll.swift`, `Scroll/ScrollAreaScroll.swift`,
  `S/CmuxNextLayout/Views/ScreenContentView+Rows.swift`, `ScreenContentView+ScrollAreas.swift`.
- Change: same technique as p03-026 (motion container sublayerTransform; hitTest and convert apply the live
  offset; NSView geometry commits at gesture end) for rows and nested scroll areas. Tell PL-motion-core.
- Acceptance: 20-frame row pan: 0 pane setFrame, 0 addTrackingArea; a click during the pan hits the pane under the
  pointer; scroll-area tests pass.
- Test phase: UNIT(RowScrollTests,ScrollAreaTests); GUI DC4 rows.
- Size M. Depends: p03-026.

#### p04-input-051 TerminalScroller knob once per frame
- Files: `S/CmuxNextTerminal/TerminalScroller.swift`, `S/CmuxNextTerminal/TerminalHostView.swift`.
- Change: Ghostty scrollbar actions and clip-view changes update the knob through one FrameClient that applies the
  latest TerminalScrollbar per frame; knob drag still scrolls in order. Land after p03-039 (same file).
- Acceptance: N updates in one frame -> 1 knob apply; knob drag tests pass.
- Test phase: UNIT(TerminalScrollerTests).
- Size S. Depends: p03-039.

#### p04-input-052 Page scrolls leave LayoutRootView routing in O(1)
- Files: `S/CmuxNextLayout/Views/LayoutRootView+Scroll.swift`, `LayoutRootView+ScrollClaim.swift`.
- Change: first check: no Command modifier (layout.scrollModifier=command), no gesture lock, no layout-owned scroll
  in progress -> return the event before any conversion, hit test or claim query.
- Acceptance: a plain page scroll does 0 pane hit tests and 0 conversions (counters); LayoutScrollModifierTests pass.
- Test phase: UNIT(LayoutScrollModifierTests,PaneHorizontalScrollClaimTests).
- Size S. Depends: 019.

#### p04-input-053 KeyContextCache
- Files: `S/CmuxNextFocusUI/KeyContextCache.swift`, `S/CmuxNextApp/Focus/KeyRouter+Context.swift`,
  `S/CmuxNextApp/Focus/KeyRouter.swift`, `T/CmuxNextAppTests/KeyContextCacheTests.swift`.
- Change: per-window Facts and KeyContext behind a generation counter, bumped on FocusMachine transitions,
  PageInputReadiness, suggestion open/close, copy mode, sidebar selection count crossing 1, file explorer keyboard,
  workspacesAsTabs, topPage and editor key-sequence state. hasMarkedText stays live. Owner PL-typing.
- Acceptance: 100 chords with no change -> 1 Facts build; one test per invalidation source; KeyRouter tests pass.
- Test phase: UNIT(KeyContextCacheTests,KeyRouterTests,KeyboardParityTests).
- Size L. Depends: 056.

#### p04-input-054 Plain-typing fast path
- Files: `S/CmuxNextFocusUI/KeyRouterMode.swift`, `S/CmuxNextApp/Focus/KeyRouter.swift`,
  `KeyRouter+TypeAhead.swift`, `KeyRouter+NewTabInput.swift`.
- Change: KeyRouterMode enum (normal, newTabCapture, creationCapture, missedModal, undoToast, recorder, popup,
  linkHints, windowHints, focusModeEscape, nativePalette), set by each owner on enter/exit; interceptKeyDown
  switches on it first; in normal mode a non-chord key does <= 3 cached checks then onTyping (only when the
  notification state needs it).
- Acceptance: KeyRouterBench plain key 0 allocations (JSON); enter/exit test per mode; the 14 ordered-check cases
  pass.
- Test phase: UNIT(KeyRouterTests,NewTabInputTests,TypeAheadTests); CMUX_BENCH=1 UNIT(KeyRouterBench).
- Size M. Depends: 053, 056.

#### p04-input-055 Allocation-free resolve; compiled when-clauses
- Files: `S/CmuxNextActions/KeyBindingTable.swift`, `WhenClause.swift`, `CompiledWhen.swift`,
  `S/CmuxNextApp/Focus/KeyRouter+Resolution.swift`, `T/CmuxNextActionsTests/CompiledWhenTests.swift`.
- Change: resolveWinner(keys:context:isRunnable:accepts:) with no candidates array; resolve() stays for diagnostics;
  bit-key clauses compile to (required, forbidden) masks; ActionRegistry.shortcuts(for:) returns an inline
  sequence (max 2).
- Acceptance: hot path calls resolveWinner (diff); compiled and interpreted agree on the default catalog and 1000
  fuzzed clauses; resolveWinner == resolve().winner across the test matrix.
- Test phase: UNIT(CompiledWhenTests,KeyBindingTableTests); CMUX_BENCH=1 UNIT(KeyRouterBench).
- Size M. Depends: 056.

#### p04-input-056 KeyRouterBench (prints numbers; no time asserts)
- Files: `T/CmuxNextAppTests/KeyRouterBench.swift`, `scripts/cmux-next/perf-hot-benches.json`.
- Change: drives interceptKeyDown with synthetic events (plain key in a terminal, Cmd-T, Cmd-D, a when-clause
  binding, Ctrl-C in a terminal) with a 60-workspace registry; timing loop only with CMUX_BENCH=1; prints JSON
  {plain_p99_us, chord_p99_us, plain_allocs, chord_allocs, tis_calls, key_equiv_views}. The only assert CI may run:
  allocation count on the calling thread via a per-thread malloc logger. Commit before 053-055 with base numbers.
- Acceptance: no time assert in the file (diff); JSON fields present; perf-hot key-dispatch bench points to it.
- Test phase: CMUX_BENCH=1 UNIT(KeyRouterBench) in Release: base numbers, then after 053-055.
- Size S.

#### p04-input-057 sendEvent per-key trims
- Files: `S/CmuxNextApp/CmuxApplication.swift`, `S/CmuxNextApp/Windows/WindowController.swift`,
  `S/CmuxNextApp/AppServices.swift`, `S/CmuxNextDesign/FindPill/FindPillView.swift`.
- Change: hideShortcutHintsForKeyDown only while the tap's hints flag is set; crossWindowKeyGuard O(1) when the key
  window did not change; FindPillView.forwardArrowKeyDown only for arrow codes while a pill is open;
  accessibilityWindow(for:) not computed when no hints show.
- Acceptance: each call behind an O(1) flag (diff); plain key with no hints and no pill calls none (counters);
  hint, find pill and cross-window tests pass.
- Test phase: UNIT(CrossWindowInputGuardTests,ShortcutHintTests,FindPillTests).
- Size S. Depends: 011.

#### p04-input-058 TerminalInputLane (key bytes straight to the attach socket)
- Files: `S/CmuxNextTerminal/TerminalSurfaceBridge.swift`, `TerminalSession.swift`, `TerminalIO.swift`,
  `TerminalInputLane.swift`, `S/CmuxNextApp/DaemonTerminalIO.swift`, `S/CmuxNextBridge/TerminalAttachDriver.swift`,
  `T/CmuxNextTerminalTests/TerminalInputLaneTests.swift`.
- Change: per-session SPSC ring of tagged records (bytes, resize, focus, takeOver, reconnect, resync), 64 KiB +
  256 records preallocated, ordered bounded overflow. Producer: io_write_cb (main) or a resize. DaemonTerminalIO
  hands the ring to TerminalAttachDriver, whose attach SocketWriter (userInteractive, 059) drains it when woken;
  LocalPTYTerminalIO drains to its write queue. Remove the Task.detached writer loop. creatingInput keeps its
  buffer until attach. Owner PL-ghostty.
- Acceptance: `rg 'Task.detached' S/CmuxNextTerminal/TerminalSession.swift` shows no writer task; 10k interleaved
  records in order; main producer never blocks (try-push; overflow path lock-free or a bounded Mutex measured <
  2 ms); ioWrite -> socketSubmit = 1 thread hop.
- Test phase: UNIT(TerminalInputLaneTests,TerminalSessionTests,InstantCreateIntentTests); GUI DC9.
- Size L. Depends: 059.

#### p04-input-059 App socket QoS
- Files: `S/CmuxNextDaemon/Connection/SocketWriter.swift`, `S/CmuxNextDaemon/Connection/LineTransport.swift`,
  `S/CmuxNextBridge/TerminalAttachDriver.swift`, `plans/cmux-next/threading-model.md`.
- Change: SocketWriter(fd:label:qos:). Attach links .userInteractive; control transport writer .userInitiated; the
  control reader thread (LineTransport.swift:166, today .userInteractive, checked) lowered to .userInitiated, so
  automation and sidebar churn events do not share typing's class; attach readers stay .userInteractive.
- Acceptance: task-priority guardrail passes; threading-model.md rows updated in the same diff; a test reads queue
  and thread QoS for both link kinds.
- Test phase: UNIT(SocketWriterTests,LineTransportTests).
- Size S.

#### p04-input-060 cmux-tui thread_qos (ThreadType) and key-path threads
- Files: `cmux-tui/crates/cmux-tui-core/src/thread_qos.rs`, `cmux-tui/crates/cmux-tui-core/src/lib.rs`,
  `src/server/listen.rs`, `src/server/connection_scheduler.rs`,
  `src/terminal_host_runtime/shared/host_serve.rs`, `src/terminal_host_runtime/shared/host_start.rs`,
  `cmux-tui/crates/cmux-holder/src/link.rs`, `cmux-tui/crates/cmux-holder-v3/src/link.rs`.
- Change: thread_qos with an enum ThreadType {InputCritical, Interactive, Utility, Background} mapped to QoS in one
  function (pthread_set_qos_class_self_np on macOS, no-op elsewhere), as Chrome's platform_thread_apple.mm.
  InputCritical (USER_INTERACTIVE) as the first statement of: mux-conn (attach connections), mux-control-dispatch,
  terminal-host-client-input (PTY write), terminal-host-pty (PTY read, echo source), terminal-host-parser,
  holder-link. Follow D1-D8 (no I/O added). Owner PL-daemon; dedupe with any QoS program.
- Acceptance: each listed thread body starts with `thread_qos::set(` (listed in the commit); macOS unit test reads
  the class back with pthread_get_qos_class_np; no other behavior change.
- Test phase: scripts/ci/cmux-tui-focused-test.sh cmux-tui-core thread_qos (fleet isolated); GUI DC9 taskinfo.
- Size M.

#### p04-input-062 CEF pre-key O(1) decided check
- Files: `S/CmuxNextBrowser/CEF/CEFRuntime+Events.swift`, `S/CmuxNextApp/Focus/KeyRouter+Hooks.swift`.
- Change: cefKeyCallback first asks KeyRouter.decided.contains(event) (O(1) identity set); decided keys return at
  once; only synthetic keys run the dispatcher.
- Acceptance: a decided key -> 0 binding resolves in the pre-key hook; synthetic keys run once; chrome-tab-keys
  tests pass.
- Test phase: UNIT(KeyRouterHooksTests,CEFKeyRoutingTests); GUI chrome-tab-keys-e2e.py.
- Size S.

#### p04-input-063 Chromium host wire: wheel phase, momentum, precise deltas
- Files: `S/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostFrame.swift`, `ChromiumHostPageView.swift`,
  `Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h`, `CEFShim/src/browser_host_main.mm`,
  `CEFShim/tests/chromium_host_wire_test.cpp`, `T/CmuxNextBrowserTests/ChromiumHostFrameTests.swift`.
- Change: v[4] phase bits, v[5] momentum bits, flags bit 63 precise; scrollingDeltaX/Y fixed point x100; the host
  maps to CefMouseWheelEvent and keeps phase for the fork API cmux_browser_send_wheel_phase (PL-cef-layer), with
  SendMouseWheelEvent fallback; golden frames on both sides.
- Acceptance: golden tests pass both sides; a momentum event round-trips its phases.
- Test phase: UNIT(ChromiumHostFrameTests); cmux-ci run of chromium_host_wire_test; GUI DC13 rubber-band.
- Size M. Depends: 038.

#### p04-input-064 Chromium host IME
- Files: `S/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostPageView+TextInput.swift`, `ChromiumHostFrame.swift`,
  `CEFShim/src/chromium_host_wire.h`, `CEFShim/src/browser_host_main.mm`,
  `T/CmuxNextBrowserTests/ChromiumHostTextInputTests.swift`.
- Change: NSTextInputClient on the page view; keyDown through interpretKeyEvents; marked text -> imeSet (UTF-16,
  max 4 KiB); insertText -> imeCommit; the host pushes imeCaret after each composition change so firstRect answers
  locally; plain keys send full characters; host side calls the fork's rp-path IME.
- Acceptance: fake input context: Japanese marked text then commit -> imeSet* then imeCommit; firstRect returns the
  last pushed rect; dead key composes; multi-unit characters sent whole.
- Test phase: UNIT(ChromiumHostTextInputTests); GUI DC13 --ime on macOS 26 and 27; check-ime-input.py.
- Size L. Depends: 063.

#### p04-input-065 Chromium host user-input priority and OS timestamps
- Files: `CEFShim/src/browser_host_main.mm`, `CEFShim/src/chromium_host_wire.h`.
- Change: the reader posts input frames with the fork's cmux_post_user_input_task (BrowserTaskTraits kUserInput),
  falling back to CefPostTask(TID_UI), chosen once at start with dlsym; t0 becomes the CEF event timestamp.
- Acceptance: t0 used as the event time (diff); fallback chosen once, not per event.
- Hand-off: InputTasks is the host's one input queue; HostInput's Post is `input_tasks.Post` once p01-process-042 starts the reader (042 drops its per-post PostInputTask). A refused task (UI thread shut down) is dropped: the BatchGate stays shut until HostInput::Stop, and nothing is posted to the other queue. Test: chromium_host_input_ring_test TestHostInputThroughInputTasks.
- Test phase: GUI chromium-host-bench.py hop_us and key-to-paint before/after.
- Size M. Depends: 063.

#### p04-input-066 Chromium page presented stage
- Files: `CEFShim/src/browser_host_main.mm`, `S/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostSession.swift`,
  `ChromiumHostFrame.swift`, `S/CmuxNextInput/InputLatencyTracker.swift`.
- Change: the host sends inputPresented(t0, presentedNs) on the fork's presentation feedback; cmux closes the
  chromiumPage slot with source hostFeedback. In-process: same through the shim event channel when the fork API
  allows; otherwise source estimatedVsync.
- Acceptance: a matching frame closes the slot by t0; an unmatched one is counted and dropped.
- Test phase: UNIT(ChromiumHostSessionTests); GUI DC1 chromium-page row.
- Size M. Depends: 005, 065.

#### p04-input-067 Event identity A (AgentPane, App)
- Files: `S/CmuxNextAgentPane/AgentPanePersonInput.swift`, `AgentPaneView.swift`,
  `S/CmuxNextApp/Control/DebugOmnibarClickBench.swift`, `Control/DebugPaneFocus.swift`, `Control/DebugTabSwitch.swift`,
  `Control/DebugWorkspaceSwitch.swift`, `Focus/FocusCoordinator.swift`, `Focus/FocusEffectApplier.swift`,
  `IconPicker/IconPickerService+BookmarkAnchors.swift`, `TerminalHostDelegate.swift`.
- Change: each code read of NSApp.currentEvent -> InputDispatchContext.event (nil between dispatches), the
  handler's own event, or the tap's lastDispatched record. NSControl/NSMenu target-action handlers may read
  currentEvent only when its timestamp is newer than lastDispatched, with `// current-event: target-action`. The
  CmuxNextActions hits are doc comments and are not changed (checked).
- Acceptance: DC7 query has 0 hits in these files; out-of-dispatch case covered (a CLI/socket run reads nil); a fake
  menu action with Option pressed during tracking reads Option.
- Test phase: UNIT(InputDispatchAgeTests,FocusCoordinatorTests).
- Size M. Depends: 011.

#### p04-input-068 Event identity B (Bookmarks, Browser, Design, Floating, Sidebar, Tabs, Terminal)
- Files: `S/CmuxNextBookmarks/UI/BookmarkBarItemView.swift`, `UI/BookmarkFolderMenu.swift`,
  `S/CmuxNextBrowser/UI/AddressBarView+Field.swift`, `UI/AddressBarView.swift`, `UI/AddressField.swift`,
  `UI/OmnibarFieldEditor.swift`, `S/CmuxNextDesign/FindPill/FindPillView.swift`, `MenuIdentityHeaderView.swift`,
  `Overlay/NativePopupHost.swift`, `Overlay/WindowOverlayHost+Mouse.swift`,
  `S/CmuxNextFloating/ChiefPet/ChiefPetReplyPanel.swift`, `S/CmuxNextSidebar/Views/GroupEditor/SidebarGroupEditor.swift`,
  `SidebarCardTextButton.swift`, `SidebarIconButton.swift`, `SidebarListView+GroupEditor.swift`,
  `S/CmuxNextTabs/TabStripView.swift`, `S/CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift`,
  `TerminalSurfaceView+TextInput.swift`.
- Change: same as 067; TerminalSurfaceView.doCommand compares against the event stored at keyDown.
- Acceptance: DC7 query returns 0 lines; terminal-keys and omnibar tests pass; Option-click tests on
  BookmarkFolderMenu and SidebarIconButton pass.
- Test phase: UNIT(TerminalKeyTests,AddressBarTests,FindPillTests); GUI terminal-keys-e2e.py.
- Size M. Depends: 011.

#### p04-input-069 Remove nextEvent(matching:) tracking loops
- Files: `S/CmuxNextBrowser/UI/ExtensionActionButton.swift`, `S/CmuxNextPalette/PalettePress.swift`,
  `S/CmuxNextDesign/TitlebarBandButton.swift`.
- Change: mouseDragged/mouseUp overrides with a small press state replace modal loops.
- Acceptance: `rg 'nextEvent\(matching'` = 0; press, drag-out and release unchanged (tests).
- Test phase: UNIT(ExtensionActionButtonTests,PalettePressTests,TitlebarBandButtonTests).
- Size S.

#### p04-input-070 input-latency-bench.py
- Files: `scripts/cmux-next/input-latency-bench.py`, `scripts/cmux-next/hid_input.py` (shared poster and probe
  parser taken from typing-frame-bench.py and sidebar-churn-typing.py), `scripts/cmux-next/typing-frame-bench.py`
  (uses hid_input.py), `scripts/measure/split-spring.sh`.
- Change: real HID keys and scrolls; surfaces terminal, home, omnibar, agent-pane, chromium-page, webkit-page,
  palette; --drag, --rate, --storm, --stall; reads input.latency signposts, debug.input, debug.hangs; JSON rows
  (surface, session, kind, stage, presentation_source, p50/p95/p99/max, n) and a host/macOS/refresh header; checks
  the Chromium page really is Chromium; exit 0 always; split-spring.sh --suite=input-latency.
- Acceptance: --self-test on a fixture; every DC1/DC2/DC5 field present; refuses debug.key input unless --input
  debug and labels it.
- Test phase: --self-test; GUI run on the base sha publishes MQ-input-latency-rows.
- Size M. Depends: 005, 007.

#### p04-input-071 input-glass-check
- Files: `scripts/cmux-next/input-glass-check.py`, `scripts/cmux-next/glass-capture.swift`.
- Change: SCStream on the caret region at display rate with SCStreamFrameInfo displayTime; real HID keys change one
  glyph; first changed frame paired with the slot's presented stage; reports glass p50/p95/p99, |glass - presented|
  p95, and the suggested per-OS offset for PresentationClock.
- Acceptance: --self-test on canned frames; refuses without the Screen Recording grant and says so.
- Test phase: GUI on a capture mini: DC3, macOS 26 and 27.
- Size M. Depends: 005.

#### p04-input-072 scroll-jank-bench.py
- Files: `scripts/cmux-next/scroll-jank-bench.py`, `scripts/cmux-next/hid_input.py`, `scripts/measure/split-spring.sh`.
- Change: real trackpad-like scrolls (began/changed/ended + momentum) at display rate over sidebar (400 workspaces),
  strip, rows, tabstrip (60 tabs), terminal scrollback, Chromium, WebKit, Home; reuses strip-scroll-check.py and
  sidebar-scroll-floor.swift setup; reports Chrome's metric names from the ledger plus dropped frames and update
  p99; --stall none or MS/PERIOD.
- Acceptance: --self-test; DC4 fields; Chromium target verified.
- Test phase: GUI DC4 (light and STRESS, macOS 26 and 27).
- Size M. Depends: 002, 005.

#### p04-input-073 perf-hot markers
- Files: `scripts/cmux-next/perf-hot-benches.json`, `S/CmuxNextInput/InputEventTap.swift`,
  `S/CmuxNextInput/PointerFrameCoalescer.swift`, `S/CmuxNextWakeups/MainJobGateHook.swift`,
  `S/CmuxNextInput/InputLatencyTracker.swift`, `S/CmuxNextTerminal/TerminalInputLane.swift`.
- Change: path ids input-tap (5 us/event), input-coalesce (10 us/frame), main-job-gate (0.2 us/job),
  input-latency-mark (0.5 us/event), terminal-input-lane (2 us/key), each with its bench and marker.
- Acceptance: each id has a marker the hook parser sees (`guardrails.py --list-perf-hot`).
- Test phase: python3 scripts/cmux-next/guardrails.py --self-test.
- Size S. Depends: 011, 021, 030, 058.

#### p04-input-074 Design doc, threading rows, PATTERNS P15, OWNERS row
- Files: `plans/cmux-next/input-pipeline-DESIGN.md`, `threading-model.md`, `PATTERNS.md`, `OWNERS.md`,
  `perf-lead.md`.
- Change: input-pipeline-DESIGN.md from this spec; threading rows for MainJobGate, coalescer clients, input and
  echo lanes, daemon ThreadType; PATTERNS P15 'Input pipeline'; OWNERS row for CmuxNextInput/InputCore; perf-lead
  row for p04.
- Acceptance: STYLE.md (ASD-STE100); every cited path exists at the head (link check).
- Test phase: none (docs).
- Size S.

#### p04-input-075 Test phase
- Files: `plans/cmux-next/perf-lead.md`, `plans/cmux-next/input-pipeline-DESIGN.md`.
- Change: on the merged head and the base sha run DC1-DC14 on the perf-lead pool (macOS 26/27, 120 Hz virtual
  display, light and STRESS) plus os-matrix.sh --os 14,15 launch and typing smoke for the hook. Record that old and
  new bench rows agree within noise on the base. Turn every failing row and every runtime-queue row into a task.
  Flip debug.mainJobGate on in Release only if DC2 shows a win and no regression.
- Acceptance: before/after table with host, macOS, refresh, sha, session for every DC; failing rows published.
- Test phase: all DC commands.
- Size M. Depends: 070, 071, 072.

#### p04-input-076 MainJobGate holding: origin classes, strict FIFO, drain after the commit
- Files: `S/CmuxNextWakeups/MainJobGate.swift`, `MainJobGateHook.swift`, `MainWork.swift` (new: MainWork.input /
  .frame), `S/CmuxNextApp/CmuxApplication.swift` (wiring), `S/CmuxNextSettings/Schema/SettingsSchema+Input.swift`
  (debug.mainJobGate), `T/CmuxNextWakeupsTests/MainJobGateClassTests.swift`, `plans/cmux-next/threading-model.md`.
- Change: hold while InputPendingState says pending or dispatching. Pass through only (a) jobs enqueued inside the
  input dispatch (main-thread flag set by route) and (b) jobs stamped by MainWork.input/frame (reserved
  side-table bit). No TaskPriority comparison. While the FIFO is not empty every new non-exempt job appends to it.
  Drain after the input's frame commit through AfterFrameCommit.swift, with an input check between jobs and a
  one-refresh deadline that releases the whole FIFO in order. A kCFRunLoopEntry observer for a non-default mode
  releases the FIFO and suspends holding until that loop exits. debug.mainJobGate: default on in DEV and NIGHTLY,
  off in Release (hook not installed). Counters held_by_origin and exempt_by_rule.
- Acceptance: tests: a Task{} created on main outside input is held; the same inside route passes; MainWork.input
  passes; an escalated job is still held; a job enqueued after release runs after held jobs; NSMenu tracking
  releases at mode entry; the input CATransaction commit happens before the first held job; ManualClock deadline
  test; setting off -> hook not installed. Pass-through stays one atomic load.
- Test phase: UNIT(MainJobGateClassTests,MainJobGateTests); GUI DC2 and DC10 A/B with the setting on/off;
  os-matrix.sh --os 14,15 launch smoke.
- Size L. Depends: 021, 023.

#### p04-input-077 Day-1 input hotspots on the base
- Files: `scripts/cmux-next/input-hotspots.py`, `plans/cmux-next/perf-lead.md`.
- Change: run typing-frame-bench.py, home-perf.py home.typing and sidebar-churn-typing.py --input real at 400
  workspaces with CMUX_NEXT_TRACE_FLOWS on the base, light and STRESS; fold trace.py output into one row per
  dominant main-thread stack over 4 ms in key windows; also the click-to-commit gap for tab and palette clicks
  (input to 042).
- Acceptance: artifacts/input-hotspots.json {surface, session, stack_top, file:line, share_ms_p95}; --self-test on a
  fixture; no app code.
- Test phase: --self-test; GUI run on the base publishes MQ-input-hotspots by hour 12.
- Size S.

#### p04-input-078 Ghostty fork: a key never waits on renderer_state.mutex behind output parsing
- Files: `ghostty-next (submodule): src/Surface.zig`, `ghostty-next (submodule): src/apprt/embedded.zig`,
  `S/CmuxNextTerminal/TerminalOutputLane.swift`, `S/CmuxNextTerminal/GhosttyLockWaitSignpost.swift`,
  `docs/ghostty-fork.md`.
- Change: (1) atomic input_waiting on Surface, set by main-thread entry points before they lock; process_output
  parses 4 KiB sub-slices and releases the lock between them when it is set. (2) Plain-press fast path:
  has_selection and viewport_at_bottom mirrored as atomics by the parser; keyCallback locks only when one needs
  work, else nothing; otherwise post scroll-to-bottom/clear-selection to the io mailbox. (3) Debug/bench
  signpost ghostty.lock_wait for each main-thread acquisition that waited > 50 us. Through p03-079's integrator
  lane; PL-ghostty reviews.
- Acceptance: fork diff: keyCallback's non-modifier block locks only behind the atomics; process_output checks
  input_waiting between 4 KiB sub-slices; Zig test with 8 MiB dense SGR: concurrent keyCallback lock wait p99 <
  0.5 ms; pointer bump is a separate commit.
- Test phase: Ghostty zig test on the fleet (isolated); GUI DC1 terminal STRESS with a `yes` sibling pane:
  ghostty.lock_wait p99 and key-to-presented p99 before/after.
- Size L.

#### p04-input-079 Ghostty actions reach main once per frame, input first
- Files: `S/CmuxNextTerminal/GhosttyRuntimeCallbacks.swift`, `GhosttyRuntime.swift`, `GhosttyActionDispatcher.swift`,
  `GhosttyActionMailbox.swift`, `T/CmuxNextTerminalTests/GhosttyActionMailboxTests.swift`.
- Change: the 5 DispatchQueue.main.async sites (lines 21, 43, 124, 154, 160) become a lock-free per-surface
  mailbox. Latest-wins per (surface, kind) for scrollbar, set_title, pwd, mouse_shape, mouse_over_link, cell_size,
  progress; discrete actions in order (bell, close, clipboard, open_url, splits, new tab). One frame-class client
  per window drains it after input and before visible work. Land after p03-119 (tick coalescing, same file).
- Acceptance: `rg 'DispatchQueue.main.async' GhosttyRuntimeCallbacks.swift` = 0; 50 scrollbar actions in a frame ->
  1 apply; discrete order kept; empty mailbox registers no client.
- Test phase: UNIT(GhosttyActionMailboxTests,TerminalHostViewTests); GUI DC2 with 13 streaming STRESS panes.
- Size M. Depends: 025, p03-119.

#### p04-input-080 Classed main-work helpers (MQ-main-nonswift)
- Files: `S/CmuxNextWakeups/MainWorkScheduler.swift`, `S/CmuxNextWakeups/MainNotificationObserver.swift`,
  `S/CmuxNextCompat/MainActorObservation.swift`, `S/CmuxNextCompat/MainRunLoopBlock.swift`,
  `T/CmuxNextWakeupsTests/MainNotificationObserverTests.swift`.
- Change: MainWorkScheduler.post(class:) for GCD and run-loop blocks; MainNotificationObserver(name:, object:,
  class:) delivering through MainWorkScheduler; input and frame classes run at once, visible/automation/background
  go through the gate and MainFrameBudget. The two Compat helpers take a class parameter (callers updated in the
  same diff, or default .visible with a deprecation note if the diff exceeds 400 lines).
- Acceptance: visible, automation and background are held while an input dispatch runs (test); input/frame run at
  once; the MQ-main-nonswift query and per-package counts are in the commit message.
- Test phase: UNIT(MainNotificationObserverTests,MainJobGateTests).
- Size M. Depends: 076.

#### p04-input-081 MQ-main-nonswift batch A (App, Sidebar, Layout, Design, Terminal)
- Files: `S/CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift`, `S/CmuxNextApp/Windows/WindowOverlayLayer.swift`,
  `S/CmuxNextApp/NewTab/NewTabSparePool.swift`, `S/CmuxNextApp/Permissions/SystemPermissionProbe.swift`,
  `S/CmuxNextApp/Themes/ThemeCoordinator+Backgrounds.swift`, `S/CmuxNextApp/GhosttyConfigLiveReload.swift`,
  `S/CmuxNextApp/AgentCursor/AgentCursorVisibilitySource.swift`, `S/CmuxNextSidebar/Views/SidebarView.swift`,
  `SidebarListView.swift`, `SidebarListView+PointerEnd.swift`, `KeyWindowRepaint.swift`,
  `S/CmuxNextLayout/Views/LayoutRootView+Overlay.swift`, `LayoutRootView+Hover.swift`, `S/CmuxNextDesign/PointerHover.swift`,
  `S/CmuxNextDesign/Overlay/WindowOverlayHost.swift`, `S/CmuxNextTerminal/GhosttyRuntime+Background.swift`,
  `TerminalSurfaceView.swift`, `TerminalHostView.swift`.
- Change: each hit -> post(class:) or MainNotificationObserver with a named MainWorkClass; same-turn needs keep the
  hop with `// input-hop-allow: <why>`.
- Acceptance: MQ-main-nonswift 0 unallowed hits in these files; every replacement names a class (diff); tests pass.
- Test phase: UNIT(NoActivateGuardTests,SidebarListViewTests,LayoutRootViewTests,PointerHoverTests,TerminalHostViewTests);
  GUI DC2 gate counters.
- Size M. Depends: 080.

#### p04-input-082 MQ-main-nonswift batch B (Browser/CEF, Pages, MacScreen, Tasks, Mobile, Control, Tabs, Design)
- Files: `S/CmuxNextBrowser/CEF/ChromiumWindowGuard.swift`, `CEF/CEFRuntime+Events.swift`, `CEF/CEFPaneHost.swift`,
  `CEF/CEFLayerHosting.swift`, `CEF/CEFHostView.swift`, `CEF/CEFEngine+Passwords.swift`,
  `S/CmuxNextPages/PageHostPool+Windows.swift`, `PageHostPool+Build.swift`, `S/CmuxNextMacScreen/MacScreenSystemShortcuts.swift`,
  `MacScreenShareHost.swift`, `MacScreenPages.swift`, `S/CmuxNextTasks/SocketTasksSource.swift`,
  `S/CmuxNextMobileHost/IPhoneHostService+Pairing.swift`, `S/CmuxNextControl/Concurrency/ControlFrameSource.swift`,
  `S/CmuxNextTabs/WindowMainObserver.swift`, `S/CmuxNextDesign/ThemedMenu.swift`, `S/CmuxNextDesign/BackdropVideoView.swift`.
- Change: same rule; socket and automation sources (SocketTasksSource, ControlFrameSource, IPhoneHostService) use
  the automation class. Remaining packages with hits after 081/082 each become one generated task.
- Acceptance: 0 unallowed hits in these files; automation sources tagged automation (diff).
- Test phase: UNIT(CEFRuntimeTests,PageHostPoolTests,MacScreenTests,SocketTasksSourceTests,ControlFrameSourceTests);
  GUI DC2 --storm cli=10hz.
- Size M. Depends: 080.

#### p04-input-083 Terminal echo lane in the app
- Files: `S/CmuxNextDaemon/Terminal/TerminalAttachment.swift`, `S/CmuxNextBridge/TerminalAttachDriver.swift`,
  `TerminalAttachMachine.swift`, `S/CmuxNextApp/DaemonTerminalIO.swift`, `S/CmuxNextTerminal/TerminalSession.swift`,
  `TerminalOutputLane.swift`, `T/CmuxNextBridgeTests/TerminalEchoLaneTests.swift`.
- Change: while attached, .output bytes go from the link reader thread through a registered synchronous sink to
  TerminalOutputLane.enqueue; back-pressure uses the lane's capacity on the reader thread. Control steps (grid,
  snapshot, replay, status, close) keep the driver path; one sequence number keeps bytes and control in order.
  TypingLatencyProbe outputReceived is marked on the reader thread. Owner PL-ghostty.
- Acceptance: bytes do not pass through an AsyncStream or Task (diff); with the cooperative pool saturated, echo
  bytes reach a fake lane within 2 ms; 10k interleaved records in order; back-pressure stops the reader without
  drops; detach drops nothing already accepted.
- Test phase: UNIT(TerminalEchoLaneTests,TerminalAttachDriverTests,TerminalSessionTests); GUI DC9 echo hops, DC1
  terminal STRESS.
- Size L. Depends: 058, 006.

#### p04-input-084 cmux-tui QoS: echo path, TUI/remote input, background UTILITY
- Files: `cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime/shared/host_accept.rs`,
  `cmux-tui/crates/cmux-tui-core/src/server/cmd_attach.rs`, `src/server/resource_attach.rs`,
  `src/server/line_connection.rs`, `cmux-tui/crates/cmux-tui/src/pty_input.rs`, `cmux-tui/crates/cmux-tui/src/session/remote.rs`,
  `cmux-tui/crates/cmux-tui/src/main.rs`, plus the spawn sites of the background threads (found by name with rg).
- Change: InputCritical on terminal-host-client, mux-attach-out (both sites), mux-render-attach-out,
  mux-resource-terminal-attach, mux-pty-input, remote-input-writer, relay-input; Interactive (USER_INITIATED) on
  mux-line-out; Utility on sqlite-wal-sync, mux-output-store-writer, mux-inventory-watch, mux-project-sources,
  cmux-config-watch, terminal-host-record-mirror, terminal-command-history, mux-session-journal-fanout. The journal
  writer goes to Utility only after PL-daemon removes request-path waits on it (note the dependency in
  threading-model.md).
- Acceptance: each named thread body starts with thread_qos::set (listed in the commit); threading-model.md row per
  class.
- Test phase: cmux-tui-focused-test.sh cmux-tui-core thread_qos; GUI DC9 taskinfo on daemon and terminal host.
- Size M. Depends: 060.

#### p04-input-085 Daemon connection scheduler: input precedence
- Files: `cmux-tui/crates/cmux-tui-core/src/server/connection_scheduler.rs`, `src/server/command_dispatch.rs`,
  `src/server/tests/connection_scheduler_input_lane.rs`.
- Change: Send, SendKey and paste for a surface take precedence over queued non-input requests of other surfaces
  (Chrome kUserInput on the daemon side); per-surface order unchanged; a long read (read_scrollback, snapshot) runs
  on a worker like clear-history.
- Acceptance: a 200k-line read_scrollback for A queued first, then Send for B: B replies first; two Sends around a
  resize keep order; no new thread per request (counter).
- Test phase: cmux-tui-focused-test.sh cmux-tui-core connection_scheduler; GUI DC2 with --storm cli=10hz read-screen.
- Size M.

#### p04-input-086 Key equivalents skip the whole-tree walk and the menu search
- Files: `S/CmuxNextApp/Windows/WindowController.swift`, `S/CmuxNextApp/Focus/KeyRouter+Hooks.swift`,
  `S/CmuxNextActions/ActionRegistry+Menus.swift`, `T/CmuxNextAppTests/KeyEquivalentWalkTests.swift`.
- Change: in WindowController.performKeyEquivalent (line 430), when KeyRouter decided the event and the first
  responder is a known content view (terminal, field editor, page host), call that view's performKeyEquivalent
  directly and return its answer; registry-bound chords are resolved by KeyRouter and do not reach the menu search;
  menu clicks unchanged (Chrome CommandDispatcher). Owner PL-typing.
- Acceptance: debug counters; in a 30-pane window Ctrl-C in a terminal visits 1 view and Cmd-T makes <= 1
  validateMenuItem call; menu enabled states correct when it opens (existing tests).
- Test phase: UNIT(KeyEquivalentWalkTests,KeyRouterTests,KeyboardParityTests); CMUX_BENCH=1 UNIT(KeyRouterBench).
- Size M. Depends: 053.

#### p04-input-087 Tab strip and saved-groups bar scroll by translation
- Files: `S/CmuxNextTabs/TabStripView+Pointer.swift`, `TabStripView.swift`,
  `S/CmuxNextTabs/Groups/SavedBar/SavedGroupsBarView.swift`, `T/CmuxNextTabsTests/TabStripScrollTests.swift`.
- Change: cells in a container whose layer translation is the scroll offset (as p03-026); wheel deltas summed per
  frame by the coalescer with phase and momentum; one translation set per frame with actions disabled; applyFrames
  only when the visible cell set changes; hover-card dismiss once per gesture.
- Acceptance: 20 wheel events in a frame -> 0 applyFrames, 1 offset set; clamp and TabScrollMath unchanged; click
  after scroll hits the tab under the pointer.
- Test phase: UNIT(TabStripScrollTests,TabStripPointerTests); GUI DC4 tabstrip.
- Size M. Depends: 030.

#### p04-input-088 Layout pointer sites: canvas drag and pan, strip scrollbar, hover focus
- Files: `S/CmuxNextLayout/Views/ScreenContentView+Canvas.swift`, `StripScrollbarView.swift`, `LayoutRootView.swift`,
  `LayoutRootView+Hover.swift`, `T/CmuxNextLayoutTests/LayoutPointerCoalescingTests.swift`.
- Change: setCanvasFrame (Canvas.swift:131), canvas pan, StripScrollbarView onDrag (line 233) and
  focusPaneForPointerHover (LayoutRootView.swift:194) through the coalescer; mouseUp flushes first. Tell PL-motion-core.
- Acceptance: 8 drags in a frame -> <= 2 setCanvasFrame, <= 2 onDrag, <= 2 hover resolves; final state after mouseUp
  equals the per-event result.
- Test phase: UNIT(LayoutPointerCoalescingTests,CanvasTests,StripScrollbarTests); GUI DC5 --drag canvas-pane,strip-scrollbar.
- Size M. Depends: 030.

#### p04-input-089 Remaining per-event pointer sites
- Files: `S/CmuxNextAgentPermissions/UI/PermissionAppTile.swift`, `S/CmuxNextApp/Handlers/BrowserDownloadsPopup.swift`,
  `S/CmuxNextBrowser/PageInfo/UI/PageInfoChipButton.swift`, `S/CmuxNextBrowser/Screenshot/BrowserSectionOverlayView.swift`,
  `S/CmuxNextFloating/ChiefPet/ChiefPetPanel.swift`, `S/CmuxNextOnboarding/Steps/HelperAppTile.swift`,
  `S/CmuxNextSidebar/Views/SidebarNowPlayingCardView.swift`, `SidebarUpdateCardView.swift`,
  `S/CmuxNextPages/PageWKWebView.swift`, `scripts/cmux-next/check-pointer-coalesce.py`.
- Change: BrowserSectionOverlayView needsDisplay, ChiefPetPanel setFrameOrigin and hover tiles/cards per delivery;
  PageWKWebView gets `// input-coalesce: native`. check-pointer-coalesce.py lists MQ-pointer-per-event hits that have
  neither a coalescer call nor the note.
- Acceptance: after 031-038, 088 and this task the script reports 0; touched tests pass.
- Test phase: UNIT(touched view tests); python3 scripts/cmux-next/check-pointer-coalesce.py; GUI 1000 Hz drag of the
  pet panel and a screenshot section.
- Size S. Depends: 030.

#### p04-input-090 resetCursorRects become cursorUpdate
- Files: `S/CmuxNextLayout/Views/ScreenContentView+Canvas.swift`, `DividerHandleView.swift`,
  `S/CmuxNextTerminal/TerminalSurfaceView+Mouse.swift`, `S/CmuxNextSidebar/Views/SidebarResizeHandle.swift`,
  `S/CmuxNextApp/RightSidebar/RightSidebarResizeHandle.swift`, `S/CmuxNextBrowser/CEF/CEFDevToolsDivider.swift`,
  `UI/ArrowCursorView.swift`, `UI/AddressField.swift`, `UI/AddressBarView.swift`, `Screenshot/BrowserSectionOverlayView.swift`,
  `S/CmuxNextDesign/Text/ChromeLabel.swift`, `S/CmuxNextRemoteBrowser/Pane/RemoteBrowserContentView.swift`,
  `S/CmuxNextFloating/FloatingChatFrames.swift`, `ChiefPet/ChiefPetPanel.swift`,
  `S/CmuxNextChiefPetWiring/ChiefPetMascotGrid.swift`, `S/CmuxNextHomeEngine/HomeChiefSettingsControls.swift`.
- Change: each view sets its cursor in cursorUpdate(with:) of its `.inVisibleRect | .cursorUpdate` area (added once,
  p03-109); resetCursorRects overrides and their invalidateCursorRects(for:) calls go away (the ShellWindow
  CursorRectHold workaround is removed if nothing needs it).
- Acceptance: MQ-cursor-rects 0 unallowed; a 20-frame divider drag makes 0 window cursor-rect rebuilds; I-beam and
  resize cursor tests pass.
- Test phase: UNIT(CursorShapeTests,DividerDragTests); GUI DC5 divider main time.
- Size M. Depends: p03-109.

#### p04-input-091 Chromium EventLatency and ScrollJank through CDP
- Files: `S/CmuxNextBrowser/CEF/CEFHistogramReader.swift`, `Packages/macOS/CmuxNext/CEFShim/src/shim_devtools_protocol.mm`,
  `S/CmuxNextInputDiagnostics/DebugInput.swift`, `S/CmuxNextControl/InputBudget/InputLatencyReporter.swift`,
  `T/CmuxNextBrowserTests/CEFHistogramReaderTests.swift`.
- Change: on debug.input or report build, Browser.getHistograms query 'EventLatency.' plus
  Event.ScrollJank.DelayedFramesPercentage.FixedWindow and Event.Latency.ScrollUpdate.*; fold into ledger rows with
  target chromiumPage/agentPane and source chromium. If renderer histograms do not reach the browser process, say so
  in the result and file a PL-cef-layer fork item.
- Acceptance: on request only, off main except the CDP send (diff); canned JSON test keeps count and sum, maps
  edges, ignores unknown histograms; no new timer.
- Test phase: UNIT(CEFHistogramReaderTests); GUI DC1 chromium-page and agent-pane rows next to the cmux slots.
- Size M. Depends: 002, 007.
- Deviation (as built): Browser.getHistograms reads the browser process's StatisticsRecorder and takes no
  target, so it cannot split browser pages from agent pane pages. The rows have target `chromiumProcess`
  (both together), not `chromiumPage`/`agentPane`. GUI DC1 compares one surface at a time: a bench sends input
  to that surface alone between `debug.input reset` and the read. A split needs a per-renderer read (a
  PL-cef-layer fork item), not this reader. Row stages are Chromium's top-level breakdown in pipeline order;
  `TotalLatency*` variants and dotted sub-stages are only in `histograms`.

#### p04-input-092 cmux web pages: passive listeners, rAF-coalesced moves, key-to-paint probe
- Files: `webviews/src/ui/frameInput.ts`, `webviews/src/ui/frameInput.test.ts`, `webviews/src/pages/markdown/tables.ts`,
  `webviews/src/pages/markdown/linkEditing.ts`, `webviews/src/agent-session/acpmux/conversation/ImageViewer.tsx`,
  `webviews/src/agent-session/acpmux/conversation/gutterSelect.ts`, `webviews/src/agent-session/acpmux/chips/useHoverCard.ts`,
  `webviews/src/agent-session/acpmux/chips/ReplyMedia.tsx`, `webviews/src/ui/pressRelease.ts`,
  `webviews/src/ui/titleTooltips.ts`, `webviews/src/ui/anchor.ts`, `webviews/src/BranchBasePicker.tsx`,
  `webviews/src/DiffToolbar.tsx` (all checked to exist).
- Change: passive wheel/scroll listeners where no preventDefault is needed; where it is, scope to the element and
  gate on the state that needs it; move handlers through frameInput (latest-wins rAF); a key-to-paint probe
  (keydown timeStamp to next rAF + one MessageChannel tick) posting a numeric histogram at most once per 10 s, only
  while debug.input or the opt-in report is on.
- Acceptance: each listed listener passive or commented with its preventDefault; every listed move handler uses
  frameInput; tests: N moves -> 1 call; probe silent when off; `bun run check` passes in webviews/.
- Test phase: `cd webviews && bun run check && bun test src/ui/frameInput.test.ts`; scripts/gallery-compare.sh;
  GUI DC1 agent-pane row.
- Size M.

#### p04-input-093 Input-turn dirty-view recorder (Debug)
- Files: `S/CmuxNextInputDiagnostics/InputDirtyRecorder.swift`, `S/CmuxNextInputDiagnostics/DebugInput.swift`,
  `scripts/cmux-next/input-dirty-views.py`.
- Change: on request, swizzle setNeedsDisplay/setNeedsLayout/needsUpdateConstraints and CALayer
  setNeedsLayout/setNeedsDisplay during an input dispatch and its commit; record view class, backtrace (resolved off
  main) and whether the view is outside the target's subtree; time the display-cycle observer per key. The script
  runs the real-HID typing bench and writes artifacts/input-dirty-views.json.
- Acceptance: `#if DEBUG || CMUX_BENCH_HOOKS`; installed on request, removed on reset (test); bounded 256 sites.
- Test phase: UNIT(InputDirtyRecorderTests); GUI run on Home, omnibar, terminal STRESS publishes MQ-input-dirty-views.
- Size M. Depends: 007, 011.

#### p04-input-094 Cross-process stages for terminal keys
- Files: `S/CmuxNextInputCore/InputStage.swift`, `S/CmuxNextBridge/TerminalAttachDriver.swift`,
  `S/CmuxNextApp/DaemonTerminalIO.swift`, `cmux-tui/crates/cmux-tui-core/src/server/cmd_terminal_io.rs`,
  `src/terminal_host_runtime/shared/host_shared.rs`, `src/terminal_host_runtime/shared/host_serve.rs`.
- Change: always send the slot id in SendParams.flow (cmd_terminal_io.rs:118); daemon and host stamp
  CLOCK_UPTIME_RAW at receive and PTY write into a fixed per-terminal atomic ring; the first output frame after the
  write carries {id, recv_ns, write_ns, echo_read_ns} in an optional header field older apps ignore; the tracker
  fills daemonReceived, ptyWritten, echoRead, echoSent. No-echo (500 ms) drops the entry.
  It also installs the terminal echo sink from 006: `InputLatencyTracker` conforms to
  `TerminalEchoLatencySink` (`dispatchingKey` is the key slot sendEvent is dispatching; `terminalEcho` marks
  echoParsed/contentSubmitted, and a slot whose key waits for its echo stays open until the ending event), and
  the composition root calls `GhosttyRuntime.shared.echoStages.install(tracker)` before the first terminal.
  Then run 006's GUI check: typing-frame-bench.py --surfaces terminal, |contents_ms - new stage| < 0.5 ms.
- Acceptance: old app + new daemon and new app + old daemon both work (tests both sides); full ring drops and
  counts; no allocation on the daemon hot path (diff); ledger shows the new deltas.
- Test phase: UNIT(InputLatencyTrackerTests); cmux-tui focused test cmd_terminal_io; GUI DC1 terminal per-stage split.
- Size L. Depends: 005, 006.

#### p04-input-095 Handlers read their event, not global input state
- Files: `S/CmuxNextDesign/PointerHover.swift`, `S/CmuxNextLayout/Views/LayoutRootView+Hover.swift`,
  `S/CmuxNextFloating/ChiefPet/ChiefPetPanel.swift`, `S/CmuxNextLayout/Views/DividerMouseCatchers.swift`.
- Change: hits of MQ-global-input-state inside an NSEvent handler use the event's modifierFlags, locationInWindow,
  buttonNumber; outside dispatch they use InputEventTap.lastPointer or carry `// global-input-allow: <why>`. This
  file list is batch 1; the query generates one task per remaining package.
- Acceptance: 0 hits inside methods that receive an NSEvent in these files (review checks each); outside dispatch
  lastPointer or an allow comment.
- Test phase: UNIT(touched tests); GUI DC5 drag with a modifier pressed and released in one frame.
- Size M. Depends: 011.

#### p04-input-096 No TIS or UCKeyTranslate per terminal key
- Files: `S/CmuxNextTerminal/GhosttyInput.swift`, `TerminalSurfaceView+Keyboard.swift`, `TerminalCopyMode.swift`,
  `S/CmuxNextApp/Focus/Keybindings/GhosttyKeyBindingLayer.swift`, `T/CmuxNextTerminalTests/InputSourceSwitchChordTests.swift`.
- Change: read the input-source switch hotkeys once (com.apple.symbolichotkeys 60, 61, plus Globe) and refresh on
  the defaults change; compare TIS only for a chord that is one of them; copy-mode ASCII from a KeyCodeLayout map
  cached per layout (KeyboardLayoutObserver); isUsersKeybind uses a Set<Shortcut> built at table load.
- Acceptance: Ctrl-C makes 0 TIS calls (counter); Ctrl-Space still detects the switch; 100 copy-mode keys make 0
  UCKeyTranslate after the first build; isUsersKeybind O(1) (diff).
- Test phase: UNIT(InputSourceSwitchChordTests,CopyModeKeysTests); CMUX_BENCH=1 UNIT(KeyRouterBench).
- Size S.

#### p04-input-097 Interaction latency (INP equivalent)
- Files: `S/CmuxNextInputCore/InteractionLatency.swift`, `S/CmuxNextInputCore/InputLatencyLedger.swift`,
  `S/CmuxNextHangReports/HangReport.swift`, `HangReportBuilder.swift`, `T/CmuxNextInputCoreTests/InteractionLatencyTests.swift`.
- Change: pair keyDown/keyUp (same keyCode), mouseDown/mouseUp, drag start/end; interaction latency = the longest
  event; per session count, worst, and INP high percentile (ignore one per 50, fixed top-k heap, max 11); export
  interaction_latency in debug.input and the opt-in report (numbers and kind/target only).
- Acceptance: no allocation per event after warm-up; 120 interactions with 2 outliers report the third-worst; a
  key with no keyUp closes at the next key; PrivacyLeakScanner passes.
- Test phase: UNIT(InteractionLatencyTests,PrivacyLeakScannerTests); DC12.
- Size S. Depends: 002, 010.

#### p04-input-098 Hit-test cost audit (Debug)
- Files: `S/CmuxNextInputDiagnostics/HitTestAudit.swift`, `S/CmuxNextInputDiagnostics/DebugInput.swift`.
- Change: on request, count views visited and time per event in window hit testing; after STRESS scroll and click
  benches, list overrides with p99 > 20 us or > 32 views per event (75 overrides today, for example
  ScreenContentView+Dock.swift:185, SidebarListView+Blocks.swift:85). Each row is one task (region cache or early
  return).
- Acceptance: Debug/bench only, installed on request (test); stable JSON; no cost when off.
- Test phase: UNIT(HitTestAuditTests); GUI STRESS run publishes MQ-hittest.
- Size S. Depends: 007.

#### p04-input-099 WebKit page presented stage
- Files: `S/CmuxNextInput/WebPageInputTiming.swift`, `S/CmuxNextInput/InputLatencyTracker.swift`,
  `T/CmuxNextInputTests/WebPageInputTimingTests.swift`.
- Change: for webkitPage slots, a DEV/bench-only user script posts PerformanceEventTiming (or rAF-after-handler)
  through the existing message handler; the tracker maps it to uptime and closes with source pageEstimated.
- Acceptance: injected only in DEV and bench builds; recorded-message test closes a slot; unmatched counted and
  dropped; numbers only.
- Test phase: UNIT(WebPageInputTimingTests); GUI DC1 webkit-page row.
- Size M. Depends: 005.

#### p04-input-100 Sidebar swipe and wheel paging through the tap (prerequisite for p03-110)
- Files: `S/CmuxNextSidebar/Views/SidebarScrollView.swift`, `S/CmuxNextSidebar/Views/ProfileBarView.swift`,
  `T/CmuxNextSidebarTests/SidebarSwipeTapTests.swift`.
- Change: ProfileSwipeTracker and SpaceWheelPager feeding (SidebarScrollView.swift:20-46, ProfileBarView.swift:318)
  moves to a window-scoped scroll observe subscription with a hit-test predicate; scrollWheel no longer calls
  tracker.feed and calls super for vertical events. On the fleet, confirm that sendEvent still sees every scroll
  event while responsive scrolling tracks a gesture; write the finding in the commit and tell p03-110's owner.
- Acceptance: swipe and wheel-page tests pass when fed through the tap; scrollWheel has no tracker.feed (diff);
  finding recorded.
- Test phase: UNIT(SidebarSwipeTapTests,ProfileSwipeTrackerTests); GUI real-HID horizontal swipe with
  isCompatibleWithResponsiveScrolling on.
- Size S. Depends: 011.

#### p04-input-101 Text input server stage
- Files: `S/CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift`, `S/CmuxNextInput/TextInputStage.swift`,
  `S/CmuxNextInput/InputLatencyTracker.swift`.
- Change: mark textInputStart/End around interpretKeyEvents in the terminal, and in the Home and omnibar field
  editors through one helper, so the input-method server round trip shows apart from cmux dispatch.
- Acceptance: two clock reads per key, no allocation; fake input context test: dispatchStart <= textInputStart <=
  textInputEnd <= dispatchEnd.
- Test phase: UNIT(InputLatencyTrackerTests); GUI DC1 with Japanese input source vs ABC.
- Size S. Depends: 005.

#### p04-input-102 Spike: strip and rows keep scrolling with main stalled
- Files: `S/CmuxNextLayout/Views/StripScrollHost.swift` (spike), `T/CmuxNextLayoutTests/StripScrollHostTests.swift`,
  `plans/cmux-next/input-pipeline-DESIGN.md`.
- Change: Chrome scrolls on the compositor thread. p03-026 still sets the motion container on main per frame, so a
  50 ms stall drops strip frames. Prototype an NSScrollView host whose clip and document view are responsive-scroll
  compatible (overdraw from preparedContentRect), with snap and landing in ColumnScrollReducer on scroll end.
  Measure DC4 strip/rows with --stall against p03-026. Write the decision (adopt, or why strip stays on main) in
  the design doc, agreed with PL-motion-core and p03.
- Acceptance: StripScrollHost and its document view report isCompatibleWithResponsiveScrolling == true and do not
  override scrollWheel without super for their axis; the decision with numbers is in the design doc.
- Test phase: UNIT(StripScrollHostTests,ColumnScrollReducerTests); GUI DC4 strip and rows --stall 50ms/100ms.
- Size L. Depends: p03-026, 072.

#### p04-input-103 Web (main): schema 3 accepts the input latency fields
- Files: `web/services/hangReports/`, `web/tests/fixtures/hang-report-schema3-input-latency.json`,
  `web/scripts/hang-reports-histograms.ts`.
- Change: on p09-observability-064's schema-3 decoder, the optional `input_latency_bucket_edges_ms`,
  `input_latency[]` (<= 64 rows, closed literal labels copied from the Swift enums, `display {refresh_hz, vrr}` per
  row, `count` == sum of 14 `buckets`) and `scroll_jank` (the six `Event.ScrollJank.*` names, clamped values), all
  three together or absent (hang-reports-DESIGN.md section 4, "Input latency"). Schema 2 keeps refusing them.
- Acceptance: 204 with the fixture byte-identical to the Swift golden; 400 for an unknown label, a wrong bucket
  sum, or the keys in schema 2; web lints; deployed on main before 104's flag turns on.
- Test phase: bun test in web/; PR on main.
- Size S. Depends: 010, p09-064.

#### p04-input-104 Wire the input latency field report into hang reports
- Files: `schemas/features/features.d/hangReportInputLatency.json`,
  `S/CmuxNextApp/HangReports/HangReportsController.swift`, `S/CmuxNextApp/HangReports/InputLatencyFieldSource.swift`,
  `T/CmuxNextAppTests/InputLatencyFieldSourceTests.swift`, `plans/cmux-next/hang-reports-DESIGN.md`.
- Change: feature `hangReportInputLatency` (default off everywhere). When on and p09-063's server-version flag says
  schema 3, the composition root builds `HangReportBuilder(wireSchema: .v3)` and passes
  `Environment.inputLatency`: an adapter over the app's `InputLatencyReporter` (`setFieldReport`,
  `fieldReportPreview`, `takeFieldReport`, `commitFieldReport`). The producer stamps each `InputLatencyBatch` with
  the window display's `InputDisplayClass` (003's refresh and VRR label).
- Acceptance: flag off: no field ledger and schema 2 on the wire; flag on: a NIGHTLY opt-in report holds
  `input_latency` rows labelled by display (DC12); hang reports off stops the field ledger.
- Test phase: UNIT(InputLatencyFieldSourceTests,HangReportServiceTests); DC12.
- Size S. Depends: 010, 103, 003, p09-063.
