# cmux next: the main-thread budget and scheduler (2026-10-23, contract 2026-10-25)

Lawrence 2026-10-23: "there's lag in the terminal whenever a lot of CLI operations are going on, like reordering
of the sidebar." Measured by PL-typing (cmux8s, macOS 27, 60 Hz): a key's own work is under 2 ms, but key to frame
is 30-50 ms idle and 160-400 ms under load; the time is the wait for the main thread (send to dispatch 8-286 ms
under load) and the display cycle's layer-tree build. Owner: PL-main (cmux-4f, perf-lead.md).

This file is the contract for main-thread work. The program that builds it is p06-scheduler
([chrome-parity/p06-scheduler.md](chrome-parity/p06-scheduler.md), "the spec" below). The "Task" column names
the p06 task that lands each piece. A piece whose task is not on the branch yet is the spec'd interface; write
against it. Section 14 describes the pieces that exist at the base.

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
| input | AppKit event dispatch, injected keys (`debug.key`, `debug.view_key`), `InputObserverHub` subscribers | none | base, 220 |
| input-response pass | A state with a pass, not a queue. A discrete input opens it only when the turn expects a frame: the `ActionEffect` is `.applied`, `.intentEffect` or `.waiting`, a view asked for display, or Ghostty asked for a draw (Chrome `is_frame_expected_after_discrete_input`). In the input's own turn, `InputResponsePass` applies every dirty person-caused observation and batch item before the CA commit. The state stays open until the end of the first link-tick render pass after the input. While it is open, automation, background and idle wait. Cap: 100 ms. | none | 002, 003, 206 |
| frame | springs, drags, the daemon drain up to the last person or frontend transaction, terminal frame holds (`FrameClient` default) | none, once per vsync | base |
| userBlocking | the async rest of a person's action: replies to person-scope commands, `.waiting` effect completions, a person-caused flush that missed the pass (Chrome kUserBlocking). It runs before visible, does not yield to its own input response, and closes that response when it commits. | the visible + automation shares, with a progress rule | 208 |
| visible | what a person sees that their input did not cause: program (PTY) changes, frontend changes, visible pages | 2.5 ms × scale | base, 201 |
| automation | anything caused by the CLI, MCP, agents, the socket or page automation | 1 ms × scale | base, 201 |
| background | work nobody sees this frame | 0.5 ms × scale | base, 201 |
| idle | `IdleScheduler`: long periods (up to 50 ms, after 50 ms of quiet) and short periods (2 ms or more left before vsync). Every idle task gets a deadline. | its deadline | 005 |

`BudgetedWorkClass` (CmuxNextWakeups/BudgetedWorkClass.swift) holds the budgeted subset: userBlocking, visible,
automation and background (task 208 adds userBlocking). Off the main thread, `WorkPriority` maps the classes onto
GCD QoS and Swift task priority ([threading-model.md](threading-model.md), "QoS and task priority").

## 2. Budget mechanics and progress rules

- `passTarget = refresh interval − 2 ms input reserve − the measured render pass` (task 201; today it is a fixed
  8 ms in `MainFrameBudget+Budgets.swift`). `RenderPassMeter` measures the render pass.
- The budgeted batch runs in its own run-loop turn, right after the tick's commit: a CFRunLoopSource that
  `AfterFrameCommit` signals. Its deadline is the next vsync minus the render estimate. So a tick turn is drain +
  frame clients + render, and a budget turn is at most the class shares. The setting
  `debug.scheduler.inTickBudget` restores the in-tick path (task 201).
- The budget protects a pending input and the frame. The class shares apply only while a key or a click is
  pending. With no input pending, a class past its share uses the frame time that the other classes left.
- **Progress rule, visible:** a class that yielded in one frame runs in the next frame.
- **Progress rule, automation and background:** for 500 ms after the last discrete input they run at least 1 task
  per 100 ms and at most 10 per second. Chrome waits 2 s; cmux uses less because agent and CLI requests have
  deadlines.
- `budget.shouldYield()` is true when input is pending, an input response is open, or the class share is spent
  (task 200). A long task checks it and continues with `postContinuation`.

## 3. Posting API (the only sanctioned ways to put work on main)

| Form | Use | Task |
|---|---|---|
| `mainWork.post(_ workClass:, owner:, file: #fileID, line: #line) { }` | A main-thread task. FIFO within its class. The first post on an idle scheduler runs on the next turn if the class may run. | 001 |
| `mainWork.postFromAnyThread(...)` | The same, from any thread. | 001 |
| `node.queue(workClass, owner:).post { }` | A task of a hideable owner. While the node is hidden, the queue holds visible and automation posts and coalesces them by key. A frozen node runs nothing. On deinit the queue drops its tasks: cmux owners are views that are gone (Blink keeps detached frame runners alive for JS). | 209 |
| `mainWork.postIdle(owner:, maxDelay: nil) { deadline in }` | Idle work. `maxDelay` is opt-in; past it the task moves to background. | 005 |
| `mainWork.postContinuation(workClass, owner:)` | The rest of a task that yielded. It goes to the front of its class queue (`scheduler.yield` semantics). | 200 |
| `BackgroundWork.run { }.reply(on: mainWork, class:, owner:)` | Off-main work with a main-thread reply (Chrome `PostTaskAndReply`). Main-actor callers use this form, not `await`, so the resume is not an unattributed job. | 001 |
| `await mainWork.apply(workClass, owner:) { }` | Only where the reply form does not fit. The caller's resume is still one unattributed job; say so in the code. | 001 |
| `MainDelivery(class:, owner:)` | Delivery from a callback that is not Swift concurrency. Off-main delivery goes through `postFromAnyThread`; inline delivery is recorded on the board. | 217 |
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
- Hang scopes per class (task 203): input 100 ms, frame and userBlocking 50 ms, budgeted classes 16.7 ms, idle its
  deadline + 16.7 ms. Menu, modal and drag sessions invalidate them. A hang event carries owner, class, location
  and turn_ms, or `unattributed`.
- Main-actor jobs that the scheduler did not post (continuation resumes, the resume after `await apply`) stay FIFO
  on `DispatchQueue.main`. `MainTurnMeter`'s unattributed share is the proof of how much remains, not a grep
  count. `MainExecutorHook` (CmuxNextWakeups/MainExecutorHook.swift, task 202, default off) is the spike that may
  give every main job a class from its task priority; its decision is recorded here when the gate runs.

## 7. Visibility tree (Chrome `content::Visibility`)

- `Visibility` (CmuxNextWakeups/Visibility.swift) is {visible, occluded, hidden}. `VisibilityNode`
  (CmuxNextWakeups/VisibilityNode.swift, task 020) has `effective` = min(own, parent). It keeps its children in two
  sets by their own state, so a parent flip visits only the children whose effective value can change.
- Subscribers get a call only on a flip. `node.isVisible` is O(1). `hiddenSince` drives the 5-minute rule.
  `mediaActiveWithin(30 s)` is Chrome's `kRecentAudioDelay`.
- `captureVote(reason:, stayHidden:)` (task 211): the node renders (observers, frame clients) while page-visible
  signals and timer alignment can stay hidden (Chrome's capturer count). Agent screenshots and screencasts of a
  hidden tab, the iPhone browser host and Mac screen share take votes.
- The tree: app (NSApp hidden, screens asleep) > window (occlusion, miniaturized; `WindowVisibilitySource`,
  CmuxNextDesign/Windows/WindowVisibilitySource.swift, task 022) > workspace (shown, companion, parked, off screen;
  `WorkspaceContentController`, task 023) > pane (suspended; `PaneController`, task 024) > tab (selected in a shown
  pane; `TabContentCache.node(for:)`, task 024) > sidebar row (viewport + 1 screen of overscan; `SidebarRowFeed`,
  task 040).
- `node.deferUntilVisible(key) { }` (task 215) runs at once if the node is visible, else once on show. It replaces
  per-view hidden-dirty flags and heavy `viewDidChangeEffectiveAppearance` bodies.
- **Show order** (task 213). Observers on screen in the focused pane, and `firstFrame` subscribers, read again in
  the show turn. Other newly visible observers post one userBlocking task each, in viewport order, so they land in
  the next 1-2 frames. A `warm` vote (hover, the Ctrl-Tab target, neighbor tabs) reads again in idle without
  drawing.
- **Chromium** (task 212, PL-cef-tab). Each CEF tab follows its tab node through the fork shim
  `cmux_shim_tab_set_visibility(browser, HIDDEN|OCCLUDED|VISIBLE)` → `WebContentsImpl::UpdateWebContentsVisibility`
  (`CEFTab+Visibility.swift`). The freeze at `browser.freezeHiddenTabs` stays the second step. Without the shim
  the tab keeps today's behavior.
- **SwiftUI.** `VisibilityGatedHostingView` (CmuxNextDesign/VisibilityGatedHostingView.swift, task 214) takes the
  hosting view out of the hierarchy while it is hidden (a snapshot layer stays) and puts it back in the show turn.
  Every tab-content hosting view uses it or opts out with a reason.
- **`WindowEvents` and `AppEvents`** (CmuxNextWakeups/WindowEvents.swift, AppEvents.swift, task 021, owner PL-arch,
  architecture-refactor-DESIGN.md row B): one observer per window or app per notification name, made on the first
  subscriber and removed on the last. `subscribe(name, node, delivery: .whenVisible/.always)`. A hidden subscriber
  gets one `missed` call on show.
- **`InputObserverHub`** (CmuxNextWakeups/InputObserverHub.swift, task 220): `CmuxApplication.sendEvent` calls it
  once. It replaces the local event monitors. Subscriptions are by mask, window and node; only visible subscribers
  in the event's window run. Its time counts as input dispatch.

## 8. Observation primitives (F5: one observer per visible thing)

| Primitive | File | Use | Task |
|---|---|---|---|
| `VisibleObservation(node, owner, read, apply)` | CmuxNextWakeups/VisibleObservation.swift | A view apply. It applies the first value in the call, then tracks with `withObservationTracking` (the same path on macOS 14-27) only while the node is visible. onChange marks it dirty; one apply per observer per frame. On hide a cancel signal ends the tracking; on show it reads again in the show order. | 025 |
| `ObservationCause` | CmuxNextWakeups/ObservationCause.swift | The scheduler's `currentCause` and `personCauseEpoch`. | 025 |
| `ServiceObservation(class, owner, read, apply)` | CmuxNextWakeups/ServiceObservation.swift | Anything that is not a view apply. The same tracking and coalescing, no node. The token cancels on release. | 026 |
| `StoreWaiters` | CmuxNextDaemon/Store/StoreWaiters.swift | Keyed O(1) waits on `DaemonStore` (`waitForTab`, `waitForWorkspace`, `waitLoaded`, `waitConnection(where:)`, `waitTabGone`), with injected-clock timeouts. They replace predicate waits in `ObservationStream`. | 027 |
| `PageWaiters` | CmuxNextBrowser/Engine/PageWaiters.swift | `page.when(phase:)` and `page.whenPrompt(kind:)`, resumed by the state setters. | 028 |
| `MachineTabIndex` | CmuxNextDaemonService/MachineTabIndex.swift | O(1) `locateTab`, kept by `StoreIndex` hooks. | 051 |
| `ObservationLedger` | CmuxNextWakeups/ObservationLedger.swift | `debug.observations`: armed, evaluated and applied counts per owner, show re-reads, SwiftUI hosting body evaluations. Atomic, no lock on the hot path. | 029 |
| `AppearanceSignals` | `AppearanceSignals.swift` in CmuxNextDesign | One injected @Observable for reduceMotion, animation speed, hover cards and inactive dim. It replaces 4 notification names. | 043 |

A tracked observation's class at flush time is `person` when `personCauseEpoch` moved after the observer became
dirty. Otherwise it is the recorded cause: frontend or program → visible, automation → automation. Person flushes
run in the input-response pass, or as userBlocking when no response is open. This rule fixes "the first cause
wins" when automation and the person change the same property in one batch.

`ObservationStream` and `MainActorObservation` (CmuxNextCompat) stay for existing code until the sweeps replace
them. New code does not add them (guardrail `view-observation`).

## 9. Cause rules

**Daemon** (PL-daemon, tasks 030, 034, 035, 224-227):

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

**App** (tasks 031, 032, 223, 207, 231):

- A `DaemonCommandScope` opened by a person-entrypoint `ActionRegistry` run records its mutation_ids (bounded,
  2 s expiry). An echo with such an id is `person`; otherwise the decoded cause; a missing field is `program`.
  There is no new wire claim.
- `EventInbox` merges and its overflow resync keep the highest cause.
- The drain sets `currentCause` per envelope and bumps `personCauseEpoch` on a person apply. A local intent apply
  is person.
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

- **`MainDeadline`** (CmuxNextWakeups/MainDeadline.swift, `TimerAlignment` in TimerAlignment.swift, task 011):
  @MainActor, with owner, class, alignment and node. Its action runs through post.
  - `.precise`: only for delays under 36 ms (Chrome `kDefaultMaxPreciseDelay`); a longer one falls back to
    flexible.
  - `.flexible` (the default): 8 ms leeway, 8 ms buckets, `tolerance:` passed to the sleep (Chrome
    `kDefaultLeeway`, `kAlignWakeUps`).
  - `.whenHidden(node)`: 1 s boundaries while hidden. A repeating or self-re-arming timer moves to 60 s after
    5 minutes hidden, with one 1 s-aligned wake allowed per minute. No alignment within 30 s of media activity or
    under a capture vote.
  - Request and quit deadlines are flexible with no-sooner semantics. A next-fire registry feeds the idle
    deadline.
- **`Deadline`** (CmuxNextWakeups/Deadline.swift, task 011): the helper for timeouts in races.
- **`AlignedWakeups`** (CmuxNextWakeups/AlignedWakeups.swift, task 012): one sleep per boundary bucket (1 s hidden,
  8 ms visible flexible). `DemandTimer` stays for off-main deadlines and gains `tolerance:`.
- **`CPUTimeBudgetPool`** (CmuxNextWakeups/CPUTimeBudgetPool.swift, task 210): hidden-node work refills at 10 ms
  per second with a 100 ms cap. Media and capture are exempt.
- **`FrameInputCoalescer`** (CmuxNextWakeups/FrameInputCoalescer.swift, task 013), one per window:
  `post(kind:, owner:) { latest, coalesced, delta in }` runs at the frame tick before frame clients. A discrete
  event flushes pending continuous work first. A drag can opt into unbuffered delivery until mouseUp. A 1-frame
  fallback covers a missing tick.
- **`PageScriptPipeline`** (task 222): one `receiveMany` evaluate per page per frame. A hidden page keeps the latest
  state envelope per subscription and a bounded FIFO for streams (overflow → resync), and flushes on show. Gate
  replies keep their turn.
- **Ghostty** (task 218, PL-ghostty): the tick is the board task `ghostty.tick`, input class within one frame of a
  key to a terminal, frame class otherwise. High-rate actions (title, pwd, progress, mouse shape, cell size) keep
  the latest value per surface and kind per frame; a hidden surface applies them on show. Discrete actions (bell,
  exit, close, clipboard) keep FIFO order.
- **CEF events** (task 219): title, URL, progress, favicon and status merge per browser per frame, visible class
  for a visible tab and background for a hidden one. Commits, dialogs, crashes and input ACKs stay FIFO and
  immediate.
- **CEF pump** (task 048): slices run on the board as `cef.pump`, input class while a CEF view is first responder
  or has an unacked input, frame otherwise. Never deferred by an input response, never classed by visibility.

## 11. Recipes and guardrail escapes

The pre-push guardrails (`scripts/cmux-next/guardrails.py`, task 014) judge added lines only. The queue generator
(`scripts/cmux-next/p06_queue.py`) uses the same rule per queue. An escape is `// <rule>-allow: <why>` in the
hook's escape window: the line, the comment and attribute block directly above it, or the trailing comment of
the code line before it. The reason must prove why the code is correct; "not migrated yet" is not a reason.

| Recipe | Queue | Do this | Guardrail rule (escape) |
|---|---|---|---|
| R-hop | Q1, Q1b, Q1c (raw hops), Q7 | Choose one: a synchronous change in the input's turn; `post(class, owner)`; `node.queue(...).post`; off-main work + `.reply(on:)`. For an async body: a nonisolated Task for the async part, and a reply or `apply` for the main part. | `main-hop` (`// main-hop-allow:`), only where AppKit order needs the hop (focus, menu tracking) |
| R-delivery | Q1c (`MainDelivery(`, `CFRunLoopPerformBlock`) | `MainDelivery(class:owner:)`; `CFRunLoopPerformBlock` → `MainDelivery` or `AfterFrameCommit`. Done when `class:` is the first argument. | `main-hop` (`// main-hop-allow:`) |
| R-obs | Q2, Q3 | `VisibleObservation` for a view apply, `ServiceObservation` for anything else. Name the class and owner. | `view-observation` (`// view-observation-allow:`) |
| R-wait | Q10 | `StoreWaiters` or `PageWaiters`, with the same timeout. | `view-observation` (`// view-observation-allow:`) |
| R-index | Q11 | A per-object revision or `MachineTabIndex`. | `view-observation` (`// view-observation-allow:`) |
| R-notif | Q4 | A `WindowEvents` or `AppEvents` subscription with a node. NSView frame and bounds notices become the view's own `layout()` or `setFrameSize`. KVO on WebKit takes the tab node. | `raw-observer` (`// raw-observer-allow:`) |
| R-vis | Q5 (`isHiddenOrHasHiddenAncestor`) | `node.isVisible`. | `visibility-walk` (`// visibility-walk-allow:`), for hit-test and accessibility uses |
| R-hide | Q5 (`viewDidHide`, `viewDidUnhide`) | The override only forwards to the node (`super`, `node.…`, `deferUntilVisible`); hidden-dirty flags become `deferUntilVisible`. | `visibility-walk` (`// visibility-walk-allow:`) |
| R-timer | Q6 | First make it an event (section "Sanctioned primitives" of [idle-wakeups.md](idle-wakeups.md)). Otherwise `MainDeadline` with class and alignment; sleeps in races use `Deadline`. Review every site by hand (rule 6). | `timer-class` (`// timer-class-allow:`) |
| R-input | Q8 (`mouseMoved`, `scrollWheel`, `mouseDragged` overrides) | cmux-side hover, cursor and drag-target work goes through `FrameInputCoalescer`; a forwarded event keeps its order and count. | `local-monitor` (`// local-monitor-allow:`) |
| R-monitor | Q8 (`addLocalMonitorForEvents`) | An `InputObserverHub` subscription; a session monitor only while its session is active. | `local-monitor` (`// local-monitor-allow:`) |
| R-appear | QA (`viewDidChangeEffectiveAppearance`) | A body that does more than set layer colors uses `deferUntilVisible`. | `visibility-walk` (`// visibility-walk-allow:`) |

`p06_queue.py --check N` counts the open hits of file group N; escapes and settled overrides (an R-hide, R-input or
R-appear body that does only what the recipe allows, an R-delivery with `class:`) are not open. The queue
commands are spec section 6. The arch ratchet rows `main_inherited_tasks`, `raw_main_hops`,
`unscoped_observations`, `visibility_walks`, `unclassed_main_deadlines` and `local_event_monitors`
(`scripts/cmux-next/arch_counts.py`, `arch-ratchet.json`, task 015) hold the totals. No CI gate, perf-gate row or
CI test belongs to this program.

## 12. Frozen API

After task 205 lands, no public signature in CmuxNextWakeups changes without the Performance Lead's OK (spec rule
8): Wakeups is under most of the 98 targets, so a signature change rebuilds them. Changes inside the module are
free. The frozen surface, with its files (CmuxNextWakeups unless the path says otherwise):

| Type or member | File | Task |
|---|---|---|
| `MainWorkClass` (+ `.userBlocking`, `.idle`), `BudgetedWorkClass` | MainWorkClass.swift, BudgetedWorkClass.swift | 005, 208 |
| `MainWorkScheduler.post`, `postFromAnyThread`, `apply`, `postContinuation`, `postIdle`, `currentCause`, `personCauseEpoch` | MainWorkScheduler+Post.swift | 001, 005, 200, 025 |
| `BackgroundWork.run{}.reply(on:class:owner:)` | BackgroundWork.swift | 001 |
| `MainFrameBudget.noteDiscreteInput(expectsFrame:)`, `noteTickRenderEnded()`, `shouldYield()` | MainFrameBudget.swift | 002, 200 |
| `InputResponsePass` | InputResponsePass.swift | 206 |
| `IdleScheduler`, `IdleDeadline` | IdleScheduler.swift | 005 |
| `StartupPhase` | StartupPhase.swift | 006 |
| `MainTurnMeter` | MainTurnMeter.swift | 008 |
| `MainOwnerLedger` | MainOwnerLedger.swift | 009 |
| `MainDeadline`, `TimerAlignment`, `Deadline` | MainDeadline.swift, TimerAlignment.swift, Deadline.swift | 011 |
| `AlignedWakeups`; `DemandTimer(tolerance:)` | AlignedWakeups.swift, DemandTimer.swift | 012 |
| `FrameInputCoalescer` | FrameInputCoalescer.swift | 013 |
| `Visibility`, `VisibilityNode` (`effective`, `isVisible`, `hiddenSince`, `mediaActiveWithin(_:)`, `subscribe(owner:)`, `deferUntilVisible(key:)`, `captureVote(reason:stayHidden:)`, `queue(_:owner:)`) | Visibility.swift, VisibilityNode.swift | 020, 209, 211, 215 |
| `MainTaskQueue` | MainTaskQueue.swift | 209 |
| `CPUTimeBudgetPool` | CPUTimeBudgetPool.swift | 210 |
| `WindowEvents`, `AppEvents` | WindowEvents.swift, AppEvents.swift | 021 |
| `VisibleObservation`, `ObservationCause`, `ServiceObservation` | VisibleObservation.swift, ObservationCause.swift, ServiceObservation.swift | 025, 026 |
| `ObservationLedger` | ObservationLedger.swift | 029 |
| `MainDelivery(class:owner:)` | MainDelivery.swift | 217 |
| `InputObserverHub` | InputObserverHub.swift | 220 |
| `MainExecutorHook` (default off, decision-gated) | MainExecutorHook.swift | 202 |
| `StoreWaiters` | CmuxNextDaemon/Store/StoreWaiters.swift | 027 |
| `PageWaiters` | CmuxNextBrowser/Engine/PageWaiters.swift | 028 |
| `MachineTabIndex` | CmuxNextDaemonService/MachineTabIndex.swift | 051 |
| `WindowVisibilitySource` | CmuxNextDesign/Windows/WindowVisibilitySource.swift | 022 |
| `VisibilityGatedHostingView` | CmuxNextDesign/VisibilityGatedHostingView.swift | 214 |
| `ChildPageGeometryRegistry` | CmuxNextBrowser/CEF/ChildPageGeometryRegistry.swift | 046 |
| `FrontendVisibilityReporter` | CmuxNextApp/Visibility/FrontendVisibilityReporter.swift | 227 |

The DocC on each public declaration is the reference for its signature. Task 205 records the pilot's before and
after numbers (unattributed share, key to frame, observations, with sha and host) in section 15.

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
  bookkeeping); a budgeted one drains one task at a time and keeps the rest, in order. Task 010 removes the
  `scheduler: = .app` default and the three batchers outside the budget window.
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
  CA commit of the same turn. `InputResponsePass` installs its observer at `CommitBoundary.order − 1`.
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

## 15. Proof

`scripts/cmux-next/sidebar-churn-typing.py --input real` (terminal typing with real HID-tap keys, idle and while a
CLI storm reorders the sidebar and changes statuses; `debug.key` does not take a person's path and is never quoted
as key latency), `automation-typing-bench.py --input real` (task 230) and `bench_cli_storm.py` (throughput before
and after), light and STRESS, on a GUI host with the input grant that passes `bench_launch.py check`, at 120 Hz
(`--vdisplay=120`). The program's targets are the spec's section 5 done checks (key to frame p50 <= 8.3 ms and
p99 <= 16.7 ms during the storm; every run-loop turn p99 <= 4 ms). Results: perf-lead.md section 5. The pilot's
numbers (task 205) and the test phase (task 160) are recorded there with sha and host.
