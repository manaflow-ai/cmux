# cmux next: the main-thread budget and scheduler (2026-10-23, contract 2026-10-25)

Lawrence 2026-10-23: "there's lag in the terminal whenever a lot of CLI operations are going on, like reordering
of the sidebar." Measured by PL-typing (cmux8s, macOS 27, 60 Hz): a key's own work is under 2 ms, but key to frame
is 30-50 ms idle and 160-400 ms under load; the time is the wait for the main thread (send to dispatch 8-286 ms
under load) and the display cycle's layer-tree build. Owner: PL-main (cmux-4f, perf-lead.md).

This file is the contract for main-thread work. The program that builds it is p06-scheduler
([chrome-parity/p06-scheduler.md](chrome-parity/p06-scheduler.md), "the spec" below). The "Task" column names
the p06 task that lands each piece. Section 12 lists every type with its file and says if it is on
perf/chrome-parity (at `4e0005673f2`) or only spec'd. A spec'd piece is the interface to write against; do not
call it from code until its task lands. Section 14 describes the pieces that existed before p06.

## Rule

The main thread does three things: input dispatch, the minimal mutation of visible state, and the Core Animation
commit. Everything else runs off it. What the app still schedules there runs as a task of one scheduler, in a
priority class, with an owner and a source location (Chrome's UI thread: typed task queues, `posted_from`).

1. **Post every main-thread task with a class and an owner.** A synchronous change in the input's own turn stays a
   direct call (the zero-latency contract, [zero-latency.md](zero-latency.md)). Any other main-thread work uses
   one of the posting forms in section 3. Do not add an unclassed hop: `Task { @MainActor`, a main-inherited
   `Task {`, `MainActor.run`, `DispatchQueue.main.async`, `CFRunLoopPerformBlock`, `RunLoop.main.perform` or
   `MainDelivery` with no class.
2. **Keep the person's visible change in the input's turn.** A person-caused observation applies in the
   input-response pass, before the commit. An async completion of a person's action is `userBlocking`. Do not move
   a person-visible change behind `visible` or `automation`.
3. **Use `VisibleObservation` only when `apply` changes views.** Use `ServiceObservation` for side effects (daemon,
   disk, model, another owner). These side effects must still happen while the node is hidden.
4. **Hidden means model only.** A hidden node gets no layout, no view sync and no animation. Its work runs once, in
   the show order, when it shows.
5. **Take the cause from the source.** The cause is the daemon envelope cause plus the app's mutation_id match.
   Never use the cause for authorization.
6. **A deadline that a person or a request waits on** is `.precise` (under 36 ms) or `.flexible`. It is never
   `.whenHidden`.

## 1. Classes (`MainWorkClass`, CmuxNextWakeups/MainWorkClass.swift)

The order is input > input-response pass > frame > userBlocking > visible > automation > background > idle. The
budgets scale with the refresh interval: "× scale" means × (interval / 16.7 ms).

| Class | What | Budget per frame | Task |
|---|---|---|---|
| input | AppKit event dispatch, injected keys (`debug.key`, `debug.view_key`), `InputEventTap` subscribers (CmuxNextInput/InputEventTap.swift, p04-input-011) | none | base, 220 |
| input-response pass | A state with a pass, not a queue. A discrete input opens it only when the turn expects a frame: the `ActionEffect` is `.applied`, `.intentEffect` or `.waiting`, a view asked for display, or Ghostty asked for a draw (Chrome `is_frame_expected_after_discrete_input`). In the input's own turn, `InputResponsePass` applies every dirty person-caused observation and batch item before the CA commit. The state stays open until the end of the first link-tick render pass after the input. While it is open, automation, background and idle wait. Cap: 100 ms. | none | 002, 003, 206 |
| frame | springs, drags, the daemon drain up to the last person or frontend transaction, terminal frame holds (`FrameClient` default) | none, once per vsync | base |
| userBlocking | the async rest of a person's action: replies to person-scope commands, `.waiting` effect completions, a person-caused flush that missed the pass (Chrome kUserBlocking). It runs before visible, does not yield to its own input response, and closes that response when it commits. | the visible + automation shares, with a progress rule | 208 |
| visible | what a person sees that their input did not cause: program (PTY) changes, frontend changes, visible pages | 2.5 ms × scale | base, 201 |
| automation | anything caused by the CLI, MCP, agents, the socket or page automation | 1 ms × scale | base, 201 |
| background | work nobody sees this frame | 0.5 ms × scale | base, 201 |
| idle | `IdleScheduler`: long periods (up to 50 ms, after 50 ms of quiet) and short periods (2 ms or more left before vsync). Every idle task gets a deadline. | its deadline | 005 |

`MainWorkClass` has input, frame, visible, automation and background today; task 005 adds `.idle` and task 208
adds `.userBlocking`. The input-response pass is a state of `MainFrameBudget`, not a case.
`BudgetedWorkClass` (CmuxNextWakeups/BudgetedWorkClass.swift) holds the budgeted subset: visible, automation and
background (task 208 adds userBlocking). Every posting form takes a `BudgetedWorkClass`. Off the main thread, `WorkPriority` maps the classes onto
GCD QoS and Swift task priority ([threading-model.md](threading-model.md), "QoS and task priority").

## 2. Budget mechanics and progress rules

- `passTarget = refresh interval − 2 ms input reserve − the measured render pass` (task 201; today it is a fixed
  8 ms in `MainFrameBudget+Budgets.swift`). `RenderPassMeter` measures the render pass.
- Task 201 (spec'd): the budgeted batch will run in its own run-loop turn, right after the tick's commit: a
  CFRunLoopSource that `AfterFrameCommit` signals. Its deadline will be the next vsync minus the render estimate.
  So a tick turn will be drain + frame clients + render, and a budget turn at most the class shares. The setting
  `debug.scheduler.inTickBudget` will restore the in-tick path. Today the batch runs in the tick (section 14), and
  neither the source nor the setting exists.
- The budget protects a pending input and the frame. The class shares apply only while a key or a click is
  pending. With no input pending, a class past its share uses the frame time that the other classes left.
- **Progress rule, visible:** a class that yielded in one frame runs in the next frame.
- **Progress rule, automation and background:** for 500 ms after the last discrete input they run at least 1 task
  per 100 ms and at most 10 per second. Chrome waits 2 s; cmux uses less because agent and CLI requests have
  deadlines.
- `budget.shouldYield()` is true when input is pending, an input response is open, or the class share is spent
  (task 200). A long task checks it and continues with `postContinuation`.

## 3. Posting API (the only sanctioned ways to put work on main)

| Form | Use | Task (state) |
|---|---|---|
| `mainWork.post(_ workClass: BudgetedWorkClass, owner:, file: #fileID, line: #line) { }` | A main-thread task. FIFO within its class. The first post on an idle scheduler runs on the next turn if the class may run. `owner` is a `String` or an interned `MainTaskOwner`. | 001 (landed, MainWorkScheduler+Post.swift) |
| `mainWork.postFromAnyThread(_:owner:) { }` | The same, from any thread. | 001 (landed) |
| `node.queue(workClass, owner:, on: mainWork).post { }`, `.post(key:) { }` | A task of a hideable owner (`MainTaskQueue`). While the node is hidden, the queue holds visible and automation posts and coalesces them by key. A frozen node runs nothing. On deinit the queue drops its tasks: cmux owners are views that are gone (Blink keeps detached frame runners alive for JS). | 209 (landed, VisibilityNode.swift, MainTaskQueue.swift) |
| `mainWork.postIdle(owner:, maxDelay: nil) { deadline in }` | Idle work. `maxDelay` is opt-in; past it the task moves to background. | 005 (spec'd) |
| `mainWork.postContinuation(workClass, owner:)` | The rest of a task that yielded. It goes to the front of its class queue (`scheduler.yield` semantics). | 200 (spec'd) |
| `work.run(priority, mayBlock: lane) { }.reply(on: mainWork, class:, owner:) { value in }` | Off-main work with a main-thread reply (Chrome `PostTaskAndReply`). Main-actor callers use this form, not `await`, so the resume is not an unattributed job. | 001 (landed, BackgroundWork.swift) |
| `await mainWork.apply(workClass, owner:) { }` (typed throws: `try` when the body throws) | Only where the reply form does not fit. The caller's resume is still one unattributed job; say so in the code. | 001 (landed) |
| `MainDelivery(class:, owner:).run { }` | Delivery from a callback that is not Swift concurrency. Off-main delivery goes through `postFromAnyThread`; inline delivery is recorded on the board. Today `MainDelivery().run` has no class and hops with `DispatchQueue.main.async` (queue Q1c counts it). | 217 (spec'd) |
| a direct call | The synchronous change in the input's own turn. | - |

The scheduler's own timers (idle start, input-response cap, starvation check, coalescer fallback, reveal deadline)
are unposted `.precise` timers or run-loop observers. They never wait behind the classes they measure.

A post without a node by a hideable owner needs `// node-free: <why>` (task 209).

## 4. Startup phases (`StartupPhase`, CmuxNextWakeups/StartupPhase.swift, tasks 006, 007, 204)

| Phase | Starts | Runs |
|---|---|---|
| launching | at launch | input, frame, userBlocking, visible, automation. Background and idle are held. The off-main best-effort fence holds `WorkPriority.bestEffort` items in `BackgroundWork` and `LaneScheduler` (task 204). |
| revealed | at LaunchReveal's first frame, at a 1.5 s precise deadline, or at once when the app launches hidden or with no window | background, and the fence opens in FIFO order |
| settled | when a reference count reaches zero: first frame, first daemon snapshot applied, session restore done, the visible Chromium page load-idle (or no page). Failsafe: 10 s (Chrome: 3 min; cmux has no network-bound restore on the critical path). | idle |

`LaunchReveal` takes `onRevealed` by init. `AppDelegate` wires `markRevealed` and the settled references, one
injected closure per reference, with no new singleton (task 007). A Debug assertion fires when
`apply(.background)` or `postIdle` is awaited in launching.

## 5. Rendering starvation guard (task 004)

Starvation is: a frame-class client is active on a visible window, and the gap between its ticks is over 100 ms
(Chrome `kDefaultRenderingStarvationThreshold`). It never applies while the displays sleep or every window is
occluded. On starvation the scheduler gates every source it controls until the next tick: the budgeted and idle
classes, CEF pump slices past one per frame, deadlines routed through post, and the drain's automation tail. It
records `stall.render_starved` with the top unattributed turn from `MainTurnMeter`.

## 6. Attribution and hangs

- `MainTaskBoard` (CmuxNextWakeups/MainTaskBoard.swift) records owner, class, `posted_from`, node state, wait time
  and run time. `MainOwnerLedger` (CmuxNextWakeups/MainOwnerLedger.swift, task 009) folds the slots off main;
  `debug.main_budget owners` lists p50, p95, p99 and max per owner. A full ring counts `dropped` and never blocks.
- `MainTurnMeter` (CmuxNextWakeups/MainTurnMeter.swift, task 008) splits every busy run-loop turn into scheduled
  work, render, input dispatch and unattributed time. It attributes only the innermost nested turn (menu
  tracking, modal sessions, live resize, drag loops). It costs two clock reads per turn and no allocation.
  `debug.main_budget` adds `turn_ms`, `task_ms`, `unattributed_share` and `top_unattributed_turns`;
  `stall.main_turn` fires over 4 ms.
- Hang scopes per class (task 203, spec'd): input 100 ms, frame and userBlocking 50 ms, budgeted classes 16.7 ms, idle its
  deadline + 16.7 ms. Menu, modal and drag sessions invalidate them. A hang event carries owner, class, location
  and turn_ms, or `unattributed`.
- Main-actor jobs that the scheduler did not post (continuation resumes, the resume after `await apply`) stay FIFO
  on `DispatchQueue.main`. `MainTurnMeter`'s unattributed share is the proof of how much remains, not a grep
  count. `MainExecutorHook` (CmuxNextWakeups/MainExecutorHook.swift, task 202, spec'd, default off) is the spike that may
  give every main job a class from its task priority; its decision is recorded here when the gate runs.

## 7. Visibility tree (Chrome `content::Visibility`)

- `Visibility` (CmuxNextWakeups/Visibility.swift) is {visible, occluded, hidden}. `VisibilityNode`
  (CmuxNextWakeups/VisibilityNode.swift, task 020) has `effective` = min(own, parent). It keeps its children in two
  sets by their own state, so a parent flip visits only the children whose effective value can change.
- Subscribers get a call only on a flip. `node.isVisible` is O(1). `hiddenSince` drives the 5-minute rule.
  `mediaActiveWithin(30 s)` is Chrome's `kRecentAudioDelay`.
- `captureVote(reason:, stayHidden:)` (task 211, spec'd; today `setCaptured(_:)` is the one switch it will drive,
  and `setMediaActive(_:)` feeds `mediaActiveWithin`): the node renders (observers, frame clients) while page-visible
  signals and timer alignment can stay hidden (Chrome's capturer count). Agent screenshots and screencasts of a
  hidden tab, the iPhone browser host and Mac screen share take votes.
- The tree: app (NSApp hidden, screens asleep) > window (occlusion, miniaturized; `WindowVisibilitySource`,
  CmuxNextDesign/Windows/WindowVisibilitySource.swift, task 022, spec'd) > workspace (shown, companion, parked, off screen;
  `WorkspaceContentController`, task 023) > pane (suspended; `PaneController`, task 024) > tab (selected in a shown
  pane; `TabContentCache.node(for:)`, task 024) > sidebar row (viewport + 1 screen of overscan; `SidebarRowFeed`,
  task 040, spec'd). Task 024 (pane, tab) is landed. Task 023 (workspace) is spec'd: until it lands,
  `WorkspaceContentController.visibilityNode` is nil and `PaneController` hangs its node on a root node.
- `node.deferUntilVisible(key: k) { }` (task 020, landed) runs at once if the node is visible, else once on show.
  It replaces per-view hidden-dirty flags and heavy `viewDidChangeEffectiveAppearance` bodies. Task 215 (landed)
  adds `deferAppearance(owner:_:)` (counted in the root's `VisibilityWorkCounts`, `appearance_applies`),
  `deferUntilShown(key:_:)` for layout work (it runs at occluded too: an occluded node keeps its layout ready) and the
  first R-appear and R-hide adopters. TabStripView and TerminalSurfaceView follow their own child node, and their
  hidden flags are gone: a hidden strip's model sync, appearance and scale, and a hidden terminal's forced grid report,
  size and scale, wait on the node under a key each. The terminal's node has a child, `windowNode`, hidden while the
  view is in no window or a container above is parked, so the work waits on everything that hides it.
- **Show order** (task 213, spec'd). Observers on screen in the focused pane, and `firstFrame` subscribers, read again in
  the show turn. Other newly visible observers post one userBlocking task each, in viewport order, so they land in
  the next 1-2 frames. A `warm` vote (hover, the Ctrl-Tab target, neighbor tabs) reads again in idle without
  drawing.
- **Chromium** (task 212, spec'd, PL-cef-tab). Each CEF tab follows its tab node through the fork shim
  `cmux_shim_tab_set_visibility(browser, HIDDEN|OCCLUDED|VISIBLE)` → `WebContentsImpl::UpdateWebContentsVisibility`
  (task 212 adds the call to CmuxNextBrowser/CEF/CEFTab+Visibility.swift, which today only finds the page window). The freeze at `browser.freezeHiddenTabs` stays the second step. Without the shim
  the tab keeps today's behavior.
- **SwiftUI.** `VisibilityGatedHostingView` (CmuxNextDesign/VisibilityGatedHostingView.swift, task 214, spec'd) takes the
  hosting view out of the hierarchy while it is hidden (a snapshot layer stays) and puts it back in the show turn.
  Every tab-content hosting view uses it or opts out with a reason.
- **`WindowEvents` and `AppEvents`** (CmuxNextWakeups/WindowEvents.swift, AppEvents.swift, task 021, landed; owner
  PL-arch, architecture-refactor-DESIGN.md row B): one observer per window or app per notification name, made on the
  first subscriber and removed on the last (`NotificationFanOut`). `subscribe(name, node:, delivery:, owner:)` with
  an `EventDelivery` (EventDelivery.swift); a subscriber with no node uses `subscribe(name, owner:)`. A hidden subscriber
  gets one `missed` call on show.
- **Input observers.** `CmuxApplication.sendEvent` feeds one tap: `InputEventTap` (CmuxNextInput/InputEventTap.swift,
  p04-input-011, landed), with `subscribe(class:phase:window:while:handler:)`. It replaces the local event monitors,
  and the hook's `input-monitor` rule refuses a new monitor outside CmuxNextInput. Task 220 (`InputObserverHub`,
  spec'd) adds the node filter: only visible subscribers in the event's window run, and their time counts as
  input dispatch. It builds that filter on the tap. A second dispatcher in `sendEvent` is a P-rule violation
  (one shared implementation, [PATTERNS.md](PATTERNS.md)).

## 8. Observation primitives (F5: one observer per visible thing)

| Primitive | File | Use | Task (state) |
|---|---|---|---|
| `VisibleObservation(node, owner:, on: mainWork, read:, apply:)` | CmuxNextWakeups/VisibleObservation.swift | A view apply. It applies the first value in the call, then tracks with `withObservationTracking` (the same path on macOS 14-27) only while the node is visible. onChange marks it dirty; one apply per observer per frame, as one task on the node's `MainTaskQueue`. On hide a cancel signal ends the tracking; on show it reads again in the show order. | 025 (landed) |
| `ObservationCause`, `ObservationCauses` | CmuxNextWakeups/ObservationCause.swift | The cause order automation < program < frontend < person. `mainWork.causes` is the one `ObservationCauses`: `currentCause`, `withCause(_:_:)`, and the person-caused flushes that the input-response pass applies (`flushPersonCaused()`). | 025, 207 (landed) |
| `ServiceObservation(class, owner, read, apply)` | CmuxNextWakeups/ServiceObservation.swift | Anything that is not a view apply. The same tracking and coalescing, no node. The token cancels on release. | 026 (spec'd) |
| `StoreWaiters` | CmuxNextDaemon/Store/StoreWaiters.swift | Keyed O(1) waits on `DaemonStore` (`waitForTab`, `waitForWorkspace`, `waitLoaded`, `waitConnection`, `waitTabGone`). Each wait has a timeout on the main deadline queue (`AlignedWakeups`), with no Task or timer of its own. They replace predicate waits in `ObservationStream`. | 027 (landed) |
| `PageWaiters` | CmuxNextBrowser/Engine/PageWaiters.swift | `page.when(phase:)` and `page.whenPrompt(kind:)`, resumed by the state setters. | 028 (spec'd) |
| `MachineTabIndex` | CmuxNextDaemonService/MachineTabIndex.swift | O(1) `locateTab`, kept by `StoreIndex` hooks. | 051 (spec'd) |
| `ObservationLedger` | CmuxNextWakeups/ObservationLedger.swift | `debug.observations`: armed, evaluated and applied counts per owner, show re-reads, SwiftUI hosting body evaluations. Atomic, no lock on the hot path. | 029 (spec'd) |
| `AppearanceSignals` | CmuxNextDesign/AppearanceSignals.swift | One injected @Observable for reduceMotion, animation speed, hover cards and inactive dim. It replaces 4 notification names. | 043 (spec'd) |

A tracked observation is marked dirty with `currentCause` at its first change. Until that cause is person, it
re-arms in the same turn, so a later change raises the cause to the highest one seen. At flush time the class is
`ObservationCause.budgetedClass`: automation → automation, program, frontend and person → visible. A person-caused
flush is also queued for the input-response pass, which applies it before the commit; one the pass does not
reach runs in its visible task (userBlocking after task 208). This rule fixes "the first cause wins" when
automation and the person change the same property in one batch.

`ObservationStream` and `MainActorObservation` (CmuxNextCompat) stay for existing code until the sweeps replace
them. New code does not add them (guardrail `view-observation`).

## 9. Cause rules

**Daemon** (PL-daemon, tasks 030, 034, 035, 224-227; spec'd: at `4e0005673f2` event_emit.rs has no cause and the
envelope has no `"cause"` field, so the app decodes every event as `program`):

- `EventCause {Frontend, Program, Automation}` (cmux-tui-core/src/mux/event_emit.rs). The request dispatcher sets a
  scoped thread-local cause from `RequestOrigin` (request_origin.rs): User or verified_app → Frontend; Agent and
  Page → Automation. `Mux::emit` stamps the envelope `"cause"`. Pool jobs copy the cause when they are submitted.
  An unscoped emit (PTY output, OSC title and status, hooks, reaps) is Program. No `MuxEvent` variant changes.
- Coalescing keeps the highest cause: frontend > program > automation.
- Lock admission by class inside `SignaledMutex::lock`, `lock_state_pinned` and the registry connection lock:
  automation yields while a frontend caller waits, is admitted at least every 4 ms, and never waits while it holds
  another rank. 2 surface and resource worker permits are kept for verified-app connections.
- QoS: lock takers stay USER_INITIATED; automation work outside the locks runs at UTILITY and is raised while it
  holds a lock ([threading-model.md](threading-model.md)).
- Fan-out: scoped subscribers indexed by SurfaceId, `Arc<MuxEvent>`, published after the state guard drops,
  frontend mailbox first. Field events of hidden surfaces (`frontend.visibility.set`) wait on a 1 s aligned flush
  and flush at once on show; structural events pass at once.
- The cause is for scheduling only. Authorization code (origin_gate.rs, app_trust.rs) never reads it.

**App** (tasks 031, 032, 223, 207, 231; `FrameBatchQueue.enqueue(cause:_:)` and the input-response pass are landed,
the rest is spec'd):

- A `DaemonCommandScope` (CmuxNextDaemon/Connection/DaemonCommandScope.swift; today it scopes a control-socket
  action) opened by a person-entrypoint `ActionRegistry` run records its mutation_ids (bounded,
  2 s expiry). An echo with such an id is `person`; otherwise the decoded cause; a missing field is `program`.
  There is no new wire claim.
- `EventInbox` merges and its overflow resync keep the highest cause.
- The drain applies each envelope in `mainWork.causes.withCause(cause) { }`. A local intent apply is person.
- The frame-class drain applies every transaction up to and including the last person or frontend one, in order.
  The non-person tail is one ordered queue: one whole transaction per task, in its head's class, with a 2 ms
  slice. A resync or snapshot stays in the frame class. Read-your-writes waiters advance per transaction.
- `FrameBatchQueue.enqueue(cause:_:)`: person and frontend items drain unbudgeted; the others keep the class
  budget.
- Page relay: a request that the app's page bridge sends within 1 s of a real gesture in that page, with a
  mutation_id the app knows, is person. A single-use gesture token is the fallback only if the relay bypasses
  the app; that path is `risk:high`.
- The second and later automation-caused structural change per window in one frame snaps through the Motion gate
  (`Motion.panes.set`); the person's changes still animate (task 038).

## 10. Timers, input and page pushes

- **`MainDeadline`** (CmuxNextWakeups/MainDeadline.swift, `TimerAlignment` in TimerAlignment.swift, task 011,
  landed): `MainDeadline(owner:, workClass:, alignment: .flexible, scheduler: deadlines)`, @MainActor. Its wake is
  an entry of the main thread's one `MainWakeUpQueue` (MainWakeUpQueue.swift), placed through the app's
  `MainDeadlineScheduler` (MainDeadlineScheduler.swift). Its action runs through post, in its class, with its
  owner and the creating file and line. `schedule(after:)` resets, `scheduleIfIdle(after:)` keeps a pending one,
  `start(every:)` repeats, `cancel()` drops it also while its action waits in its class queue.
  - `.precise`: only for delays under 36 ms (Chrome `kDefaultMaxPreciseDelay`); a longer one falls back to
    flexible.
  - `.flexible` (the default): no sooner than the deadline, snapped up to the next 8 ms boundary (32 ms in Energy
    Saver) below 1 s, and to the whole uptime second from 1 s on (Chrome `kDefaultLeeway`, `kAlignWakeUps`).
  - `.whenHidden(node)`: 1 s boundaries while hidden. A repeating or self-re-arming deadline whose node has been
    hidden 5 minutes joins the node's wake-up budget: one wake a minute for the whole node, or one 1 s-aligned wake
    when the node had none in the last minute. No alignment within 30 s of media activity or while the node is
    captured.
  - Request and quit deadlines are flexible with no-sooner semantics. `MainDeadlineScheduler.nextFire` is the
    next-fire registry that the idle deadline reads (task 005).
- **`Deadline`** (CmuxNextWakeups/Deadline.swift, task 011, landed): the helper for timeouts in races
  (`Deadline(limit).run(label) { }`, `value(label) { }`, typed error `Deadline.Exceeded`).
- **`AlignedWakeups`** (CmuxNextWakeups/AlignedWakeups.swift, task 012, landed): `AlignedWakeups(queue:)` places a
  deadline on `MainWakeUpQueue`'s boundaries with a `Placement` (precise, flexible, hidden), so close deadlines
  share one wake. `DemandTimer` (DemandTimer.swift) stays for off-main deadlines; `schedule(after:tolerance:)` has
  a tolerance by default.
- **`CPUTimeBudgetPool`** (CmuxNextWakeups/CPUTimeBudgetPool.swift, task 210, spec'd): hidden-node work refills at
  10 ms per second with a 100 ms cap. Media and capture are exempt. Until it lands, a hidden node's deadlines have
  only the wake-up budget above.
- **`FrameInputCoalescer`** (CmuxNextWakeups/FrameInputCoalescer.swift, task 013, landed), one per window from
  `FrameInputCoalescers.coalescer(for:)` (FrameInputCoalescers.swift): `post(kind, owner:, sample:) { }` or
  `post(event, owner:) { }` runs at the frame tick before frame clients. A discrete
  event flushes pending continuous work first. A drag can opt into unbuffered delivery until mouseUp (`requestUnbufferedUntilPointerUp(owner:)`). A 1-frame
  fallback covers a missing tick.
- **`PageScriptPipeline`** (CmuxNextPages/PageScriptPipeline.swift; task 222, spec'd, changes it): one `receiveMany` evaluate per page per frame. A hidden page keeps the latest
  state envelope per subscription and a bounded FIFO for streams (overflow → resync), and flushes on show. Gate
  replies keep their turn.
- **Ghostty** (task 218, spec'd, PL-ghostty): the tick is the board task `ghostty.tick`, input class within one frame of a
  key to a terminal, frame class otherwise. High-rate actions (title, pwd, progress, mouse shape, cell size) keep
  the latest value per surface and kind per frame; a hidden surface applies them on show. Discrete actions (bell,
  exit, close, clipboard) keep FIFO order.
- **CEF events** (task 219, spec'd): title, URL, progress, favicon and status merge per browser per frame, visible class
  for a visible tab and background for a hidden one. Commits, dialogs, crashes and input ACKs stay FIFO and
  immediate.
- **CEF pump** (task 048, spec'd): slices run on the board as `cef.pump`, input class while a CEF view is first responder
  or has an unacked input, frame otherwise. Never deferred by an input response, never classed by visibility.

## 11. Recipes and guardrail escapes

The queue generator (`scripts/cmux-next/p06_queue.py`) maps each queue to one rule (its docstring: main-hop Q1, Q1b,
Q1c, Q7; view-observation Q2, Q3, Q10, Q11; raw-observer Q4; visibility-walk Q5, QA; timer-class Q6; local-monitor
Q8). The pre-push guardrails (`scripts/cmux-next/guardrails.py`, `MAIN_CLASS_RULES`, task 014, landed) refuse the
same six rules on added lines only. An escape is `// <rule>-allow: <why>` in the hook's escape window: the line,
the comment and attribute block directly above it, or the trailing comment of the code line before it. The reason
must prove why the code is correct; "not migrated yet" is not a reason.

Two older hook rules cover part of these queues, with their own escapes:

- `main-async` refuses an added `DispatchQueue.main.async` (`// main-async-allow: <the API that forces a GCD hop>`)
  and gives the R-hop fix. The hook's `main-hop` rule does not match `DispatchQueue.main.async`, but the queue
  counts it under main-hop (Q1c). So a `DispatchQueue.main.async` that must stay carries both escapes,
  `main-async-allow` for the hook and `main-hop-allow` for the queue.
- `input-monitor` refuses an added `addLocalMonitorForEvents` or `addGlobalMonitorForEvents` outside CmuxNextInput
  (`// input-monitor-allow: <why the tap cannot see this event>`). A monitor that must stay carries both escapes,
  `input-monitor-allow` and `local-monitor-allow`.

| Recipe | Queue | Do this | Guardrail rule (escape) |
|---|---|---|---|
| R-hop | Q1, Q1b, Q1c (raw hops), Q7 | Choose one: a synchronous change in the input's turn; `post(class, owner)`; `node.queue(...).post`; off-main work + `.reply(on:)`. For an async body: a nonisolated Task for the async part, and a reply or `apply` for the main part. | `main-hop` (`// main-hop-allow:`), only where AppKit order needs the hop (focus, menu tracking) |
| R-delivery | Q1c (`MainDelivery(`, `CFRunLoopPerformBlock`) | `MainDelivery(class:owner:)` (task 217; until then `MainDelivery().run` stays an open hit); `CFRunLoopPerformBlock` → `MainDelivery` or `AfterFrameCommit`. Done when `class:` is the first argument. | `main-hop` (`// main-hop-allow:`) |
| R-obs | Q2, Q3 | `VisibleObservation` for a view apply, `ServiceObservation` for anything else. Name the class and owner. | `view-observation` (`// view-observation-allow:`) |
| R-wait | Q10 | `StoreWaiters` or `PageWaiters`, with the same timeout. | `view-observation` (`// view-observation-allow:`) |
| R-index | Q11 | A per-object revision or `MachineTabIndex`. | `view-observation` (`// view-observation-allow:`) |
| R-notif | Q4 | A `WindowEvents` or `AppEvents` subscription with a node. NSView frame and bounds notices become the view's own `layout()` or `setFrameSize`. KVO on WebKit takes the tab node. | `raw-observer` (`// raw-observer-allow:`) |
| R-vis | Q5 (`isHiddenOrHasHiddenAncestor`) | `node.isVisible`. | `visibility-walk` (`// visibility-walk-allow:`), for hit-test and accessibility uses |
| R-hide | Q5 (`viewDidHide`, `viewDidUnhide`) | The override contains only `super.viewDidHide()` / `super.viewDidUnhide()` and `node.set(.hidden)` / `node.set(.visible)` for its own direction. Move hidden-dirty work out of the override into `node.deferUntilVisible(key:_:)` at the place that marks it dirty. | `visibility-walk` (`// visibility-walk-allow:`) |
| R-timer | Q6 | First make it an event (section "Sanctioned primitives" of [idle-wakeups.md](idle-wakeups.md)). Otherwise `MainDeadline` with class and alignment; sleeps in races use `Deadline`. Review every site by hand (rule 6). | `timer-class` (`// timer-class-allow:`) |
| R-input | Q8 (`mouseMoved`, `scrollWheel`, `mouseDragged` overrides) | cmux-side hover, cursor and drag-target work goes through `FrameInputCoalescer`; a forwarded event keeps its order and count. | `local-monitor` (`// local-monitor-allow:`) |
| R-monitor | Q8 (`addLocalMonitorForEvents`) | An `InputEventTap.subscribe(class:phase:window:while:handler:)` subscription (CmuxNextInput); a session monitor only while its session is active. Task 220 adds the node filter on the tap. | `local-monitor` (`// local-monitor-allow:`); the hook's `input-monitor` (`// input-monitor-allow:`) |
| R-appear | QA (`viewDidChangeEffectiveAppearance`) | A body that does more than set layer colors uses `deferUntilVisible`. | `visibility-walk` (`// visibility-walk-allow:`) |

`p06_queue.py --check N` counts the open hits of file group N; escapes and settled overrides (an R-hide, R-input or
R-appear body that does only what the recipe allows, an R-delivery with `class:`) are not open. The queue's R-hide
test is wider than the hook's: it also settles a hide override that calls any `node.` member or
`deferUntilVisible`, which the hook's `visibility-walk` rule refuses. Write the hook's form (the R-hide row). The queue
commands are spec section 6. The arch ratchet rows `main_inherited_tasks`, `raw_main_hops`,
`unscoped_observations`, `visibility_walks`, `unclassed_main_deadlines` and `local_event_monitors`
(`scripts/cmux-next/arch_counts.py`, `arch-ratchet.json`, task 015, spec'd) will hold the totals; until then
`p06_queue.py --check N` is the count. No CI gate, perf-gate row or CI test belongs to this program.

## 12. Frozen API

After task 205 lands, no public signature in CmuxNextWakeups changes without the Performance Lead's OK (spec rule
8): Wakeups is under most of the 98 targets, so a signature change rebuilds them. Changes inside the module are
free. The frozen surface, with its files (CmuxNextWakeups unless the path says otherwise). "Landed" means on
perf/chrome-parity at `4e0005673f2`; "spec'd" means the task has not landed and the name is the spec's interface.

| Type or member | File | Task | State |
|---|---|---|---|
| `MainWorkClass` (input, frame, visible, automation, background), `BudgetedWorkClass` (visible, automation, background) | MainWorkClass.swift, BudgetedWorkClass.swift | base | landed |
| `MainWorkClass.userBlocking`, `.idle`; `BudgetedWorkClass.userBlocking` | MainWorkClass.swift, BudgetedWorkClass.swift | 005, 208 | spec'd |
| `MainWorkScheduler.post(_:owner:file:line:_:)`, `postFromAnyThread(_:owner:file:line:_:)`, `apply(_:owner:file:line:_:)`, `causes`; `MainPostSite` | MainWorkScheduler+Post.swift, MainWorkScheduler.swift | 001, 025 | landed |
| `MainWorkScheduler.postContinuation`, `postIdle` | MainWorkScheduler+Post.swift | 200, 005 | spec'd |
| `BackgroundWork.run(_:mayBlock:shutdown:_:)` → `Pending.reply(on:class:owner:file:line:_:)` | BackgroundWork.swift | 001 | landed |
| `MainFrameBudget.noteDiscreteInput(expectsFrame:)`, `noteTickRenderEnded()` | MainFrameBudget.swift, MainFrameBudget+InputResponse.swift | 002 | landed |
| `MainFrameBudget.shouldYield()` | MainFrameBudget.swift | 200 | spec'd |
| `InputResponsePass` (`enqueue(owner:_:)`, `applyPersonCaused()`), `InputResponseRunLoop` | InputResponsePass.swift, InputResponseRunLoop.swift | 206 | landed |
| `IdleScheduler`, `IdleDeadline` | IdleScheduler.swift | 005 | spec'd |
| `StartupPhase` (`Phase`, `Reference`, `whenReached(_:_:)`, `markDone(_:)`, `admits(_:)`) | StartupPhase.swift | 006 | landed |
| `RenderStarvationGuard`, `RenderPassMeter` | RenderStarvationGuard.swift, RenderPassMeter.swift | 004, base | landed |
| `MainTaskBoard`, `MainTaskOwner`, `MainTaskPost` | MainTaskBoard.swift, MainTaskOwner.swift, MainTaskPost.swift | base, 001 | landed |
| `MainTurnMeter` | MainTurnMeter.swift | 008 | landed |
| `MainOwnerLedger` | MainOwnerLedger.swift | 009 | landed |
| `MainDeadline`, `MainDeadlineScheduler`, `TimerAlignment`, `Deadline` | MainDeadline.swift, MainDeadlineScheduler.swift, TimerAlignment.swift, Deadline.swift | 011 | landed |
| `MainWakeUpQueue`, `AlignedWakeups`; `DemandTimer.schedule(after:tolerance:)` | MainWakeUpQueue.swift, AlignedWakeups.swift, DemandTimer.swift | 011, 012 | landed |
| `FrameInputCoalescer`, `FrameInputCoalescers` | FrameInputCoalescer.swift, FrameInputCoalescers.swift | 013 | landed |
| `Visibility`, `VisibilityNode` (`effective`, `isVisible`, `hiddenSince`, `mediaActiveWithin(_:)`, `setCaptured(_:)`, `subscribe(owner:_:)`, `deferUntilVisible(key:_:)`, `queue(_:owner:on:)`, `freeze()`) | Visibility.swift, VisibilityNode.swift | 020, 209 | landed |
| `VisibilityNode.deferAppearance(owner:_:)`, `VisibilityNode.deferUntilShown(key:_:)`, `VisibilityWorkCounts`; the first R-appear and R-hide adopters (TabStripView, TerminalSurfaceView) | VisibilityNode.swift, VisibilityWorkCounts.swift, TabStripView.swift, TerminalSurfaceView+Visibility.swift | 215 | landed |
| `VisibilityNode.captureVote(reason:stayHidden:)` | VisibilityNode.swift | 211 | spec'd |
| `MainTaskQueue` | MainTaskQueue.swift | 209 | landed |
| `CPUTimeBudgetPool` | CPUTimeBudgetPool.swift | 210 | spec'd |
| `WindowEvents`, `AppEvents`, `EventDelivery` | WindowEvents.swift, AppEvents.swift, EventDelivery.swift | 021 | landed |
| `VisibleObservation`, `ObservationCause`, `ObservationCauses` | VisibleObservation.swift, ObservationCause.swift | 025, 207 | landed |
| `ServiceObservation` | ServiceObservation.swift | 026 | spec'd |
| `ObservationLedger` | ObservationLedger.swift | 029 | spec'd |
| `MainDelivery(class:owner:)` (today `MainDelivery()` with no class) | MainDelivery.swift | 217 | spec'd |
| `InputEventTap` (the input tap that task 220's node filter builds on) | CmuxNextInput/InputEventTap.swift | p04-input-011 | landed |
| `InputObserverHub` (the node filter) | InputObserverHub.swift | 220 | spec'd |
| `MainExecutorHook` (`install()`, `isRequested(feature:environment:)`, `workClass(priority:inInputTurn:)`, `stats`); `MainWorkScheduler.installMainExecutorHook(requested:)` (default off, decision-gated, section 17) | MainExecutorHook.swift, MainWorkScheduler.swift | 202 | landed (off) |
| The budget turn (a CFRunLoopSource that `AfterFrameCommit` signals) and the setting `debug.scheduler.inTickBudget` | AfterFrameCommit.swift, MainWorkScheduler.swift | 201 | spec'd |
| `StoreWaiters` (the waits are `DaemonStore.waitForTab`, `waitForWorkspace`, `waitLoaded`, `waitConnection`, `waitTabGone`) | CmuxNextDaemon/Store/StoreWaiters.swift | 027 | landed |
| `PageWaiters` | CmuxNextBrowser/Engine/PageWaiters.swift | 028 | spec'd |
| `MachineTabIndex` | CmuxNextDaemonService/MachineTabIndex.swift | 051 | spec'd |
| `WindowVisibilitySource` | CmuxNextDesign/Windows/WindowVisibilitySource.swift | 022 | spec'd |
| `VisibilityGatedHostingView` | CmuxNextDesign/VisibilityGatedHostingView.swift | 214 | spec'd |
| `AppearanceSignals` | CmuxNextDesign/AppearanceSignals.swift | 043 | spec'd |
| `ChildPageGeometryRegistry` | CmuxNextBrowser/CEF/ChildPageGeometryRegistry.swift | 046 | spec'd |
| `FrontendVisibilityReporter` | CmuxNextApp/Visibility/FrontendVisibilityReporter.swift | 227 | spec'd |

When a spec'd task lands, its commit changes its row to landed and corrects the signature here.

The DocC on each public declaration is the reference for its signature. Task 205 records the pilot's before and
after numbers (unattributed share, key to frame, observations, with sha and host) in
[perf-lead.md](perf-lead.md) section 5, the place that section 15 names.

## 13. Chrome sources (chromium.googlesource.com, main)

A task that copies a constant reads the source again and quotes it in its commit.

| Topic | Source | What cmux takes |
|---|---|---|
| Typed UI-thread queues, startup gating | `content/browser/scheduler/browser_task_queues.h`; `base::TaskPriority` in `docs/threading_and_tasks.md` | the classes; kUserBlocking above kUserVisible; best-effort only after `OnStartupComplete()` |
| Selection | `base/task/sequence_manager/task_queue_selector.h` | strictly the highest class first, oldest first within a class |
| Attribution, typed runners, per-frame queues | `FROM_HERE` / `posted_from`; `third_party/blink/renderer/platform/scheduler/TaskSchedulingInBlink.md` | `posted_from`; a class is a required argument; per-node queues with voters; `PostTaskAndReply` → `.reply(on:)` |
| Input response, rendering starvation | `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.h` (`kDiscreteInputResponse`, `kDefaultRenderingStarvationThreshold = 100 ms`, `kEndIdleWhenHiddenDelayMillis = 10000`) | the input-response state; the starvation guard; idle stops 10 s after hide |
| Idle tasks | `third_party/blink/renderer/platform/scheduler/common/idle_helper.h` | short and long idle periods (1-50 ms), a deadline per task, nested posts wait |
| Hidden pages | `third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.h` (`kRecentAudioDelay = 30 s`); `content/public/browser/visibility.h`; `WebContents::IncrementCapturerCount` | 1 s alignment; the 5-minute rule; the CPU-time pool; {visible, occluded, hidden}; capture votes |
| Timers | `base/task/delay_policy.h`, `base/task/task_features.h` (`kDefaultLeeway = 8 ms`, `kAlignWakeUps`, `kTimerSlackMac`, `kDefaultMaxPreciseDelay = 36 ms`) | `.flexible` and `.precise` |
| Continuous input | `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.h` (`WebCoalescedInputEvent`, `DispatchRafAlignedInput`, `ShouldFlushQueue`, `needs_low_latency_until_pointer_up_`) | `FrameInputCoalescer` |
| Frames | `cc/scheduler/scheduler.h` | one frame per vsync; deadline = interval − draw estimate |
| Hangs | `base/threading/hang_watcher.h` (`WatchHangsInScope`, `InvalidateActiveExpectations`) | per-scope deadlines; reports without a crash; menu and modal sessions invalidate |
| Startup | `chrome/browser/after_startup_task_utils.cc`; `ThreadPoolInstance::BeginBestEffortFence` (`base/task/thread_pool/thread_pool_instance.h`) | the settled reference count with a failsafe; the off-main best-effort fence |
| Locks | `docs/threading_and_tasks.md` ("Usage of locks is discouraged in Chrome") | sequences instead of locks |

Where cmux goes further: automation (CLI, MCP, agents, socket) is a cause below the person in the app and in the
daemon, with per-client fairness. Chrome schedules extensions with no class of their own.

## 14. Pieces at the base

These pieces exist before p06 (at `772cdfc45ac`). The sections above extend them; they do not replace them.

- `MainWorkScheduler` (one per app, built by `AppDelegate`, the composition root, and passed by init to the control
  socket, `AppServices`, every `DaemonService` and the watchdog; no shared instance): the `MainFrameBudget` and the
  one display link budgeted batches tick on, so the budget's window opens once per real frame (never once per tick
  of each window's link). While that link exists its ticks own the window: a request outside any tick never opens
  one, and a tick within one refresh period of a window a request opened on an idle app keeps it, so one run loop
  pass never gets two budgets. A drain that leaves work re-arms on its queue directly (`scheduleFrameFromMain`),
  never through a run loop hop that lands after the tick, so the link stays up for the whole backlog. Budgeted
  clients and queues take it in their init and never fall back to another scheduler. The Cloud, SSH and server
  services get it by init from `AppServices`.
- `MainFrameBudget`: `mayRun(class)`, `run(class, owner:)` (nested tasks are charged as themselves; the owner is a
  `MainTaskOwner` interned on the board when the queue or method is built, so a task start takes no lock),
  `beginFrame` at each tick, stats for `debug.main_budget` (`idle_tasks`: tasks run on idle time past the share).
  At the base the scheduled work per frame is 4 ms in all (visible 2.5, automation 1, background 0.5) and stops at
  8 ms minus the longest render pass that `RenderPassMeter` measured (never above 4 ms; the first task of a class
  still runs). Task 201 replaces this with the refresh-scaled target in section 2.
- `FrameScheduler.deliver`: frame clients first, then (on the budgeted scheduler) budgeted clients in class order
  while their class may run, the client that ran least recently first (round-robin, so one saturating client never
  starves the others of its class); a held client stays active and ticks next frame.
- `FrameBatchQueue` / `FrameBatcher`: a frame queue runs all its work every frame as plain calls (no per-item task
  bookkeeping); a budgeted one drains one task at a time and keeps the rest, in order. Task 010 moved the
  three batchers outside the budget window onto it; the frame queue's `scheduler: = .app` default is still there.
- `MainActorWorkQueue` (CmuxNextControl/Concurrency/MainActorWorkQueue.swift): requests are automation tasks under
  the shared budget, FIFO within a connection (injected input included). An injected key at the head of its
  connection runs on the next run loop turn, ahead of other connections, and makes every budgeted class yield
  while it waits (`MainTaskBoard` count); each input turn runs only the input queued before it, and input counts in
  the per-connection limit.
- `DaemonStore.drain`: a frame-class batcher (`DaemonService.drainScheduler`, a frame client on the
  `MainWorkScheduler`'s link, so it ticks before the budgeted classes of the same frame) applies everything
  buffered as one batch, never split across frames. The batch holds the echoes of the person's own actions, and
  most actions have no intent (close other tabs, close a workspace, duplicate, move to a new window, reopen), so
  the echo is when the change first shows. Its cost is what changed: the inbox coalesces whole-value surface
  events (title, size, scroll, agent presence). Workspace, screen, pane and tab deltas carry consecutive revisions
  and agent statuses are transitions; they are never coalesced. A snapshot applies only what differs
  (SnapshotDiff). Task 223 splits the non-person tail out of the frame class (section 9).
- `CommitBoundary` (CmuxNextSignposts/CommitBoundary.swift): a one-shot observer at order 2,000,001, right after the
  CA commit of the same turn. `InputResponsePass` installs its observer at order 1,000,000 (`InputResponsePass.order`): after default-order
  observers, before AppKit's display cycle and the CA commit (2,000,000). Never at `CommitBoundary.order − 1`,
  because an observer added later at the same order as CA's commit runs after it.
- Pending input (`SessionInputPending`, behind the `SessionInputEvents` seam; `WindowServerInputEvents` in the app,
  a fake in SessionInputPendingTests): the window server's time of the last key-down or mouse-button event against
  the last such event AppKit dispatched in this app. Mouse moves and scroll are left out (they stream and would
  starve batches); an undispatched event stops counting after two 60 Hz frames.
- Watchdog (`MainThreadWatchdog.attach(board:)`): every stall record names the scheduled task its sample caught
  (`task_owner`, `task_class`, `task_budget_ms`, `task_started_ms`). Only the explicit task diagnostics mode
  (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`) also records each task that ran past its class budget, with a stack sampled
  when it crossed the budget (`debug.hangs` `over_budget`): it wakes the watchdog per task and suspends the main
  thread per over-budget task, so it perturbs bench numbers and is never on for a measured run.
  Signposts `stall.main_task` (every task; not mirrored to MetricKit) and `stall.over_budget`.

## The posting API, to freeze after the pilot (p06-scheduler-205)

Section 12 is the frozen surface; this section is what the pilot uses of it and how its DocC is checked.

plans/cmux-next/chrome-parity/p06-scheduler.md section 3 and rule 8. **Not frozen yet.** The task order is: migrate
the pilot, bench it, record the numbers, then freeze. The bench (below, "Not measured yet") has not run, so the
API below is the proposed frozen set, not a frozen one. When the pilot numbers are recorded and no worse, from then
on no public signature in CmuxNextWakeups changes without the Performance Lead's OK; changes inside the package are
internal only, because a public change rebuilds most of the 98 targets.

Every public and open declaration of CmuxNextWakeups has a DocC comment (a protocol witness such as `==` or
`description` takes its doc from the protocol). `python3 scripts/cmux-next/p06_queue.py --undocumented` lists any
that has none and exits 1; `tests/test_p06_queue.py` runs it over the tree (a local test, not CI).

| Need | API | File |
|---|---|---|
| Run main work in a class, with an owner and its posting site | `mainWork.post(_:owner:file:line:_:)`, `postFromAnyThread(_:owner:file:line:_:)`, `await mainWork.apply(_:owner:file:line:_:)` | `MainWorkScheduler+Post.swift` |
| Off-main work, then its main part | `BackgroundWork.run(...).reply(on:class:owner:file:line:_:)`; async work: `BackgroundWork.task(_:shutdown:_:)`, then `postFromAnyThread` | `BackgroundWork.swift`, `BackgroundWork+Task.swift` |
| A node's work, held while it is hidden or frozen, keyed | `node.queue(_:owner:on:)` then `post(key:_:)` / `post(_:)` | `VisibilityNode.swift`, `MainTaskQueue.swift` |
| Visibility of a window, workspace, pane, tab, row | `VisibilityNode`, `Visibility`, `subscribe(owner:_:)`, `deferUntilVisible(key:_:)` | `VisibilityNode.swift`, `Visibility.swift` |
| Follow the model for a view | `VisibleObservation(node, owner:on:read:apply:)` | `VisibleObservation.swift` |
| Follow the model for a service (side effects run while hidden) | `ServiceObservation(class, owner:on:read:apply:)` | `ServiceObservation.swift` (task 026) |
| A main-thread deadline | `MainDeadline(owner:workClass:alignment:scheduler:)` on the app's one `MainDeadlineScheduler` (`AppServices.mainDeadlines`) | `MainDeadline.swift`, `MainDeadlineScheduler.swift`, `TimerAlignment.swift` (task 011) |
| A time limit raced against async work | `Deadline(limit).run(label:onTimeout:_:)` | `Deadline.swift` (task 011) |
| A window or app notification | `WindowEvents.of(window).subscribe(...)`; the injected `AppEvents` (`AppServices.appEvents` for the default center, `AppServices.workspaceEvents` for NSWorkspace's) `.subscribe(...)` | `WindowEvents.swift`, `AppEvents.swift` (task 021) |
| Wait for the store to list a tab or workspace, to load or to connect | `store.waitForTab(...)`, `waitForWorkspace(...)`, `waitLoaded(timeout:)`, `waitConnection(...)` | `CmuxNextDaemon/Store/StoreWaiters.swift` (task 027) |
| An off-main deadline | `DemandTimer` (main-actor code uses `MainDeadline`) | `DemandTimer.swift` |

Not landed yet, so they join the set with the Performance Lead's OK when their tasks land: `postIdle`
(IdleScheduler, task 005), `postContinuation` and `shouldYield` (task 200), the `userBlocking` class and
`MainDelivery(class:owner:)`. A wait on something that is not the store (a window's pane mount) is a
`ServiceObservation` whose apply ends the wait (`AgentChatPaneWait`).

**Merge order.** The pilot uses `ServiceObservation` (task 026) in about ten files. It is on perf/chrome-parity
now (`CmuxNextWakeups/ServiceObservation.swift`), and this branch has merged that tip in.

## The pilot (p06-scheduler-205)

The pilot directories take every recipe before the file-group sweeps start: `CmuxNextApp/Notifications/`,
`CmuxNextApp/AgentCursor/`, `AgentActivityPageService.swift` and `AgentActivityLineConnection.swift`. The new
types go to their domain packages, not the App: `StatusRunFollower` and `NotificationsPanelLedgerWatch` to
CmuxNextBridge, `AgentChatPaneWait` (the pane wait `AgentActivityPageService` runs) to CmuxNextAgentActivity.

| What | Recipe | After |
|---|---|---|
| The service's `Task { for await ObservationStream }` loops (arrivals, Dock badge, settings, viewed tabs, feed, permission bridge, ledger seed, status runs) | R-obs | `ServiceObservation`: a burst of changes is one apply and one posted flush per frame, in its class (arrivals, Dock badge, settings, viewed tabs and ledger seed `visible`; status runs (`cmux status`) `automation`; feed and permission bridge `background`). Each change still re-arms the tracking with one read of `read` in its own turn (`ServiceObservation` rule 2) |
| Finished-run follower (500 per-workspace tasks and an AsyncStream) | R-obs | a `StatusRunFollower` token that owns one `ServiceObservation` of the workspace set and one per workspace, still O(changed workspace) per change; releasing or cancelling it stops all of them |
| Held OSC 7501 alert: a `DemandTimer` and a `Task` loop | R-timer, R-obs | `MainDeadline` (visible, flexible) and a `ServiceObservation` of the tab's records |
| `timeout` dismissals | R-timer | `MainDeadline` (visible, flexible) |
| Banner clicks and authorization replies (`Task { @MainActor }` from the center's threads) | R-hop | `postFromAnyThread`: a click `visible`, an authorization `background` |
| Approval answers (Allow once and Deny on a banner, a Chief hand's banner) | R-hop | the async answer is a `BackgroundWork.task(.userBlocking)`; what follows on main (the note, reading or opening the tab) is `postFromAnyThread(.visible)`. The answerers (`AgentApprovalAnswering`, `HandsService.answer`) are main-actor async in their own packages; their own hops are those packages' file groups |
| Ledger replies (`await MainActor.run`) | R-hop | `postFromAnyThread(.visible)` |
| Notifications panel ledger watch | R-obs | `NotificationsPanelLedgerWatch`: the panel's open makes its node visible, loads once and follows the ledger through a `VisibleObservation` on the node; its close stops the observation and hides the node, so a closed panel reads nothing |
| Panel and row appearance changes | R-appear | `deferUntilVisible` on the panel's node |
| Agent cursor window and Space notices (5 + 1 `addObserver`, a `Task` per notice) | R-notif, R-hop | `WindowEvents` per cmux window and `AppServices.workspaceEvents` for the Space; one coalesced re-resolve posted in `automation` |
| Agent cursor window state loop | R-obs | `ServiceObservation(.automation)` |
| Agent cursor target lookup (`locateTab` and a walk of every workspace) | R-index | three index lookups in the tab's own store |
| An input to a target this window does not list (`elsewhere`) | (hidden draws nothing) | no cursor command; a cursor that leaves is hidden once |
| An input to a target this window lists but does not show (`hidden(anchor:)`, a background workspace or tab) | (hidden draws nothing) | the first input puts the indicator on the anchor; later ones apply nothing unless the anchor moved or half the indicator's 10 s idle fade passed since it was last put (`AgentCursorOverlayModel.indicatorNeedsApply`) |
| Agent activity pane wait | R-wait | `AgentChatPaneWait`, a `ServiceObservation(.userBlocking)` (the person waits for the chat they picked) whose apply ends the wait |

**A design decision on the cursor acceptance.** The spec's "100 cursor updates for a hidden workspace give 0
applies" is met for a target the window does not list. For a target it lists but does not show, the pilot keeps
the indicator on the sidebar row or tab chip, so the person sees where the agent works: 100 inputs within 5 s give
one `.indicate`, and a long run gives one per 5 s (each `.indicate` restarts the idle fade and rebuilds the
window's tag links). Zero would let the indicator fade after 10 s while the agent keeps working there.

Kept, with a reviewed escape: the CUA one-shot's request deadline (`timer-class-allow`: it is off main, where
`DemandTimer` is the deadline). `p06_queue.py` judges as the R-notif target a notice name passed straight to a
`subscribe(` (the hook's raw-observer rule, `guardrails.raw_observer_in`), and the workspace center handed to
`AppEvents(center:` in the composition root (`AppServices.swift`) only.

**Old task 037's agent-activity half is file group 341's.** The agent activity line stream reaches main through
`AgentActivitySocketSource.swift` and `AgentActivityModel.swift` (CmuxNextAgentActivity: 3 open Q1b R-hop hits and
1 open Q1 hit at the time of writing), which are in group 341's files, not in this task's. Group 341 moves that
delivery to the automation class (`postFromAnyThread(.automation, owner: "agent-activity.lines")` or a
`ServiceObservation(.automation)`); 205 does not claim it. 205 took the agent cursor half of 037 and the pane wait.

Numbers. Queue hits in the pilot files (`p06_queue.py` scan, open = not escaped and not settled), on
cmux-orchestrator-1 (Linux, no build):

| | sha | open hits | escaped | settled |
|---|---|---|---|---|
| before | `12685b2d219` (perf/chrome-parity) | 43 | 0 | 0 |
| after | `6340ec3455c` (cp/p06-scheduler-205) | 0 | 1 | 7 |

**Not measured yet, so 205 is not done and the API is not frozen.** The test phase on one fleet GUI host with the
input grant, both sides on the same host and session, at the base sha and at the head sha, records here with both
shas and the host: the unattributed share (`debug.main_budget` `unattributed_share`), key to frame p50/p95/p99
(`sidebar-churn-typing.py --input real` and `automation-typing-bench.py`, light and STRESS;
`automation-typing-bench.py` has no `--input` flag yet, so its keys are `debug.key` stand-ins and are quoted as
such), the per-owner task counts and wait and run times of the `notifications.*`, `agent-cursor.*` and
`agent-activity.*` owners (`debug.main_budget` owner ledger), and idle wakeups (`scripts/bench_idle.py`). The
freeze and the fan-out (the file-group sweeps) start only when those numbers show the pilot is no worse.

## 15. Proof

`scripts/cmux-next/sidebar-churn-typing.py --input real` (terminal typing with real HID-tap keys, idle and while a
CLI storm reorders the sidebar and changes statuses; `debug.key` does not take a person's path and is never quoted
as key latency), `automation-typing-bench.py --input real` (task 230) and `bench_cli_storm.py` (throughput before
and after), light and STRESS, on a GUI host with the input grant that passes `bench_launch.py check`, at 120 Hz
(`--vdisplay=120`). The program's targets are the spec's section 5 done checks (key to frame p50 <= 8.3 ms and
p99 <= 16.7 ms during the storm; every run-loop turn p99 <= 4 ms). Results: perf-lead.md section 5. The pilot's
numbers (task 205) and the test phase (task 160, "p06 scheduler test phase": before and after per done check, and
the instrument each check needs) are recorded there with sha and host.

## 16. Queue close-out counts (task 347, open)

Task 347 is not done. Its first pass is a partial residual sweep only: it migrated the residual hits that no
in-flight task holds. Its acceptance ("every done-check ratchet count is at its target") is not met, and
`arch-ratchet.json` is not updated. The task stays open until file groups 300-346 land. Then it migrates the
hits that are left, places `layer_hard` and `layer_unplaced` (or gives them a reviewed exception), runs
`arch-ratchet.py --update`, commits `arch-ratchet.json` and replaces the table below with counts at target.

The spec's section 5 check 11, measured at `6061b2d824b` (perf/chrome-parity `17f2e8b9979` plus task 347) with
`p06_queue.py`'s queues: "open" is a hit with no reviewed escape that is not settled (section 11). The cut is
`772cdfc45ac`. The Q1b row uses the queue's heuristic, because `main_inherited_tasks` (task 015) has not landed.

| Count | Cut | Now: open (escaped) | Target |
|---|---|---|---|
| `main_inherited_tasks` (Q1 + Q1b) | 480 + 778 | 221 + 441 (50 + 62) | <= 10 reviewed escapes |
| `raw_main_hops` (Q1c) | 53 | 23 (16) | <= 5 outside Wakeups |
| `MainActor.run` (Q7) | 69 | 15 (0) | <= 10 |
| `ObservationStream(` (Q2) | 297 | 131 (1), 16 in `*View*.swift` | <= 20, none in `*View*.swift` |
| raw `withObservationTracking` (Q3) | 58 | 11 (7) | <= 5, in the primitives |
| Q4 observer kinds | 263 | 105 (50; 60 settled) | <= 12 |
| `isHiddenOrHasHiddenAncestor` | 159 | 97 | <= 10 |
| gating `viewDidHide`/`viewDidUnhide` | 54 | 27 | 0 |
| `DemandTimer(` (all, main-actor and off-main) | 187 | 143 | 0 on the main actor without MainDeadline |
| periodic `Task.sleep`/`clock.sleep` | 76 | 35 | 0 |
| `addLocalMonitorForEvents` | 32 | 0 | 1 (the hub) |
| `didUpdateNotification` | 3 | 0 | 0 |
| `app_broadcast_names` (arch_counts) | 13 | 3 | <= 2 |
| `observer_sites` (arch_counts) | 340 | 235 | <= 40 |

The counts are not at target yet, because 25 of the 47 file groups have not landed: their files hold 1,373 of the
open hits (`p06_queue.py --check N` for 300, 303, 304, 309, 322, 325 and 328-346). The landed groups' files hold none.
After task 347, `p06_queue.py --residual` lists 42 hits:

- 40 in the Notifications and AgentCursor pilot files of task 205, which are on `cp/p06-scheduler-205` and not landed.
- 2 in `CmuxNextHibernation/ContentDiscardScheduler.swift`: its `DemandTimer` deadline and the main-actor task that
  awaits the host's `prepareDiscard`. Its six discard suites drive the deadline with a `ManualClock`, so the move to
  a `MainDeadline` on a rig is its own task.

`arch-ratchet.py --update` refuses at this head, because of rises that are not from this program: `layer_hard` 34 over
33 and `layer_unplaced` 2 (`CmuxNextAppCore`, `CmuxNextUiLayerPreview` are not in `architecture-layers.json`). Run
it again when those are placed or carry a reviewed exception; it then records the drops above.

## 17. Priority-ordered main executor (task 202, decision gate)

**What it is.** `MainExecutorHook` (CmuxNextWakeups/MainExecutorHook.swift) takes
`swift_task_enqueueMainExecutor_hook` and puts each main-actor job in one of five FIFO classes by its task's
priority. A run-loop source on the main run loop runs them in the common modes (Chrome's
`MessagePumpCFRunLoopBase::work_source_`, `base/message_loop/message_pump_apple.mm`), highest class first and oldest
first within a class (`base/task/sequence_manager/task_queue_selector.h`).

The classes follow the spec's mapping (p06-scheduler.md, task 202):

| Job | Class |
|---|---|
| enqueued by the main thread while a discrete input's dispatch is open (`MainWorkScheduler.noteDiscreteDispatch`) | `input` |
| `.high` (userInitiated) and above (a `Task {}` made on main inherits the main thread's user-interactive QoS) | `visible` |
| `.medium`, or no priority (the runtime's default; a `Task {}` made on a default-QoS socket or daemon thread) | `automation` |
| `.low` (utility) | `background` |
| `.background` | `idle` (the lowest FIFO: it runs only when no other class holds a job; no idle deadline) |

A pass runs only the jobs queued before it began (each job gets a sequence number; the pass takes the next one as its
cutoff), at least one. A job that a job of the pass enqueues waits for a later pass, whatever its class. After the
first job the pass stops before any job below `input` while the person's input is pending (the budget's
`SessionInputPending` and the board's injected-input count, checked at most every 250 us).

A pass never signals its source again. An observer of the main run loop's before-waiting and exit stages, at
`MainRunLoopObserver.lastOrder` (after Core Animation's commit at 2000000 and AppKit's observers), signals the next
pass when work is queued. A source0 signaled from inside its own pass would keep `__CFRunLoopRun` polling
(`sourceHandledThisLoop`), and polling skips the before-waiting observers: a steady stream of main-actor jobs would
hold back the commit. So every two passes have the commit and those observers between them, however fast work
arrives. `MainExecutorHookTests.runLoopObserversRunBetweenPassesUnderAStreamOfJobs` runs the real main run loop under
a self-renewing stream of jobs and checks it. An enqueue while no pass waits for those observers signals at once.

**Switch.** Feature `mainExecutorHook` (perfPath, default off on every channel), installed once by the composition
root (`CmuxNextApp.swift`). `CMUX_MAIN_EXECUTOR_HOOK=1` turns it on for one launch, and `0` keeps it off even when the
feature is on. In a test process launched with `CMUX_MAIN_EXECUTOR_HOOK=1`, the first `MainWorkScheduler` installs it.
Main-actor jobs before that first scheduler run on the main dispatch queue, so suites that run earlier do not go
through the hook. The hook word is taken only when it is free. The p04-input MainJobGate (021/076) and
the p08 main-job census (080) want the same word: the first install wins and the others report `busy`.

**The gate.** Each step runs with the hook on, on macOS 26, 27, 14 and 15:

1. `CMUX_MAIN_EXECUTOR_HOOK=1` fleet full `swift test`.
2. `os-matrix.sh --os 14,15` for the two older versions.
3. `automation-typing` STRESS, with the hook on and off.

`MainExecutorHookTests.runtimeJobsRunInOrderThroughTheInstalledHook` checks real runtime jobs. In the gate's run it
makes a scheduler first (so the hook is installed whatever order the suites run in) and requires
`MainExecutorHook.installed`: a `missing` or `busy` install fails it. Then a utility task's six jobs go through the
hook's `background` class, `assumeIsolated` and `dispatchPrecondition(.onQueue(.main))` hold, and the task's jobs keep
their order.

- **If it passes:** queues Q1, Q1b and Q7 shrink to "give the task the right priority". The main-hop guardrail can then
  accept a `Task(priority:)` with a stated priority.
- **If it fails:** record the failing suite and why here. The R-hop rewrite plan stays.

**Decision: open.** The gate has not run. Until it passes, the R-hop rewrite plan stays, and no code depends on the
hook. These risks were found while building it. Each gate run checks them:

- **Priority inversion on escalation.** A queued job keeps the class it was queued with. When a high-priority waiter
  escalates a low task, the runtime may not enqueue it again on this executor. Its waiting job stays in
  `background` until the classes above it drain. Pending input holds every class below `input` (a pass then runs one
  job at most, plus input jobs), so the wait is not bounded by this hook: it lasts while higher classes keep jobs
  queued or the person's input stays pending.
- **Medium is automation.** The spec's mapping puts `.medium` and no priority below `visible`. A main-actor job that
  shows something to the person and was started from a default-QoS thread without a stated priority now waits for
  `visible` work. The gate's STRESS run checks that no visible update starves.
- **Nested run loops.** The main dispatch queue does not drain inside a nested run loop that a main-queue block
  started: a menu or a modal opened from a main-actor job. CFRunLoop can call this source again inside a nested
  run loop, so other main-actor jobs can run there. Code that counted on them waiting until the menu closes changes
  behavior.
- **Hosts that never run the main CFRunLoop.** If the main thread runs `dispatchMain()` and never runs the main
  CFRunLoop, the jobs wait forever. AppKit and XCTest run the run loop. A Swift Testing host that does not run it
  fails the gate at once (a time-limit failure, not a wrong result).
- **Order against non-Swift main work.** `MainRunLoopBlock`, `CFRunLoopPerformBlock` and GCD main blocks no longer
  share one FIFO with main-actor jobs. A test or a caller that queued both and expected arrival order sees them in
  pass order instead.
- **Strict class order.** Background and idle jobs can wait for as long as higher classes keep work queued. This is the
  selector's rule, and the budget's progress rule does not cover these jobs.
