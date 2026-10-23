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
| input | a person's input; injected stand-ins (`debug.key`, `debug.view_key`) run on the next main run loop turn, ahead of queued requests | none | - |
| frame | springs, autoscroll, frame probes, terminal frame holds (`FrameClient` default) | none | no |
| visible | daemon store batches, sidebar row patches, content presentation (`FrameBatcher` default) | 2.5 ms | yes |
| automation | control-socket requests (CLI, MCP, agents): the work queue and the control batcher | 1 ms | yes |
| background | work nobody sees this frame | 0.5 ms | yes |

Why 4 ms in total: the target is no main-thread stall over 8 ms (key to frame p95 under 8 ms). One run loop pass
holds the person's input dispatch (under 2 ms a key), the scheduled tasks, and the commit of what they changed; 4 ms
of scheduled work leaves at least 4 ms for input and commit. The split puts the person's visible updates first.

Progress rules, so every change still shows within one frame of being due: the first task of a class in a frame
always runs; a class that yielded to input in one frame does not yield in the next. This is batching to the display
cadence, not a throttle: work over budget runs on the next frame, never later.

## Pieces

- `MainFrameBudget` (one per app, owned by `FrameScheduler.app`, shared by every window scheduler): `mayRun(class)`,
  `run(class, owner:)` (nested tasks are charged as themselves), `beginFrame` at each display tick, stats for
  `debug.main_budget`.
- `FrameScheduler.deliver`: frame clients first, then budgeted clients in class order while their class may run; a
  held client stays active and ticks next frame.
- `FrameBatcher(owner:workClass:)`: drains its queued work one budgeted task at a time and keeps the rest, in order.
- `MainActorWorkQueue`: requests are automation tasks under the shared budget; injected input has its own FIFO,
  runs on the next run loop turn and makes every budgeted class yield while it waits (`MainTaskBoard` count).
- `DaemonStore.drain`: applies a batch in slices of 32 events while the visible class may run; the rest goes back
  to the front of `EventInbox`. The inbox coalesces whole-value surface events (title, size, scroll, agent status,
  agent presence): the newest per surface replaces an older one in the buffer. Workspace, screen, pane and tab
  deltas carry consecutive revisions and are never coalesced.
- Pending input (`SessionInputPending`): the window server's time of the last key-down or mouse-button event against
  the last such event AppKit dispatched in this app (a local monitor). Mouse moves and scroll are left out (they
  stream and would starve batches); an undispatched event stops counting after two 60 Hz frames.
- Watchdog (`MainThreadWatchdog.attach(board:)`): every stall record names the scheduled task its sample caught
  (`task_owner`, `task_class`, `task_budget_ms`, `task_started_ms`); DEBUG and bench launches also record each task
  that ran past its class budget, with a stack sampled when it crossed the budget (`debug.hangs` `over_budget`).
  Signposts `stall.main_task` (every task; not mirrored to MetricKit) and `stall.over_budget`.

## Proof

`scripts/cmux-next/sidebar-churn-typing.py` (terminal typing idle and while a CLI storm reorders the sidebar and
changes statuses) and `bench_cli_storm.py`, light and STRESS, on a GUI host that passes `bench_launch.py check`.
Guard: churn-phase key to frame p95 < 8 ms and max main-thread stall < 8 ms. Results: perf-lead.md section 5.
