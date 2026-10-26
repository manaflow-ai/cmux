# cmux next: the main-thread budget (2026-10-23)

Lawrence 2026-10-23: "there's lag in the terminal whenever a lot of CLI operations are going on, like reordering
of the sidebar." Measured by PL-typing (cmux8s, macOS 27, 60 Hz): a key's own work is under 2 ms, but key to frame
is 30-50 ms idle and 160-400 ms under load; the time is the wait for the main thread (send to dispatch 8-286 ms
under load) and the display cycle's layer-tree build. Owner: PL-main (cmux-4f, perf-lead.md).

## Rule

The main thread does three things: input dispatch, the minimal mutation of visible state, and the Core Animation
commit. Everything else runs off it. What the app still schedules there runs as a task of one scheduler, in a
priority class, under a per-frame budget (Chrome's UI thread: USER_BLOCKING, USER_VISIBLE, BEST_EFFORT).

## Classes (CmuxNextWakeups `MainWorkClass`)

| Class | What | Budget per frame | Yields to pending input |
|---|---|---|---|
| input | a person's input; injected stand-ins (`debug.key`, `debug.view_key`) at the head of their connection run on the next main run loop turn, ahead of other connections' queued requests (never ahead of their own connection's) | none | - |
| frame | springs, autoscroll, frame probes, terminal frame holds (`FrameClient` default) | none | no |
| visible | daemon store batches, sidebar row patches, content presentation (`FrameBatcher` default) | 2.5 ms | yes |
| automation | control-socket requests (CLI, MCP, agents): the work queue and the control batcher | 1 ms | yes |
| background | work nobody sees this frame | 0.5 ms | yes |

Why 4 ms in total: the target is no main-thread stall over 8 ms (key to frame p95 under 8 ms). One run loop pass
holds the person's input dispatch (under 2 ms a key), the scheduled tasks, and the commit of what they changed; 4 ms
of scheduled work leaves at least 4 ms for input and commit. The split puts the person's visible updates first.
That 4 ms for the commit is not assumed: `RenderPassMeter` times the main run loop's before-waiting phase (AppKit
layout and display, the Core Animation commit: the cost the tasks' changes leave behind them, which no task body
measures) while the budgeted link runs, and the next frame's scheduled work stops at 8 ms minus the longest such
pass (never above 4 ms; the first task of a class still runs). Requests whose commits are expensive so run fewer per
frame. The pending-input checks between tasks count in the 4 ms too, and each is one window-server query
(`kCGAnyInputEventType` against the newest event AppKit dispatched) unless some input is still on its way.
Measured numbers (light and STRESS, `--input real`, `bench_cli_storm.py`: `max_input_check_ms`,
`max_render_pass_ms`, `max_frame_ms`) are still to be taken on the fleet; until then this split is a design bound,
not a measured one.

The budget protects a pending input and the frame, nothing else. The per-class shares hold only while a key or a
click is pending. With none pending, a class past its share uses the frame time the others left, up to the 4 ms in
all (idle-time scheduling, Chrome's idle tasks); input is checked before every task, so a key that arrives stops the
batch at the next task. A CLI storm on an idle main thread so drains at the 4 ms a frame the control queue had
before the split, not at its 1 ms share.

Progress rules, so every change still shows within one frame of being due: the first task of a class in a frame
always runs; a class that yielded to input in one frame does not yield in the next. This is batching to the display
cadence, not a throttle: work over budget runs on the next frame, never later.

## Pieces

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
- `FrameScheduler.deliver`: frame clients first, then (on the budgeted scheduler) budgeted clients in class order
  while their class may run, the client that ran least recently first (round-robin, so one saturating client never
  starves the others of its class); a held client stays active and ticks next frame.
- `FrameBatchQueue` / `FrameBatcher`: a frame queue runs all its work every frame as plain calls (no per-item task
  bookkeeping); a budgeted one drains one task at a time and keeps the rest, in order.
- `MainActorWorkQueue`: requests are automation tasks under the shared budget, FIFO within a connection (injected
  input included). An injected key at the head of its connection runs on the next run loop turn, ahead of other
  connections, and makes every budgeted class yield while it waits (`MainTaskBoard` count); each input turn runs
  only the input queued before it, and input counts in the per-connection limit.
- `DaemonStore.drain`: a frame-class batcher (`DaemonService.drainScheduler`, a frame client on the
  `MainWorkScheduler`'s link, so it ticks before the budgeted classes of the same frame) applies everything
  buffered as one batch, never split across frames. The batch holds the echoes of the person's own actions, and most actions have no
  intent (close other tabs, close a workspace, duplicate, move to a new window, reopen), so the echo is when the
  change first shows; a budgeted class held it behind pending input and other visible work, split a transaction
  across frames, and let the backlog grow under steady churn (review 2 of pl-main-bc). Its cost is what changed:
  the inbox coalesces whole-value surface events (title, size, scroll, agent presence): the newest per surface
  replaces an older one in the buffer. Workspace, screen, pane and tab deltas carry consecutive revisions and agent
  statuses are transitions; they are never coalesced. A snapshot applies only what differs (SnapshotDiff).
- Pending input (`SessionInputPending`, behind the `SessionInputEvents` seam; `WindowServerInputEvents` in the app,
  a fake in SessionInputPendingTests): the window server's time of the last key-down or mouse-button event against
  the last such event AppKit dispatched in this app (a local monitor). Mouse moves and scroll are left out (they
  stream and would starve batches); an undispatched event stops counting after two 60 Hz frames.
- Watchdog (`MainThreadWatchdog.attach(board:)`): every stall record names the scheduled task its sample caught
  (`task_owner`, `task_class`, `task_budget_ms`, `task_started_ms`). Only the explicit task diagnostics mode
  (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`) also records each task that ran past its class budget, with a stack sampled
  when it crossed the budget (`debug.hangs` `over_budget`): it wakes the watchdog per task and suspends the main
  thread per over-budget task, so it perturbs bench numbers and is never on for a measured run.
  Signposts `stall.main_task` (every task; not mirrored to MetricKit) and `stall.over_budget`.

## The posting API, frozen (p06-scheduler-205)

plans/cmux-next/chrome-parity/p06-scheduler.md section 3 and rule 8. From this task on, no public signature in
CmuxNextWakeups changes without the Performance Lead's OK; changes inside the package are internal only, because a
public change rebuilds most of the 98 targets. Each of these has DocC on its declaration:

| Need | API | File |
|---|---|---|
| Run main work in a class, with an owner and its posting site | `mainWork.post(_:owner:file:line:_:)`, `postFromAnyThread(_:owner:file:line:_:)`, `await mainWork.apply(_:owner:file:line:_:)` | `MainWorkScheduler+Post.swift` |
| Off-main work, then its main part | `BackgroundWork.run(...).reply(on:class:owner:file:line:_:)` | `BackgroundWork.swift` |
| A node's work, held while it is hidden or frozen, keyed | `node.queue(_:owner:on:)` then `post(key:_:)` / `post(_:)` | `VisibilityNode.swift`, `MainTaskQueue.swift` |
| Visibility of a window, workspace, pane, tab, row | `VisibilityNode`, `Visibility`, `subscribe(owner:_:)`, `deferUntilVisible(key:_:)` | `VisibilityNode.swift`, `Visibility.swift` |
| Follow the model for a view | `VisibleObservation(node, owner:on:read:apply:)` | `VisibleObservation.swift` |
| Follow the model for a service (side effects run while hidden) | `ServiceObservation(class, owner:on:read:apply:)` | `ServiceObservation.swift` (task 026) |
| A main-thread deadline | `MainDeadline(owner:workClass:alignment:scheduler:)` on the app's one `MainDeadlineScheduler` (`AppServices.deadlines`) | `MainDeadline.swift`, `MainDeadlineScheduler.swift`, `TimerAlignment.swift` (task 011) |
| A time limit raced against async work | `Deadline(limit).run(label:onTimeout:_:)` | `Deadline.swift` (task 011) |
| A window or app notification | `WindowEvents.of(window).subscribe(...)`, `AppEvents.of(center).subscribe(...)` | `WindowEvents.swift`, `AppEvents.swift` (task 021) |
| An off-main deadline | `DemandTimer` (main-actor code uses `MainDeadline`) | `DemandTimer.swift` |

Not landed when the API froze, so they join it with the Performance Lead's OK when their tasks land: `postIdle`
(IdleScheduler, task 005), `postContinuation` and `shouldYield` (task 200), `StoreWaiters` (task 027), the
`userBlocking` class and `MainDelivery(class:owner:)`. Until `StoreWaiters` lands, a predicate wait is a
`ServiceObservation` whose apply ends the wait (`AgentActivityPageService`'s pane wait).

## The pilot (p06-scheduler-205)

The pilot directories take every recipe before the file-group sweeps start: `CmuxNextApp/Notifications/`,
`CmuxNextApp/AgentCursor/`, `AgentActivityPageService.swift` and `AgentActivityLineConnection.swift`.

| What | Recipe | After |
|---|---|---|
| The service's `Task { for await ObservationStream }` loops (arrivals, Dock badge, settings, viewed tabs, feed, permission bridge, ledger seed, status runs) | R-obs | `ServiceObservation`, one flush per frame in its class: arrivals, Dock badge, settings, viewed tabs and ledger seed `visible`; status runs (`cmux status`) `automation`; feed and permission bridge `background` |
| Finished-run follower (500 per-workspace tasks and an AsyncStream) | R-obs | one `ServiceObservation` of the workspace set and one per workspace, still O(changed workspace) per change |
| Held OSC 7501 alert: a `DemandTimer` and a `Task` loop | R-timer, R-obs | `MainDeadline` (visible, flexible) and a `ServiceObservation` of the tab's records |
| `timeout` dismissals | R-timer | `MainDeadline` (visible, flexible) |
| Banner clicks and authorization replies (`Task { @MainActor }` from the center's threads) | R-hop | `postFromAnyThread`: a click `visible`, an authorization `background` |
| Ledger replies (`await MainActor.run`) | R-hop | `postFromAnyThread(.visible)` |
| Notifications panel ledger watch | R-obs | `VisibleObservation` on the panel's node: visible while the panel shows, so a closed panel evaluates nothing |
| Panel and row appearance changes | R-appear | `deferUntilVisible` on the panel's node |
| Agent cursor window and Space notices (5 + 1 `addObserver`, a `Task` per notice) | R-notif, R-hop | `WindowEvents` per cmux window and `AppEvents` for the Space; one coalesced re-resolve posted in `automation` |
| Agent cursor window state loop | R-obs | `ServiceObservation(.automation)` |
| Agent cursor target lookup (`locateTab` and a walk of every workspace) | R-index | three index lookups in the tab's own store |
| An input to a target this window does not show | (hidden draws nothing) | no cursor command; a cursor that leaves is hidden once (`AgentCursorOverlayModel`) |
| Agent activity pane wait | R-wait | `ServiceObservation` whose apply ends the wait |

Kept, with a reviewed escape: the two approval answers (`main-hop-allow`: `HandsService.answer` and
`AgentApprovalAnswering` are main-actor async, so a nonisolated task adds hops instead of removing them) and the
CUA one-shot's request deadline (`timer-class-allow`: it is off main, where `DemandTimer` is the deadline).
`p06_queue.py` judges a name or center handed to `WindowEvents`/`AppEvents` as the R-notif target.

Numbers. Queue hits in the pilot files (`p06_queue.py` scan, open = not escaped and not settled), on
cmux-orchestrator-1 (Linux, no build):

| | sha | open hits | escaped | settled |
|---|---|---|---|---|
| before | `5c6bcf17e5e` (perf/chrome-parity) | 43 | 0 | 0 |
| after | cp/p06-scheduler-205 | 0 | 3 | 8 |

Not measured yet (the test phase, task 160, on a fleet GUI host with the input grant, both sides on the same host
and session; record the sha and host here): the unattributed share (`debug.main_budget` `unattributed_share`),
key to frame (`sidebar-churn-typing.py --input real` and `automation-typing-bench.py`, light and STRESS;
`automation-typing-bench.py` has no `--input` flag yet, so its keys are `debug.key` stand-ins and are quoted as
such), the per-owner task counts and wait and run times of the `notifications.*` and `agent-cursor.*` owners
(`debug.main_budget` owner ledger; `debug.observations` does not exist yet), and idle wakeups
(`scripts/bench_idle.py`), before and after. Fan-out (the file-group sweeps) starts only when those numbers show
the pilot is no worse.

## Proof

`scripts/cmux-next/sidebar-churn-typing.py --input real` (terminal typing with real HID-tap keys, idle and while a
CLI storm reorders the sidebar and changes statuses; `debug.key` does not take a person's path and is never quoted
as key latency) and `bench_cli_storm.py` (throughput before/after), light and STRESS, on a GUI host with the input
grant that passes `bench_launch.py check`.
Guard: churn-phase key to frame p95 < 8 ms and max main-thread stall < 8 ms. Results: perf-lead.md section 5.
