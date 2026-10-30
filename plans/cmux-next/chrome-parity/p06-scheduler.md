# p06-scheduler: one main-thread scheduler on the Blink/Chrome model

Program owner: Performance Lead (PL-main). Checkout: `perf/chrome-parity` at `772cdfc45ac`
(origin/feat-cmux-next). Push window: 72 hours, hundreds of agents, one branch.

This is the final spec, after the fixer applied the three adversarial reviews. Section 9 records
what happened to each review item. Every count in this file is from `git grep` at `772cdfc45ac`,
with `///` lines excluded, unless the text says "approximate".

Summary of the program:

- One scheduler owns all main-thread work. Every task has a class and an owner, and is attributed
  to a source location.
- The classes are input > input-response pass > frame > userBlocking > visible > automation >
  background > idle.
- A visibility tree (app > window > workspace > pane > tab > row) decides what runs. Hidden things
  update the model only, and Chromium is also told that they are hidden.
- One observer per visible thing (F5).
- Every daemon event carries a cause. Automation never competes with the person, in the app or in
  the daemon.
- Timers have classes, leeway and hidden alignment. Idle tasks get deadlines, and startup phases
  gate best-effort work.
- About 2,700 queue hits in about 1,130 files are migrated by about 48 machine-generated file-group
  tasks. Each file is touched once, with every recipe applied.

---

## 1. Chrome reference

The design and the three reviews cited these sources on chromium.googlesource.com (main). A task
that copies a constant must read the source again and quote it in its commit.

1. **Typed task queues on the browser UI thread.** `content/browser/scheduler/browser_task_queues.h`
   defines these queue types:
   - kBestEffort ("only execute if there's nothing else to do"; it can be starved)
   - kUserVisible ("not an immediate response to a user interaction")
   - kUserBlocking ("affect the UI immediately after a user interaction"), which runs above
     kUserVisible
   - kUserInput, which runs above kUserBlocking and changes the priority of yielding to native work
   - kNavigationNetworkResponse
   - kMainFrameNavigationNetworkResponse
   - kBeforeUnloadBrowserResponse
   - kStartup

   A control queue has the maximum priority. Every queue has a `QueueEnabledVoter`. "All queues are
   initially disabled". `EnableAllExceptBestEffortQueues()` runs before `RunLoop::Run`, and
   best-effort work starts only at `OnStartupComplete()`. `base::TaskPriority` (USER_BLOCKING,
   USER_VISIBLE, BEST_EFFORT; `docs/threading_and_tasks.md`) maps onto these queues.
2. **Selection.** `base/task/sequence_manager/task_queue_selector.h` keeps an O(1) highest pending
   priority (ActivePriorityTracker). It runs the strictly highest priority first, and the oldest
   task first within one priority. Starvation protection exists only between immediate and delayed
   work (`kMaxDelayedStarvationTasks = 3`).
3. **Attribution.** Every task carries `posted_from` (`FROM_HERE`). In Blink,
   `TaskSchedulingInBlink.md` says that `blink::TaskType` is a required argument of
   `GetTaskRunner()`, and `GetCurrentDefault` is banned in `blink/` and `content/renderer/`. Tasks
   "should be associated with a frame to allow the scheduler to freeze or prioritise individual
   frames": each FrameScheduler owns throttleable, freezable and pausable queues behind voters.
   `PostTaskAndReply` posts the reply on the caller's typed runner. Deferrable tasks wait 2 s after
   a user gesture, "as it's very likely that another gesture will arrive soon".
4. **Input response and rendering starvation.**
   `main_thread/main_thread_scheduler_impl.h` has these rules:
   - `UseCase::kDiscreteInputResponse` ("waiting for the subsequent paint") and
     `RenderingPrioritizationState::kWaitingForInputResponse` start only when
     `is_frame_expected_after_discrete_input`. The NEXT frame then runs at input priority.
   - `kRenderingStarved` begins after `kDefaultRenderingStarvationThreshold = 100 ms` without a
     frame. Chrome then RAISES the compositor priority ("prioritize the next frame, but don't block
     input"), and also holds other work back.
   - `kEndIdleWhenHiddenDelayMillis = 10000`.
5. **Idle tasks.** `common/idle_helper.h` has short idle periods between frames and long idle
   periods of 1 to 50 ms. Each idle task gets a deadline, and a task posted from an idle task waits
   for the next period. requestIdleCallback has an OPTIONAL timeout and no default.
6. **Hidden pages pay almost nothing.** `page_scheduler_impl.h` has these rules:
   - wake-ups of hidden frames align to 1 s
   - after 5 min hidden, intensive throttling allows 1 wake-up per minute, but it applies only to
     JS timers, and a 1 s-aligned wake-up is still allowed if none happened in the last minute
   - there are separate wake-up budget pools and a CPU-time budget pool
   - `kRecentAudioDelay = 30 s`: "A page cannot be throttled or frozen 30 seconds after playing
     audio"

   `content/public/browser/visibility.h` defines {VISIBLE, OCCLUDED, HIDDEN}. NSWindow occlusion
   feeds `WasOccluded` and `WasHidden`. Hidden comes first; freezing (performance_manager freezing
   policy) comes later. `WebContents::IncrementCapturerCount(stay_hidden)` keeps a hidden page
   rendering for capture.
7. **Timers.** `base/task/delay_policy.h` and `task_features.h` give these rules:
   - flexible delayed tasks get `kDefaultLeeway = 8 ms`
   - `kAlignWakeUps` aligns wake-ups to 8 ms
   - `kTimerSlackMac` applies on Mac
   - only `kPrecise` tasks under `kDefaultMaxPreciseDelay = 36 ms` stay exact
8. **Continuous input.** `main_thread_event_queue.h`:
   - Continuous events merge into one, and their deltas add up (`WebCoalescedInputEvent`,
     getCoalescedEvents). They are sent at the frame (`DispatchRafAlignedInput`).
   - Discrete events are sent at once. `ShouldFlushQueue` sends pending continuous events first.
   - `needs_low_latency_until_pointer_up_` switches to unbuffered delivery.
   - A fallback timer covers the case where no BeginMainFrame comes.
9. **Frames.** `cc/scheduler` sends one BeginFrame per vsync, and sets its deadline from the frame
   interval minus the estimated draw time. Animation runs on the compositor thread.
10. **Hangs.** `base/threading/hang_watcher.h`:
    - Deadlines are per scope (`WatchHangsInScope`, default 10 s) and per THREAD TYPE, not per task
      type.
    - A hang is reported with `DumpWithoutCrashing`.
    - `InvalidateActiveExpectations` covers waits on user input.
11. **Startup.** `after_startup_task_utils.cc` uses a reference count (paint, idle, restore, the
    visible page load-idle) with a 3 min failsafe. The thread pool holds a best-effort fence
    (`BeginBestEffortFence`) until startup ends.
12. **Locks.** `docs/threading_and_tasks.md` says: "Usage of locks is discouraged in Chrome.
    Sequences inherently provide thread-safety."

**Where cmux goes further.** Automation (CLI, MCP, agents, socket) is a first-class cause below the
person, in the app AND in the daemon, with per-client fairness. Chrome schedules extensions with
no class of their own.

---

## 2. cmux today (772cdfc45ac)

**What exists (PL-main, `plans/cmux-next/main-thread-budget.md`, `Sources/CmuxNextWakeups/`):**

- `MainWorkClass` (input > frame > visible > automation > background) and `BudgetedWorkClass`.
- `MainFrameBudget`: visible 2.5 ms, automation 1 ms and background 0.5 ms per frame.
  `passTarget` is fixed at 8 ms (`MainFrameBudget+Budgets.swift:39`) and does not change with the
  refresh rate. The class shares yield to `SessionInputPending`. A class that yielded in one frame
  runs in the next one (the progress rule).
- `MainWorkScheduler` (one link for budgeted work), `MainTaskBoard`, `FrameScheduler` (one
  CADisplayLink per window), `FrameBatchQueue`, `DemandTimer` and `WorkPriority`.
- `RenderPassMeter` times the beforeWaiting phase.
- `CommitBoundary`: a one-shot observer at order 2,000,001, right after the CA commit of the SAME
  turn (`CmuxNextSignposts/CommitBoundary.swift:41`).
- `MainActorWorkQueue` handles control requests in the automation class.
- `DaemonStore.drain` is a frame-class batcher (`DaemonService.swift:88`). `EventInbox` (inside
  `DaemonStore+Driver.swift`) merges per-surface events.

**How little runs through the scheduler:**

- One production budgeted client: `AppControl.swift:50` `Control.frames` (automation).
- Three unbudgeted batchers sit outside the budget window: `SidebarBridge.swift:52` `SidebarRows`,
  `ContentPresentationScheduler.swift:30` and `NewTabPage+Open.swift:16`.
  `FrameBatcher.init(owner:scheduler: = .app)` has a default argument.
- All other main-thread work is unclassified and goes to `DispatchQueue.main` in FIFO order. These
  are the queue hits (section 6):

| Queue | What | Hits / files |
|---|---|---|
| Q1 | `Task { @MainActor` | 480 / 338 |
| Q1b | plain `Task {` in a main-actor type (approximate; heuristic) | about 778 / 389 |
| Q1c | `DispatchQueue.main.async` 15, `CFRunLoopPerformBlock` 9, `RunLoop.main.perform` 2, `MainDelivery(` 27 | 53 / 36 |
| Q2 | `ObservationStream(` | 297 / 217 |
| Q3 | raw `withObservationTracking` | 58 / 49 |
| Q4 | `addObserver(` (83), NSWindow/NSApplication names, NSWorkspace center, `notifications(named:)`, DistributedNotificationCenter, KVO `.observe(\.`, NSView frame/bounds notices, `didUpdateNotification` (3) | 263 / 121 |
| Q5 | `isHiddenOrHasHiddenAncestor` 159, `viewDidHide` 28, `viewDidUnhide` 26 | 213 / 131 |
| Q6 | `DemandTimer(` 187, `Task.sleep` 33, `.sleep(for:/until:)` 43 | 263 lines / 218 |
| Q7 | `MainActor.run` | 69 / 40 |
| Q8 | `mouseMoved`/`scrollWheel`/`mouseDragged` overrides 54, `addLocalMonitorForEvents` 32 (28 files) | 86 / 68 |
| QA | `override func viewDidChangeEffectiveAppearance` | 161 / 150 |
| Q10 | predicate waits in ObservationStream | 22 |
| Q11 | O(all) ObservationStream closures; `locateTab(` call sites | 22; 121 |
| — | `withChecked/UnsafeContinuation` (resumes are unordered main jobs) | 176 |
| — | NSHostingView/NSHostingController (SwiftUI tracks on its own) | 31 in 22 files |
| — | app-defined Notification.Name | 12 (the arch ratchet counts 13) |

All queues together: **2,721 hits in 1,132 files**. Of the files hit by Q1-Q8, 217 of 790 are hit
by 2 or more queues and 48 by 3 or more. So a split by queue would edit the same file up to 5
times.

**Raw main hops that matter most:**

- Ghostty: `GhosttyRuntimeCallbacks.swift:21,43,124,154,160` (wakeup tick and actions) use
  `DispatchQueue.main.async`.
- CEF: `CEFRuntime+Events.swift:20` sends every CEF event as `DispatchQueue.main.async`.
- Pages: `PageScriptPipeline.swift:108` runs one `evaluate` per router envelope.

**No visibility model:**

- `isHiddenOrHasHiddenAncestor` is used as an ad hoc gate 159 times.
- `occlusionState` is read 25 times.
- Per-view hide deferrals: TabStripView.modelChangedWhileHidden, TerminalSurfaceView.isShown,
  WorkspaceContentController park/drawsNothing/isOffScreen.
- Chromium is never told that a tab is hidden. `CEFTab+Freeze.swift:20-23` records that
  `CefBrowserHost::WasHidden` does nothing for windowed Chrome-style browsers, and that a hidden
  page ran rAF at about 98/s until the 30 s freeze.

**O(all) observers (F5):**

- SidebarRowFeed arms one observation per listed row (400 at 400 workspaces).
- `AppServices.locateTab` (`AppServices.swift:611`) loops all daemons, and has 121 callers.
- PointerHover.refresh is O(all) targets (about 20 ms, perf-lead row 8).
- SidebarSameTurn.observe, ControlSnapshotPublisher.publishNow and SidebarDocStore.show each take
  more than 8 ms (row 6).

**Automation leaks:**

- Daemon events are applied in the frame class in the person's frame.
- Only WorkspaceDelta, TabDelta and FrontendProjectionChanged carry `origin` or `mutation_id`.
- `cmux-tui-core` has 199 `.emit(` sites. `MuxEventBroadcaster::emit` (`event_bus.rs:203`) runs
  under its subscriber mutex and clones each event per subscriber.
- `RequestOrigin` (`request_origin.rs:70`: Page, Agent, User when `verified_app`) already
  classifies requests.
- State and registry locks (`mux/signaled_mutex.rs`, std Mutex plus a condvar; the registry
  connection uses parking_lot) and worker admission (`server/worker_admission.rs`) do not know
  the frontend from automation. No daemon thread sets a QoS.

**No idle, no startup phases, no frame-aligned continuous input, and no class on hangs**
(`MainThreadHangEvent` has no owner).

**Measured (perf-lead.md):**

- Typing during 400-workspace sidebar churn: key-to-frame p95 143 ms.
- Home composer under load: 284-400 ms.
- Send-to-dispatch wait under load: 8-286 ms.
- Idle main wakeups: 27-107/s.
- STRESS every-action sweep: 231 actions over 10 ms to commit, 447 with dropped frames.

**Tooling that exists:**

- Pre-push guardrails: main-async, action-wait, task-priority, main-blocking, thread-doc.
- `arch-ratchet.json` rows: `observer_sites` 340, `app_broadcast_names` 13,
  `assume_isolated_outside_adapters` 151.
- `scripts/cmux-next/lint/sgconfig.yml` (ast-grep).
- `sidebar-churn-typing.py --input real`. `automation-typing-bench.py` has `--layouts
  light,stress` but no `--input`.

---

## 3. Target design

### A. One scheduler, classes by type (CmuxNextWakeups, PL-main)

| Class | What | Budget |
|---|---|---|
| input | AppKit event dispatch, injected keys, InputObserverHub subscribers | unbudgeted |
| input-response pass | a STATE with a pass. It opens on a discrete input only when the turn expects a frame (Chrome `is_frame_expected_after_discrete_input`): the ActionEffect is `.applied`, `.intentEffect` or `.waiting`; a view asked for display; or ghostty asked for a draw. In the input's own turn, a beforeWaiting observer ordered BEFORE the CA commit (`CommitBoundary.order - 1`) applies, unbudgeted, every dirty observation and batch item whose cause is person (`InputResponsePass`). The state stays open until the end of the first link-tick render pass after the input. While it is open, automation, background and idle wait. It has a 100 ms cap. | unbudgeted pass |
| frame | springs, drags, daemon drain up to the last person/frontend transaction, terminal frame holds | unbudgeted, once per vsync |
| userBlocking | the async rest of a person's action: replies to person-scope commands, `.waiting` effect completions, the person-caused flush that missed the pass (Chrome kUserBlocking). It runs before visible, does not yield to its own input response, and closes it on commit. | capped at the visible + automation shares |
| visible | what a person sees that their input did not cause: program (PTY) changes, frontend changes, visible pages | 2.5 ms × (interval / 16.7 ms) |
| automation | anything caused by CLI, MCP, agent, socket or page automation | 1 ms × scale |
| background | nobody sees it this frame | 0.5 ms × scale |
| idle | `IdleScheduler`: long periods (up to 50 ms after 50 ms of quiet) and short periods (2 ms or more left before vsync). Every idle task gets a deadline. | deadline |

**Budget mechanics.**

- `passTarget = refresh interval − 2 ms input reserve − the measured render pass`. The class shares
  scale with interval / 16.7 ms.
- The budgeted batch runs in its OWN run-loop turn right after the tick's commit (a CFRunLoopSource
  signaled from AfterFrameCommit), with a deadline of the next vsync minus the render estimate. So a
  tick turn is drain + clients + render, and a budget turn is at most the class shares. This makes
  the fixed target "turn p99 <= 4 ms" possible. The cost is a second CA commit in some frames; task
  201 measures it and keeps the old path behind a setting.

**Progress rules.**

- visible keeps "yielded last frame → runs this frame".
- automation and background use a typing-burst window: for 500 ms after the last discrete input
  they run at least 1 task per 100 ms and at most 10/s. Chrome uses 2 s; cmux uses less because of
  agent and CLI request deadlines.

**Posting API.** These are the only sanctioned ways to put work on main:

- `mainWork.post(_ class, owner, file: #fileID, line: #line) { }`: per-class FIFO.
- `node.queue(class, owner).post { }`: per-node queues with enabled voters. While the node is hidden
  they hold, and they coalesce by key. A frozen node runs nothing. On deinit the queue drops its
  tasks. Blink keeps detached frame runners alive for JS; cmux owners are views that are gone.
- `mainWork.postIdle(owner, maxDelay: nil) { deadline in }`.
- `mainWork.postContinuation(class, owner)`: goes to the FRONT of its class queue (scheduler.yield
  semantics). `budget.shouldYield()` returns true when input is pending, an input response is open
  or the share is spent.
- `BackgroundWork.run { }.reply(on: mainWork, class:, owner:)`, the cmux PostTaskAndReply. Main-actor
  callers use the reply form instead of `await`, so the resume is not an unattributed job.
- `await mainWork.apply(class, owner) { }` only where the reply form does not fit. The caller's
  resume is still one unattributed job, and the code says so.
- A synchronous change in the input's own turn stays a direct call (zero-latency contract).
- The scheduler's own timers (idle start, input-response cap, starvation check, coalescer fallback,
  reveal deadline) are unposted `.precise` timers or run-loop observers. They are never queued
  behind the classes they measure.

**Startup phases.**

- **launching**: input, frame, userBlocking, visible and automation run; background and idle are
  held. The off-main best-effort fence holds `WorkPriority.bestEffort` items in BackgroundWork and
  LaneScheduler.
- **revealed**: at LaunchReveal's first frame, or at a 1.5 s precise deadline, or AT ONCE when the
  app launches hidden or with no window. Background and the fence open.
- **settled**: a reference count of first frame, first daemon snapshot applied, session restore
  done, and the visible Chromium page load-idle (or no page), with a 10 s failsafe (Chrome uses
  3 min; cmux has no network-bound restore on the critical path). Idle is enabled.

**Rendering starvation guard.** It is based on link lateness: a frame-class client is active on a
VISIBLE window, and the gap between its ticks went over 100 ms. It never applies while the displays
sleep or every window is occluded. On starvation it gates every source the scheduler controls:
budgeted and idle classes, CEF pump slices beyond one per frame, deadlines routed through post, and
the automation drain tail. It records the top unattributed turn from MainTurnMeter in
`stall.render_starved`.

**Attribution.**

- `MainTaskBoard` records owner, class, `posted_from`, the node state, wait and run time
  (MainOwnerLedger).
- `MainTurnMeter` splits every turn into scheduled work, render, input dispatch and unattributed
  time. It attributes only the innermost nested run-loop turn (menu tracking, modal sessions, live
  resize, drag loops).
- Hang scopes per class: input 100 ms, frame and userBlocking 50 ms, budgeted 16.7 ms, idle its
  deadline + 16.7 ms. Menu, modal and drag sessions invalidate them. Hang events carry owner,
  class, location and turn_ms, or `unattributed`.

**Runtime spike.** The Swift runtime main-executor enqueue hook may give every main job a class
from its Task priority (task 202, decision-gated). If it passes, Q1/Q1b/Q7 shrink to "set the right
priority". If it fails, the rewrite plan stands.

### B. Visibility tree (Chrome content::Visibility)

- `Visibility` = {visible, occluded, hidden}. `VisibilityNode.effective` = min(own, parent). Each
  node keeps its children in two sets by their own state, so a parent flip visits only children
  whose effective value can change.
- Subscribers get notified only on a flip. `node.isVisible` is O(1). `hiddenSince` drives the 5-min
  rule. `mediaActiveWithin(30 s)` replaces a current holdsMedia flag (Chrome kRecentAudioDelay).
- `captureVote(reason, stayHidden)`: the node renders (observers, frame clients) while page-visible
  signals and timer alignment can stay hidden (Chrome capturer count). Agent screenshots and
  screencasts of a hidden tab, the iPhone browser host and Mac screen share take votes.
- Tree: app (NSApp hidden, screens asleep) > window (occlusion, miniaturized) > workspace (shown,
  companion, parked, off screen) > pane (suspended) > tab (selected in a shown pane) > sidebar row
  (viewport + 1 screen of overscan).
- `node.deferUntilVisible(key) { }` runs at once if visible, else once on show. It replaces per-view
  hide flags and heavy `viewDidChangeEffectiveAppearance` bodies.
- **Show order.** Observers on screen in the focused pane (and `firstFrame` subscribers) re-read
  synchronously in the show turn. Other newly visible observers post one userBlocking task each, in
  viewport order, so they land in the next 1-2 frames. A `warm` vote (hover, Ctrl-Tab target,
  neighbor tabs) re-reads in idle without drawing.
- **Chromium.** Each CEF tab follows its tab node through a fork shim
  `cmux_shim_tab_set_visibility(browser, HIDDEN|OCCLUDED|VISIBLE)` →
  `WebContentsImpl::UpdateWebContentsVisibility`. Blink's own hidden-page throttling then starts in
  the same turn. The freeze at `browser.freezeHiddenTabs` stays as the second step.
- **SwiftUI.** `VisibilityGatedHostingView` takes the hosting view out of the hierarchy while it is
  hidden (a snapshot layer remains), so SwiftUI does no graph work. It restores the view in the
  show turn.
- **WindowEvents / AppEvents** (architecture-refactor-DESIGN.md row B, workstream A4, owner PL-arch,
  located in Wakeups): one observer per window or app per notice name. They fan out to subscribers
  whose node is visible, or to `always` subscribers. A hidden subscriber reads the current value
  on show.
- **InputObserverHub.** `CmuxApplication.sendEvent` calls one hub that replaces the 32 local event
  monitors. Subscriptions are by mask, window and node; only visible subscribers in the event's
  window run.

### C. One observer per visible thing (F5)

- **`VisibleObservation(node, owner, read, apply)`.**
  - It applies the first value synchronously, then tracks through `withObservationTracking` (the
    same path on macOS 14-27) only while the node is visible.
  - onChange marks it dirty. Its class at flush time is person when the scheduler's
    `personCauseEpoch` moved after the observer became dirty (this fixes "the first cause wins").
    Otherwise it is the recorded cause: frontend or program → visible, automation → automation.
  - Person-caused flushes run in the InputResponsePass; one task per observer per frame otherwise.
  - On hide, a cancel signal fires the tracking off. On show it re-reads in the show order above.
- **Recipe rule:** use VisibleObservation ONLY when `apply` touches views. Anything that writes the
  model, the daemon, the disk or another owner uses `ServiceObservation(class, owner, read, apply)`.
- **`StoreWaiters`** (DaemonStore) and **`PageWaiters`** (browser page) replace predicate waits with
  keyed O(1) waiters that have timeouts.
- `MachineTabIndex` (in CmuxNextDaemonService) makes `locateTab` O(1).
- Global settings broadcasts become `AppearanceSignals` (@Observable, injected).
  Point-to-point broadcasts become direct subscriber registries.
- `debug.observations` reports armed, evaluated and applied counts per owner, plus SwiftUI hosting
  body evaluations.

### D. Automation never competes with the person

**Daemon (PL-daemon):**

- **Cause per envelope, not per variant.** The request dispatcher sets a scoped thread-local
  `EventCause` derived from `RequestOrigin`: User/verified_app → `frontend`; Agent and Page →
  `automation`.
  - `Mux::emit` captures the cause into the subscriber envelope.
  - Pool jobs (terminal create, active_creations) copy it when submitted.
  - Unscoped emits (PTY output, OSC title and status, hooks, reaps) are `program`.
  - No MuxEvent variant changes, so the 199 emit sites stay as they are.
  - Coalescing keeps the highest cause: frontend > program > automation.
  - Cause is for scheduling only and is never read by authorization code.
- **Person cause, app side.** A DaemonCommandScope opened by a person-entrypoint ActionRegistry run
  records its mutation_ids (bounded, 2 s expiry). An echo with such an id is `person`. There is NO
  new wire claim.
- **Page relay.** Home composer and agent pane requests that reach the daemon through page relay
  get person when the app's page bridge sends them within 1 s of a real gesture in that page, and
  the app knows their mutation_id. Only if the relay bypasses the app does task 231 add a
  single-use gesture token. That path is `risk:high` and needs an independent review receipt.
- **Lock admission by class** inside `SignaledMutex::lock`, `lock_state_pinned` and the registry
  connection lock:
  - frontend callers increment a waiting counter, and automation yields while it is above 0
  - automation is admitted at least every 4 ms
  - nothing waits while another rank is held (lock_rank asserts it)
  - this covers the reader-thread path (`connection_frame.rs` handle_request), not only
    `mux-control-dispatch`
- **Reserved worker permits.** 2 surface and resource worker permits are kept for verified-app
  connections.
- **QoS.** Threads that take state or registry locks stay USER_INITIATED. Automation work OUTSIDE
  the locks runs at UTILITY, and a thread is raised (`pthread_override_qos_class_start_np`) while
  it holds a lock, so the frontend never waits behind a UTILITY holder.
- **Fan-out.** Scoped subscribers are indexed by SurfaceId and events are wrapped in
  `Arc<MuxEvent>`. Emits are collected under `Mux::state` and published after the guard drops, and
  the frontend mailbox is served first.
- **Frontend visibility.** The app sends its visible surface set (`frontend.visibility.set`,
  coalesced per frame). Field events of hidden surfaces wait in CoalescedEventKey slots on a 1 s
  aligned flush, and are flushed at once on show. Structural events pass at once.
- **Lock histograms.** `debug.daemon_locks` reports wait and hold time per origin and per op.

**App:**

- **Drain, ordered by cause.** The frame-class drain applies every transaction up to and including
  the LAST person or frontend one (an ordered flush; a person event never goes before earlier
  automation events). The trailing non-person transactions go to one ordered tail queue. Each task
  applies one whole transaction in the class of the head transaction (program → visible,
  automation → automation), with a 2 ms slice. A resync or snapshot stays in the frame class.
  Read-your-writes waiters advance per transaction.
- `mainWork.currentCause` is set per envelope while the drain applies it.
- **FrameBatchQueue items carry a cause.** Person and frontend items drain unbudgeted (in the pass
  or the frame tick). Others keep the class budget.
- Hidden nodes have no armed observers and held queues, so a hidden-workspace change costs the
  model apply only.
- BrowserHost provider commands, agent cursor and activity, and ControlSnapshotPublisher run as
  automation or background.
- An automation-caused structural layout change that is the second or later one per window in one
  frame snaps through the Motion gate (`Motion.panes.set`). The person's changes still animate.

### E. Timers, input, page pushes

- **`MainDeadline`** (@MainActor) takes owner, class, alignment and node. Alignment is one of:
  - `.precise` (only for delays < 36 ms; longer ones fall back to flexible)
  - `.flexible` (the DEFAULT: 8 ms leeway, 8 ms buckets, `tolerance:` passed to the sleep)
  - `.whenHidden(node)`: 1 s boundaries while hidden. Repeating or self-re-arming timers move to
    60 s after 5 min hidden, with one 1 s-aligned wake allowed per minute. There is no alignment
    within 30 s of media activity or under a capture vote.

  Request and quit deadlines are flexible with no-sooner semantics. A next-fire registry feeds the
  idle deadline. `DemandTimer` stays for off-main deadlines and gains `tolerance:`. The R-timer
  recipe asks first: can this timer become an event (idle-wakeups.md)?
- **`AlignedWakeups`**: one sleep per boundary bucket.
- **`CPUTimeBudgetPool`**: hidden-node work refills at 1 % of wall time (10 ms/s) with a 100 ms
  cap. Media and capture are exempt.
- **`FrameInputCoalescer`** (per window): the handler gets the latest event, the coalesced list and
  the accumulated delta, and runs at the frame tick before frame clients. A discrete event flushes
  pending continuous work first. Drags opt into unbuffered delivery until mouseUp. A 1-frame
  fallback covers a missing tick.
- **`PageScriptPipeline`**: one `receiveMany` evaluate per page per frame. Hidden pages keep the
  latest state envelope per subscription and a bounded FIFO for streams (overflow → resync), and
  flush on show. Gate replies keep their turn.
- **Ghostty tick and actions.**
  - The tick is a board task (`ghostty.tick`): input class within one frame of a key to a
    terminal, frame class otherwise.
  - High-rate actions (title, pwd, progress, mouse shape, cell size) keep the latest value per
    surface and kind per frame. On a hidden surface they are applied on show.
  - Discrete actions (bell, exit, close, clipboard) keep FIFO order.
- **CEF events.** Title, URL, progress, favicon and status are merged per browser per frame: visible
  class for a visible tab, background for a hidden one. Commits, dialogs, crashes and input ACKs
  stay FIFO and immediate.
- **CEF pump.** Slices go on the board (`cef.pump`) and are attributed. Pump requests are never
  deferred while a CEF view is first responder or has an unacked input. The pump is not classed by
  visibility, because Chromium's UI thread serves every page; hidden savings come from the
  visibility shim. F2 later removes the pump.
- `NSWindow.didUpdateNotification` observers (3) become dirty flags.

### F. Ratchet and tooling (pre-push only, never CI)

**Guardrail rules on added lines:**

- `main-hop`: one predicate shared with arch_counts. It flags main-inherited Task, `Task {
  @MainActor`, `MainActor.run`, raw main-queue hops and `MainDelivery` without a class. Escape
  `// main-hop-allow: <why>`.
- `view-observation`
- `visibility-walk`: also flags new `viewDidHide`/`viewDidUnhide` gating.
- `timer-class`: flags `DemandTimer` on main without MainDeadline, `Task.sleep` and `clock.sleep`
  loops.
- `raw-observer`: the full Q4 regex.
- `local-monitor`

**arch-ratchet:**

- Reuse `observer_sites` and `app_broadcast_names`, and teach arch_counts that WindowEvents and
  AppEvents are coalescing adapters.
- Add `main_inherited_tasks`, `raw_main_hops`, `unscoped_observations`, `visibility_walks`,
  `unclassed_main_deadlines` and `local_event_monitors`.

**Queue generator.** `scripts/cmux-next/p06_queue.py` unions all queues by file and packs file
groups (section 6).

No perf-gate rows, budgets, CI jobs or CI tests. Agents run every bench themselves on the fleet.

---

## 4. Rules

1. **No new unclassified main hop.** All main work is posted with a class and an owner, or is a
   synchronous change in the input's own turn. Escapes need a reason that proves why AppKit order
   requires the hop (focus, menu tracking).
2. **The person's visible change stays in the input's turn.** A person-caused observation applies in
   the InputResponsePass before the commit. Async completions are userBlocking. A sweep that moves
   a person-visible change behind visible or automation is a defect (zero-latency.md).
3. **VisibleObservation only for view applies.** Side effects (daemon, disk, model, other owners)
   use ServiceObservation and must still happen while hidden.
4. **Hidden = model only.** No layout, view sync or animation for hidden nodes. Work runs once in
   the show order on show.
5. **Cause comes from the source.** Daemon envelope cause plus app mutation_id matching. Cause is
   never used for authorization.
6. **Deadlines a person or request waits on** are `.precise` (< 36 ms) or `.flexible`, never
   `.whenHidden`. Review every R-timer site by hand.
7. **One file, one sweep.** File-group tasks apply every recipe to their files in one diff. No
   other sweep edits those files. Hot files (WorkspaceContentController, PaneController,
   AppServices, TabContentCache, CmuxApplication) are serialized: 003 → 023 → 024 → 049 → FG302 →
   FG303.
8. **API freeze at hour 12.** After task 205 lands, no public signature in CmuxNextWakeups changes
   without the Performance Lead's OK. Wakeups changes are internal only, because they rebuild most
   of the 98 targets.
9. **Tests.**
   - Each primitive has unit tests that fail without it. They are green on macOS 26 and 27 before
     the freeze, because 48 sweeps depend on them.
   - Each sweep adds one harness case per migrated owner class (hidden → 0 view applies and 1 on
     show; person → applies before the commit; automation → yields to fake input; side effects
     still sent while hidden).
   - Sweeps land on `cmux-ci compile-check` plus review. Their suites run in the test phase
     (task 160), as "speed over gates" asks.
   - Every commit records which suites were run red and green, or "not run: test phase".
10. **Owners.** Tell the owner and land with their OK:
    - Sidebar: a590
    - window switch: PL-switch
    - Terminal: PL-ghostty
    - CEF: PL-motion-cef, PL-cef-tab, PL-cefhost
    - layout motion: PL-motion-core
    - daemon: PL-daemon
    - WindowEvents (A4): PL-arch
    - QoS: PL-qos
11. **Risk tier.** Daemon lock admission, worker permits and the visibility-scoped subscription are
    `risk:normal` (no policy change), but each needs PL-daemon's review. Task 231's gesture-token
    fallback is `risk:high`.
12. No new CI gates, budgets or perf-gate rows. Pre-push guardrails and arch-ratchet only.
13. macOS 14 and 15: check function in Tart VMs (`os-matrix.sh`); VM timing is not perf evidence.
    Frame claims need `--vdisplay=120`.

### Recipes

| Recipe | Queue | Rule |
|---|---|---|
| R-hop | Q1, Q1b, Q1c, Q7 | Choose one of: synchronous in the turn (the person's change), `post(class, owner)`, `node.queue(...).post`, or off-main compute + `.reply(on:)`. Async bodies: a nonisolated Task for the async part plus a reply or `apply` for the main part. |
| R-obs | Q2, Q3 | VisibleObservation (views only) or ServiceObservation (anything else). Name the class and owner. |
| R-wait | Q10 | StoreWaiters or PageWaiters with the same timeout. |
| R-index | Q11 | Per-object revision or the MachineTabIndex. |
| R-notif | Q4 | WindowEvents or AppEvents subscription with a node. NSView frame/bounds notices become the view's own `layout()`/`setFrameSize`. KVO on WebKit takes the tab node. |
| R-vis | Q5 walks | `node.isVisible`. Hit-test and accessibility uses keep `// visibility-walk-allow:`. |
| R-hide | Q5 hide/unhide | `viewDidHide`/`viewDidUnhide` only forward to the node; hidden-dirty flags become `deferUntilVisible`. |
| R-timer | Q6 | Event first; otherwise MainDeadline with class and alignment; sleeps in races use the `Deadline` helper. |
| R-input | Q8 overrides | cmux-side hover, cursor and drag-target work goes through FrameInputCoalescer; forwarded events keep order and count. |
| R-monitor | Q8 monitors | InputObserverHub subscription; session monitors only while active. |
| R-appear | QA | Bodies that do more than set layer colors use `deferUntilVisible`. |
| R-delivery | Q1c | `MainDelivery(class:owner:)`; CFRunLoopPerformBlock → MainDelivery or AfterFrameCommit. |

---

## 5. Done checks

1. **Key to frame**, real HID keys at 120 Hz (`split-spring.sh --vdisplay=120`;
   `automation-typing-bench.py --input real`, `sidebar-churn-typing.py --input real`), in the
   terminal, Home composer and omnibar, light and STRESS, while `script-storm-bench.py` /
   `bench_cli_storm.py` reorder the sidebar and change statuses: p50 <= 8.3 ms, p99 <= 16.7 ms.
   Today the sidebar-churn p95 is 143 ms.
2. **Automation isolation:** storm key-to-frame p99 minus idle p99 <= 1.0 ms, same session and host.
3. **`debug.main_budget` during the STRESS storm:**
   - every run-loop turn (innermost nested turn attributed) p99 <= 4 ms and max <= 16.7 ms
   - each scheduled task p99 <= 4 ms
   - unattributed share of busy main time <= 5 %
   - `yielded_to_input_response` > 0
   - 0 automation, background or idle tasks between a discrete input and the end of its first
     tick render pass, except the one-frame-late progress task of task 002's decision when keys
     arrive every frame
   - every person-caused apply runs before that commit (`input_response_pass.applies` > 0 and
     `late_person_applies` = 0)
4. **Hidden-workspace storm** (`script-storm-bench.py --hidden 50`, 1000 CLI ops):
   - 0 visible or automation tasks from hidden-node queues (the board records node state)
   - `hidden_workspace_layouts` = 0
   - app main <= 0.05 ms/op
   - frontend mailbox events for hidden surfaces <= 1 per surface per second
   - 0 SwiftUI body evaluations in hidden hosting views
5. **Observers per event** (`debug.observations`, 400 workspaces): armed sidebar-row observations
   <= rows on screen + 1 screen of overscan (<= 80; today 400). One status change → exactly 1 row
   re-map and <= 2 evaluations app-wide.
6. **Idle** (`bench_idle.py mixed-hidden`, 60 s, 10 hidden Chromium tabs + 5 hidden terminals),
   window visible and app hidden:
   - app + daemon <= 1.0 wakeups/s
   - main thread <= 0.5/s
   - daemon threads sum <= 0.5/s
   - hidden Chromium tab rAF = 0/s before the 30 s freeze

   Today main is 27-107/s.
7. **Launch** (`bench_launch.py`):
   - `launch.order_ok`: 0 background, idle or best-effort tasks before `launch.revealed`
   - first frame cold <= 300 ms, warm <= 150 ms
   - an `open -g` launch reaches revealed at once
8. **Every-action sweep** STRESS at 120 Hz: 0 runs whose `action.commit` interval contains an
   automation, background or idle `stall.main_task`. Cmd-T, Cmd-N and Cmd-W have 0 dropped frames.
9. **Daemon** (`perf-10x-daemon.sh`, 64-client CLI storm):
   - app send-to-reply p95 <= 2 ms
   - frontend lock wait p95 <= 0.5 ms (`debug.daemon_locks`)
   - automation clients still complete >= 1 request per 4 ms
10. **Workspace switch** with 12 panes at 400 workspaces: `bench_tab_switch.py` p95 < 16 ms.
    **Theme toggle** at 50 workspaces: deferred appearance bodies run only for the visible
    workspace (`appearance_applies`).
11. **Ratchet counts at program end** (section 6 commands, `///` excluded):

| Count | Today | End |
|---|---|---|
| `main_inherited_tasks` (Q1 + Q1b) | 480 + about 778 | <= 10 reviewed escapes |
| `raw_main_hops` (Q1c) | 53 | <= 5 outside Wakeups |
| `MainActor.run` | 69 | <= 10 |
| `ObservationStream(` | 297 | <= 20, none in `*View*.swift` |
| raw `withObservationTracking` | 58 | <= 5, in the primitives |
| Q4 observer kinds | 263 | <= 12: adapters and reviewed KVO; exactly 1 `accessibilityDisplayOptionsDidChange` |
| `isHiddenOrHasHiddenAncestor` | 159 | <= 10 |
| gating `viewDidHide`/`viewDidUnhide` | 54 | 0 |
| main-actor DemandTimer without MainDeadline | 187 | 0 |
| periodic `Task.sleep`/`clock.sleep` loops | 76 | 0 |
| `addLocalMonitorForEvents` | 32 | 1 (the hub) |
| `didUpdateNotification` | 3 | 0 |
| app_broadcast_names | 13 | <= 2 |
| `observer_sites` | 340 | <= 40 |

12. **Production budgeted clients:** visible >= 4 owners (SidebarRows, ContentPresentation,
    VisibleObservation flush, PageScriptPipeline) and background/idle >= 5 owners.
    `git grep -n -E 'FrameBatcher\(owner: "[^"]+"\)' Packages/macOS/CmuxNext/Sources` returns 0.
13. **Unit suites green on the fleet** for macOS 26 and 27, and for 14 and 15 in Tart, each with a
    red run before and a green run after:
    - MainFrameBudgetTests, MainWorkPostTests, InputResponsePassTests, IdleSchedulerTests,
      StartupPhaseTests
    - MainTurnMeterTests, MainTaskQueueTests, CPUTimeBudgetPoolTests, VisibilityTreeTests,
      WindowEventsTests
    - VisibleObservationTests, ServiceObservationTests, StoreWaitersTests, PageWaitersTests,
      FrameInputCoalescerTests
    - MainDeadlineTests, AlignedWakeupsTests, InputObserverHubTests,
      VisibilityGatedHostingViewTests, DrainCauseSplitTests
    - EventCauseTests, GhosttyTickClassTests, PageScriptPipelineBatchTests
    - the cmux-tui tests event_cause, signaled_mutex_class, worker_admission, event_bus,
      frontend_visibility
14. **Hang soak**, 30 min STRESS with the CLI storm: 0 hangs > 250 ms (`debug.hangs`, with class
    and owner), 0 `stall.render_starved` over 100 ms, `unattributed` hangs = 0.

---

## 6. Machine queues

`S=Packages/macOS/CmuxNext/Sources`. Every query drops `///` lines (`| grep -v '///'`).

| Queue | Command | Today |
|---|---|---|
| Q1 | `git grep -n -E 'Task *(\(priority:[^)]*\))? *\{ *@MainActor' -- $S` | 480 / 338 |
| Q1b | the `main_inherited_tasks` predicate in `arch_counts.py` (task 015): every `Task {` / `Task(priority:` whose enclosing type or function is main-actor isolated (annotation, NSView/NSViewController/NSWindowController superclass, or View conformance). Today's heuristic: plain `Task {` in files that declare such a type. | about 778 / 389 |
| Q1c | `git grep -n -E 'DispatchQueue\.main\.async\|CFRunLoopPerformBlock\|RunLoop\.main\.perform\|MainDelivery\(' -- $S` | 53 / 36 |
| Q2 | `git grep -n 'ObservationStream(' -- $S ':!**/CmuxNextCompat/ObservationStream.swift'` | 297 / 217 |
| Q3 | `git grep -n withObservationTracking -- $S ':!**/ObservationStream.swift'` | 58 / 49 |
| Q4 | `git grep -n -E 'addObserver\(\|(NSWindow\|NSApplication)\.(did\|will)[A-Za-z]+Notification\|NSWorkspace\.shared\.notificationCenter\|notifications\(named:\|DistributedNotificationCenter\|\.observe\(\\\.\|NSView\.(frame\|bounds)DidChangeNotification\|didUpdateNotification' -- $S` | 263 / 121 |
| Q5 | `git grep -n -E 'isHiddenOrHasHiddenAncestor\|override func viewDid(Hide\|Unhide)\b' -- $S` | 213 / 131 |
| Q6 | `git grep -n -E 'DemandTimer\(\|Task\.sleep\|\.sleep\((for\|until):' -- $S` | 263 / 218 |
| Q7 | `git grep -n -E 'MainActor\.run\b' -- $S` | 69 / 40 |
| Q8 | `git grep -n -E 'override func (mouseMoved\|scrollWheel\|mouseDragged)\(\|addLocalMonitorForEvents' -- $S` | 86 / 68 |
| Q9 | `git grep -n -E 'FrameBatcher\(owner: "[^"]+"\)' -- $S` | 3 (task 010) |
| Q10 | `git grep -n -E 'for await .* in ObservationStream\(.*where .*\{ *(return\|break)' -- $S` | 22 |
| Q11 | `git grep -n -E 'ObservationStream\(.*(workspaces\|allTabs\|\.tabs\b\|\.panes\b\|\.contains *\{\|first\(where\|filter *\{\|\.map *\{\|machines\.)' -- $S`, plus `locateTab(` | 22; 121 |
| QA | `git grep -n 'override func viewDidChangeEffectiveAppearance' -- $S` | 161 / 150 |
| QH | `git grep -n -E 'NSHostingView\|NSHostingController' -- $S` | 31 / 22 (task 214) |
| Q12 | runtime: `debug.main_budget owners` sorted by unattributed time and p99, plus `unattributed` hang events. Each owner over 1 ms p99 not yet classed is one follow-up task (task 160). | runtime |
| Q13 | daemon: emit sites reached with no cause scope, from the `program` default counter in `debug.daemon_locks`/server-stats. Each unexpected `program` emit from a request path is one task. | runtime |
| QD | `bench_idle.py` `daemon_threads`: each daemon thread over 0.05 wakeups/s at idle is one task (task 228) | runtime |

**File-group generator (task 216).** `scripts/cmux-next/p06_queue.py`:

1. Runs Q1-Q8, Q10, Q11 and QA.
2. Groups hits by file.
3. Packs files into tasks of about 40-70 hits, by directory, then by OWNERS.md owner.
4. Prints, per task: the files, the recipes per file, the owner to tell, and the check command
   (`p06_queue.py --check <group>`).

Each file is in exactly one task. Section 8 lists the planned cut (FG300-FG346), measured at
772cdfc45ac. The generator may rebalance it but must keep the same directories in one task.

---

## 7. Risks

1. **Swift main-actor jobs are FIFO on `DispatchQueue.main`.**
   - The scheduler orders only posted work. Continuation resumes (176 sites) and `await apply`
     resumes stay unattributed jobs.
   - Proof is MainTurnMeter's unattributed share, not grep counts.
   - Task 202 may remove this limit. If its gate fails, the rewrite plan stands.
2. **Cause rides on Observation's synchronous willSet onChange** inside the drain, plus the
   personCauseEpoch. A runtime that defers onChange would class everything as visible.
   VisibleObservationTests pins this.
3. **Moving work to visible or automation can add one frame.** The InputResponsePass and
   userBlocking are the guard. Reviewers check every Handlers diff against zero-latency.md. Focus
   and menu hops keep escapes.
4. **The show turn can grow** (12 panes). The show order (task 213) makes it O(on-screen
   observers). Measure with bench_tab_switch.py.
5. **The separate budget turn (task 201) adds a second CA commit in some frames.** Measure the
   commit cost. If it hurts, keep the in-tick path behind the setting and redefine done check 3 per
   task.
6. **Idle starvation under STRESS.** maxDelay is opt-in. The spare Chromium window refill uses
   500 ms, or Cmd-T in a new pane gets slower.
7. **Timer alignment changes meaning.** A wrong `.whenHidden` delays a reconnect or an auth refresh
   by up to 60 s. Only repeating timers get 60 s, and every site is reviewed.
8. **Daemon lock admission** touches cmux-tui-core locks: deadlock and lock-order risk. Admission
   never waits while a rank is held, and the 4 ms bound must hold or agents time out. Use loom or a
   10k-iteration stress run, plus per-class wait histograms.
9. **The Chromium visibility shim needs a fork API bump** (PL-cef-tab). Without it the tab keeps
   today's behavior. A wrong HIDDEN breaks capture; capture votes cover agents, the phone and screen
   share.
10. **VisibilityGatedHostingView removes views from the hierarchy.** First-responder, accessibility
    and `onAppear` side effects in SwiftUI pages can break. Adopt only for tab content, test each
    page, and keep a per-page opt-out.
11. **Hot files and owner conflicts.** Rule 7 serializes hot files. The file-group cut keeps each
    file in one task. Owner-held groups (Sidebar, Terminal, CEF, Windows, Layout) start first, so
    the owners can review early.
12. **Rebuild cost.** Wakeups is under nearly every target. The API freeze (rule 8) limits the
    rebuild storm that works against the 30 s leaf-edit target.
13. **Token leaks.** VisibleObservation and ServiceObservation tokens must cancel on release. On
    macOS 14 and 15 the fallback does not wake on deallocation, so a forgotten token keeps tracking
    armed until its next change.
14. **Chrome constants** are quoted from the design's and reviews' reads of chromium main. A task
    that copies one re-reads the source.
15. **Fleet.** No fleet Mac runs macOS 14 or 15 (use Tart for function only). Frame checks need a
    120 Hz virtual display.
16. **Schedule.**
    - Hours 0-12: wave 0, all primitives and the pilot.
    - Hours 12-48: the 48 file groups, the daemon work and the adopters, in parallel.
    - Hours 48-72: the test phase and fix loops (tasks 160, 161).

    A primitive that misses the freeze leaves its recipe's hits to task 347.

---

## 8. Task table

**Base dependencies of the file-group tasks (FG-base):** 205 (freeze + pilot), 216 (generator),
011, 012, 013, 021, 024, 026, 027, 028, 051, 214, 215, 217, 220.

| ID | Title | Size | Depends on | Queue |
|---|---|---|---|---|
| 001 | MainWork.post / apply / reply, with posted_from | M | — | — |
| 002 | Input-response state (frame-expected only; closes after the next tick render); typing-burst progress rule | M | — | — |
| 003 | Wire discrete input and expected-frame signals into the budget | S | 002 | — |
| 004 | Rendering starvation guard on link lateness | S | 008 | — |
| 005 | IdleScheduler with deadlines | M | 001 | — |
| 006 | Startup phases: reveal fallback and settled refcount | S | 005 | — |
| 007 | Wire startup phases to LaunchReveal, snapshot and restore | S | 006 | — |
| 008 | MainTurnMeter with nested-turn attribution | M | — | — |
| 009 | Per-owner wait/run ledger with posted_from and node state | M | 001 | Q12 |
| 010 | No batcher outside the budget window | S | 001, 207 | Q9 |
| 011 | MainDeadline: class, precise/flexible/whenHidden, next-fire registry | M | 001, 020 | Q6 |
| 012 | AlignedWakeups and visible leeway buckets; DemandTimer tolerance | S | 011 | — |
| 013 | FrameInputCoalescer: deltas, coalesced list, unbuffered | M | — | Q8 |
| 014 | Pre-push guardrail rules | M | — | — |
| 015 | Arch-ratchet rows and the main-inherited predicate | M | 014 | Q1b |
| 016 | Docs: contract, classes, recipes | S | 205 | — |
| 020 | VisibilityNode tree (two child sets, mediaActiveWithin, deferUntilVisible hook) | M | — | — |
| 021 | WindowEvents and AppEvents in Wakeups (A4, PL-arch) | M | 020 | Q4 |
| 022 | Window and app visibility source | M | 021 | — |
| 023 | Workspace visibility nodes | S | 020, 003 | — |
| 024 | Pane and tab visibility nodes | M | 023 | — |
| 025 | VisibleObservation with personCauseEpoch | L | 001, 020 | Q2 |
| 026 | ServiceObservation (no deprecation trick) | M | 025 | Q2 |
| 027 | StoreWaiters | M | — | Q10 |
| 028 | PageWaiters | S | — | Q10 |
| 029 | debug.observations (+ hosting body counts) | S | 025 | — |
| 030 | cmux-tui envelope-level cause from RequestOrigin (thread-local) | M | — | Q13 |
| 031 | App: person cause from its own mutation_ids; EventInbox max cause | S | 030 | — |
| 032 | Drain publishes currentCause and bumps personCauseEpoch | S | 025, 031 | — |
| 033 | Drain cost O(changes) audit and histogram | M | — | — |
| 034 | Daemon lock admission by class inside SignaledMutex and the registry lock | M | 030, 226 | — |
| 035 | Daemon QoS: lock takers USER_INITIATED, boost while holding | S | 034 | — |
| 036 | BrowserHost provider and automation as the automation class | M | 001, 026 | — |
| 038 | Automation bursts snap through the Motion gate | M | 032 | — |
| 039 | ControlSnapshotPublisher off the visible path | M | 026, 002 | Q3 |
| 040 | SidebarRowFeed observes only rows on screen (a590) | M | 020 | — |
| 041 | PointerHover per-window registry | M | 013 | Q8 |
| 042 | StatusIndicatorView on its node | S | 022 | Q4, Q5 |
| 043 | Settings broadcasts → AppearanceSignals | M | 021, 025 | Q4 |
| 044 | Ghostty configRevision (PL-ghostty) | S | 025 | Q4 |
| 045 | Sidebar doc and favicon broadcasts → direct (a590) | S | — | Q4 |
| 046 | Child-page geometry registry (PL-motion-cef; skip if F1 removed it) [partial] | M | — | Q4 |
| 047 | Hidden windows stop visibleOnly frame clients | S | 022 | — |
| 048 | CEF pump on the board, attribution only, never deferred while focused | S | 009 | — |
| 049 | Launch: classify the AppServices/AppDelegate starts | M | 007, 026 | — |
| 050 | Idle adopters: spare window, warmup, snapshot recorder | M | 005 | — |
| 051 | MachineTabIndex in CmuxNextDaemonService; O(1) locateTab | M | 027 | Q11 |
| 150 | Bench: script-storm-bench `--hidden N` | S | 009, 029, 229 | — |
| 152 | Bench: observers per event at 400 workspaces | S | 029 | — |
| 160 | Test phase: full before and after on the fleet | L | all landed | Q12 |
| 161 | Deep review of the program range | M | 160 | — |
| 200 | shouldYield and postContinuation; SidebarDocStore.show chunked | M | 001, 002 | Q12 |
| 201 | Refresh-scaled budget; budgeted batch in its own post-commit turn | M | 008, 002 | — |
| 202 | Spike (decision gate): priority-ordered main executor hook | L | 001, 008 | — |
| 203 | Hang scopes per class; hang reports with owner and class | S | 009 | Q12 |
| 204 | Off-main best-effort fence during launch | S | 006 | — |
| 205 | Wave 0: API freeze and pilot (App/Notifications + App/AgentCursor + agent activity) | L | 001, 002, 011, 020, 021, 025, 026, 027 | Q1-Q8 |
| 206 | InputResponsePass: person applies before the commit | M | 002, 025 | — |
| 207 | FrameBatchQueue items carry a cause | S | 206 | — |
| 208 | userBlocking class | S | 002, 001 | — |
| 209 | Per-node task queues (hold, coalesce, freeze, drop) | M | 001, 020 | — |
| 210 | CPUTimeBudgetPool for hidden nodes | S | 209, 011 | — |
| 211 | Capture votes on VisibilityNode | S | 020 | — |
| 212 | Chromium visibility shim from the tab node (PL-cef-tab) | M | 024, 211 | — |
| 213 | Show order: on-screen sync, rest userBlocking; warm votes | S | 025, 029 | — |
| 214 | VisibilityGatedHostingView and the tab-content adopters | M | 024, 029 | QH |
| 215 | deferUntilVisible + R-appear/R-hide with the first adopters | M | 024 | QA, Q5 |
| 216 | Queue generator p06_queue.py | S | 015 | all |
| 217 | MainDelivery(class:owner:) and the raw-hop primitive | S | 001 | Q1c |
| 218 | Ghostty tick and actions on the board (PL-ghostty) | M | 001, 024 | Q1c |
| 219 | CEF events on the board, coalesced (PL-motion-cef) | M | 001, 024 | Q1c |
| 220 | InputObserverHub and the per-instance monitors | M | 024 | Q8 |
| 221 | Remove the didUpdateNotification observers | S | 021 | Q4 |
| 222 | PageScriptPipeline: one evaluate per page per frame; hidden coalescing | M | 001, 024 | — |
| 223 | Drain: ordered flush by cause, automation tail, 2 ms slices | M | 031, 033, 001 | — |
| 224 | Daemon fan-out: indexed, Arc-shared, emitted outside the state lock | M | — | — |
| 225 | Daemon reserved frontend worker permits | S | 034 | — |
| 226 | Daemon lock wait/hold histograms (debug.daemon_locks) | S | — | — |
| 227 | Visibility-scoped frontend subscription | L | 024, 030 | — |
| 228 | Daemon idle wakeups: per-thread queue and first fixes | M | — | QD |
| 229 | Benches: main wakeups, mixed-hidden, hidden layout counters, launch order | S | 023 | — |
| 230 | automation-typing-bench `--input real` (replaces old task 151) | S | — | — |
| 231 | Page-relay person cause (app bridge; gesture-token fallback, risk:high) | M | 030, 031 | — |
| 300-346 | File-group sweeps (below) | M/L | FG-base + listed | Q1-Q8, Q10, Q11, QA |
| 347 | Queue close-out: residual hits, ratchet `--update`, docs | M | 300-346 | all |

### Task details: core scheduler

**p06-scheduler-001: MainWork.post / apply / reply, with posted_from.**
- Files: `CmuxNextWakeups/MainWorkScheduler.swift`, `MainWorkScheduler+Post.swift` (new),
  `FrameBatchQueue.swift`, `BackgroundWork.swift`, `MainTaskBoard.swift`,
  `Tests/CmuxNextControlTests/MainWorkPostTests.swift` (new).
- Change:
  - Add `post(_ class:, owner:, file: StaticString = #fileID, line: UInt = #line, _ body:)`, with
    one lazily built budgeted FrameBatchQueue per class. The first post after idle runs on the
    next turn if the class may run.
  - Add `postFromAnyThread`, `apply(class, owner) async -> T`, and
    `BackgroundWork.run{}.reply(on:class:owner:)`.
  - The board records posted_from.
- Acceptance: tests on `MainWorkScheduler.testing` with a fake link:
  1. classes posted in reverse run in class order in one frame
  2. pending input defers a post until input clears or the progress rule applies
  3. the first post on an idle scheduler runs before any frame
  4. apply returns the value
  5. a reply runs on main in its class and records the posting file and line
- Test phase: fleet `swift test --filter MainWorkPostTests` and `MainFrameBudgetTests`, macOS 26
  and 27, red then green.

**p06-scheduler-002: Input-response state and typing-burst progress rule.**
- Files: `MainFrameBudget.swift`, `MainFrameBudget+Stats.swift`, `MainFrameBudgetTests.swift`.
- Change:
  - `noteDiscreteInput(expectsFrame:)` opens the state only when expectsFrame is true.
    `noteTickRenderEnded()` closes it after the first link-tick render pass that follows the input
    turn. A userBlocking commit also closes it. 100 ms cap.
  - While it is open, automation, background and idle are false. Visible waits until the pass and
    the frame.
  - For 500 ms after the last discrete input, automation and background run at least 1 task per
    100 ms and at most 10/s. Visible keeps the every-other-frame rule.
  - Stats: `yieldedToInputResponse[]`, `waitedForBurstSlot[]`, `inputResponseCapHits`,
    `maxInputResponseNanos`.
  - The open state asks the budgeted link for one tick (a frame client of the MainWorkScheduler
    that ticks while the state is open), and every measured render pass reports
    `noteTickRenderEnded`. So a key with no budgeted work queued closes at its next frame, not at
    the cap.
  - The rate bounds use the whole 100 ms on both sides, so they hold for starts off a tick too.
    Only requests count toward the rate: a batch that runs requests (the control drain) does not.
    An injected key behind its connection's requests is never held by the automation rate.
- **Decision (2026-10-26, review of 002): the two rules "0 automation tasks inside an input
  response" (section 5, item 3) and "at least 1 task per 100 ms" conflict when frame-expecting
  keys arrive every frame.** The input response wins for one frame: a due task that meets an open
  response waits for the next frame, then runs, also inside a response. At 30 keys/s the next
  frame has no open response, so no task runs inside one, and the gap between tasks is at most
  100 ms plus one frame. At a key every frame, one task per 100 ms plus one frame runs inside a
  response. The section 5 metric counts those. The lead can change this rule.
- Acceptance: injected-clock tests:
  1. a key with expectsFrame=false opens no window
  2. with expectsFrame=true, automation stays false until noteTickRenderEnded and NOT at the
     key's own CommitBoundary
  3. cap at 100 ms
  4. the frame class is unaffected
  5. keys at 30/s give automation <= 10 tasks/s and >= 1 per 100 ms
- Test phase: fleet MainFrameBudgetTests, red then green.

**p06-scheduler-003: Wire discrete input.**
- Files: `CmuxNextApp/CmuxApplication.swift`, `CmuxNextFocusUI/InputDispatchContext.swift`,
  `CmuxNextApp/AppServices.swift` (injection lines only), `CmuxNextActions/ActionRegistry.swift`.
- Change:
  - sendEvent calls `noteDiscreteInput` for keyDown, mouseDown kinds and `debug.key`.
  - expectsFrame is set from the ActionEffect kind (`.applied`, `.intentEffect`, `.waiting`), a
    `needsDisplay` request during the turn, or a ghostty draw request.
  - The link tick reports `noteTickRenderEnded`. mainWork is passed by init.
- Acceptance: nothing runs on keyUp, mouseMoved or flagsChanged. A KeyDownDispatchTests case: a
  budgeted automation post queued before a key runs after the NEXT tick's render pass (fake link).
- Test phase: fleet KeyDownDispatchTests, CommitBoundaryAppKitTests;
  `automation-typing-bench.py --input real` before and after.

**p06-scheduler-004: Rendering starvation guard on link lateness.**
- Files: `MainFrameBudget.swift`, `FrameScheduler.swift`, `FrameStall.swift`, the signpost
  catalog, MainFrameBudgetTests.
- Change: starvation = frame-class clients are active on a window whose node is visible, and the
  tick gap is over 100 ms. Never while the displays sleep or all windows are occluded. On
  starvation, gate budgeted, idle, extra CEF slices, posted deadlines and the drain automation
  tail until the next tick. Emit `stall.render_starved` with the top unattributed turn from
  MainTurnMeter.
- Acceptance: tests:
  1. a fake link that skips 12 ticks while a fake main job runs → 1 starved event that names the
     job's turn
  2. an occluded window with active clients does not stop automation
  3. the next tick re-enables
- Test phase: fleet MainFrameBudgetTests.

**p06-scheduler-005: IdleScheduler.**
- Files: `IdleScheduler.swift` (new), `MainWorkClass.swift`, `MainWorkScheduler.swift`,
  `IdleSchedulerTests.swift` (new).
- Change:
  - Add `.idle` and `postIdle(owner:, maxDelay: Duration? = nil, body: (IdleDeadline) -> Void)`.
  - Long periods come after 50 ms with no input, no active frame client and no queued budgeted
    work, with deadline = min(50 ms, MainDeadline next fire).
  - Short periods: 2 ms or more left before vsync, deadline = vsync − 1 ms.
  - Nested posts wait for the next period, and input ends the period.
  - maxDelay is opt-in; a task past it moves to background.
  - Idle periods stop 10 s after the app node, or the task's node, goes hidden, and resume on
    show.
  - The period timer is an unposted precise timer.
- Acceptance: fake-clock tests:
  - no idle while input is pending or a frame client is active
  - deadline <= 50 ms
  - nested posts wait
  - promotion only with maxDelay
  - no idle 10 s after hide
  - 0 WakeupLedger wakeups over 10 s when the queue is empty
- Test phase: fleet IdleSchedulerTests.

**p06-scheduler-006: Startup phases.**
- Files: `StartupPhase.swift` (new), `MainWorkScheduler.swift`, `StartupPhaseTests.swift` (new).
- Change: launching → revealed → settled, as in section A:
  - revealed at the first frame, at a 1.5 s precise deadline, or at once when the app is hidden or
    windowless
  - settled is a reference count with a 10 s failsafe
  - background and idle posts are held in launching
  - a Debug assertion fires when `apply(.background)` or `postIdle` is awaited in launching
- Acceptance: tests:
  - held bodies run in order after the phase change
  - visible and automation are never gated
  - windowless → revealed at 1.5 s
  - hidden launch → revealed at once
  - settled waits for all references or 10 s
- Test phase: fleet StartupPhaseTests.

**p06-scheduler-007: Wire startup phases.**
- Files: `CmuxNextDesign/Launch/LaunchReveal.swift`, `CmuxNextApp/AppDelegate.swift`,
  `CmuxNextDaemon/Store/DaemonStore+Driver.swift` (a first-snapshot callback), and the restore
  completion hook.
- Change: LaunchReveal takes `onRevealed` by init. AppDelegate wires `markRevealed` and the
  settled references (snapshot applied, restore done, visible page load-idle). No new singleton.
- Acceptance: one injected closure per reference; no new static. bench_launch.py shows
  `launch.revealed` before any background task.
- Test phase: fleet bench_launch.py cold and warm, macOS 26 and 27, and `open -g`.

**p06-scheduler-008: MainTurnMeter.**
- Files: `MainTurnMeter.swift` (new), `MainFrameBudget+Stats.swift`,
  `CmuxNextControl/Diagnostics/MainFrameBudget+Report.swift`, `CmuxApplication.swift`,
  `MainTurnMeterTests.swift` (new).
- Change:
  - Entry, afterWaiting, beforeWaiting and exit observers time each busy turn and track nesting
    depth. Only the innermost turn is attributed; the sendEvent span closes at each nested turn
    boundary.
  - Each turn splits into scheduled, render, input dispatch and unattributed time.
  - Fixed-bucket histograms fold off main.
  - `debug.main_budget` gains `turn_ms`, `task_ms`, `unattributed_share` and
    `top_unattributed_turns`. `stall.main_turn` fires over 4 ms.
  - Always on: two clock reads per turn, no allocation.
- Acceptance: tests:
  - 3 ms task + 2 ms unattributed → share 0.4
  - a nested `CFRunLoopRunInMode` inside a sendEvent span is attributed to the inner turn and not
    counted twice
  - no allocation per turn
  - report fields only added
- Test phase: fleet MainTurnMeterTests; Release per-turn overhead < 100 ns.

**p06-scheduler-009: Per-owner ledger.**
- Files: `MainTaskBoard.swift`, `MainOwnerLedger.swift` (new), `MainFrameBudget+Report.swift`,
  `MainTaskBoardSpanTests.swift`.
- Change: each post records enqueue time, posted_from and node state. The board writes a fixed
  slot (owner, class, file/line, node state, wait, run). The ledger folds off main.
  `debug.main_budget owners` lists p50/p95/p99/max.
- Acceptance: known waits land in the right buckets; ring overflow counts `dropped` and never
  blocks; node state is reported.
- Test phase: fleet MainTaskBoardSpanTests.

**p06-scheduler-010: No batcher outside the budget window.**
- Files: `CmuxNextDaemonService/FrameBatcher.swift`, `CmuxNextApp/SidebarBridge.swift`,
  `ContentPresentationScheduler.swift`, `NewTabPage+Open.swift`.
- Change: remove the default `scheduler: = .app`. SidebarRows and ContentPresentation become
  `budgeted: .visible, on: mainWork`. Their person items are unbudgeted through task 207, and
  showNow stays synchronous. NewTabPage.close uses `mainWork.frames`.
- Acceptance:
  - Q9 returns 0
  - no `FrameScheduler.app` in these files
  - BudgetedFrameBatcherTests: an automation SidebarRows flush yields to pending input; a person
    row patch (Cmd-N) runs in the same frame while 400 automation patches are queued
- Test phase: fleet BudgetedFrameBatcherTests, DaemonDrainFrameTests; sidebar-churn-typing.py
  `--input real`.

**p06-scheduler-011: MainDeadline.**
- Files: `MainDeadline.swift` (new), `TimerAlignment.swift` (new), `Deadline.swift` (new helper),
  `MainDeadlineTests.swift` (new).
- Change:
  - Add `@MainActor MainDeadline(owner:, workClass:, alignment:, scheduler:)` with a synchronous
    action through post.
  - Alignment rules are in section E (`.precise` < 36 ms, `.flexible` default, `.whenHidden`).
  - A next-fire registry; the `Deadline` helper for race timeouts.
  - DemandTimer is unchanged except that it gains `tolerance:`.
- Acceptance: fake-clock tests:
  - precise on time
  - a precise timer over 36 ms is downgraded
  - flexible within 8 ms
  - hidden → 1 s
  - repeating hidden 5 min → 60 s with 1 s-aligned wake allowed once a minute
  - one-shot hidden stays at 1 s
  - mediaActiveWithin(30 s) or a capture vote disables alignment
  - nextFire is the earliest
  - 0 wakeups when empty
- Test phase: fleet MainDeadlineTests.

**p06-scheduler-012: AlignedWakeups and visible leeway.**
- Files: `AlignedWakeups.swift` (new), `MainDeadline.swift`, `DemandTimer.swift`,
  `AlignedWakeupsTests.swift` (new).
- Change: one sleep per boundary bucket (1 s hidden, 8 ms visible flexible). Sleeps pass
  `tolerance:`.
- Acceptance: 50 hidden deadlines in one second → 1 ledger wakeup; 20 visible flexible deadlines
  in one 8 ms bucket → 1 wakeup; precise ones are exact; cancelling all of them cancels the
  bucket.
- Test phase: fleet AlignedWakeupsTests; bench_idle.py.
- As built: AlignedWakeups is the placement layer on p14-energy-013's `MainWakeUpQueue` (its one
  CFRunLoopTimer), not its own sleeps. `AlignedWakeups.Placement` (`.precise`, `.flexible`, `.hidden`)
  is the resolved form of 011's `TimerAlignment`: `MainDeadline` maps `.whenHidden(node)` to `.hidden`
  while the node is hidden and not exempt, else to `.flexible`. Hidden entries sit in a second heap
  that runs only in a fire at or after each entry's whole uptime second, so they never ride an earlier
  visible fire (Blink fences its throttled queue the same way). Blink also runs tasks that fall due in
  the 3 ms after the wake-up; cmux holds those for their own second, so a re-arming hidden owner runs at
  most once per second. DemandTimer sleeps with `WakeLeeway`'s tolerance by default (`.zero` for exact).
- Follow-up (p06-scheduler-012b, after 011 lands): `MainDeadline` places through `AlignedWakeups` on
  the composition root's `MainWakeUpQueue`. Until then no production deadline goes through
  AlignedWakeups, and bench_idle.py measures only the DemandTimer tolerance.

**p06-scheduler-013: FrameInputCoalescer.**
- Files: `FrameInputCoalescer.swift` (new), `CmuxApplication.swift`,
  `FrameInputCoalescerTests.swift` (new).
- Change: per window, `post(kind:, owner:) { (latest, coalesced, delta) in }` runs at the frame
  tick before clients. A discrete event flushes first. Owners can opt into unbuffered delivery
  until mouseUp. 1-frame fallback.
- Acceptance: 10 drags in a frame → 1 body with delta = sum and 10 coalesced events; an unbuffered
  owner gets 10 calls; a discrete flush runs pending work first; with the link down the fallback
  fires once.
- Test phase: fleet FrameInputCoalescerTests.

**p06-scheduler-014: Pre-push guardrail rules.**
- Files: `scripts/cmux-next/guardrails.py`, `tests/test_cmux_next_guardrails.py`.
- Change: add the rules main-hop (shares the predicate with task 015), view-observation,
  visibility-walk, timer-class, raw-observer and local-monitor. Each judges added lines only and
  is fail-open, with escapes. No CI step.
- Acceptance:
  - each rule flags a sample added line, ignores base lines, honors its escape and is listed in
    `--list`
  - deleting `@MainActor in` inside a main-actor scope is still flagged
  - the pass stays under 1 s
- Test phase: local `python3 -m pytest tests/test_cmux_next_guardrails.py` (portable).

**p06-scheduler-015: Arch-ratchet rows and the main-inherited predicate.**
- Files: `scripts/cmux-next/arch_counts.py`, `plans/cmux-next/arch-ratchet.json`, the arch ratchet
  tests.
- Change:
  - Add the predicate `main_inherited_tasks`, using the existing brace parser: a Task whose
    enclosing type or function is main-actor isolated.
  - Add the rows `raw_main_hops`, `unscoped_observations`, `visibility_walks`,
    `unclassed_main_deadlines` and `local_event_monitors`.
  - Teach `observer_sites` that WindowEvents and AppEvents are coalescing adapters.
  - Reuse `app_broadcast_names`. Write the totals with `--update`.
- Acceptance: fixtures:
  - a bare `Task {` in a @MainActor class counts 1
  - a nonisolated Task with reply counts 0
  - removing the annotation does not change the count
  - the totals match section 6 at the measured sha
- Test phase: local pytest; `arch-ratchet.py --check`.

**p06-scheduler-016: Docs.**
- Files: `plans/cmux-next/main-thread-budget.md`, `threading-model.md`, `PATTERNS.md`,
  `idle-wakeups.md`.
- Change: document the class table, posting API, phases, Visibility tree, observation primitives,
  recipes, cause rules, the frozen API (from task 205) and Chrome sources. Add a PATTERNS entry
  "main-thread work is posted with a class".
- Acceptance: every new type is named with its file; the recipes match the guardrail escapes; STE
  style.
- Test phase: docs only.

### Task details: visibility and observation

**p06-scheduler-020: VisibilityNode tree.**
- Files: `CmuxNextWakeups/Visibility.swift`, `VisibilityNode.swift` (new),
  `VisibilityTreeTests.swift` (new).
- Change: Visibility enum; @MainActor node with a weak parent and two child sets by own state;
  effective, isVisible, hiddenSince, mediaActiveWithin(_:); `subscribe(owner:)` tokens notified
  only on a flip; the `deferUntilVisible(key:)` hook.
- Acceptance: tests:
  - 1000 own-hidden children under a flipping parent → 0 visits and 0 notifications
  - a parent going visible notifies only own-visible children
  - tokens release on deinit
  - no strong cycle
- Test phase: fleet VisibilityTreeTests.

**p06-scheduler-021: WindowEvents and AppEvents in Wakeups.**
- Files: `CmuxNextWakeups/WindowEvents.swift` (new), `CmuxNextWakeups/AppEvents.swift` (new),
  `Tests/CmuxNextControlTests/WindowEventsTests.swift` (new).
- Change: this is A4's adapter, built in Wakeups as architecture-refactor-DESIGN.md row B says.
  Ask PL-arch first; if A4 has landed it, adopt and add only the node hook.
  - One MainActorObservation per window or app per name, created on the first subscriber and
    removed on the last.
  - `subscribe(name, node, delivery: .whenVisible/.always)`.
  - A hidden subscriber gets one `missed` call on show.
  - WindowKeyFamily (Design and App copies) moves onto it.
- Acceptance: a test NotificationCenter: 100 subscribers → 1 observer per name; hidden
  subscribers get 0 calls, then 1 on show; the last unsubscribe removes the observer.
- Test phase: fleet WindowEventsTests.

**p06-scheduler-022: Window and app visibility source.**
- Files: `CmuxNextDesign/Windows/WindowDrawPolicy.swift`,
  `CmuxNextDesign/Windows/WindowVisibilitySource.swift` (new),
  `CmuxNextTabs/WindowVisibilityObserver.swift`, `CmuxNextApp/Windows/WindowController.swift`.
- Change: the window node is fed from occlusion, miniaturize, NSApp hidden and screens asleep
  through WindowEvents and AppEvents. WindowDrawPolicy.onScreen reads the node.
  WindowVisibilityObserver becomes a thin wrapper. Get PL-switch's OK.
- Acceptance: one source of window visibility; miniaturize then deminiaturize flips the node
  twice.
- Test phase: fleet WindowEventsTests, Tabs tests.
- Decision (review of the first pass; pending PL-switch's OK): WindowDrawPolicy.onScreen does
  not read the node. It applies the node's own rule (`WindowVisibilitySource.appKitState(of:)`)
  to AppKit's live state. The draw readers (TerminalSurfaceView, SurfaceInvariantMonitor) observe
  `didChangeOcclusionState` themselves, and Foundation does not document observer order, so a
  cached node can be stale in their handler and no second notice corrects it. The app node adds
  nothing for drawing: AppKit already leaves every window occluded while the app is hidden or
  the displays sleep. The node's effective state serves the flip subscribers (tab strip,
  sidebar, workspace nodes). Draw readers can read the node once they subscribe to it instead
  of the notice (follow-up with PL-ghostty).

**p06-scheduler-023: Workspace nodes.**
- Files: `CmuxNextApp/WorkspaceContentController.swift`, `Windows/WindowController.swift`.
- Change: each controller owns a node (parent: the window). Park → hidden; unpark and
  followAttention → visible; a drawing companion → visible; off screen → hidden. State publishing
  only.
- Acceptance: LayoutHiddenMotionTests pass; park then unpark flips the node; an unmounted
  workspace has no node.
- Test phase: fleet LayoutHiddenMotionTests, FirstFrameGateTests.

**p06-scheduler-024: Pane and tab nodes.**
- Files: `PaneController.swift`, `PaneContentView.swift`, `TabContentCache.swift`.
- Change: the pane node is hidden while suspended. A tab node is visible when it is selected in a
  visible pane. `TabContentCache.node(for:)`.
- Acceptance: selecting B flips A hidden and B visible in the same turn, with 2 notifications.
- Test phase: fleet PaneController and TabContentCache suites.

**p06-scheduler-025: VisibleObservation.**
- Files: `VisibleObservation.swift` (new), `ObservationCause.swift` (new),
  `VisibleObservationTests.swift` (new).
- Change:
  - The behavior is described in section C.
  - The scheduler holds `personCauseEpoch` and `currentCause`. Flush class = person if the epoch
    moved since the observer became dirty, else the recorded cause.
  - Person flushes go to the InputResponsePass queue, or to userBlocking outside an open
    response.
  - Cancel-signal disarm on hide; show order through task 213.
  - Uses withObservationTracking on every macOS (no native Observations iterator).
- Acceptance: tests:
  1. hidden: 100 changes → 0 reads
  2. 5 changes in a frame → 1 apply
  3. hide then show → 1 read
  4. automation cause → automation class
  5. automation then person on the same property in one batch → person class
  6. after hide, the registrar holds 0 trackings
- Test phase: fleet VisibleObservationTests, macOS 26 and 27; 14 and 15 via os-matrix.sh.

**p06-scheduler-026: ServiceObservation.**
- Files: `ServiceObservation.swift` (new), `CmuxNextCompat/ObservationStream.swift` (doc only),
  `ServiceObservationTests.swift` (new).
- Change: the same tracking and coalescing as VisibleObservation, with no node. The token cancels
  on release. No `@available(deprecated)` trick: Swift cannot deprecate per importing target. Q2
  is the git grep.
- Acceptance: Equatable dedupe; a burst → 1 apply; token release stops callbacks; the class is
  honored.
- Test phase: fleet ServiceObservationTests.

**p06-scheduler-027: StoreWaiters.**
- Files: `CmuxNextDaemon/Store/StoreWaiters.swift` (new), `StoreIndex.swift`, `DaemonStore.swift`,
  `Tests/CmuxNextDaemonTests/StoreWaitersTests.swift` (new).
- Change: waitForTab (by id, surface or resource), waitForWorkspace, waitLoaded,
  waitConnection(where:) and waitTabGone, kept in keyed dictionaries and resumed by StoreIndex
  hooks. Injected-clock timeouts; resume on cancel.
- Acceptance: a waiter for X runs 0 evaluations on 1000 other inserts and resumes in X's apply;
  timeout and cancel resume with nil.
- Test phase: fleet StoreWaitersTests.

**p06-scheduler-028: PageWaiters.**
- Files: `CmuxNextBrowser/Engine/PageWaiters.swift` (new), `PageClosingTabs.swift`,
  `PageWaitersTests.swift` (new).
- Change: `page.when(phase:)` and `page.whenPrompt(kind:)`, resumed by the state setters. Move
  `PageClosingTabs.swift:25` onto them.
- Acceptance: resumes once on the transition; 0 evaluations on title changes.
- Test phase: fleet PageWaitersTests.

**p06-scheduler-029: debug.observations.**
- Files: `CmuxNextWakeups/ObservationLedger.swift` (new), `CmuxNextApp/Control/AppControl.swift`.
- Change: atomic per-owner armed, evaluated and applied counts, plus show re-read count and time,
  plus hosting body evaluations (from task 214). A DEV snapshot method with reset.
- Acceptance: per-owner fields; no lock on the hot path.
- Test phase: fleet sidebar-stress-bench.py reads it before and after one status change.

### Task details: daemon and cause

**p06-scheduler-030: Envelope-level cause (PL-daemon).**
- Files: `cmux-tui-core/src/mux/event_emit.rs`, `request_origin.rs`,
  `server/connection_scheduler.rs`, `server/connection_frame.rs`, `server/terminal_create.rs`,
  `mux/event_cause_tests.rs` (new), `cmux-tui/spec/events.md`.
- Change: `EventCause {Frontend, Program, Automation}`.
  - The dispatcher sets a scoped thread-local from RequestOrigin (User/verified_app → Frontend;
    Agent, Page → Automation). Pool jobs capture it.
  - Mux::emit stamps the envelope `"cause"`; an unscoped emit is Program.
  - No MuxEvent variant changes. Cause is documented as scheduling-only.
- Acceptance: Rust tests:
  - a CLI split → automation
  - an app split → frontend
  - a pool-finished create keeps its cause
  - an OSC title → program
  - no use of cause in origin_gate.rs or app_trust.rs (grep)
- Test phase: fleet `cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --arg
  test --arg event_cause --ref SHA`.

**p06-scheduler-031: App person cause.**
- Files: `CmuxNextDaemon/Connection/DaemonCommandScope.swift`,
  `Events/DaemonEvent+Decoding.swift`, `Store/DaemonStore+Driver.swift` (EventInbox),
  `Tests/CmuxNextDaemonTests/EventCauseTests.swift` (new).
- Change:
  - A person-entrypoint scope records its mutation_ids (bounded, 2 s expiry). An echo with such
    an id → person, else the decoded cause; a missing field → program.
  - EventInbox merges and the overflow resync keep the max cause.
  - No wire claim.
- Acceptance: a person echo → person; a socket-run echo → automation; 1 automation + 1 person on
  one surface → person; an old daemon → program.
- Test phase: fleet EventCauseTests, DaemonDrainFrameTests.

**p06-scheduler-032: Drain publishes the cause.**
- Files: `DaemonStore+Driver.swift`, `DaemonStore+Events.swift`, `ObservationCause.swift`,
  DaemonDrainFrameTests.
- Change: set `currentCause` per envelope (save and restore), and bump personCauseEpoch on a person
  apply. A local intent apply sets person.
- Acceptance: a batch of 1 automation and 1 person event: the observer changed only by automation
  posts as automation, the other one as person.
- Test phase: fleet DaemonDrainFrameTests, VisibleObservationTests.

**p06-scheduler-033: Drain cost.**
- Files: `DaemonStore+Driver.swift`, `DaemonStore.swift`, `DrainCostTests.swift` (new).
- Change: a per-batch histogram (owner DaemonStore.drain). Make `adoptUnread`, `recomputeSidebar`
  and `workspaceListMayHaveChanged` O(changed records) through StoreIndex revisions.
- Acceptance: 1000 title events across 50 workspaces → recomputeSidebar 0 times; the counters
  prove it.
- Test phase: fleet DrainCostTests; script-storm-bench `--hidden` drain p99 <= 1 ms.
- As built: the unread sum (`UnreadLedger`, kept by StoreIndex) and the workspace-list check (an
  order-free digest in StoreIndex) cost the workspaces that joined, left or changed their own count.
  `recomputeSidebar` is still O(workspaces), but runs only for a batch that changed the order, the
  membership or a group; a replayed add, a move to its own place and the lift and restore of an
  unchanged overlay run none. `debug.drain_cost` reports the histogram (the owner ledger's buckets)
  and the counters; script-storm-bench `--hidden` reads its p99.
- Follow-up (p06-scheduler-033b): patch only the sidebar sections a batch touches. Placing a moved
  workspace inside its section needs its daemon-order position without a walk of the list (an
  order-statistic index over `workspaces`); until then one flattening is O(workspaces).
- Follow-up (to p09-observability-000): a `HistogramID` for the drain (in us, owner PL-daemon), so
  each drain also records through `Metrics`; the catalog is frozen, so DrainCost keeps a local one.

**p06-scheduler-034: Lock admission by class.**
- Files: `mux/signaled_mutex.rs`, `lock_rank.rs`, `diagnostics.rs` (per-class LockStats), the
  registry connection lock in `workspace_registry/registry_connection.rs`, `server/priority_gate.rs`
  (new helper), `mux/signaled_mutex_class_tests.rs` (new).
- Change: admission inside `SignaledMutex::lock`, `lock_state_pinned` and the registry connection
  lock, reading the thread-local cause:
  - frontend callers increment a waiting counter; automation waits on the release condvar while it
    is above 0, bounded to 4 ms
  - nothing waits while another rank is held
  - this covers reader-thread request paths and pool threads
- Acceptance: Rust tests:
  - 32 automation threads + 1 frontend request → the frontend acquires within 1 critical section,
    for both lock types
  - the automation admit gap is <= 4 ms
  - a 10k-iteration stress run (or loom) has no deadlock
  - per-class wait p95 is in server-stats
- Test phase: fleet `cmux-tui-rust-check.sh test signaled_mutex_class`; perf-10x-daemon.sh with
  64 clients.

**p06-scheduler-035: Daemon QoS.**
- Files: `server/connection_scheduler.rs`, `server/line_connection.rs`,
  `cmux-tui-platform/src/qos.rs` (new), `plans/cmux-next/threading-model.md`.
- Change: verified-app dispatchers run at USER_INITIATED. Automation work outside locks runs at
  UTILITY, and is raised with `pthread_override_qos_class_start_np` while it holds a state or
  registry lock. The journal writer goes to UTILITY only after PL-daemon's "no request waits on the
  journal" lands. Coordinate with PL-qos.
- Acceptance:
  - a Rust test reads `qos_class_self()` per class and while a lock is held
  - under CPU contention, a frontend request queued behind a UTILITY holder completes within 1
    critical section
  - the threading-model rows are updated in the same push
- Test phase: fleet `cmux-tui-rust-check.sh test qos`.

**p06-scheduler-223: Drain ordered flush by cause.**
- Files: `DaemonStore+Driver.swift`, `DaemonStore+Events.swift`, `Store/FrameBatchScheduler.swift`,
  `Store/EventInboxCoalesceKey.swift`, `Tests/CmuxNextDaemonTests/DrainCauseSplitTests.swift`
  (new).
- Change: section D:
  - the frame drain applies up to and including the last person or frontend transaction
  - the tail is one ordered queue, one whole transaction per task, in its head's class, with a
    2 ms slice
  - a resync stays in the frame class
  - waiters advance per transaction
- Acceptance: tests:
  1. [auto ×100, person] → all 101 apply in the frame turn, in order
  2. [auto ×1000] → spread over frames within the automation share, none split
  3. a waiter for N fires after N
  4. a person arrival flushes the queued tail first
- Test phase: fleet DrainCauseSplitTests, DaemonDrainFrameTests; automation-typing-bench
  `--input real` storm minus idle p99.

**p06-scheduler-224: Daemon fan-out.**
- Files: `cmux-tui-core/src/event_bus.rs`, `mux/event_emit.rs`, `event_bus_tests.rs`.
- Change: scoped subscribers are indexed by SurfaceId and events are `Arc<MuxEvent>`. Emits under
  `Mux::state` go to a per-thread buffer and are published after the guard drops. The frontend
  mailbox goes first.
- Acceptance: 500 SurfaceSession subscribers + a TitleChanged → 1 scoped filter run; no clone per
  subscriber; a lock_rank debug check proves emit never runs under `Mux::state`; order per
  subscriber is unchanged.
- Test phase: fleet `cmux-tui-rust-check.sh test event_bus`; perf-10x-daemon.sh.

**p06-scheduler-225: Reserved frontend worker permits.**
- Files: `server/worker_admission.rs`, `server/connection_frame.rs`.
- Change: keep 2 surface and resource worker permits that only verified-app connections can take.
- Acceptance: with automation holding every shared permit, a frontend surface op is admitted at
  once.
- Test phase: fleet `cmux-tui-rust-check.sh test worker_admission`.

**p06-scheduler-226: Lock histograms.**
- Files: `mux/signaled_mutex.rs`, `diagnostics.rs`, `lock_rank.rs`.
- Change: wait and hold time per acquisition, by origin and op (thread-local request scope), in
  fixed-bucket atomic histograms. Add the `debug.daemon_locks` op.
- Acceptance: a forced 5 ms automation hold shows in that op's hold histogram and in the waiting
  frontend op's wait histogram; 2 clock reads per acquisition.
- Test phase: fleet `cmux-tui-rust-check.sh test signaled_mutex`; perf-10x-daemon.sh.

**p06-scheduler-227: Visibility-scoped frontend subscription.**
- Files: `event_bus.rs`, `server/frontend_visibility.rs` (new), `cmux-tui/spec/events.md`,
  `CmuxNextDaemon/Connection/DaemonConnection+Commands.swift`,
  `CmuxNextApp/Visibility/FrontendVisibilityReporter.swift` (new; a move of reporting wiring; if
  app-type refuses, place it in CmuxNextDaemonService).
- Change: the `frontend.visibility.set` op, sent at most once per frame. In the frontend mailbox,
  field events of hidden surfaces go into CoalescedEventKey slots on a 1 s aligned flush, flushed
  at once on show. Structural events pass at once. Automation subscribers are not affected.
- Acceptance: 1000 hidden title changes in 1 s → 1 event; show flushes within 1 ms; an exit is
  never delayed; the app sends at most once per frame.
- Test phase: fleet `cmux-tui-rust-check.sh test frontend_visibility`; bench_idle.py with busy
  hidden terminals; script-storm `--hidden`.

**p06-scheduler-228: Daemon idle wakeups.**
- Files: `scripts/cmux-next/bench_idle.py`, the daemon threads that the queue finds (277
  `recv_timeout`, 80 `wait_timeout` and 132 `thread::sleep` sites in core, server-core and tui).
- Change: per-thread wakeups by thread name (from `proc_pidinfo` deltas). Fix the first entries:
  blocking waits with an explicit wake, and aligned long periods for maintenance when no client is
  active.
- Acceptance: `daemon_threads` is in the JSON; the idle sum is <= 0.5/s after the fixes.
- Test phase: fleet bench_idle.py terminals and chromium-hidden.

**p06-scheduler-231: Page-relay person cause.**
- Files: `CmuxNextPages/PageHostBridge.swift`, `WebKitPageHostBridge.swift`,
  `ChromiumPageHostBridge.swift`, `DaemonCommandScope.swift`; only for the fallback:
  `request_origin.rs`.
- Change: first check whether page-relay requests pass through the app bridge.
  - If they do: requests sent within 1 s of a real gesture in that page get a mutation_id that is
    recorded as person (task 031).
  - If they do not: a single-use gesture token from the verified app (the same pattern as
    `origin.confirmation.issue`). The daemon accepts `input` only with the token. This is
    `risk:high` and needs an independent review receipt.
- Acceptance: a composer send after a key-down → person; without a gesture → automation; a
  replayed token is refused (fallback only).
- Test phase: fleet Pages suites; `cmux-tui-rust-check.sh test request_origin` (fallback);
  home-typing-still.py under the CLI storm.

### Task details: adopters

**p06-scheduler-036: BrowserHost provider and automation in the automation class.**
- Files: `CmuxNextBrowserHost/BrowserHostProvider.swift`, `BrowserHostProvider+Tabs.swift`,
  `CmuxNextBrowserAutomation/TabWatcher.swift`, `DialogBroker.swift`.
- Change: provider command bodies go through `post(.automation, owner: "browser-host.<cmd>")`.
  The TabWatcher and DialogBroker loops become `ServiceObservation(.automation)`.
- Acceptance: BrowserHostProviderFrameTests: a command queued during pending input runs after
  it; 0 Q1 and Q2 hits in these files.
- Test phase: fleet BrowserHostProviderFrameTests; browser-use-perf.sh while typing.

**p06-scheduler-038: Automation bursts snap.**
- Files: `CmuxNextLayout/Model/LayoutModel.swift`, `CmuxNextApp/WorkspaceContentController+Intents.swift`.
- Change: the second or later automation-caused structural change per window per frame applies
  through `Motion.panes.set(...)` (the gate's no-animation path), with the cause as a parameter.
  Land with PL-motion-core's OK.
- Acceptance: 5 automation splits in one frame → 0 springs and 1 layout; 1 person split → 1
  spring; check-motion.sh passes.
- Test phase: fleet LayoutHiddenMotionTests plus the new case; script-storm frame drops.

**p06-scheduler-039: ControlSnapshotPublisher off the visible path.**
- Files: `CmuxNextApp/Control/ControlSnapshotPublisher.swift`, ControlSnapshotLazyPublishTests.
- Change: publishNow runs as background behind a dirty flag. A fresh-snapshot reader promotes it
  to automation for its request. The 2 tracking loops become `ServiceObservation(.background)`.
- Deviation (as built): the 2 loops are not `ServiceObservation`s. They are one shared one-shot
  tracking with a dirty bit (`DirtyTracking` in the publisher file). It arms again only when a
  publish reads, and it calls the publisher on the first change. `ServiceObservation` is wrong here
  for 2 reasons. It reads again on every flush, and the topology read is the whole build. It also
  flushes a person-caused change in the input-response pass, and here the reader's need sets the
  class, not the cause. A reader that waits raises the pending publish to automation through the
  store's `waiterAdded` hook, also when it starts to wait after the change (`action.run`,
  `after: "sync"`). A model change does not mark the store stale. Only a work-queue frame does, so
  a plain read gets the last published value. `system.ping`, `debug.hangs` and `debug.queue`
  (`readingLastPublished()`) never wait for a build, and `fresh(deadline:)` is bounded by the
  request deadline.
- Acceptance: 50 changes in a frame → 1 publish; never inside an input-response window.
- Test phase: fleet ControlSnapshotLazyPublishTests; sidebar-churn-typing.py.

**p06-scheduler-040: SidebarRowFeed observes only rows on screen (a590).**
- Files: `CmuxNextSidebar/Store/SidebarRowFeed.swift`, `Views/SidebarListView+Layout.swift`,
  SidebarRowFeedTests.
- Change: row nodes follow the visible range plus 1 screen of overscan. Only visible rows are
  armed. A row scrolled out is disarmed and marked stale by revision, and re-mapped once on
  scroll-in if its revision moved.
- Acceptance: 400 rows, 30 visible → <= 60 armed; an off-screen change → 0 maps; scroll-in → 1
  map.
- Test phase: fleet SidebarRowFeedTests; sidebar-churn-typing.py at 400 workspaces.

**p06-scheduler-041: PointerHover.**
- Files: `CmuxNextDesign/PointerHover.swift`, PointerHoverTests.
- Change: a per-window registry keyed by hit view. A key or window change refreshes at most the
  target under the pointer and the previous one. Moves go through FrameInputCoalescer.
- Acceptance: 500 targets + a key change → <= 2 `place()` calls.
- Test phase: fleet PointerHoverTests; Cmd-Tab-back bench.

**p06-scheduler-042: StatusIndicatorView on its node.**
- Files: `CmuxNextDesign/StatusIndicator/StatusIndicatorView.swift`.
- Change: remove the per-indicator occlusion observers and walks. The spinner frame client runs
  only while the row or tab node is visible.
- Acceptance: no addObserver, occlusionState or walk left in the file; a hidden indicator has no
  active client.
- Test phase: fleet StatusIndicator tests; bench_idle.py.

**p06-scheduler-043: AppearanceSignals.**
- Files: `CmuxNextDesign/Motion/Motion.swift`, `HoverCards/HoverCardTiming.swift`,
  `WindowMaterialView.swift`, `AppearanceSignals.swift` (new).
- Change: reduceMotion, speed, hoverCards and inactiveDim become one @Observable, injected by
  AppServices. AppEvents observes `accessibilityDisplayOptionsDidChange` once. Readers use
  VisibleObservation. Delete the 4 names.
- Acceptance: 4 fewer names; exactly 1 a11y observer.
- Test phase: fleet Design Motion suites; Reduce Motion toggle at 60 workspaces → evaluations only
  for visible views.

**p06-scheduler-044: Ghostty configRevision (PL-ghostty).**
- Files: `CmuxNextTerminal/GhosttyRuntime.swift`, `CmuxNextApp/GhosttyConfigLiveReload.swift`.
- Change: an observable `configRevision`; visible surfaces observe it, and hidden ones re-read on
  show. Delete `configDidChange`.
- Acceptance: the name is deleted; a reload with 20 hidden terminals → 0 hidden work.
- Test phase: fleet CmuxNextTerminalTests config cases.

**p06-scheduler-045: Sidebar broadcasts (a590).**
- Files: `CmuxNextSidebar/Store/SidebarDocStore.swift`, `CmuxNextSidebar/Model/SidebarModel.swift`.
- Change: refused, settled and itemFaviconsChanged become store-instance callbacks or revisions.
- Acceptance: 3 fewer names; the tests use the store API.
- Test phase: fleet CmuxNextSidebarTests.

**p06-scheduler-046: Child-page geometry registry.**
- Files: `CmuxNextBrowserCore/Engine/BrowserWindowOcclusion.swift`, `CmuxNextBrowser/CEF/CEFHostView.swift`,
  `CEF/ChildPageGeometryRegistry.swift` (new).
- Change: replace `browserChildWindowPagesNeedUpdate` and `geometryDidChange` with a per-window
  dirty-set registry. Skip if F1 layer hosting has already deleted the child windows.
- Acceptance: 2 fewer names; moving 1 of 10 hosts → 1 post.
- Test phase: fleet CEF host tests; pane-perf.sh.
- Status: partial (cp/p06-scheduler-046). The per-window `ChildPageGeometryRegistry` replaced
  `browserChildWindowPagesNeedUpdate` (by then the `BrowserPageUpdates` notification): one registry per window, kept
  on the window as `WindowEvents` is, reached through `NSWindow.updateBrowserPageGeometry(force:)`; moving 1 of 10
  hosts gives 1 post. `geometryDidChange` stays: the fork's
  `CmuxParentViewTracker` observes it, so p11-codebase-051 needs a fork call first. No dirty set: every request
  visits every page of the window, since a pane move does not reach the views in it and the layout does not name
  the panes it moved.

**p06-scheduler-047: Hidden windows stop non-essential frame clients.**
- Files: `CmuxNextWakeups/FrameClient.swift`, `FrameScheduler.swift`,
  `CmuxNextDesign/GlassLens/GlassBackdropFeed.swift`, `BackdropVideoView.swift`.
- Change: `visibleOnly: VisibilityNode?` (a capture vote counts as visible). Adopt it in the glass
  feed and the backdrop video.
- Acceptance: a hidden visibleOnly client is never ticked; the link drops when it is the only
  client.
- Test phase: fleet FrameScheduler tests; bench_idle.py with the app hidden.

**p06-scheduler-048: CEF pump attribution.**
- Files: `CmuxNextBrowser/CEF/CEFMessagePump.swift`, `CEFPumpSchedule.swift`.
- Change: each slice runs inside `budget.run(owner: cef.pump)` and keeps the 2 ms bound. Class: input
  while a CEF view is first responder or has an unacked input, frame otherwise. Never deferred by
  input response. No visibility classing. Tell PL-motion-cef and PL-cefhost.
- Acceptance: pump passes show in `debug.main_budget owners`; 0 deferrals while a page has focus;
  hidden-tab CDP round trip is unchanged.
- Test phase: fleet typing-frame-bench.py omnibar and page typing p99 (no worse).

**p06-scheduler-049: Launch deferrals.**
- Files: `AppDelegate.swift`, `AppServices.swift`, `AppServices+Chromium.swift`,
  `AppServices+Borders.swift`, `Cloud/AppServices+Cloud.swift`.
- Change: classify the 14 starts. First-frame needs stay immediate. Feed, updates, cloud sign-in,
  bookmark sync, history retention and the Chromium hint move to postIdle, or to background after
  reveal.
- Acceptance: every start has a class; signposts show none of the deferred starts before reveal.
- Test phase: fleet bench_launch.py cold and warm, 5 runs each.
- As built (`CmuxNextLaunch/LaunchStart.swift`): p08-startup-017/029/031 already post the Feed card,
  `Updater.start`, the device hub, the cmux-tui notices and the platform follows, each with its
  priority. Every other start of the launch turn is a `LaunchStart` case: first-frame ones run in a
  `launch.startup_task` signpost with `priority=launchTurn`; bookmark sync (Chromium's models and the
  imports' migration), closed-history retention and the Chromium hint wait for startup complete with
  feature `launchStartDeferral`. The updater's settings follow stays first-frame: `Updater.start`
  needs the person's schedule and ring, and the sidebar's What's New and tip switches follow it. A
  Mac Screen tab or Settings > Devices posts `DeviceHub.startNeeded` right after the first frame.
  The startup tip since posts `Settings.start`, `HangReports.start`, `ConfigActions.start`, `Themes.start`
  (critical), `MouseSideButtons.start`, `KeybindingsFile.start` and Ghostty's config watch, and folds the
  daemon's prompts into `Daemon.start`: those have their class as the post's priority and no `LaunchStart` case.

**p06-scheduler-050: Idle adopters.**
- Files: `CmuxNextBrowser/CEF/CEFSpareWindow.swift`, `CmuxNextChromiumWarmup/ChromiumWarmup.swift`,
  `CmuxNextApp/SidebarSnapshot/SidebarSnapshotRecorder.swift`.
- Change: spare refill `postIdle(maxDelay: 500 ms)`; warmup idle check → postIdle; snapshot writes
  start in idle, with the write off main. Tell PL-cef-tab.
- Acceptance: no poll or timer left; refill never runs inside an input response.
- Test phase: fleet cef-tab.sh new-tab times unchanged or better; bench_idle.py.

**p06-scheduler-051: MachineTabIndex.**
- Files: `CmuxNextDaemonService/MachineTabIndex.swift` (new), `CmuxNextApp/AppServices.swift`
  (injection only).
- Change: tab id/resource → daemon, kept by StoreIndex hooks; `locateTab` becomes O(1). It lives in
  DaemonService, not in CmuxNextApp (the app-type guardrail).
- Acceptance: locateTab has no loop; 10 daemons × 1000 tabs → 1 lookup.
- Test phase: fleet index tests; every-action-sweep `--only` for 3 placement actions.

**p06-scheduler-200: shouldYield and postContinuation.**
- Files: `MainFrameBudget.swift`, `MainWorkScheduler+Post.swift`,
  `CmuxNextSidebar/Store/SidebarDocStore.swift`, MainWorkPostTests.
- Change: `budget.shouldYield()` and `postContinuation` (front of the class queue). With a590's OK,
  SidebarDocStore.show runs in chunks. SidebarSameTurn.observe and publishNow are listed as Q12.
- Acceptance: a 10-chunk task that yields after chunk 3 resumes chunk 4 before later posts of its
  class; a show of 400 rows never exceeds the visible share in one frame.
- Test phase: fleet MainWorkPostTests, CmuxNextSidebarTests; sidebar-churn-typing.py.

**p06-scheduler-201: Refresh-scaled budget and a separate budget turn.**
- Files: `MainFrameBudget+Budgets.swift`, `MainFrameBudget.swift`, `MainWorkScheduler.swift`,
  `AfterFrameCommit.swift`, MainFrameBudgetTests, MainTurnMeterTests.
- Change: `passTarget = interval − 2 ms − measured render`, shares scaled by interval / 16.7 ms. The
  budgeted batch runs in its own turn, signaled after the tick commit, with deadline = next vsync −
  render estimate. Setting `debug.scheduler.inTickBudget` restores the old path.
- Acceptance: at 120 Hz the visible share is about 1.25 ms; the tick turn has no budgeted tasks;
  the budget turn ends before the deadline; both turn kinds are reported.
- Test phase: fleet suites; automation-typing-bench STRESS both settings; CA commit count per
  frame.

**p06-scheduler-202: Spike: priority-ordered main executor.**
- Files: `CmuxNextWakeups/MainExecutorHook.swift` (new), `MainWorkScheduler.swift`,
  `MainExecutorHookTests.swift` (new), `plans/cmux-next/main-thread-budget.md`.
- Change: `swift_task_enqueueMainExecutor_hook` feeds a queue chosen by job priority
  (userInitiated/high → visible, medium → automation, utility/low → background, background → idle;
  jobs started inside an input turn → input), drained by a run-loop source that yields to
  SessionInputPending. Default off.
- Decision gate:
  - all Swift suites pass with the hook on (macOS 26, 27, 14 and 15 in Tart)
  - `assumeIsolated` and `dispatch_assert_queue` still hold
  - one task's jobs keep their order
- Acceptance: 100 low jobs then 1 high job → the high one runs first; per-task order is kept; the
  setting can turn it off; the decision is recorded.
- Test phase: fleet full `swift test` with `CMUX_MAIN_EXECUTOR_HOOK=1`; automation-typing-bench
  STRESS on and off.

**p06-scheduler-203: Hang scopes and attribution.**
- Files: `MainTaskBoard.swift`, `CmuxNextApp/HangReports/WatchdogReporting.swift`,
  `CmuxNextCrashReporting/MainThreadHangEvent.swift`,
  `CmuxNextControl/Diagnostics/MainThreadWatchdog.swift`,
  `CmuxNextHangReports/HangReportBuilder.swift`, `CmuxApplication.swift`, MainTaskBoardSpanTests.
- Change:
  - per-class deadlines (section A); an overrun is reported without crashing, with owner, class,
    location and stack
  - menu, modal and drag sessions invalidate the deadlines
  - in Nightly and Release the board read stays on (one atomic load)
  - hang events gain owner, class, location and turn_ms, or `unattributed`
- Acceptance: a 300 ms visible task → 1 report with owner, class and location; the same inside menu
  tracking → 0; a hang in an unclassified job → `unattributed`; no allocation per task.
- Test phase: fleet MainTaskBoardSpanTests, MainThreadWatchdogTaskWakeTests; the hang soak.

**p06-scheduler-204: Best-effort fence.**
- Files: `BackgroundWork.swift`, `LaneScheduler.swift`, `StartupPhase.swift`, StartupPhaseTests.
- Change: while launching, `WorkPriority.bestEffort` items queue but do not start; reveal releases
  them in FIFO order.
- Acceptance: a bestEffort post waits for reveal; userVisible runs at once; a running item is not
  waited on.
- Test phase: fleet StartupPhaseTests; bench_launch.py.

**p06-scheduler-205: Wave 0, API freeze and pilot.**
- Files: the CmuxNextWakeups public signatures, `CmuxNextApp/Notifications/`,
  `CmuxNextApp/AgentCursor/`, `CmuxNextApp/AgentActivity/AgentActivityPageService.swift`,
  `CmuxNextAgentActivity/AgentActivityLineConnection.swift`, `plans/cmux-next/main-thread-budget.md`.
- Change: land every public signature (post, reply, postIdle, MainDeadline, VisibilityNode,
  queues, VisibleObservation, ServiceObservation, waiters, WindowEvents) with DocC.
  - Migrate the pilot directories with all recipes: Notifications, AgentCursor, and the scope of
    old task 037 (agent cursor and activity as automation; a hidden overlay draws nothing).
  - Bench and record the numbers. Freeze the API.
- Acceptance:
  - the pilot directories have 0 queue hits
  - a hidden NotificationsPage → 0 panel evaluations
  - 100 cursor updates for a hidden workspace → 0 applies
  - the doc records before and after unattributed share, key-to-frame and observations with sha
    and host
  - fan-out starts only when the pilot is no worse
- Test phase: fleet Wakeups suites, Notifications and AgentCursor suites;
  automation-typing-bench `--input real` and bench_idle.py before and after.

**p06-scheduler-206: InputResponsePass.**
- Files: `CmuxNextWakeups/InputResponsePass.swift` (new), `MainFrameBudget.swift`,
  `VisibleObservation.swift`, `InputResponsePassTests.swift` (new).
- Change: a beforeWaiting observer at `CommitBoundary.order − 1`, installed only while a response
  is open. It drains person dirty observations and person batch items, unbudgeted.
- Acceptance: tests with a fake run loop:
  1. key → model change → apply runs before that turn's commit
  2. automation-only changes are not applied in the pass
  3. automation then person on the same property → applied in the pass
  4. the observer is absent when no response is open
- Test phase: fleet InputResponsePassTests; automation-typing-bench `--input real` p50.

**p06-scheduler-207: FrameBatchQueue cause.**
- Files: `FrameBatchQueue.swift`, `CmuxNextApp/SidebarBridge.swift`, BudgetedFrameBatcherTests.
- Change: `enqueue(cause:_:)`. Person and frontend items drain unbudgeted (pass or tick), the rest
  stay budgeted. SidebarRows passes the store change's cause.
- Acceptance: 400 automation patches + 1 person patch → the person one runs in the same turn or
  next frame; the automation ones spread out.
- Test phase: fleet BudgetedFrameBatcherTests; every-action-sweep `--only workspace.new` STRESS.

**p06-scheduler-208: userBlocking class.**
- Files: `MainWorkClass.swift`, `BudgetedWorkClass.swift`, `MainFrameBudget+Budgets.swift`,
  `MainFrameBudget.swift`, `CmuxNextActions/ActionRegistry.swift`, MainFrameBudgetTests.
- Change: `.userBlocking` runs before visible, does not yield to its own response and closes it on
  commit. Cap = visible + automation shares, with a progress rule. `.waiting` completions and
  person-scope replies use it.
- Acceptance: 50 visible queued → userBlocking runs first; it runs while its response is open; a
  flood is capped and visible progresses every second frame.
- Test phase: fleet MainFrameBudgetTests; every-action STRESS for Cmd-T, Cmd-N and Cmd-W.

**p06-scheduler-209: Per-node task queues.**
- Files: `CmuxNextWakeups/MainTaskQueue.swift` (new), `VisibilityNode.swift`,
  `MainWorkScheduler+Post.swift`, `MainTaskQueueTests.swift` (new).
- Change: `node.queue(class, owner)` with an enabled voter. A hidden node holds visible and
  automation posts and coalesces them by key; background runs at aligned wakes. `freeze()` runs
  nothing. On show, held tasks run first in the next frame. On deinit the queue drops its tasks
  (the doc says why). `post` without a node needs `// node-free:` for hideable owners.
- Acceptance:
  1. 100 keyed posts while hidden → 0 runs, then 1 on show
  2. frozen → 0 runs
  3. after deinit, closures are released (weak probe)
  4. the board's node state proves 0 hidden visible/automation runs
- Test phase: fleet MainTaskQueueTests, MainWorkPostTests.

**p06-scheduler-210: CPU-time budget pool.**
- Files: `CPUTimeBudgetPool.swift` (new), `MainTaskQueue.swift`, `MainDeadline.swift`,
  `CPUTimeBudgetPoolTests.swift` (new).
- Change: hidden-node work is charged to the pool, which refills 10 ms/s up to a 100 ms cap. A
  negative balance waits for the next aligned wake that has budget. Media and capture are exempt.
- Acceptance: 20 ms per fire is limited to an average of 10 ms/s; visible work is never charged;
  exempt nodes are never deferred.
- Test phase: fleet CPUTimeBudgetPoolTests; script-storm `--hidden 50` CPU%.

**p06-scheduler-211: Capture votes.**
- Files: `VisibilityNode.swift`, `CmuxNextBrowserHost/BrowserHostProvider+Frames.swift`,
  `CmuxNextMobileHost/IPhoneBrowserHosts.swift`, `CmuxNextMacScreen/MacScreenShareHost.swift` (the
  files that own the capture paths; confirm the names).
- Change: `captureVote(reason:, stayHidden:)`. Agent screenshots and screencasts of hidden tabs,
  the iPhone browser host and screen share take one.
- Acceptance: a voted hidden node ticks its visibleOnly client and applies observations; timers
  stay aligned when stayHidden; release → 1 flip, 1 notification.
- Test phase: fleet VisibilityTreeTests, provider frame tests; an agent screenshot of a hidden tab
  is fresh.

**p06-scheduler-212: Chromium visibility shim (PL-cef-tab).**
- Files: `CmuxNextBrowser/CEF/CEFTab+Visibility.swift` (new), `CEFShimLibrary.swift`,
  `CEFTab+Freeze.swift`, `CmuxNextApp/Hibernation/BrowserHibernation.swift`, the fork shim
  `cmux_shim_tab_set_visibility` (fork API bump).
- Change: the tab node drives HIDDEN, OCCLUDED or VISIBLE. A capture vote with stayHidden keeps
  rendering. The freeze stays second. Without the shim (forkFeatures), today's behavior stays.
- Acceptance:
  - hide → `document.visibilityState === 'hidden'` before the next frame, and a rAF counter reads
    0/s before the freeze
  - show → visible in the show turn
  - an occluded window → OCCLUDED
- Test phase: fleet CEF tab tests; bench_idle.py, 10 hidden tabs, renderer wakeups in the first
  30 s.

**p06-scheduler-213: Show order.**
- Files: `VisibilityNode.swift`, `VisibleObservation.swift`, `VisibilityShowCostTests.swift` (new).
- Change: on show, on-screen observers in the focused pane (and `firstFrame` subscribers) run in
  sync; the rest post userBlocking tasks in viewport order. `warm` votes re-read in idle. The
  ledger records show cost.
- Acceptance: a workspace with 12 panes and 400 hidden row observers shows → sync re-reads only
  for on-screen ones; the rest within 2 frames.
- Test phase: fleet VisibilityShowCostTests; bench_tab_switch.py and rapid-switch-e2e.py p95
  < 16 ms.

**p06-scheduler-214: VisibilityGatedHostingView.**
- Files: `CmuxNextDesign/VisibilityGatedHostingView.swift` (new), `ObservationLedger.swift`, and
  the tab-content hosting sites:
  - `CmuxNextApp/Checklist/WorkspaceTodoPageService.swift`
  - `Handlers/ChiefMemoryPageService.swift`
  - `RightSidebar/DockSectionHostView.swift`, `RightSidebar/MachineSectionHostView.swift`
  - `TaskManager/TaskManagerPageService.swift`, `Vault/VaultHostView.swift`
  - `CmuxNextFeed/FeedHostView.swift`, `CmuxNextHistory/HistoryPageHostView.swift`,
    `StashPageHostView.swift`
  - `CmuxNextTasks/TasksHostView.swift`, `CmuxNextServer/ServerHostView.swift`,
    `CmuxNextBookmarks/UI/BookmarkManagerHostView.swift`
  - `CmuxNextApps/Render/AppSceneHostingView.swift`, `Section/AppSectionProvider.swift`
- Change: remove the hosting view while hidden (a snapshot layer remains) and restore it in the
  show turn. A per-page opt-out exists. A Debug body counter.
- Acceptance: a hidden TasksHostView with 100 model changes → 0 body evaluations, 1 on show;
  first responder and accessibility are restored; every tab hosting view uses it or opts out with
  a reason.
- Test phase: fleet VisibilityGatedHostingViewTests and the page suites; script-storm `--hidden`
  with a Tasks page open.

**p06-scheduler-215: deferUntilVisible and the first adopters.**
- Files: `VisibilityNode.swift`, `CmuxNextTabs/TabStripView*.swift`,
  `CmuxNextTerminal/TerminalSurfaceView.swift` (PL-ghostty), `CmuxNextControl` layout counters
  (`appearance_applies`).
- Change: `deferUntilVisible(key)`. Write the R-appear and R-hide recipes and adopt them in
  TabStripView (delete `modelChangedWhileHidden`) and TerminalSurfaceView (`isShown`). The 161
  appearance overrides and 54 hide/unhide sites are migrated by the FG sweeps.
- Acceptance: the theme-flip test with 50 hidden workspaces runs the deferred bodies only for the
  visible one, then once per workspace on show; the flags are deleted.
- Test phase: fleet Tabs and Terminal suites, LayoutHiddenMotionTests.

**p06-scheduler-216: Queue generator.**
- Files: `scripts/cmux-next/p06_queue.py` (new), `tests/test_p06_queue.py` (new).
- Change: section 6: union, group, pack, owner and recipes per file, and `--check <group>`.
- Acceptance: a file hit by 3 queues is in 1 task with 3 recipes; no file is in two tasks; owners
  match OWNERS.md.
- Test phase: local pytest (portable).

**p06-scheduler-217: MainDelivery class and raw hops.**
- Files: `CmuxNextWakeups/MainDelivery.swift`, `CmuxNextCompat/MainRunLoopBlock.swift`,
  `CmuxNextControl/Concurrency/ControlFrameSource.swift`.
- Change: `MainDelivery(class:owner:)` is required. Off-main delivery goes through
  `postFromAnyThread`; inline delivery is recorded on the board. `MainRunLoopBlock` gains a class.
  The sites migrate in the FG sweeps.
- Acceptance: MainDelivery cannot be built without a class (compile); the board records inline
  deliveries.
- Test phase: fleet MainWorkPostTests.

**p06-scheduler-218: Ghostty tick (PL-ghostty).**
- Files: `CmuxNextTerminal/GhosttyRuntimeCallbacks.swift`, `GhosttyRuntime.swift`,
  `GhosttyRuntime+Background.swift`, `GhosttyActionDispatcher.swift`,
  `Tests/CmuxNextTerminalTests/GhosttyTickClassTests.swift` (new).
- Change: section E.
- Acceptance: 100 setTitle in a frame → 1 apply; hidden → 0, then 1 on show; `ghostty.tick` in
  owners; no `DispatchQueue.main.async` left in the callbacks file.
- Test phase: fleet GhosttyTickClassTests, CmuxNextTerminalTests; automation-typing STRESS with 10
  agents; bench_idle terminals.

**p06-scheduler-219: CEF events (PL-motion-cef, PL-cefhost).**
- Files: `CmuxNextBrowser/CEF/CEFRuntime+Events.swift`, `CEFLayerHosting.swift`, `CEFPaneHost.swift`,
  `CEFEngine+Passwords.swift`.
- Change: section E.
- Acceptance: 50 progress events for a hidden tab → 0 visible tasks, 1 apply on show; a crash is
  never coalesced; no raw hop left in these files.
- Test phase: fleet CmuxNextBrowserTests; typing-frame-bench omnibar while 5 hidden tabs load.

**p06-scheduler-220: InputObserverHub.**
- Files: `CmuxNextWakeups/InputObserverHub.swift` (new), `CmuxApplication.swift`,
  `CmuxNextAgentPane/AgentPaneView.swift`, `AgentSubagentPanes.swift`,
  `CmuxNextTerminal/TerminalModifierMonitor.swift`, `CmuxNextLayout/Views/LayoutRootView.swift`,
  `InputObserverHubTests.swift` (new).
- Change: sendEvent calls the hub once. Subscriptions by mask, window and node; only visible ones
  in the event's window run. Time is recorded as input dispatch. Migrate the per-instance monitors;
  the rest go to the FG sweeps (R-monitor).
- Acceptance: 40 hidden agent panes + 1 visible → 1 closure runs per keyDown (41 before); 0
  monitors left in the 4 files.
- Test phase: fleet InputObserverHubTests, AgentPane gesture tests; automation-typing STRESS p99.

**p06-scheduler-221: didUpdateNotification.**
- Files: `CmuxNextApp/Windows/WindowOverlayLayer.swift`, `CmuxNextDesign/Overlay/WindowOverlayHost.swift`,
  `CmuxNextRemoteBrowser/Pane/RemoteBrowserSurfaces.swift`.
- Change: a dirty flag set by geometry changes, read once at the tick or AfterFrameCommit, or the
  specific notices through WindowEvents.
- Acceptance: 0 `didUpdateNotification`; 100 keys with no overlay change → 0 syncs.
- Test phase: fleet overlay tests; automation-typing light turn p99.

**p06-scheduler-222: PageScriptPipeline batching.**
- Files: `CmuxNextPages/PageScriptPipeline.swift`, `PageRouter.swift`, `PageWebView.swift`,
  `PageScriptPipelineBatchTests.swift` (new), the `webviews/` router (batch form).
- Change: section E. Run `scripts/web-lint.sh`.
- Acceptance: 20 envelopes in a frame → 1 evaluate; hidden: 100 state envelopes → 0, then 1 on
  show with the last value; Gate reply order is unchanged.
- Test phase: fleet CmuxNextPagesTests; home-typing-still.py and sidebar-churn with Home open;
  `bun run check` in webviews/.

**p06-scheduler-229: Benches.**
- Files: `scripts/cmux-next/bench_idle.py`, `bench_launch.py`,
  `CmuxNextApp/Control/DebugLayoutCounters.swift`, `tests/test_bench_idle.py`.
- Change: main-thread wakeups/s, per-owner wakeups (`debug.wakeups`), the `mixed-hidden` scenario;
  `hidden_workspace_layouts` and `hidden_workspace_applies`; the launch signpost order check.
- Acceptance: the JSON has `main_wakeups_per_s`, `owners`, `hidden_workspace_layouts` and
  `launch.order_ok`; the parser tests pass.
- Test phase: local pytest; fleet one run at base.

**p06-scheduler-230: automation-typing-bench `--input real`.**
- Files: `scripts/cmux-next/automation-typing-bench.py`, `sidebar-churn-typing.py` (shared helper).
- Change: share the real-input helper; `--input {debug,real}`; idle and storm p50/p95/p99/max per
  mode; `debug.main_budget` turn p99, unattributed share and yielded counts. STRESS already exists
  as `--layouts`.
- Acceptance: `--help` lists `--input`; the JSON has the fields.
- Test phase: fleet GUI host with the input grant, at base.

**p06-scheduler-150: script-storm-bench `--hidden N`.**
- Files: `scripts/cmux-next/script-storm-bench.py`, its test.
- Change: N hidden workspaces and 1000 CLI ops. Report main ms/op, hidden-node tasks by class,
  `hidden_workspace_layouts` and frontend mailbox events per hidden surface. Numbers only.
- Acceptance: parse test; `--help` documents it.
- Test phase: fleet before and after.

**p06-scheduler-152: Observers per event bench.**
- Files: `scripts/cmux-next/sidebar-stress-bench.py`.
- Change: a phase: one CLI status change → the `debug.observations` delta.
- Acceptance: `row_maps_per_change` and `armed_rows` in the output.
- Test phase: fleet before and after task 040.

**p06-scheduler-160: Test phase.**
- Files: `plans/cmux-next/perf-lead.md`, `main-thread-budget.md`.
- Change: at the merge-base and the program head, on 120 Hz virtual displays, macOS 26 and 27
  (14 and 15 in Tart, function only), run:
  - every-action-sweep, light and STRESS
  - sidebar-churn-typing and automation-typing `--input real`
  - script-storm `--hidden 50`
  - bench_idle mixed-hidden, window visible and app hidden
  - bench_launch, including `open -g`
  - perf-10x-daemon with 64 clients
  - bench_tab_switch with 12 panes
  - a theme toggle at 50 workspaces
  - a 30-min STRESS hang soak

  Also run every unit suite named in done check 13 that the sweeps deferred. Record the numbers in
  perf-lead.md section 5. Each unclassed owner over 1 ms p99 and each `unattributed` hang becomes
  a Q12 task.
- Acceptance: every done check has before and after numbers with sha and host; misses are listed
  as follow-up tasks.
- Test phase: this task is the test phase.

**p06-scheduler-161: Deep review.**
- Files: `.claude/workflows/cmux-next-deep-review.js` (run, not edit).
- Change: run it on the landed range with these lenses:
  - class choice (no person change behind automation)
  - lost updates on show and side effects lost while hidden
  - waiter timeouts
  - daemon admission bound and QoS inversion
  - the macOS 14 tracking path
  - cause never used for authorization
- Acceptance: each finding has a fix with a regression test, or a written refutation.
- Test phase: fixes run their suites on the fleet.

**p06-scheduler-347: Queue close-out.**
- Files: residual hits from `p06_queue.py`, `plans/cmux-next/arch-ratchet.json`, docs.
- Change: migrate the residual hits (primitives that missed the freeze, new code since the cut);
  run `arch-ratchet.py --update`; record the final counts.
- Acceptance: every section 5 check-11 count is at target.
- Test phase: fleet compile-check; the suites of the touched files.

### File-group sweeps (FG300-FG346)

**Common spec for every FG task:**
- Change: apply every recipe to every queue hit in the group's files (`p06_queue.py --group N`
  lists them): R-hop, R-delivery, R-obs, R-wait, R-index, R-notif, R-vis, R-hide, R-timer,
  R-input, R-monitor, R-appear. Each replacement names a class, an owner and, where hideable, a
  node. Add one harness case per migrated owner class (rule 9).
- Acceptance: `p06_queue.py --check <group>` returns 0 hits except reviewed escapes. No new
  `await` in a bindEffect handler. Person-visible changes stay in the turn. Side effects still run
  while hidden.
- Test phase: fleet `cmux-ci compile-check --app --package macOS/CmuxNext` at landing; the
  group's suites and benches in the test phase (task 160).
- Depends on: FG-base plus the extra listed.

Hit counts are union hits at 772cdfc45ac (Q1b approximate).

| ID | Group (under `Packages/macOS/CmuxNext/Sources/`) | Hits | Size | Extra deps | Owner to tell | Suites and benches |
|---|---|---|---|---|---|---|
| 300 | CmuxNextApp root files A* | 63 | L | 049 | — | CmuxNextAppTests (Agent*, App*); every-action `--only` |
| 301 | CmuxNextApp root files B*–M* | 56 | M | — | — | BrowserTabService, ChatSettings, GhosttyConfig suites |
| 302 | CmuxNextApp root files N*–S* (Pane*, Sidebar*, Surface*) | 60 | L | 023, 024, 049, 207 | a590 (SidebarBridge) | PaneController, Sidebar churn; sidebar-churn-typing |
| 303 | CmuxNextApp root files T*–W* (TabContentCache*, WindowRoot*, WorkspaceContentController) | 54 | M | 302 | PL-switch | LayoutHiddenMotionTests, FirstFrameGateTests; bench_tab_switch |
| 304 | CmuxNextApp/Handlers A*–B* | 48 | M | — | — | every-action `--only` (touched ids), light and STRESS |
| 305 | CmuxNextApp/Handlers C*–H* | 49 | M | — | — | every-action `--only` |
| 306 | CmuxNextApp/Handlers K*–W* | 67 | L | — | — | every-action `--only`; Cmd-W 0 missed frames |
| 307 | CmuxNextApp/Control | 67 | L | 039 | — | CmuxNextControlTests, ControlSnapshotLazyPublishTests |
| 308 | CmuxNextApp/Home | 61 | L | — | PL-typing | Home suites; home-typing-still.py |
| 309 | CmuxNextApp/{Pages,InternalPages,NewTab,Viewers} | 64 | L | 222 | — | app page suites |
| 310 | CmuxNextApp/Windows | 52 | M | 022, 221 | PL-switch | bench_tab_switch, rapid-switch-e2e |
| 311 | CmuxNextApp/{Focus,InputVerification,GlobalHotKeys,SleepyMode} | 45 | M | — | focus.md owner | focus suites |
| 312 | CmuxNextApp/{Cloud,SessionTransfer,ServerUpdates} | 58 | M | — | — | CloudMoveTests |
| 313 | CmuxNextApp/{Remote,RemoteView,Server,Phone,MacScreen} | 49 | M | — | — | ServerReachAdmissionTests |
| 314 | CmuxNextApp/{Feed,HangReports,Crash,ErrorJournal,Quit,Usage,SidebarSnapshot} | 42 | M | 203 | — | HangReports suites; quit deadlines keep `.flexible` no-sooner |
| 315 | CmuxNextApp/{Onboarding,Themes} | 51 | M | — | — | Onboarding, Themes suites |
| 316 | CmuxNextApp/{Bookmarks,History,FileExplorer,FilesPane} | 51 | M | 005 | — | History, Bookmarks suites |
| 317 | CmuxNextApp/{Drag,HostPressure,TopPages} | 54 | M | — | — | surface-drag-stress.py |
| 318 | CmuxNextApp/{Hibernation,BrowserProfiles,Screenshots,Apps,Screens,LayoutTemplates} | 58 | M | 212 | — | hibernation suites |
| 319 | CmuxNextApp/{Permissions,ComputerUse,RightSidebar,BrowserHost,AgentRecents,DeepLinks,Settings,SidebarSections,Hints} | 57 | M | 214 | — | touched suites |
| 320 | CmuxNextApp remaining small dirs (LinkHints, Links, Projects, IconPicker, ClipboardReads, Stash, Vault, AgentActivity, Passwords, AgentHarnesses, TabSearch, DesignMode, PaletteUsage, Favicons, Accounts, BrowserHits, ChiefMove, GlobalSearch, IconAssets, Pairing, QuickComposer, TaskManager) | about 45 | M | 214 | — | compile-check |
| 321 | CmuxNextBrowser/UI | 64 | L | — | — | CmuxNextBrowserTests; typing-frame-bench omnibar |
| 322 | CmuxNextBrowser/CEF | 63 | L | 048, 212, 219, 050 | PL-motion-cef, PL-cef-tab | CEF tab tests; cef-tab.sh |
| 323 | CmuxNextBrowser/{WebKit,PageInfo,Engine,Core,Omnibox,Screenshot} | 58 | M | — | — | CmuxNextBrowserTests |
| 324 | CmuxNextDesign root files | 71 | L | 043, 041, 047 | — | CmuxNextDesignTests; check-motion.sh |
| 325 | CmuxNextDesign/{Overlay,Dialog,Toast,Tooltip,Quit,Windows} | 48 | M | 221 | — | overlay, hover suites |
| 326 | CmuxNextDesign/{StatusIndicator,Motion,HoverCards,ColorTransition,GlassLens,Launch,FindPill,Text,Diagnostics} | 44 | M | 042, 043 | PL-motion-core | Motion suites; check-motion.sh |
| 327 | CmuxNextSidebar/Views first half (by file name) | about 61 | L | 040 | a590 | CmuxNextSidebarTests; sidebar-stress-bench |
| 328 | CmuxNextSidebar/Views second half | about 61 | L | 040, 327 | a590 | CmuxNextSidebarTests |
| 329 | CmuxNextSidebar/{Store,Model,Logic} + CmuxNextTabs | 60 | L | 040, 045, 215 | a590 | Sidebar, Tabs suites |
| 330 | CmuxNextAgentPane root files first half | about 47 | M | 220 | — | CmuxNextAgentPaneTests |
| 331 | CmuxNextAgentPane second half + FreeTier, Approvals | about 48 | M | 220, 330 | — | AgentPane suites; home-streaming bench |
| 332 | CmuxNextHome | 46 | M | 214 | PL-typing | Home suites; home-typing-still |
| 333 | CmuxNextHomeEngine, ChiefPetWiring, ChiefMemory, ChiefViews, HostedChief | 57 | M | — | — | CmuxNextHomeEngineTests |
| 334 | CmuxNextTerminal | 54 | L | 218, 044, 215, 220 | PL-ghostty | CmuxNextTerminalTests; Cmd-Tab with 40 terminals (`windowStateUpdates` <= visible count) |
| 335 | CmuxNextMacScreen | 59 | M | 211 | — | MacScreenHubTests |
| 336 | CmuxNextPages, CmuxNextPopups, CmuxNextBookmarks | 52 | M | 222 | — | CmuxNextPagesTests, CmuxNextPopupsTests |
| 337 | CmuxNextLayout, CmuxNextFloating, CmuxNextFilesUI | 63 | L | 038, 220 | PL-motion-core | LayoutHiddenMotionTests, CmuxNextFilesTests; surface-drag-stress |
| 338 | CmuxNextUpdater, WebUpdates, Settings, DesignTokens | 57 | M | — | — | CmuxNextSettingsTests |
| 339 | CmuxNextDaemon, DaemonService, DaemonRecovery, WorkspaceRepair, WorkspaceNaming, Bridge | 71 | L | 033, 223, 051 | — | CmuxNextDaemonTests, CmuxNextWorkspaceRepairTests; service targets use ServiceObservation only, request deadlines off main |
| 340 | CmuxNextControl, Wakeups (scheduler-owned escapes), Compat (MainActorObservation stays the one adapter; old task 111), Tasks, Actions, FocusUI | 62 | L | 217 | — | CmuxNextControlTests, CmuxNextCompatTests; bench_cli_storm throughput |
| 341 | AgentLanes, AgentUpdates, AgentPermissions, AgentActivity, AgentQuestion, Diff | 58 | M | — | — | AgentLanes, Diff suites |
| 342 | MobileHost, Phone, PhoneAccess, NowPlaying, KeepAwake, Devices, Mobile | 73 | L | 211 | — | CmuxNextMobileHostTests, CmuxNextPhoneTests, KeepAwake |
| 343 | CmuxNextApps, Palette, Onboarding (target) | 56 | M | 214 | — | CmuxNextAppsTests; palette-open.sh |
| 344 | CmuxNextHistory, BrowserHistory, Feed, Cloud, Server, Screenshots (targets) | 67 | L | 214 | — | History, Feed suites |
| 345 | BrowserAutomation, BrowserHost, RemoteBrowser, RemoteView, RemoteViewSessions, RemoteLocalhostService, RemoteLocalhost, BrowserCore | 70 | L | 036, 046 | — | BrowserAutomation, RemoteView suites |
| 346 | Remaining targets: Accounts, ChromiumWarmup, Dictation, Resources, CookieImport, HostPressure, ImportCards, ComputerUse, FileGrid, Files, Favicons, BrowserImport, ErrorJournal, VSCodeServer, WakeupsTestSupport, ChromiumRuntime, Remote, RemoteFetch, ServerHelper | about 57 | M | 050 | — | compile-check |

---

## 9. Review disposition

Review 1 (coverage), review 2 (correctness), review 3 (Chrome fidelity). "Confirmed" means the
fixer checked the claim in the code at 772cdfc45ac.

| Review item | Disposition |
|---|---|
| R1: Q1 misses main-inherited `Task {` (about 786) | Confirmed (heuristic 778). Applied as Q1b, the `main_inherited_tasks` predicate (015), the guardrail (014) and the FG sweeps. R1's separate ast-grep rule was dropped in favor of R2's brace-parser predicate, so the ratchet and the guardrail share one definition. Tasks R1-201..205 are folded into FG300-346. |
| R1: raw hops, MainDelivery, Ghostty, CEF events | Confirmed (`GhosttyRuntimeCallbacks.swift:21,43,124,154,160`; `CEFRuntime+Events.swift:20`; Q1c 53). Applied as 217, 218, 219 and Q1c in the FG sweeps. |
| R1: cause should map from RequestOrigin; page-relay typing | Confirmed (`request_origin.rs:70,169-170`). Applied in 030 (from RequestOrigin) and 231 (app bridge first, token fallback marked risk:high). |
| R1: gate only on mux-control-dispatch; shared permits | Applied: 034 moves admission into the locks themselves (covers the reader path and pool threads); 225 reserves permits; 226 adds histograms. |
| R1/R2/R3: QoS inversion | Applied in 035: lock takers stay USER_INITIATED, with a boost while a lock is held. |
| R1/R2: per-target deprecation is impossible | Applied: the deprecation step is dropped; the queues are git grep and the predicate. |
| R1/R2: same file in many tasks | Confirmed (217 of 790 files in 2+ queues, 48 in 3+). Applied: generator 216 and file groups 300-346; the per-queue tasks 060-136 are removed. |
| R1: Q4 misses observer kinds; didUpdateNotification | Confirmed (Q4 broadened to 263; didUpdate 3). Applied as the broadened Q4, 221 and R-notif. |
| R1: appearance overrides and SwiftUI hosting | Confirmed (161; 31 hosting sites in 22 files). Applied as 215 and 214 (merged with R2-209) and R-appear in FG. |
| R1: daemon fan-out and hidden-surface events | Confirmed (`event_bus.rs:203`). Applied as 224 and 227. |
| R1: PageScriptPipeline per-envelope evaluate | Confirmed (`PageScriptPipeline.swift:108`). Applied as 222. |
| R1: sleeps are timers; visible leeway | Confirmed (33 + 43). Applied: Q6 broadened; R-timer; leeway in 011/012 (merged with R3's DelayPolicy rules). |
| R1: runtime hook spike | Applied as 202 (decision-gated). |
| R1: InputObserverHub | Confirmed (32 monitors in 28 files). Applied as 220 and R-monitor in FG. |
| R1: benches cannot measure 3 done checks | Confirmed (`automation-typing-bench.py` has no `--input`; STRESS is `--layouts`). Applied as 229 and 230; old 151 dropped. |
| R1: VisibilityNode test conflicts with O(changed subtree) | Applied in 020 (two child sets, 0 visits). |
| R1: idle and scheduler timers must not be posted | Applied in section A and task 005. |
| R1: hang field attribution | Applied in 203 (merged with R3-140). |
| R1/R2/R3: show-turn cost | Applied as 213 (merged R1-226, R2-211 and R3's show fix, plus warm votes). |
| R1: drain slicing; R3: drain split by cause | Applied as 223 (ordered flush, cause tail, 2 ms slices). |
| R1: daemon idle wakeups | Applied as 228 and queue QD. |
| R1: hide/unhide deferrals | Confirmed (28 + 26). Applied as 215 (primitive) and R-hide in FG. |
| R2: person's visible change waits a frame behind inputResponse | Applied: InputResponsePass (206) and the person route in 025. |
| R2: "person wins" cannot be built with one-shot onChange | Applied: personCauseEpoch (025, 032). |
| R2: SidebarRows budgeted with no person carve-out | Applied as 207 and in 010's acceptance. |
| R2: Q1 grep is gameable; async bodies | Applied: predicate 015 and recipe R-hop with the reply form. |
| R2: wave 0, pilot, freeze | Applied as 205 and rule 8. |
| R2/R3: starvation guard semantics | Applied in 004 (link lateness, visible windows only, gates every controlled source). |
| R2: 199 emit sites; program cause; coalescing | Confirmed (199). Applied in 030: envelope-level thread-local cause, `program`, max cause. |
| R2: new wire claim collides with socket policy | Applied: no wire claim in the default path (031); the fallback (231) is risk:high. |
| R2: DemandTimer isolation; next-fire source; event first | Applied as MainDeadline (011) and the R-timer recipe. |
| R2: windowless launch never reveals | Applied in 006 (1.5 s, or at once when hidden). |
| R2: VisibleObservation would drop side effects | Applied: rule 3 and the recipe rule. |
| R2: SwiftUI hosting not covered | Applied as 214. |
| R2: nested run loops in MainTurnMeter | Applied in 008. |
| R2: WindowEvents is A4's, in Wakeups | Confirmed (architecture-refactor-DESIGN.md:224,304). Applied in 021 (located in Wakeups, PL-arch). |
| R2: ratchet rows duplicate the existing ones | Confirmed (`observer_sites` 340, `app_broadcast_names` 13). Applied in 015. |
| R2: no new CmuxNextApp files | Applied: MachineTabIndex is in DaemonService (051); 227's reporter falls back to DaemonService. |
| R2: snap through the Motion gate | Applied in 038. |
| R2/R3: CEF pump classing harms input | Applied in 048 (attribution only, never deferred while focused). |
| R2: grep-only acceptance | Applied: rule 9 harness cases per sweep. |
| R2: schedule | Applied: risk 16 and the section 8 dependencies. |
| R3: inputResponse closes in the same turn | Confirmed (`CommitBoundary.order` 2,000,001, same turn). Applied in 002 and 003 (expectsFrame; closes after the next tick render). |
| R3: progress rule points the wrong way | Applied in 002 (typing-burst window; the reason for the difference from Chrome is written down). |
| R3: automation model applies in the person's frame | Applied as 223. |
| R3: Chromium never told it is hidden | Confirmed (`CEFTab+Freeze.swift:20-23`). Applied as 212 and capture votes in 211. |
| R3: posts have no node | Applied as 209 (per-node queues) and 210 (CPU pool). |
| R3: timer model differs from Chrome | Applied in 011 (precise < 36 ms, flexible default, 60 s only when repeating, 30 s media recency). |
| R3: maxDelay default misreads Chrome | Applied in 005 (default nil; idle stops 10 s after hide). The design text is corrected. |
| R3: settled should be a reference count; off-main fence | Applied in 006 and 204. |
| R3: passTarget fixed; turn target impossible | Confirmed (`MainFrameBudget+Budgets.swift:39`). Applied as 201. |
| R3: posted_from and the reply form | Applied in 001 and 009. |
| R3: userBlocking class | Applied as 208. |
| R3: coalescing drops deltas | Applied in 013. |
| R3: HangWatcher reference was wrong | Applied: section 1 item 10 corrected; task 203. |
| R3: shouldYield | Applied as 200. |
| Original 037 (agent cursor) | Merged into the pilot (205). |
| Original 111 (Compat observers) | Merged into FG340. |
| Original 135 and 136 (Q10, Q11) | Merged into the FG sweeps with R-wait and R-index; 051 is kept. |
| Original 151 | Replaced by 230 (STRESS already exists). |

## 10. Deep review of the landed range (task 161)

Range: the p06-scheduler commits on perf/chrome-parity at bd61faade91. The repo workflow
`.claude/workflows/cmux-next-deep-review.js` reads and lands only feat-cmux-next, so its lenses
(correctness, root cause, concurrency, guards, completeness, platform) were applied by hand, with
the six lenses of task 161. Each row is a fix with its regression test, or the evidence that
refutes it.

| Lens | Disposition |
|---|---|
| Lost updates on show: deferred view work and `whenVisible` events skipped a capture | Fixed in 161. `deferUntilVisible`, `NotificationFanOut` (WindowEvents, AppEvents) and `AppearanceSignals` read `isVisible`, while view observations, frame clients and node queues follow `wantsFrames`. A stay-hidden capture vote (an agent's screenshot or screencast of a hidden tab, screen share) drew views whose recolor, bar reload or missed event had not run. They now follow `wantsFrames`, so the work runs in the vote's turn, as Chromium paints a captured hidden WebContents (`WebContents::IncrementCapturerCount`). Tests: `VisibilityCaptureVoteTests.aVotedHiddenNodeRunsItsDeferredViewWork`, `WindowEventsTests.aCapturedHiddenSubscriberHearsPostsWhileTheVoteHolds`, `AppearanceSignalsTests.aCapturedHiddenSubscriberIsCurrentForTheCapture`. |
| Side effects lost while hidden | Refuted. The 29 `VisibleObservation` adopters apply only to views and view models. The one deferred engine write, `WebKitTab.progressDidChange`, feeds only the progress bar (`BrowserTabStateMachine` keeps the maximum, and load start, finish and failure arrive as their own events). |
| Daemon admission bound | Refuted. The 14 `signaled_mutex_class` tests pass (admit gap at most 4 ms, 32 automation threads against 1 frontend on the three locks, the stress run has no deadlock). The rank boost is taken before the admission on all three locks (`SignaledMutex::lock`, the state lock, `RegistryConnection::get_at` and `pin`), so a reserved automation caller that a frontend waits behind runs raised. A caller that holds a rank never waits on the gate. |
| QoS inversion | Refuted. `LockBoost` raises before the wait and holds until release; a `WorkQos` entered under a boost changes nothing. `cmux-tui-platform` qos (9) and `cmux-threads` qos (7) tests pass. |
| Waiter timeouts | Refuted. Every `KeyedWaiters` wait has a `.flexible` deadline on the one wake-up queue (rule 6), resumes once and is dropped on cancel. `StoreWaiters` `.loaded` is touched inside the snapshot apply and settled by the publish that ends `withOverlayLifted`; `.connection` settles in its `didSet`. |
| macOS 14 tracking path | Refuted in code: one `withObservationTracking` path on every macOS, no `#available` branch in the observation types, and the cancel signal drops an armed tracking the same way on 14. The Tart 14 and 15 function run belongs to task 160 (not run). |
| Class choice (no person change behind automation) | Refuted for the landed range: `ActionOrigin.user` is person, every other origin automation; a completion outside a run is a direct gesture (`ActionCompletion`). Open, not a defect of the range: page-relay requests (Home composer, agent pane) stay automation until task 231 lands. |
| Cause never used for authorization | Refuted. Rust: `EventCause` is read by the event bus, emit, diagnostics, request QoS and the threads that carry it; `origin_gate`, `app_trust` and the remote relay read the origin, and an envelope's origin claim and `priority` only narrow the cause. Swift: `ObservationCause` is read by scheduling code only; `PageRelayChannel` decides the user claim from the relay context and the gesture, not the cause. |
| Outside p06 (routed to p02-threads) | On Linux debug at bd61faade91, 10 cmux-tui-core tests fail because the blocking checks panic on sqlite and condvar calls on `surface-N-reader`, `mux-control-dispatch` and `mux-line-out`: `event_cause_of_an_osc_title_is_program`, 2 `connection_qos` tests and 7 `origin_gate` `mutation_actor::legacy` tests. The panics are in `surface/directory.rs`, `cmd_server.rs`, `cmd_frontend.rs` and `bounded_outbound.rs`, not in p06 code. |
