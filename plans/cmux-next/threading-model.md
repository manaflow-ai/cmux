# cmux-next threading model (enforced)

Owner: Performance Lead (PL-blocking, 2026-10-24; the detector's one process-wide table approved by the
Performance Lead with PL-arch). Chrome's model is the reference: the UI thread never
blocks (`base::ScopedBlockingCall`, `base::ThreadRestrictions`), each thread owns its state, work moves
between threads as messages, and every queue has a bound and a back-pressure rule.

How it is enforced:
- **Runtime (the real guard).** The checked seams in `CmuxNextCompat/Threading` wrap the blocking primitives
  (`FileManager.checked`, `Data(blockingContentsOf:)`,
  `String(blockingContentsOf:)`, `URL.blockingResourceValues`, `FileHandle.blocking*`,
  `blockingRead/Recv/Write/Send`, `DispatchSemaphore/DispatchGroup/NSCondition/DispatchWorkItem.blockingWait`,
  `DispatchQueue.blockingSync`, `Process.blockingWaitUntilExit`, `Process.blockingRun` and `blockingPosixSpawn`
  (a process spawn: screen.close stalled main 807 ms on one, 2026-10-24), `blockingXPCSendWithReply`, and a contended
  `Mutex` wait over 2 ms); code that calls them is checked, and slice (c) moves the raw calls onto them (see
  the next item). On the main thread outside `allowBlocking(<reason>)` a seam call is a violation, recorded once
  per call site (`#fileID:#line`; two seam calls on one line share a site). Debug records during the push
  (p02-threads-006; p02-threads-021 flips main and pool to trap after the sweep): each new site logs one
  unified-log fault (`log stream --predicate 'category == "blocking"'`; a fault stays in the persistent log), and
  the Debug menu's "Main-Thread Blocking (N)" shows a badge with the number of sites added since its submenu was
  last opened; the `debug.blocking` socket command lists them. The mode is read once, when the table is made
  (`BlockingMode.resolved(environment:)`); launch with `CMUX_BLOCKING_TRAP=1` to stop at the call (the opt-in
  crash mode, next item; a contended `Mutex` wait is always recorded only: it is measured on the wall clock). A seam call on main is always a new
  bug: move it onto `work.run(_, mayBlock:)` or resolve its answer before the input's turn (the terminal
  identity's terminfo check is one launch read on the files lane, awaited where a terminal's env is built). Bench builds (`reload.sh --config bench`,
  `-DCMUX_BLOCKING_CHECKS`): recorded for `debug.blocking`, never a trap. Nightly: to come with the
  `nightly.yml` flag and PL-telemetry's hang-report sink (kind + image UUID + offset frames only, no paths or
  names); it records by default, traps only in the opt-in crash mode (next item) and has no log or menu.
  Release: compiled out. Debug records on the main thread and
  the pool until the every-action sweep (p02-threads-300, RUN-1) shows 0 main and 0 pool sites; then task 021 makes
  both trap by default. Daemon (`cmux-threads::blocking`): a disallowed thread's blocking call records its site in
  every build and, in Debug, panics at the caller's location (Chrome's `DCHECK`); `CMUX_DAEMON_BLOCKING=record`
  turns the panic off. Release never panics.
  The same seam call on a shared pool thread (the Swift cooperative pool, `Task.detached`, an actor, a GCD root
  queue such as `DispatchQueue.global`) is a violation too, recorded at its own `pool` site (`debug.blocking`
  `context`, `contexts.pool`; not in the Debug menu); launch a Debug build with `CMUX_BLOCKING_TRAP_POOL=1` to
  stop at it. A `BackgroundWork` `.files` or `.system` item, a named queue, a named thread and `allowBlocking` may
  block. A `.cpu` item may not (the lane is sized to the cores): a seam in it records a `wrong-lane` site in the
  `cpu-lane` context, with the seam's own kind as its `seam_kind`, never a trap; run the item on `.files` for
  `file-io`, on `.system` for any other seam kind (p02-threads task 015). The pool
  is found by the queue label (the `com.apple.root.` prefix, which the cooperative pool's queues share, on a
  thread with no pthread name), which is libdispatch's, not API (p02-threads task 005).
- **Opt-in crash mode (Debug and Nightly, `-DCMUX_BLOCKING_CHECKS`; never a bench build; p02-threads-009).**
  Chrome's configurable DCHECK (base/check.h `DCHECK_IS_CONFIGURABLE`: a Canary ships DCHECKs on but non-fatal,
  and a launch can make them fatal). The default is record. Launch with `CMUX_BLOCKING_TRAP=1` (read once, when
  the table is made) and a main-thread violation records its site, hands it to the sink through the drain queue
  and waits at most 50 ms for it (so the hang report keeps the call that stopped the process, and a sink stuck
  on a lock the main thread holds cannot turn the trap into a hang), logs one `os_log` fault
  (`category == "blocking"`), then stops the process at the call. A bench build (`CMUX_BENCH_HOOKS`) ignores the
  variable: a bench run measures the app, and a shell that exports the variable for Debug work passes it on. A
  contended `Mutex` wait is always recorded only: it is measured on the wall clock. The pool trap
  (`CMUX_BLOCKING_TRAP_POOL=1`) stays Debug only.
- **What the detector does not see yet** (slice (c): migrate to a seam, or the probe below finds it): every
  raw call that does not go through a seam (today almost all of them: `FileManager.default`, `Data(contentsOf:)`
  and so on), `NSXPCConnection.synchronousRemoteObjectProxy`, `DispatchQueue.asyncAndWait`, semaphore and group
  `wait(wallTimeout:)`, `Operation`/`OperationQueue` waits, `NSConditionLock`, `pthread_cond_wait`,
  `pthread_join`, raw `os_unfair_lock`/`OSAllocatedUnfairLock`/`NSLock` contention, raw writes
  (`Data.write(to:)`, `String.write(to:)`),
  `NSData`/`NSString`/`NSDictionary`/`NSArray`/`NSImage(contentsOf:)`, `FileHandle.readData(ofLength:)`,
  `open`/`stat`/`fsync`/`connect`/`accept`/`poll`, `getaddrinfo`, synchronous Security and Launch Services
  calls, and blocking inside Apple frameworks. `scripts/measure/blocking-probe.sh` (a measurement-only
  interposer on the fleet) finds these in a running app.
- **Pre-push (the early warning).** `scripts/cmux-next/guardrails.py` refuses, in added lines only:
  `main-blocking` (a blocking call, raw or seam, directly in main-actor code: explicit `@MainActor` code and
  the function bodies of main-actor-by-default UI targets, not closures inside them, which may run later or
  elsewhere; `DispatchQueue.main.sync`, `Thread.sleep` and `usleep` anywhere), `raw-blocking` (a raw blocking
  primitive elsewhere in Sources: use the seam, so the runtime check sees it if it ever runs on main) and
  `thread-doc` (a new thread, queue or `BlockingAllowance` whose literal label this page's "Registered threads
  and queues" does not list; a label that is a variable is not judged). A `.wait(` with `await` before it in its
  statement is an async wait and is not refused. Escape: `// blocking-allow: <why>` (to be counted by the arch
  ratchet's `blocking_allow_escapes` row: to come, PL-arch).

## Contexts, modes and seams

**Contexts.** The detector gives each thread one context (`BlockingContext`, CmuxNextCompat):

| Context | Which threads | Blocking seam | Sync primitive (semaphore, group, condition, `blockingSync`) |
|---|---|---|---|
| main | the main thread | violation (outside `allowBlocking`) | violation |
| pool | the Swift cooperative pool (label suffix `.cooperative`) and GCD root queues (`com.apple.root.` prefix, no pthread name): `Task.detached`, actors, `DispatchQueue.global` | violation | violation |
| lane | a `BackgroundWork` `.files` or `.system` item | allowed | target: violation (`lane-sync`, task 119) |
| cpu-lane | a `BackgroundWork` `.cpu` item | `wrong-lane` site (records, never traps) | `wrong-lane` site |
| dedicated | a named thread or queue in [Registered threads and queues](#registered-threads-and-queues) | allowed | allowed |

The daemon has the same split. `cmux_threads::disallow_blocking()` at the entry of a request or echo thread
makes it "main-like"; a `cmux_threads::work` worker may block; other registered threads may block.

**Modes.**

| Build | App (Swift) | Daemon (Rust) |
|---|---|---|
| Debug | record: one unified-log line per site, the Debug menu count, `debug.blocking`. `CMUX_BLOCKING_TRAP=1` traps main sites, `CMUX_BLOCKING_TRAP_POOL=1` pool sites. Task 021 makes trap the default after RUN-1 passes (`CMUX_BLOCKING_TRAP=0` turns it off) | record (`server.blocking`) and panic at the caller's location (Chrome's `DCHECK`); `CMUX_DAEMON_BLOCKING=record` turns the panic off |
| Bench (`-DCMUX_BLOCKING_CHECKS`) | record, never a trap | as Release |
| Nightly | target: compiled in with `-DCMUX_BLOCKING_CHECKS`, record, one report per new site to the opt-in hang-report sink (at most 5 per launch, 1 per site per 24 h); `CMUX_BLOCKING_TRAP=1` opts in to a trap | as Release |
| Release | the check is compiled out; only the trace hook (one relaxed atomic load) and lane latency stats stay | per-site counters (256 sites, then `overflow`), never a panic |

**Seams.** Each seam passes `#fileID` and `#line` and runs inside `blockingCall(kind)`. Swift seams live in
`CmuxNextCompat/Threading` (one file per family): files (`FileManager.checked`, `Data(blockingContentsOf:)`,
`String(blockingContentsOf:)`, `URL.blockingResourceValues`, `FileHandle.blocking*`, POSIX), sockets and
descriptors (`blockingRead/Recv/Write/Send`), sync waits (`blockingWait` on semaphores, groups, conditions and work
items; `DispatchQueue.blockingSync`), processes (`blockingPosixSpawn`, `Process.blockingRun`,
`Process.blockingWaitUntilExit`), IPC replies (`blockingXPCSendWithReply`), system calls and queries (Security,
LocalAuthentication, AX, window lists, Launch Services and `NSWorkspace`, ServiceManagement, host resolution,
`sysctl`/`proc`), SQLite, ImageIO and image decodes, size-gated CPU work, and C library calls that read files
inside (`blockingFFI`: libghostty's config build, which runs on the files lane through `GhosttyConfigLoading`
and is applied on main once, p02-threads-129). The kinds are `BlockingKind`:
file-io, fs-metadata, socket-read, socket-write, sync-wait, ipc-reply, xpc-reply, process-spawn, process-wait,
process-reap, lock-wait, system-call, system-query, sqlite, sleep, cpu-intensive, wrong-lane, ffi and
priority-inversion (the main thread awaits a BackgroundWork item stated below `.userBlocking` while input work runs
on the main task board; record only). The GPU wait inside Ghostty's `drawFrame` on main is not a config load: it
belongs to PL-ghostty G1.

Rust checked forms live in `cmux-tui/crates/cmux-threads`: `checked::fs`, `checked::process`, `checked::sync`
(`recv`, `recv_timeout`, `join`, condvar waits, `sleep`), `checked::block_on`, `checked::ipc_reply`,
`scoped_blocking_call(kind, f)` for the rest, `own_fd_read` / `own_fd_write` / `own_fd_write_all` for a
thread's own descriptor, and `LockHolder` for timed lock waits (`lock_wait`). The kinds are `BlockingKind`:
fs, process-spawn, process-wait, recv, join, condvar-wait, sleep, sqlite, block-on, ipc-reply, fd-read,
fd-write, lock-wait and priority-inversion.

## Threads and queues

"QoS" is what the code sets at this commit (`process-model-census.py --check-thread-doc` compares it with a
running app). "Target QoS" is the model below ("QoS and task priority" and the closed user-interactive list);
"as today" means the code already meets it, and the task named in the cell changes the code and this row
together. "Waits
on (QoS)" names what the thread may wait for and the QoS of the thread on the other side: a wait on a thread of
lower QoS is a priority inversion, so every such row names how it is bounded or boosted. The daemon's threads
are in [Daemon threads](#daemon-threads-cmux-tui).

| Thread / queue | Owns | Waits on (QoS) | QoS | Target QoS | Bound and back-pressure |
|---|---|---|---|---|---|
| **Main thread** (AppKit, SwiftUI, CEF UI thread via the external message pump `CEFMessagePump`, Ghostty app tick) | All UI state, `@MainActor` models, CA commits, CEF browser-process UI work | Nothing. Donating waits only: a short `Mutex` section (the holder gets main's QoS while main waits; a wait over 2 ms is recorded), and the reviewed `allowBlocking` reasons below. CEF's `CefDoMessageLoopWork` slice is 2 ms (`cmux-pump-time-slice-us`). | user-interactive (system) | user-interactive (closed list) | Input first; everything else through the scheduler below |
| **Main-thread scheduler** (`CmuxNextWakeups`: `MainWorkClass` input > input-response pass > frame > visible > automation > background, with userBlocking after frame and idle last once p06 tasks 208 and 005 land; `MainFrameBudget`; `MainWorkScheduler.post`/`postFromAnyThread`/`apply`, `BackgroundWork` `.reply(on:class:owner:)`; per-node `MainTaskQueue`; `MainDeadline` on the one `MainWakeUpQueue` timer; `FrameBatchQueue`; `MainActorWorkQueue` for control-socket work; owner PL-main; contract in [main-thread-budget.md](main-thread-budget.md)) | Order, class and per-frame budget of main-thread work; owner, `posted_from` and node state of each task (`MainTaskBoard`, `MainOwnerLedger`); unattributed turn time (`MainTurnMeter`) | Never | main | main | Budgets per frame: visible 2.5 ms, automation 1 ms, background 0.5 ms (4 ms of an 8 ms target); p06 task 201 scales them by refresh interval / 16.7 ms. Over budget: the rest runs next frame (no drop). Hidden nodes hold their visible and automation posts (coalesced by key); a hidden node's deadlines wake on whole seconds, and after 5 minutes hidden a repeating one shares one wake a minute per node. Task 210 adds `CPUTimeBudgetPool` (10 ms/s, 100 ms cap) for hidden background work, and task 005 idle tasks with a deadline. `MainActorWorkQueue`: 1024 pending, 256 per connection; full: the request fails `busy`; expired: `timeout`, never runs |
| **Main wake-up queue** (`MainWakeUpQueue`, `MainWakeUpHeap`, `MainWakeUpTimer` in CmuxNextWakeups; p14-energy-013, 023 and 037, p06-scheduler 011 and 012; one per app, owned by `MainWorkScheduler` (`wakeUps`); design in [idle-wakeups.md](idle-wakeups.md) section 9) | The one main run-loop `CFRunLoopTimer` (common modes, made once, parked between arms) for every main-thread deadline: `MainDeadline`, `DemandTimer` with `mainWork:` (`scheduleOnMain`), the CEF pump's delayed requests; the heap of pending entries ordered by latest time, and a second heap of hidden entries | Inserts and cancels come from any thread and take the queue's `Mutex` for one heap change and at most one `CFRunLoopTimerSetNextFireDate` (a short donating section). The `EnergyPolicySource` lock is a leaf read inside it (the source calls its observers outside its lock), so the order is always queue then source. The fire never waits: the callout only queues a common-modes run-loop block | main (the fire); the caller's (insert, cancel) | as today | One timer and one wake for all entries: a fire date of min(the earliest flexible deadline aligned to 8 ms, 32 ms in Energy Saver, or the whole second; the earliest latest time); precise entries (below 36 ms) are never aligned; an arm to the armed date is skipped. 0 wakes with no entry. A fire runs due entries for at most 2 ms (`fireBudget`), then a continuation armed for now runs the rest after pending input. Hidden entries run only at or after their whole uptime second. Ledger: one `MainWakeUpQueue` `fire` per wake and one record per owner; `debug.energy` shows the entries and `coalescedFires` |
| **Main job gate** (`MainJobGate`, `MainJobGateHook`, `MainJobGateRunLoop`, `MainWork`, `InputPendingState` in CmuxNextWakeups; p04-input-076, feature `mainJobGate` and setting `debug.mainJobGate`; off: the hook is not installed) | The Swift runtime's `swift_task_enqueueMainExecutor_hook`: every main-actor job of the process, by origin (never by priority). While input is pending or in dispatch, a job that is not the dispatch's own (main thread, `CmuxApplication.route`), not a `MainWork.input`/`.frame` task's and not inside a nested tracking or modal loop waits in one FIFO; while the FIFO is not empty every such job appends | The hook makes no system call when the word is zero: one acquiring load of `InputPendingState`. A held job takes the FIFO's `Mutex` for one append (a short donating section; the first one wakes the main run loop). The release forwards to the runtime's enqueue under that `Mutex`, and a release that stops holding (uninstall, a nested loop's entry) sets its bit in the same section, so a later job never reaches the main queue ahead of a released one | the enqueuing thread's (hook); main (drain) | as today | Every release runs after a commit stage (`AfterFrameCommit.everyPass`: after Core Animation's commit at `beforeWaiting` and at `exit`), never before the input's commit: one job per pass while no input is pending; the whole FIFO in order one display refresh after the first held job, with one precise `MainWakeUpQueue` wake per hold so the deadline holds in an idle app; at the entry of an event-tracking or modal-panel loop (holding resumes at its exit) and at uninstall. The end of each dispatch publishes the kinds still pending. `MainJobGate.counters` (`debug.input` section `gate`): held by origin, exempt by rule, released by reason, deferred over one frame |
| **Energy Saver inputs** (`CmuxNextEnergy`, p14-energy-021 and 120; `EnergyMonitor`, `PowerSourceMonitor`, `BatteryLevel`, `LowPowerMode`, `ThermalStateWatch`, `SuspendWatch` with its wake path queue `com.cmuxterm.next.energy.wake-path`; `EnergyPolicyDriver`, the one writer of the app's `EnergyPolicySource`) | The power inputs (power source, battery charge, Low Power Mode, thermal state, sleep, wake and display sleep) and the resolved `EnergyPolicy` | Nothing: the IOPS power-source notification is a run-loop source on the main run loop; Low Power Mode and the thermal state are `NotificationCenter` notifications that hop to main; sleep, wake and display sleep are `NSWorkspace` notices through the app's `AppEvents`, and after each wake one `NWPathMonitor` on the wake path queue reports the first satisfied path, then is cancelled. Readers on any thread read the policy under the source's short `Mutex` | main | utility for the power-source and battery notifications, main only on an input edge (p14-energy-058) | Event-driven, no timer. One main delivery per power-source change today; after p14-energy-058, a battery percent change reaches main only when it crosses 20% or the power source changes. `EnergyPolicySource.update` tells its observers only on a changed value |
| **Frame clock** (`FrameScheduler`; `MotionClock`, `DisplayLinkDriver`, `DemandTimer` on it). `DisplayClock` (p03-rendering-010) holds one link per display and every `FrameScheduler` (window, app, budgeted) subscribes to it; with feature `vsyncHub` (p03-rendering-014, off by default) that link is the `VSyncHub`'s, and its ticks reach main as one coalesced post per vsync | Frame ticks for clients | Never | main | main | One link per display with an active client, 0 at idle; one stall timer per display; a link is rebuilt after 3 stalls of 100 ms (through the hub: `VSyncHub.rebuildLink(display:)`, so the display's off-main subscribers move to the new link too) |
| **VSyncHub** thread `cmux-next vsync <display>`, one per display that got a link (`CmuxNextWakeups/VSyncHub.swift`, p03-rendering-014, feature `vsyncHub`, off by default; Chrome `ui/display/mac/ca_display_link_mac.mm` and `display_link_mac.mm`) | The display's only link, added to its own run loop; its subscriber list (a `Mutex`, held only to copy or change it, never across a callback); off-main `Sendable` vsync callbacks (Ghostty surfaces after p03-rendering-083) and the main fan-out of `DisplayClock` | Its run loop only. The subscriber `Mutex` (main or a subscriber holds it briefly, never across a callback). A callback that blocks is a bug. It never touches a layer whose superlayer belongs to an `NSView` | user-interactive (`// qos-allow:`) | user-interactive (closed list: a frame waits on it) | The thread starts with the display's first link: a display with no screen (`DisplayClock.noDisplay`, a gone screen) gets no thread, however often its link is retried. The link runs while a subscriber is armed, at the fastest rate an armed subscriber asked for, and is paused while none is (`debug.wakeups` `vsync.live_links` counts the displays with an armed subscriber, `vsync.paused_links` the paused ones); it goes with the display's last subscriber, and the thread stays, asleep in its run loop. A paused link is kept, as Chrome keeps a `DisplayLinkMac` while a consumer holds it and only stops its `CADisplayLink` when the last `VSyncCallbackMac` unregisters, so an arm needs no main hop to make a link. Producers arm on dirty content and a tick that returns `.done` disarms them (an arm during the tick wins). Main gets one coalesced tick post (`MainRunLoopBlock`, common modes), at most one pending: a newer vsync replaces a pending one. Hop: `vsync.main_hop_p50_ms` / `main_hop_p99_ms` (post to main take, last 256 ticks). Before `vsyncHub` turns on by default, the round's fleet run records here: typing-frame-bench main tick p99 with the feature on and off, and bench_idle.py wakeups of the `cmux-next vsync` threads with a visible idle terminal (paused link: 0 expected). If the p99 rises >= 0.1 ms, the composition root keeps `DisplayClock()` main links next to the hub (<= 2 links per display; rendering-DESIGN difference 6). Measurement: not yet run, so the feature stays off |
| **Input pipeline on the main thread** (p04-input, owner PL-input; [input-pipeline-DESIGN.md](input-pipeline-DESIGN.md)): `InputEventTap` (CmuxNextInput), each window's `FrameInputCoalescer` (`FrameScheduler.input`) and its clients (`PointerFrameConsumer`s and keyed `post(kind, owner:)` bodies: divider and edge drags, hover, terminal pointer, remote input), `FrameInputCoalescers` (one per app), `SessionInputPending`, `PresentationClock`, `InputLatencyTracker` | The dispatch of each `NSEvent` to its subscribers; continuous input held until the window's frame tick, then delivered in the tick's input stage before its frame clients; the open latency slots of the turn and their presented estimates | Nothing. The per-event path takes no lock, makes no allocation and builds no `String` (tap delivery copies no list; the tracker's path is measured by `perEventPathAllocatesNothing`). `SessionInputPending` makes one window-server query per check in the common case | user-interactive (main) | as today | Coalescer: at most two deliveries per consumer per frame interval (the leading edge and the tick), plus one per change of kind, button, modifiers or scroll phase; a drag keeps its newest 16 points; a discrete event flushes first. Fallback: one one-shot `.precise` `DemandTimer` per window (`FrameInputCoalescer.fallback`), armed only while work is pending and the link is not running (one refresh for a drag or keyed post, 5 s otherwise, Chrome `kMaxRafDelay`). Latency: 128 open slots (a full table refuses the event and counts it, `droppedCount`), a 256-slot ring on main, half a ring per batch |
| **Input latency stages and fold** (CmuxNextInputCore `InputLatencySlotTable`, CmuxNextControl `InputLatencyReporter`; p04-input tasks 001, 002) | A stage time stamped off main (the terminal input lane, text input, Chromium host feedback); the histograms of closed slots | Nothing: a stage is one relaxed atomic store, written once, from any thread; the reporter's `submit` is one bounded stream yield and one atomic add | the stamping thread's own; the reporter's reader: the task its owner starts (utility; not wired in the app at this commit) | as today | Reporter stream: 4 batches; a batch that does not fit is dropped and its slots counted (`slots_dropped`) |
| **Main job gate** (CmuxNextWakeups; p04-input tasks 021 record-only and 076 holding, not landed; landed: the input-turn hop recorder of task 022, `MainJobGateDiagnostics`, `InputTurnCalloutTimer`, `CalloutStackSampler`, wired by CmuxNextControl `InputTurnHops`) | Target: the Swift runtime's main-executor enqueue hook classes each main-actor job by its declared origin and holds the rest while input is pending, then drains them in FIFO order after the input's frame commit (`AfterFrameCommit`). Today: a record of the main-thread jobs and non-Swift callouts that ran in or near an input turn (`debug.input hops`) | Hook (target): nothing; it runs on the enqueuing thread, reads one relaxed atomic and makes no system call. Recorder: producers on any thread take no lock and make no allocation; the fold runs on `DispatchQueue.global(qos: .utility)` under a `Mutex` the main thread never takes; the sampler's deadline (`input-turn-hops.sampler`, a `DemandTimer` with no queue, on the cooperative pool) suspends main once to sample a long callout's stack | hook: the enqueuing thread's; fold: utility; sampler: user-initiated (its `DemandTimer` `Task` gets this from the main thread, which the Swift runtime lowers from user-interactive) | hook: the enqueuing thread's; fold: utility; sampler: user-initiated | Holding (target): at most one refresh past the input's commit; a nested run loop (menu, modal, drag session) releases the FIFO. Recorder: 64 pending records (`pendingLimit`), past that dropped and counted |
| **Main-thread watchdog** thread `cmux-next main-thread watchdog` | Stall/hang detection and stack samples | Its own kqueue (`MainThreadWatchdogAlarm`: a one-shot timer the main thread arms when its run loop wakes and deletes before it sleeps, and a user event for stop and task starts); a main turn shorter than the timer wakes it never. Per main-thread hang episode (p09-observability-110): one write of the run's fatal-hang record (a few KiB, temporary file and rename, no fsync) at the hang threshold and at each checkpoint, and one unlink when the main thread answers | user-interactive | user-interactive (closed list: it samples a wedged main thread) | Rings of 128 hangs and 128 over-budget entries |
| **Quit and crash deadlines**: threads `cmux-next quit deadline` (`QuitDeadline`), `cmux-next crash deadline` (`CrashDeadline`) | The deadline after quit starts or after a crash signal: stop a wedged main thread and end the process | Its own semaphore with a deadline (nothing it waits for runs below it) | user-interactive | user-interactive (closed list: it must run while main is wedged) | Quit deadline: one thread, started when quit starts (`QuitDeadline.arm`). Crash deadline: one thread, started at launch (`CrashDeadline.install`) and parked on its Mach semaphore (0 wakes) until a crash arms it |
| **Daemon connection** reader thread `cmux-tui reader <path>`; writer queue `com.cmuxterm.next.daemon.write`; `actor DaemonConnection`; `EventInbox` pump task | Socket read and line split, then each event straight into the store's `EventInbox` on the reader (`DaemonEventRoute`, p02-threads-133: no cooperative-pool job between the socket and main); outbox drain; handshake and reconnect; the pump task passes on only the events buffered before the store took the connection | Reader: `read(2)` of the daemon socket, fed by the daemon's `mux-line-out` (user-interactive). Writer: `write(2)`, drained by the daemon's `mux-conn` (default today; under `daemonRequestQos`, task 224: user-initiated until classed, user-interactive for the app's connections, utility for automation) | reader and writer by connection role, one class for both (`DaemonWireStats.Role.writerQoS` and `readerQoS`, p02-threads-030, p04-input-059; SocketWriterQoSTests, LineTransportTests read the reader thread's class back): user-interactive only for the key-carrying role `terminal_attach` (key echo path), user-initiated for `control` (commands, replies, automation and sidebar events: lowered from user-interactive by p04-input-059 so their churn never shares typing's class; most typed keys go on `terminal_attach` (`TerminalAttachment.enqueueInput`), but two key paths stay on `control` at user-initiated: `send {terminal_id}` from `CreatingTerminalInput` for keys typed into a new split before its attach target is known (until p04-input-058 buffers them until attach), and `send-key` for a TUI's Command chords from `TerminalHooks` (`TerminalKeyEquivalent.sendToProgram`)), `page_relay`, `agent_session_attach`, `journal_read`, `session_ending`, `shutdown`, default for `loopback_forward` (bulk page bytes stay below keystrokes), utility for `socket_probe` | as today (closed list: the reader and the writer of `terminal_attach`) | Line over 64 MiB closes the connection; outbox 64 MiB, past it `write` fails `.backlog`; inbox 4096 events, field events coalesced, overflow collapses to one resync; main drains 32 per slice under the visible budget. Hang-watched (p09-observability-069): each line the reader handles is one `daemon.line` scope (100 ms budget, p02-threads-017) and each outbox drain step (one send) one `daemon.write` scope (2 s); the reader's wait in `read(2)` and a write waiting in the FIFOs are in none (LineTransportHangScopeTests, SocketWriterHangScopeTests, FrameWriterStepTests) |
| **Terminal attach** (`TerminalAttachment` reader → `TerminalEchoRouter` → the view's output lane, or `TerminalEventQueue`) | One terminal's output stream: live output goes from the reader straight to the output lane once the view names it and has applied every record still on the stream (`TerminalEchoRoute` markers, p04-input-083: no AsyncStream, task or pool thread between the socket and the parser); control records (replay, snapshot, grid, size, close) stay on the queue | The reader waits above 8 MiB queued and resumes below 2 MiB, waits while the output lane is above its 2 MiB high water until the lane wakes it (drained or closed) or the link detaches, and waits while more than 2 MiB of output is held behind a marker in flight until the view resumes that marker (the held output then goes to the lane, and the route opens one round trip after the last record however fast output comes); both consumers are user-interactive (the output lane, the driver's pump) | user-interactive | user-interactive (closed list, on the daemon reader) | The daemon's attach mailbox overflows and ends the stream |
| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | Feeding `ghostty_surface_process_output`; local PTY I/O | PTY read and write; the shell on the other end runs at default | user-interactive, all three (the PTY write since p02-threads-030, LocalPTYQoSTests) | as today (closed list) | 2 MiB high water: the consumer task suspends. Hang-watched (p09-observability-069): each output chunk's parse is one `terminal.feed` scope (100 ms budget, p02-threads-017); each PTY `read(2)` of at most 64 KiB and the yield of its chunk one `localpty.read` scope (1 s; a drain to EAGAIN makes one scope per chunk, so heavy output makes more scopes, never a longer one) and each input flush (write until EAGAIN) one `localpty.write` scope (2 s); a chunk waiting on the lane's queue and the PTY's wait for readiness are in none (TerminalOutputLaneHangScopeTests, LocalPTYHangScopeTests) |
| **Ghostty renderer and IO threads** (per surface, inside GhosttyKit) | Rendering; termio | Renderer mailbox (64, latest-value-wins, never waits); termio queue 64 | Renderer: focused user-interactive, visible user-initiated, hidden utility (ghostty-next `src/renderer/Thread.zig` `setQosClass`); a hidden renderer gets no wake from output or its cursor blink ([Renderer QoS](#renderer-qos-rendering-design-r5), p03-rendering-088). IO: not set | declared by library: as today; IO removed for manual-IO surfaces by p03-rendering-086 ([Renderer QoS](#renderer-qos-rendering-design-r5)) | cmux runs surfaces in manual IO mode: no Ghostty read thread |
| **BackgroundWork lanes** (`CmuxNextWakeups`, one per app; slot queues `com.cmuxterm.next.work.<lane>.<slot>`, files `com.cmuxterm.next.work.files.<priority>.<slot>`) | Work that may block, off main and off the pool | files: disk. system: system calls (DNS, Security, Launch Services, AX, window server). cpu: nothing (a seam there is `wrong-lane`) | the item's (`WorkPriority.qos` through `.enforceQoS`; the slot queue states none) | the item's: user-initiated (userBlocking, userVisible), utility or background; never user-interactive | [Lanes](#lanes); a slot has a GCD thread only while it has work |
| **Swift cooperative pool and actors** (`actor`s that own I/O: daemon, cloud, remote, stores; `Task.detached` at `.utility`/`.userInitiated`) | Async I/O and domain state off main | Nothing (never a blocking call on the pool; blocking work belongs on a lane or a dedicated thread or queue). An `await` is not a wait: the thread runs other tasks | the task's priority | the task's priority | Each actor's own stream bounds (`AsyncStream` with a buffering policy, never `.unbounded`) |
| **DispatchSource handlers** (control socket `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; file watchers; process and signal sources) | Event delivery only | Non-blocking reads | as the queue; control socket: utility (automation, p02-threads-031, ControlSocketQoSTests). Its main hop keeps the method's `MainWorkClass` (automation; `debug.key` and `debug.view_key` input), and an injected key runs ahead of queued automation once it reaches the main-thread queue. A `debug.key` with the client's `timestamp` (bench-typing.py) keeps that send time on its event, so the wait on this utility lane and the main-thread queue counts in the bench's `key_to_*` latency; the reply's `injected_at` (main thread, at injection) gives that wait apart, as bench-typing's `key_to_injection_ms` | as today | Coalesced by the source; main-queue sources only hop. Hang-watched (p09-observability-070): the control accept queue is lane `control.accept`, one scope per accept pass (1 s); each connection queue is its own lane `control.connection`, one scope per job (1 s, 2 s for a job that sends) |
| **Process queues** `com.cmuxterm.next.process.<name>` (`ProcessRun`) and the `ProcessLauncher` queues `com.cmuxterm.next.sleepy-lock`, `com.cmuxterm.next.relaunch`, `com.cmuxterm.next.find-in-directory` (userBlocking: user-initiated), `com.cmuxterm.next.now-playing`, `com.cmuxterm.next.android-screen`, `com.cmuxterm.next.diff-sidecar` (userVisible: the queue user-initiated since p02-threads-115, the child default) | One child's spawn and its exit source | `posix_spawn` (the kernel); never a wait for the child: the exit source reports it | the run's `WorkPriority.qos` | the run's; the child gets `WorkPriority.processQoS`, never user-interactive | One queue per run or launcher; the user's `gh` (`com.cmuxterm.next.process.gh`, bestEffort): 2 runs at once app-wide, the rest in arrival order (`AppServices.pullRequests`, one `BoundedProcessRunner` every pull request reader shares; cx-mb1e0) |
| **Child launchers** `com.cmuxterm.next.child-launcher.<owner>` (`ChildProcessLauncher`, CmuxNextCompat; owner p02-threads, task 037): `daemon-bridge` (one per `DaemonBridge`), `chromium-host` (one per Chromium host session), `acpmux` (one per `AcpmuxHost`), `computer-use-helper` (one per Computer Use helper v2), `shell-complete` (one per pane's completion), all user-blocking; `agent-shell` (one per pane's `AgentPaneShell`), user-visible; `crash-watcher` (once at launch), best effort | Every raw `posix_spawn` of CmuxNext, in call order per owner: Chrome's process launcher sequence (`content/browser/child_process_launcher_helper.cc`), one per long-lived owner instead of one per process (no singleton to share) | `posix_spawn` only (the kernel); never the child's output or exit, which its owner waits for elsewhere | the launcher's `MayBlockPriority.qos` | as today | One serial queue per owner, made with the owner, never per spawn; an item is one spawn, so a queue is held for one `posix_spawn` at most |
| **Daemon bridge dial** `com.cmuxterm.next.daemon.bridge-dial` (`DaemonBridge.open`, concurrent, one per `DaemonBridge`) | The wait for a just-spawned bridge's first stderr line | the bridge child (`poll`, up to 10 s per byte, `DaemonBridge.replyTimeoutMs`) | user-initiated | as today | One item per opening bridge connection (at most one per connection role); the child is killed and reaped when the line is late or a refusal |
| **Hang watch** (p09-observability, owner PL-telemetry). App: the `HangWatch` slots in CmuxNextTrace (`TraceRuntime.shared.hangWatch`), read by `HangMonitor` on the existing `cmux-next main-thread watchdog` thread's kqueue (no new thread; p02-threads-016, attached by `AppControl.startWatchdog`). Rust: in the daemon, `mux-request-watchdog` is the one hang watcher (p10-stability-032, no second thread); holder, terminal host and acpmux: one `mux-hang-watch` thread each (cmux-threads `HangWatcher`, p02-threads-205; scopes wired in task 232) | Watched threads' and lanes' deadlines; the hang record and stack sample of an overdue slot; app reports go to `debug.hangs` `thread_janks` at the budget, with no stack (`MainThreadWatchdog.threadJanks`), and `thread_hangs` 2 s later, with the stack and crash keys (`MainThreadWatchdog.threadHangs`), both apart from main-thread stalls | Its kqueue (app) or a `Condvar` (Rust). Sampling: between `thread_suspend` and `thread_resume` it only reads registers and stack memory into a preallocated buffer, no lock and no allocation | user-interactive (app, the watchdog's); utility (Rust `mux-hang-watch`) | user-interactive (app, closed list); utility (Rust `mux-hang-watch`, task 205) | Opening a scope is a clock read, one store (a lane: two) and one load of the plan; closing one store; no lock and no system call. App: while scopes open and close, one scan per minimum deadline (100 ms); after a scan with no slot changed it sleeps to the earliest open deadline (a 30 s job alone: no periodic wake); with nothing open it parks with no timer (0 idle wakes). A scope whose deadline the plan would see over one minimum deadline late (parked, or sleeping to a later deadline) posts one `EVFILT_USER`. Detection within deadline + minimum deadline. Rust: while scopes open it sleeps to the earliest open deadline, at most one minimum deadline, parks after a wake with no scope open and none opened since, and the first open after that wakes it. A watcher that wakes over 100 ms late blames nobody. One hang record per overdue scope, kept when a nested scope closes |
| **Trace ring adoption** (p09-observability, owner PL-telemetry). App: a `BackgroundWork` `.files` job at launch and at `trace.start` (no new thread). Rust: one `cmux-trace-open` one-shot thread per process at start | Moving the heap ring into its file: rename the spare file or create one, `mmap` `MAP_SHARED`, copy the heap records, swap the ring pointer; delete dead-pid rings older than 3 days | Disk (open, `ftruncate`, `mmap`, rename, unlink) | utility (app lane item); Rust not set | utility (Rust by task 229) | Once per process start and once per recording start; the writers keep writing the heap ring until the swap, never wait for it; an `mmap` failure keeps the heap ring and is counted; a recording mapping is never unmapped while the process lives; the directory is capped at 16 MiB |
| **Blocking detector drain** `com.cmuxterm.app.next.blocking-drain` | Resolving violations to image UUID + offset; the Debug log line; the sink | Nothing | utility | utility | Ring of 64 new sites, 128 sites per launch; past either: counted in `overflow`. Hang-watched (p09-observability-070): lane `blocking.drain`, one scope per drain-queue job (10 s), set by the composition root through `BlockingDetector.watchDrain` (Compat cannot import the hang watch). In trap mode the main thread waits for one drain pass at most 50 ms before it stops the process |
| **Memory release sink** `com.cmuxterm.app.next.memory.release-sink` (CmuxNextMemory `MemoryReleaseSink`, p07-memory-069) | The last references of what memory release slices unlinked (CGImage, Data, IOSurface) and their frees; one `malloc_zone_pressure_relief(nil, 0)` per escalation to critical (PartitionAlloc's zone has no `pressure_relief`; the fork's `ReclaimAll()` purge is not wired yet: follow-up task "Fork PartitionAlloc purge" after p07-memory-069) | Nothing but the frees and the relief | utility | utility | One block per dropped value; a slice unlinks at most its 2 ms budget's worth on main, so the queue holds at most a few frames' drops; one relief per critical pass, queued after that pass's drops |
| **Daemon connection upkeep** queues `com.cmuxterm.next.retry-wake` (`RetryWake`: vnode watch on the socket's folder), `com.cmuxterm.next.daemon.path.<machine>` (network path monitor), `com.cmuxterm.next.daemon.exit.<pid>` (an old daemon's exit source during a version handoff), `com.cmuxterm.next.process-progress` (`ProcessRunner` stdout write counter) | Events that wake a reconnect or report a child's progress | Nothing: kernel and `Network` sources deliver events, the handler only hops | retry-wake and daemon exit user-initiated (the reconnect of disconnected terminals waits on them); path and process-progress utility (p02-threads-032) | as today | One queue each; sources coalesce |
| **Settings and file watchers** `com.cmuxterm.next.settings.watcher` (`ConfigFileWatcher`), `cmux.files.fsevents` (`FolderWatchStream`, Files pane), `cmux.files.tree-fsevents` (`FileTreeWatchStream`, file explorer) | FSEvents and vnode callbacks | Nothing: the callback only coalesces and hops | settings watcher utility (p02-threads-032); `cmux.files.fsevents` user-initiated; `cmux.files.tree-fsevents` utility | settings watcher as today; `cmux.files.fsevents` user-initiated, as today (userVisible: a change shows soon; a userVisible thread runs at user-initiated since p02-threads-115); `cmux.files.tree-fsevents` as today | FSEvents latency coalesces bursts; one stream per watched root |
| **Power source** `com.cmuxterm.next.energy.power-source` (`PowerSourceMonitor`, CmuxNextEnergy; registered only on a Mac with an `IOPMPowerSource`) | notify(3) power-source and charge registrations (the charge one only on battery), the IOKit power-source snapshot | powerd (one `IOPSCopyPowerSourcesInfo` IPC per notification) | utility (p14-energy-058) | as today | One notification per source or charge change; the main thread hears only a new source or low-battery band (Chrome's `IOPMPowerSourceSamplingEventSource`, no timer) |
| **Home cache** `com.cmuxterm.home.cache` (the `HomeCache` actor's executor, CmuxHomeCore, shared with iOS) | Home drafts and cache files | Disk (its own file writes block this queue, never a pool thread) | user-initiated | as today (the forced quit's last draft write runs on it with the pool full) | One serial queue |
| **Remote and mobile I/O** `com.cmuxterm.next.remote-localhost` (`RemoteLocalhostProxy`), `com.cmuxterm.next.cloud-browser-proxy` (`CloudProxyLoopbackOpener`), `com.cmuxterm.next.remote-fetch` (`RemoteFetchPinnedTransport`), `cmux.remote-view.rd-transport`, `cmux.remote-view.mock-host` (tests and fixtures), `cmux.next.mobile.unix-lane` (`UnixSocketLane`) | Loopback proxies for a remote page, pinned fetches, the remote desktop byte stream, the mobile lane to the daemon | Socket I/O through `Network` and dispatch sources (non-blocking); the far side is a remote host or the daemon | remote-localhost, cloud-browser-proxy and mobile unix-lane (p02-threads-032) user-initiated; the others default (no QoS stated) | remote-localhost, cloud-browser-proxy, mobile unix-lane as today; remote-fetch and rd-transport user-initiated (a visible pane waits on them, task 033); mock-host utility (task 033) | One queue per proxy or connection; the transports' own buffers |
| **Remote view render** `cmux.remote-view.render` (`MetalYUVRenderer`) | Drawing one NV12 frame into the remote view's `CAMetalLayer` (YUV to RGB shader) | `nextDrawable`: one of the layer's two drawables, freed by the window server (never on main) | user-interactive | user-interactive (closed list); lowered for a hidden view by p03-rendering-114 | Serial; the presenter's `LatestFrameMailbox` keeps only the newest frame |
| **Mac Screen capture** `cmux.screen.capture` (`ScreenCaptureBackend`, CmuxVNCWebRTC in Packages/Shared, used by `MacScreenHubHost`) | ScreenCaptureKit sample buffers of this Mac's display, handed to the encoder for a remote viewer | Nothing: SCStream calls back on it; state behind its `Mutex` | user-initiated (p02-threads-146) | user-initiated: no local frame waits on it, a viewer on another device does | One SCStream, 60 fps at most, frames only on change |
| **Browser host provider** thread `cmux browser-host provider reader`; queue `com.cmuxterm.next.browser-host.provider.write` (`ProviderConnection`) | The browser-host provider socket | Reader: `read(2)` of its socket. Writer: `write(2)` | user-initiated, both (the writer since p02-threads-032) | as today | One per provider connection |
| **Browser support** `com.cmuxterm.import-history-sync` (`ImportHistorySync`), `com.cmuxterm.chromium-runtime.download` (URLSession delegate queue, serial), thread `cmux-next webkit setup probe` (`WebKitSetupGate`, one-shot) | History import sync; the Chromium runtime download; WebKit's one sandbox-extension request | Import: disk and SQLite. Download: nothing (URLSession delivers). Probe: the WebKit request | import default (no QoS stated); download and probe utility | import utility (task 033); download and probe as today | Serial queue; one probe per launch |
| **Agent pane and acpmux client** `com.cmuxterm.app.next.agent-pane.inbound`, `com.cmuxterm.app.next.agent-pane.socket` (URLSession delegate queue, serial), `com.cmuxterm.app.next.tasks.socket` (`SocketTasksSource`), `com.cmuxterm.app.next.tasks.directory` (its socket directory watch), `com.cmuxterm.app.next.agent-pane.prompt-journal`, `cmux.next.agent-pane.acpmux-exit.<pid>`, `cmux.next.agent-pane.acpmux-launch-reap.<pid>`, `cmux.next.agent-pane.acpmux-log-progress`, `cmux.next.agent-pane.acpmux-status`, `cmux.next.agent-pane.acpmux-host` (the `AcpmuxHost` actor's executor), `cmux.acpmux.checked-line`, `cmux.agent-activity.socket`, `com.cmuxterm.app.next.chief-settle` | The agent pane's socket to acpmux and its frames; the task list socket; prompt journal writes; acpmux launch, exit and status; agent activity lines; the Chief settle notice | inbound, agent-pane.socket, tasks.socket, acpmux-status, agent-activity: socket reads and writes (non-blocking sources); prompt-journal: disk; exit and reap: process sources; log-progress, tasks.directory: a vnode source | inbound, agent-pane.socket, tasks.socket user-initiated; prompt-journal, agent-activity (p02-threads-032), tasks.directory utility; the others default (no QoS stated) | inbound, agent-pane.socket, tasks.socket as today (the visible pane waits); prompt-journal, agent-activity as today; acpmux queues and chief-settle utility (task 033) | Serial queues; the pane's inbox bounds |
| **Computer Use helper** queue `com.cmuxterm.next.computer-use.helper-reap` (one per `DisclaimedHelperSpawner`), thread `cua-helper-v2-stdout` (`ComputerUseHelperV2Spawner`) | Reaping the helper after SIGTERM; reading its stdout | reap: a process-exit source (`ChildExitWatch`), one `waitpid` that returns at once (p02-threads-128); stdout: `read(2)` of its pipe | utility | as today | One reap queue per spawner; one stdout thread per helper |
| **Diagnostics writers** `cmux-next.hang-episodes`, `cmux-next.hang-episodes.symbols` (`HangEpisodeRecorder`), `com.cmuxterm.app.next.run-marker`, `com.cmuxterm.app.next.crash-forwarder`, `com.cmuxterm.app.next.owner-panic-forwarder`, `com.cmuxterm.app.next.invariant-sink`, `com.cmuxterm.app.next.renderer-stability`, `com.cmuxterm.next.typing-probe` (writes), `com.cmux.host-pressure` (`HostPressureMonitor`), `debug.window_record` (Debug window recording) | Hang episode files and symbolication; the run marker; crash and owner-panic forwarding; invariant and renderer stability reports; typing probe records; host memory and thermal pressure; Debug frame recording | Disk (writes and symbol reads); host-pressure: nothing (a pressure source hands one level change to main); window record: disk | utility; `debug.window_record` user-initiated | as today (window record is a Debug tool a person runs and watches) | Serial queues; the recorders' own rings |
| **Launch warm-ups** threads `cmux-next resource bundle warm-up`, `cmux-next launch warm-up`, `cmux-next icon warm-up`, `cmux-next terminal prefetch` (one-shot) | Opening the app's SwiftPM resource bundles; building the action catalog (`ActionCatalogLaunch.build`, p08-startup-092), the SF Symbols catalog and the display UUIDs while AppKit starts; decoding the icon pack and catalog (`IconPack.decodeBundledInBackground`, p08-startup-039); warming the Metal driver and the terminal's fonts (`TerminalLaunchPrefetch`, p08-startup-091) | Bundle warm-up: disk (bundle reads). Terminal prefetch: disk (config and font reads); main never waits on it. Icon warm-up: disk (the bundled icon JSON); a main-thread icon read during that decode waits for the rest of it (`swift_once`). Launch warm-up: nothing; the main thread never waits on it unseen: the registry's catalog read (`ActionCatalogLaunch.descriptors`) finds the catalog built, or claims the build with one compare-and-swap and builds it itself, or finds the warm-up's claim and waits in `swift_once` for the rest of that one build, recorded as `launch.action_catalog_main_wait_us` (`debug.startup` `action_catalog_main_wait_ms`) and the `launch.action_catalog_first_main_access` interval | bundle, icon and terminal prefetch warm-ups user-initiated; launch warm-up user-interactive (`// qos-allow:`: main reads what it builds before the first frame) | as today (launch warm-up in the closed list: a frame waits on it) | One each per launch, then they exit |
| **Server helper files** `com.cmuxterm.server-helper.files` (`ServerHelperFileLane`, in the root `cmux-server-helper` process, not the app; p02-threads-036) | `FileFixPriorStore` reads and writes: the value each applied pmset fix replaced, one small JSON file per helper label | Disk (one read, or one read and one atomic write, per item); nothing waits on a lower QoS | user-initiated (the person's fix request waits for its reply) | as today | Serial; one item per XPC request, and the service's `FixQueue` runs one request at a time |
| **Misc** `cmux.updates.network` (updater path monitor), `cmux.home.fixture.video` (fixture media), `cmux.home.promised-files` (a drop's file promises) | Network path for the updater; fixture video frames; promised-file writes | updates: nothing (path events); fixture: disk; promised files: disk | updates utility (p02-threads-032); fixture default (no QoS stated); promised files user-initiated | updates as today; fixture utility (task 033); promised files as today (the person waits for the dropped files) | Serial queues |
| **Chromium** (in-process browser: UI thread = the app's main thread; Chromium's own IO and worker threads; renderer, GPU and utility helper processes; out-of-process host prototype `com.cmuxterm.chromium-host.read` / `.exit` / `.control`; CEF child exit queue `com.cmuxterm.app.next.cef-children`) | Web pages | Chromium's IO thread blocks on its own sockets, never the UI thread. The host prototype's threads wait only in `poll` and on their exit source | Chromium's; the host prototype threads and queues user-initiated; `com.cmuxterm.app.next.cef-children` user-initiated (p02-threads-032: it must add NOTE_EXIT on a new helper before Chromium reaps it) | declared by library (Chromium sets it from the thread type, `base/threading/platform_thread_apple.mm`); host prototype and cef-children as today | Child exits on `com.cmuxterm.app.next.cef-children`; host prototype: 256 KiB send buffer, input sent at once; on a full socket frames wait in the input outbox (one latest-wins slot each for moves, wheels (deltas summed) and geometry between two discrete frames; discrete frames kept in order; over 4096 discrete or 1 MiB waiting: the connection ends) flushed by a writable source on `com.cmuxterm.chromium-host.write`, one `write` per fire; a full socket that takes no byte for a 30 s window (a `DemandTimer` check, at most one per window) ends the connection; 4096 unread frames from the host, over: the connection ends; in the host one frame queue (moves, wheel deltas and geometry coalesce, keys kept), over 4096: the host ends; one exit queue per launcher (kqueue process source, no thread per host); control channel `com.cmuxterm.chromium-host.control` (one reader thread per end, user-initiated, waits only in `poll`; p01-process-012): sends never block, a refused frame waits in the outbox where state ops coalesce per (op, page); over 256 KiB or 4096 waiting is counted (`quota_excess`) and ends the host only after 60 s over without a break; a malformed frame ends it; replies resume on the reader, other messages reach main as one visible task per batch, and past 4096 unread the reader stops reading until main drains |

## Closed user-interactive list

Only these threads and queues run at user-interactive (Chrome's `kDisplayCritical`: the UI thread, the
compositor and the threads a frame or an echoed key waits on). Any other cmux thread or queue at user-interactive
is a bug. A new entry needs a row here in the same commit, with the reason a frame or the key echo waits on it.
The Swift guardrail `task-priority` refuses a new `.userInteractive` without `// qos-allow: <why>`; in the daemon
the sources are `ECHO_PATH_QOS` (`cmux-tui-core/src/echo_thread.rs`) and cmux-holder's `link::LINK_READER_QOS`,
which `thread_qos_tests.rs` keeps equal to `ThreadType::InputCritical`. The list covers every package linked into
the app, not only CmuxNext: check it with
`rg -n -e '\.userInteractive' -e QOS_CLASS_USER_INTERACTIVE Packages/macOS Packages/Shared -g '!**/Tests/**'`
(doc comments that name the class aside, every hit is a row below).

| Thread or queue | Process | Why a frame or the echo waits on it | At user-interactive today |
|---|---|---|---|
| Main thread and the frame clock on it | app | The UI thread | yes (system) |
| `cmux-next vsync <display>` | app | Frame ticks | yes |
| `cmux-next main-thread watchdog` | app | Samples a wedged main thread; the app hang watch | yes |
| `cmux-next quit deadline`, `cmux-next crash deadline` | app | Must run while main is wedged | yes |
| `cmux-tui reader <path>` of the `terminal_attach` connections | app | Daemon output to the terminal | yes (`DaemonWireStats.Role.readerQoS`, p04-input-059, LineTransportTests); every other role's reader, `control` included, runs below it |
| `com.cmuxterm.next.daemon.write` of the `terminal_attach` connections | app | Most keys to the daemon (`TerminalAttachment.enqueueInput`) | yes (p02-threads-030, `DaemonWireStats.Role.writerQoS`, SocketWriterQoSTests); every other role's writer, `control` included (p04-input-059), runs below it. A `terminal_attach` writer targets its view's `terminal.attach-input` queue (p04-input-058), so it drains on that serial queue. Two key paths still use `control` and so run at user-initiated: pre-attach input of a new split (`send {terminal_id}` from `CreatingTerminalInput`) and a TUI's Command chords (`send-key` from `TerminalHooks`) |
| `com.cmuxterm.next.localpty.read`, `com.cmuxterm.next.localpty.write` | app | Local PTY echo | yes, both (the write since p02-threads-030, LocalPTYQoSTests) |
| `com.cmuxterm.next.terminal.output` | app | Feeds the terminal surface | yes |
| `com.cmuxterm.next.terminal.attach-input` (one per `DaemonTerminalIO`) | app | A terminal's input lane drains here, and the attach connection's `daemon.write` writer targets it: a key goes from the main thread to the attach socket's `write(2)` in one thread hop (p04-input-058, `TerminalInputLane`, `DaemonTerminalIO.inputDrain`) | yes |
| `cmux-next launch warm-up` (one-shot) | app | Before the first frame main reads the action catalog, the menu's SF Symbol and the display UUIDs it builds; below main's QoS a loaded machine ran them after main reached them. Main's catalog wait is recorded (`launch.action_catalog_main_wait_us`, p08-startup-092) | yes (`LaunchWarmup`, `// qos-allow:`); the thread exits after its work |
| `cmux.remote-view.render` | app | Remote desktop frames (compositor class, task 131); a hidden view: p03-rendering-114 | yes |
| Ghostty renderer of the focused surface | app | Declared by library (ghostty-next `setQosClass`) | yes |
| `mux-conn` of the app's UI connection | daemon | Reads the person's keys | no: default today; under `daemonRequestQos` the app's connections rest at user-interactive once classed (task 224, `ConnectionClass::Person` reader = `ECHO_PATH_QOS`) |
| `mux-line-out`, `mux-pty-input`, `mux-attach-out`, `mux-render-attach-out` | daemon | Key in, echo out | yes |
| `remote-input-writer`, `relay-input` | cmux-tui client, relay | The person's keys to a remote daemon or a session socket | yes (p04-input-084) |
| `mux-terminal-io`, `mux-terminal-read`, `surface-<id>-reader`, `surface-<id>-host`, `surface-<id>-host-frames`, `surface-frames` | daemon | PTY output and frames | yes |
| `terminal-host-pty`, `terminal-host-parser`, `terminal-host-client`, `terminal-host-client-input` | terminal host | PTY output, parse, frames out, keys in | yes |
| `holder-link` (cmux-holder `link::LINK_READER_QOS`) | daemon | Routes each held terminal's output to its surface: the echo of a held terminal | yes (p04-input-060, `ThreadType::InputCritical`; `thread_qos_tests.rs` keeps the two equal); cmux-holder-v3's `holder-link` is not set |
| Holder `poll` loop | holder | The PTY that outlives the daemon | no: not set; task 207 after task 223 |

Per-terminal reader and parser threads (`surface-<id>-reader`, `surface-<id>-host`, `surface-<id>-host-frames`, `terminal-host-pty`, `terminal-host-parser`) drop to utility while no view shows the terminal (a parked tab, a hidden workspace; a view that only stops counting toward the size still shows it), and return at their next wake when one does (task 236, feature `hiddenTerminalQos`; each thread applies its class itself with `cmux_threads::apply_pending_qos`).
Child processes never inherit this class: a shell or agent starts at default (task 223), and a helper at its
`WorkPriority.processQoS` or utility.

## Lanes

App: one `BackgroundWork` per process, built in AppServices (`work`). Daemon: one `cmux_threads::work::Work`
per process, built where the session opens (`mux/construct.rs`, label `mux`).

| Lane | App today | App target | Daemon (`cmux_threads::work`) |
|---|---|---|---|
| files | Width 4/3/2/1 by priority (userBlocking/userVisible/bestEffort/idle, `FilesLaneWidths`; task 116): each priority has slots of its own, so a best-effort write never waits in front of a user-blocking read and one slow read does not hold the next; ordered work through a `WorkSequence` | as today | Width 4/3/2/1 by priority |
| system | Width 6; 1 slot only for an uncapped userBlocking item (Chrome `PrioritizedDispatcher`, counting every busy slot); host resolution capped at 4 | as today | Width 6/5/2/1 by priority; 1 slot only for UserBlocking |
| cpu | Performance cores minus 1 (at least 1); a blocking seam is `wrong-lane` | as today | Performance cores minus 1 (at least 2) |

- Best effort and idle: at most 2 running per shared lane, idle at most 1 (Chrome `kMaxBestEffortTasks`,
  `base/task/thread_pool/thread_pool_impl.cc`; the idle limit is cmux's). An item boosted by its waiter runs at
  the waiter's level and is not capped. Daemon: done. App: done (`LaneScheduler.bestEffortCap` / `idleCap`,
  p02-threads-115, LaneBestEffortCapTests); the files lane is held by its widths instead (2 best-effort and 1 idle slot), so a hung low read never holds the other low level. On the system
  lane (may block) an item that has run longer than `BackgroundWork.mayBlockThreshold` (1 s) stops counting, so two
  hung calls never hold every later low item: Chrome's `ThreadGroup::BlockingStarted` /
  `IncrementMaxBestEffortTasksLockRequired` (`base/task/thread_pool/thread_group.cc`, `kForegroundMayBlockThreshold`).
  The lane checks only while a low item waits for the cap: one one-shot timer to the earliest such moment, no poll.
  After `beginShutdown` the cap is lifted so block-shutdown items finish (Chrome's `OnShutdownStarted` sets
  `max_best_effort_tasks_` to `max_tasks_`).
- Startup fence: best-effort and idle posts wait until launch settles (`beginBestEffortFence` /
  `endBestEffortFence`); an awaited item never waits for the fence. The app raises it once
  (`raiseLaunchFence`, from `LaunchOrder.BestEffortFence` in `main()`) and lowers it once, at startup complete
  or after its 3 s cap, whichever comes first; the cap's one-shot timer exists only while the fence is up, and
  shutdown lifts the fence and cancels the cap.
- QoS by priority: the table in "QoS and task priority" below. Daemon workers keep one class for life (`fg`
  user-initiated, `be` utility, `idle` background), named `mux-<lane>-<fg|be|idle>` (lane `files`, `sys`,
  `cpu`); on Linux a `mux-launch` thread (user-initiated) starts them.
- Hang deadlines per item: files 5 s, system 30 s, cpu 10 s. Each slot registers with the hang watch on its own
  (under the lane's name), as Chrome watches each pool worker thread: items of one lane run at once, and a scope
  nests only on one thread.
- **Sequence rule.** Work that must run in order (writes to one file or one store) goes through one sequence:
  `work.sequence(label)` (lane `.files` by default) returns a `WorkSequence` (Chrome `SequencedTaskRunner` on the
  thread pool, base/task/sequenced_task_runner.h; task 116). Its items run in post order, never two at once, each
  on any free slot of the lane at its own priority; the front item runs at the highest priority waiting behind it
  and leaves the startup fence while one of them is awaited, moved in place (it stays before the work posted after
  it), and `onRan` reports the level it ran at. A cancelled awaited item leaves the sequence; shutdown drops items in
  their turn, so a block-shutdown save behind a dropped item still runs. Never count on order outside a sequence:
  the items of one priority on one lane run at once. Sequences today: the startup trace's drains, the incognito
  ledger read then the settings read at launch (`LaunchRead(in:)`: the launch window needs the ledger's answer),
  and the managed-status writes (`StartupDestination.Lane.sequence`).
- Shutdown: `skipOnShutdown` (default) is dropped at quit, `continueOnShutdown` runs on, `blockShutdown` is
  awaited inside the quit deadline and raised to user-initiated (task 118). `blockShutdown` is only for one
  bounded write (< 50 ms, atomic replace).

## Daemon threads (cmux-tui)

Every row is a thread name the daemon side starts (cmux-tui-core, cmux-tui, cmux-holder, the terminal host,
acpmux). "Registered" means it starts through `cmux_threads::spawn` (or `echo_thread::spawn`) and is listed by
`server.threads` with its declared QoS; the other rows still use `std::thread::Builder` and move in tasks
213-218 and 229 (queue MQ-12), with one-shot threads becoming `work` items in task 230. `<id>` is a per-object
part of the name.

| Thread / queue | Owns | Waits on (QoS) | QoS | Target QoS | Registered | Bound and back-pressure |
|---|---|---|---|---|---|---|
| `mux-server`, `mux-ws-server` (accept; `ACCEPT_THREAD_QOS`, server/listen.rs, websocket_listener.rs) | Accepting local and WebSocket connections | `accept` | user-initiated | as today: every connection, the person's too, waits on accept (p02-threads-211) | yes | Max 64 connections; over: `server.busy` |
| `mux-conn`, `mux-remote-conn` (one reader per connection) | Line read; a `Command` line queues on the connection's control sequence, and a `cmux.protocol/2` line or feature route goes to the connection's request sequence (`Mux::post_connection_request`: a System-lane `work` item, one request at a time in read order, inside `will_block`), so no handler runs on the reader (remote-relay lines still do); blocking disallowed once its setup is done: before its first message the reader resolves the peer's identity (`origin_gate::AcceptedPeer::resolve`: the peer's executable from procfs or its audit token, canonicalized), which may block and stalls only that connection (p02-threads 309) | Its socket (`read`, the client's QoS); request work that may block goes to `work` | default (`CONNECTION_READER_QOS`) | user-interactive for the app's UI connection, utility for automation (CLI, MCP, hook, agent, page, remote), user-initiated until the hello (task 224; done under `daemonRequestQos`) | yes | Per connection 256 requests / 16 MiB (over: error, not run) |
| `mux-seq-input`, `mux-seq-control` (the daemon-wide sequenced pool's request workers: input 2, control the cores minus 2; every connection's control sequence and stream sequences run on them, no thread per connection; server/sequenced_pool.rs, p05-ipc-073), `mux-ws-conn` (one per WebSocket connection: reads frames and runs their requests); `spawn_request_thread`, server/connection_scheduler.rs | Taking the connection's requests in order off its scheduler: an ordinary request runs on the connection's request sequence (`Mux::post_connection_request`: a System-lane `work` item at its cause's priority, inside `will_block`, at the connection's class), and the control sequence takes nothing else until it ends, so the requests keep their order and one-at-a-time; a clear-history or create goes to its own worker as before. `mux-ws-conn` hands its lines to the same request sequence. A task that blocks (a request-path blocking note, or `request_path::will_block` around a PTY or host input write and the `wait-for` wait) starts one temporary worker (at most 256) | Store locks (`LockHolder`, timed; owner boost by task 226), `work` replies. Blocking disallowed (`cmux_threads::disallow_blocking`): a checked blocking call is a recorded site and, in Debug, a panic (`CMUX_DAEMON_BLOCKING=record` turns it off) | user-initiated (`REQUEST_THREAD_QOS`, p02-threads-211) | as today; automation clients utility (task 224; done under `daemonRequestQos`: a control task runs at the connection's class); clear-history runs as a System-lane `work` item at its cause's priority, blocking disallowed (task 230) | yes | Rules D1-D8 in perf-lead.md |
| `mux-seq-utility`, `mux-seq-background` (the sequenced pool's bulk and background workers, server/sequenced_pool.rs, p05-ipc-073) | Bulk and background stream sequences | Nothing outside their tasks; idle workers wait on their condition variable with no timeout | utility, background | as today (p05-ipc-080 sets QoS per the PL-qos table) | yes | 2 utility, 1 background, plus one temporary worker per blocked task (at most 256) |
| `mux-surface-operation` (cmux-tui `pty_input.rs`) | One surface operation off the PTY input scheduler | Store locks (`LockHolder`) | user-initiated (`cmux_threads::spawn`, p05-ipc-080) | a `work` item at the priority of the request it serves (task 230) | yes | One thread per operation today |
| attach-stream drains (no thread: a sequence per view on the pool's input workers; server/attach_pump.rs, stream_attach_out.rs, snapshot_attach_out.rs, p05-ipc-079) | The output, notifications and snapshot digest of a view attached with a client-minted `stream`; a legacy view keeps `mux-attach-out`, `mux-render-attach-out`, `mux-snapshot-attach-out` and `mux-attach-notifications` | Nothing: a turn takes what its sources hold and returns; sources, the writer's room and closes post the next turn, the idle digest is a delayed task on the wake grid. Its end does not wait either: with no room for its `stream-end`, the connection wakes it when an item leaves the queue or the connection closes | the pool's (`mux-seq-input`) | as today | yes: each item is an echo hang scope (`mux-attach-out`, `mux-render-attach-out`, `mux-snapshot-attach-out`) | One item past the stream's backpressure cap (2), 64 items per turn, and one bulk item (a READY, a history or images chunk) per turn; 50 byte, render and snapshot views each add at most 2 threads (`tests/attach_threads.rs`) |
| `mux-session-mutation` (cmux-tui `pty_input/session_mutation.rs`) | The PTY input scheduler's session mutations (split, close, zoom, a divider drag's ratio), handed off by `mux-pty-input` in queue order; the scheduler dequeues nothing else while one runs | SQLite registry commits (local session), the daemon's reply (remote session) | user-initiated | as today | yes | One thread per dispatcher; one mutation at a time |
| `mux-line-out`, `mux-attach-out`, `mux-render-attach-out` | Writing queued bytes to one connection | Its socket (`write`); the producer queue (`Condvar`, producers user-interactive): the writer's wait for its next item is an idle wait (`Condvar::idle`, Chromium's `declare_only_used_while_idle`), never a violation (p02-threads 308) | user-interactive | user-interactive (closed list). `mux-line-out` stays there, not user-initiated: it writes the app's `terminal_attach` connection too, whose echo the app reads at user-interactive; it moves with its connection's class (task 224) | yes | Outbound 256 per stream, 4096 per connection (over: the largest stream ends); write timeout 2 s |
| `mux-pty-input` | Writing keys to PTYs | The PTY (`write`); the shell runs at default | user-interactive | user-interactive (closed list) | yes | One bounded scheduler; per-surface order, byte writes batched, motion coalesced |
| `remote-input-writer` (cmux-tui client, `session/remote.rs`, one per remote session) | Writing the person's keys and control requests to a remote daemon in order | The remote transport (`write`); its queue's `Condvar` | user-interactive (`ECHO_PATH_QOS`, `cmux_threads::spawn`, p04-input-084) | user-interactive (closed list) | yes | `INTERACTIVE_WRITE_QUEUE_CAPACITY` writes; over: backpressure error |
| `relay-input` (cmux-tui relay, `main.rs`, one per relay) | Copying stdin (the person's keys) to the session socket | stdin (`read`), the socket (`write`) | user-interactive (`ECHO_PATH_QOS`, `cmux_threads::spawn`, p04-input-084) | user-interactive (closed list) | yes | `io::copy` buffer; ends at stdin EOF |
| `mux-terminal-io` (one per owner; mux/terminal_work/read_loop.rs) | Readiness of every daemon-local PTY's output: one kqueue (epoll on Linux), routing only, as Chrome's IO thread (content/browser/browser_thread_impl.cc over base/message_loop/message_pump_kqueue.cc) | The kqueue or epoll set, no timeout (0 idle wakeups) | user-interactive | user-interactive (closed list) | yes | One thread; starts with the owner's first local PTY (p07-memory-095) |
| `mux-terminal-read` (read loop workers) | Reading and parsing a ready local PTY's output (`surface/local_reader.rs`): at most one run per terminal at once, so its output stays in order; a run reads 4 chunks and yields | The PTY (nonblocking read), the parser lock | user-interactive | user-interactive (closed list) | yes | At most 4 running, plus one for each worker inside `will_block` (a query response write that waits; Chrome's ScopedBlockingCall WILL_BLOCK); one parks with no timeout, the others exit when idle (p07-memory-095) |
| `surface-<id>-reader` (holder and byte-backend terminals only), `surface-<id>-host`, `surface-<id>-host-frames` | One terminal's holder or backend output or its host's frames; the cwd, progress, program status, notifications and exit its output changes are published by queued `work` items (Files lane, the terminal's sequence), never on the reader: each is a SQLite registry commit (MQ-13). `surface-<id>-host` disallows blocking only while it streams a host connection: between connections it runs the host's lifecycle (exit or lost-connection commit, reconnect backoff, record reads, handshake), which may block, as no echo crosses it then | Its holder sink, backend channel or host socket (own descriptor) | user-interactive | user-interactive; utility while its workspace is hidden (task 236); holder terminals move to the VT pool (p01-process-120), hosted ones to the read loop (p07-memory-095b) | yes | One per terminal (see [Per-terminal threads](#why-the-daemon-keeps-thread-per-connection)) |
| `surface-frames` (one per process) | Frame production for every surface (one thread, not one per terminal) | Its condition variable, no timer at idle | user-interactive | user-interactive (closed list) | yes | One thread |
| `mux-reaper` (one per process, `cmux_threads::reaper`, task 237) | Waiting for the exits of the daemon's children: terminal shells, terminal hosts, terminal holders, Chief brains, the journal plugin; each exit completes on a `work` system-lane item (reaped with `waitpid`, or left a zombie for `watch_exited`) | kqueue `EVFILT_PROC` `NOTE_EXIT` (macOS), pidfds in one epoll set (Linux); no timeout, 0 idle wakeups | utility | same | yes | One thread for every child; a child it cannot register (Linux without `pidfd_open`, no descriptor left): one `mux-reap-wait` for it; when even that thread cannot start, the caller's own fallback (`terminal-host-reaper`, `holder-reaper` outside a mux, the journal plugin's timed poll, a failed launch) |
| `surface-<id>-wait` (holder and byte-backend terminals) | Waiting for one terminal's end on a holder or an app backend (not a child of the daemon) | The holder sink or the backend channel | not set | as today | no | One thread per holder or backend terminal |
| `mux-terminal-work` (8 workers) | Terminal jobs; registry commits of `mux/resource_effects.rs` intents go through the journal writer (next row) | Disk; the journal writer | user-initiated (`TERMINAL_WORK_QOS`, p02-threads-212) | as today | yes | 1024 queued jobs; a job that does not fit runs inline |
| `mux-<lane>-<fg/be/idle>`, `mux-launch`, `mux-delay` (`cmux_threads::work`) | Work that may block, by lane; `mux-delay` holds items posted with a delay (`Work::post_delayed`, Chrome's `DelayedTaskManager`) until due; a delayed item never blocks shutdown (a delayed block item is a skip item, as Chrome's `TaskTracker` refuses delayed tasks at shutdown), and the launcher starts `mux-delay` when the first poster's nice is above user-initiated. One-shot request work (`Mux::post_request_wait`: Cloud, Chief inspect and control, agent start/attach/call/trust/transfer/update/inventory/CLI job, URL open, loopback open, browser-runtime start, scripts, tab restart, one-shot browser CDP bootstrap; clear-history is a System-lane item with blocking disallowed), per-terminal retries (`Mux::post_mux_retry`: adoption, template completion, exit detach, host-record cleanup), per-terminal deadlines (`Mux::post_mux_work_after`: respawn backoff, grid hold end, creating-input expiry) and browser-runtime stop run here, not on a thread each (p02-threads 230). Adoption tries also hold one of 8 `Mux::terminal_replays` permits (Chrome's `PostJob` max concurrency); a try past them parks with no thread, and its handshake and replay run inside `will_block`, so a 60-host start takes no System-lane slot from other UserVisible or UserBlocking work | Disk (files), system calls (sys), nothing (cpu); a wait on another process or the network inside `will_block`, outside the lane's limits; `mux-delay` its condition variable, no timeout with nothing delayed | `fg` user-initiated, `be` utility, `idle` background; `mux-launch`, `mux-delay` user-initiated | same | yes | [Lanes](#lanes); an item runs at the priority of the request it serves (`EventCause::work_priority`: the app's requests UserBlocking, the rest UserVisible) |
| `mux-session-journal-writer` (+ `-fanout`, `-hooks`, `-reaper`), `journal-hook-worker-<index>`, `journal-hook-stdin`, `sqlite-wal-sync` | Durable session journal; hook delivery (`journal-hook-stdin` writes one hook child's input) | Disk; SQLite (`LockHolder` chokepoints, task 225); `journal-hook-stdin`: the hook child's stdin pipe | writer declared user-initiated; with `daemonRequestQos` on, a commit attempt no request waits on runs at utility (a `WorkQos`, so a ranked lock it takes raises it), and an attempt stays user-initiated while a request waits on the writer: a receipt it has not taken (an indeterminate registry receipt counts until its answer is taken) or space in a full lane (`journal_ingress/writer_qos.rs`, p02-threads-212); receipts carry the writer's class (`cmux_threads::sync`), so a receipt sent below its request is a `priority-inversion` site; `-fanout`, `-hooks`, `-reaper`, the hook workers, `journal-hook-stdin` and `sqlite-wal-sync` utility (`cmux_threads::spawn`, p02-threads-212; they take no terminal or registry lock) | as today (the registry lock's owner boost is task 226). The writer's declared class goes to utility only after PL-daemon removes the request-path waits on it (receipts, lane space); p04-input-084 leaves it user-initiated for that reason | yes | `sync_channel(1024)` terminal, `(256)` durable: the producer waits for space; durable wait deadline 30 s |
| `mux-project-sources`, `terminal-command-history` (p04-input-084) | Editor project import and its folder watch; finished shell command rows, their expiry and client deletes | Disk (editor stores); the workspace registry (project import commit, command rows); the watch or the worker's queue | `terminal-command-history` default (`cmux_threads::spawn`, `request_qos::UPKEEP_THREAD_QOS`); `mux-project-sources` utility through `spawn_raisable` (p05-ipc-080, the watcher row of [PL-qos](#daemon-qos-by-role-pl-qos-p05-ipc-080)); with `daemonRequestQos` on each import pass and each command store or expiry pass runs at utility (`RequestQos::enter_upkeep_pass`), raised while it holds the registry a request waits for. A client's delete waits on its answer, not on the registry lock, so no lock raises the worker for it: while a delete is queued and unanswered (`CommandHistoryQueue`'s count), every pass runs at the declared class, also an append pass the worker runs before a delete it already took | as today | yes | One pass at a time; `MAX_QUEUED_COMMANDS` queued commands |
| `mux-inventory-watch` (one per watching client), `terminal-host-record-mirror` (one per process), `cmux-config-watch` (one per settings or keybindings watch; crate cmux-config, `watch::WATCH_THREAD_QOS`) (p04-input-084) | Agent inventory watch over acpmux; the host records' workspace-key mirror; settings and keybindings file events | acpmux socket; disk; the kernel file watch | utility (`ThreadType::Utility`: `mux-inventory-watch` through `spawn_raisable`, p05-ipc-080, the others through `cmux_threads::spawn`; cmux-config sits below cmux-tui-core, and `thread_qos_tests.rs` keeps its class equal to `ThreadType::Utility`). They hold no lock a request or a resize waits for: `cmux-config-watch` only posts each hint's reload to the mux's Files lane at user-visible, one at a time in hint order (`settings::post_reload`, as Chromium's `FilePathWatcher` posts to a sequence), because the reload holds the store lock that `with_settings` and `settings_apply` take and `adopt_host_size_policy` holds `client_sizing`, and std's mutex donates no priority on Linux | as today | yes | One per watcher; the mirror keeps the newest record per path |
| `mux-output-store-writer`, `cmux-journal-maintenance`, `journal-retention` | Terminal output store snapshots and segments; journal maintenance; coalesced reconnect checkpoints | Disk; SQLite; a terminal slot lock (output store snapshot) and the workspace registry (output store prune, checkpoints) | default (`cmux_threads::spawn`, `request_qos::UPKEEP_THREAD_QOS`); with `daemonRequestQos` on each pass runs at utility as a `WorkQos` (`RequestQos::enter_upkeep_pass`, p02-threads-212), so a terminal or registry lock the pass holds raises it to user-initiated (`LockBoost`) and a PTY reader or request never waits behind a utility holder | as today | yes | One pass at a time per thread |
| `mux-request-watchdog` (one per process; p05-ipc-006, cmux-tui-core server/request_watchdog.rs; the daemon's one hang watcher, p10-stability-032) | The hang scopes of requests, journal writer commits and holder-link frames, with one append to `owner-hangs-<session>.jsonl` per hang (at its 2 s or 1 s tier). Requests running past 250 ms: every connection frame from its arrival until its handler returns (v2 operations, sniffed handlers, remote-relay frames) and every `cmd` the connection's scheduler runs on another thread; one `slow_requests` entry each with its final duration (server-stats) and a `slow-request` debug-spans line. `wait-for` and other waits by design are counted in `expected_waits`, not recorded | `park` / `park_timeout`, no timer while idle. A request claims one of 256 slots with atomics; only the first request while disarmed unparks the thread, and a run that ends slow before a scan hands its end over through its slot. Armed, it wakes only on a 250 ms grid, records overruns and finished-slow runs, and disarms on a tick with nothing left to watch and no new request. An overrun still running is recorded with its thread's stack (p05-ipc-008: it stops that thread, `thread_suspend` on macOS, SIGURG on Linux, < 1 ms p95, nothing allocated while it is stopped; frame pointers are walked on macOS and in Linux builds with `-C force-frame-pointers=yes`, otherwise only the pc is kept, `stack_truncated`); a run first seen after it ended gets `run-ended`, no stack | utility (`cmux_threads::spawn`; a failed start is counted in `spawn_failures` and retried by the next arm) | as today | yes | 0 wakes at idle; at most 1 wake per 250 ms (4/s) plus one, under any request spacing; 128-entry ring; a request past 256 busy slots is counted as unwatched, never blocked; Linux captures run one at a time, each waits at most 50 ms for the signal's answer |
| `mux-maintenance` (one per process that uses it: the daemon and acpmux; p14-energy-020, crate cmux-wake `maintenance.rs`, `MaintenanceClock`, re-exported as `cmux_tui_core::wake`) | Periodic maintenance jobs registered with `register(JobSpec, job)` (acpmux, p14-energy-034: catalog refresh, harness health, upload sweep, each only a send to its one tokio adapter task), run one after another on a 5-minute wall-clock grid (each period rounded up to a multiple of 300 s), shifted by a per-install phase in whole 300 s steps (`Placement`; acpmux keeps a random one in its home, so installs spread their server checks across the period); a job also run at registration first runs on the grid at least half a period (and 300 s) later. Durability jobs (output store flush and snapshot, journal checkpoint, journal maintenance) are refused: they stay dirty-triggered one-shot `wake::deadline`s. Design in [idle-wakeups.md](idle-wakeups.md) section 9 | macOS: kqueue `EVFILT_TIMER` for the earliest due wall-clock instant (`NOTE_ABSOLUTE`, `NOTE_NSECONDS`, `NOTE_MACH_CONTINUOUS_TIME`, `NOTE_LEEWAY` with a 30 s leeway) plus `EVFILT_USER` for registrations, energy edges and stop; Linux: its command channel with a timeout to the due instant under a 30 s `PR_SET_TIMERSLACK`. Nothing registered: no timeout | utility (`cmux_threads::spawn`) | as today | yes | 0 wakes with nothing registered; otherwise at most one wake per 300 s boundary for all jobs; after a sleep each overdue job runs once, spread over one 30 s leeway; in Energy Saver a `skippable_in_saver` job runs at 4x its period. A job that blocks delays the jobs after it: long work goes to a `work` lane |
| `mux-acpmux-energy` (daemon, unix; p14-energy-034, cmux-tui-core `mux/acpmux_energy.rs`) | Writes the daemon's Energy Saver mode to acpmux as `_acpmux/energy` on the agent chat watch's connection: once as the watch connects, then once per `EnergyMode` edge (the edge watcher only queues a message) | Its channel (`recv`, no timeout); a socket write with a 3 s timeout | utility (`cmux_threads::spawn`) | as today | yes | 0 idle wakes; one line per connection and per edge |
| `mux-hang-watch` (holder, terminal host, acpmux; the daemon uses `mux-request-watchdog`, p10-stability-032; cmux-threads hang.rs `HangWatcher`, p02-threads-205; the holder watches each loop pass after `poll` at 100 ms and reports an overdue one to its daemon as a HANG frame, p02-threads-232) | Hang scopes in that process: each watched thread's deadline slot (512, then counted as unwatched), a 128-record ring and one call of the process's hang sink per overdue scope | Its `Condvar` (no timeout while parked), the slot-owner and ring locks for one record | utility | utility | yes | Opening a scope: a clock read, the slot's stores and the armed count, no lock and no system call; only a 0 -> 1 arm of a parked watcher takes the condvar lock to wake it. While scopes open it sleeps to the earliest open deadline, at most one minimum deadline; it parks after a wake with no scope open and none opened since. 0 idle wakes; 10,000 short scopes < 10 wakes |
| `debug-crash-inject` (daemon, cmux-tui-core `server/debug_crash_inject.rs`), `acpmux-debug-crash-inject` (acpmux, `debug_crash_inject.rs`); both only under `cfg(any(debug_assertions, feature = "bench"))`, p09-observability-101 | Running one injected crash (`debug-panic` / `_acpmux/debug_panic`: panic, abort or segv) for crash-matrix.py | Nothing | daemon: utility (`cmux_threads::spawn`); acpmux: not set (`std::thread::Builder`) | as today | daemon: yes; acpmux: no | One-shot per local request; it crashes at once: a panic ends the thread, abort and segv end the process |
| `cmux-trace-open` | Moving the trace ring into its file, then making the crash-key page beside it | Disk | not set | utility (task 229) | no | One-shot at process start |
| `cmux-memory-pressure` (Linux only, one per process that starts the kernel source: the daemon's `Mux::memory` on its first refill, acpmux; cmux-memory `pressure_linux.rs`, p07-memory-042. macOS uses one libdispatch source on the utility global queue, no thread) | The PSI triggers on `/proc/pressure/memory` and the kernel's vote in the memory registry; runs each level change's consumer delivery | `poll` on the two triggers and its stop pipe | utility | utility | yes | 0 idle wakes (no deadline with no pressure); under pressure one deadline, two trigger windows after the last event; ends when its watch drops or a trigger fails, and its vote is withdrawn |
| `mux-ws-out`, `mux-events-out` (cmd_subscribe.rs, websocket_listener.rs) | Writing to one WebSocket client; one event subscription's stream | Its socket (`write`); the event bus | user-initiated (`REQUEST_THREAD_QOS`, p02-threads-211) | as today; utility for automation clients (task 224) | yes | Event bus 4096 per subscriber, then disconnect |
| `mux-events-<generation>` (cmux-tui `app/mux_ingress.rs`) | The TUI front end's event stream | Its socket (`read`) | user-initiated (`cmux_threads::spawn`, p05-ipc-080) | as today | yes | One per connection generation |
| `holder-link` (cmux-holder `link.rs`; cmux-holder-v3 `link.rs`) | Routing each held terminal's output to its surface | The holder socket (holder: see below) | cmux-holder: user-interactive (`LINK_READER_QOS`, `ThreadType::InputCritical`, p04-input-060); cmux-holder-v3: not set | user-interactive (closed list): the echo of a held terminal waits on it; cmux-holder-v3 moves with task 218 | cmux-holder: yes; cmux-holder-v3: no | 1 MiB link queue, 512 KiB credit window |
| `browser-surface-<id>-worker`, `-events`, `-bootstrap`; `browser-host-*` | One browser surface's CDP traffic | Sockets to the browser host | not set | user-initiated (task 215); a one-shot CDP bootstrap is a `work` request wait (task 230); a provider bootstrap (`-bootstrap`, a loop that waits with no bound for the provider's target and retries until the surface dies) stays a thread | no | Per surface |
| `chief-*`, `mux-agent-*`, `acpmux-*` watchers, `machine-*`, `cmux-apps-*`, `cmux-app-server:<name>`, `cmux-app-host:<name>`, other named one-shots (`mux-url-open`, `mux-cloud-request`, `mux-launch-snapshot` and about 60 more) | Agents, machines, apps and one-shot requests | Sockets, child processes, disk | not set | loops: utility unless a person waits on them (tasks 213-218); one-shots: `work` items at the priority of the request they serve (task 230) | no | Per loop |
| tokio runtimes (acpmux, link, remote, cloud conversations, coderouter, server pairing) | Async I/O of that subsystem | Sockets on the runtime | not set, unnamed workers | named and registered through `cmux_threads::tokio::builder(name, qos)` (task 228); acpmux workers default, blocking pool utility, at most 16 | no | Per runtime |

### Daemon QoS by role (PL-qos, p05-ipc-080)

Every `mux-*` thread the daemon and the cmux-tui front end start has a class by its role, as Chromium gives
every thread a `ThreadType` (`base/threading/platform_thread.h`) and maps it once to a QoS class
(`ThreadTypeToQoSClass`, `base/threading/platform_thread_apple.mm`). Each starts through `cmux_threads::spawn`
(registered, declared class set before its body runs), so `ipc-census.py --queue Q8` does not list it. The journal
writer and the echo-path threads of task 150 are not in this table.

| Role | Class | Threads | Why |
|---|---|---|---|
| Request helper: one-shot, its request's reply waits on it | starts user-initiated (`request_qos::REQUEST_HELPER_QOS`, `RequestQos::spawn_helper`); with `daemonRequestQos` on it runs at its request's cause class (frontend user-initiated, automation utility, `WorkQos`) | `mux-resource-terminal-wait`. The other one-shot request helpers (agent CLI job, inventory, trust, transfer, update, attach, call and start, browser-runtime start, Chief control and inspect, Cloud request, URL open, loopback open) are `work` items at their request's priority (`Mux::post_request_wait`, p02-threads 230), not threads | A plain thread inherits its creator's class: from the person's reader that is user-interactive, from an automation reader utility. Chromium posts such work with the priority of the request it serves (`base/task/task_traits.h`) |
| Control streams and request-path workers | user-initiated (`ThreadType::Interactive`) | `mux-attach-notifications`, `mux-resource-browser-attach`, `mux-resource-sidebar-attach`, `mux-snapshot-attach-out`, `mux-resource-terminal-attach` (both wait for their attach to commit, so not the echo path, which disallows blocking), `mux-resource-session-events`, `mux-resource-conversation-events`, `mux-resource-session-journal`, `mux-acpmux-link` (requests wait in `call` for the replies it reads), `mux-deadline` (a request waits for the batch's deadline), `cmux-link-in`, `cmux-link-out` (terminal relay pumps; task 150 reviews them), `mux-remote-entry` (accept, `ACCEPT_THREAD_QOS`); front end: `mux-events-<generation>`, `surface-attach-<n>`, `mux-browser-input-<n>`, `mux-surface-operation`, `mux-graphics-writer` | A person waits on them, but no frame or key echo does (Chromium `kDefault`) |
| Bulk | utility | `mux-loopback-rd`, `mux-loopback-wr` (page bytes; through `spawn_raisable`), `mux-browser-runtime-out` (drains the browser host's stdout; takes no lock) | Below every request and key, as the app's `loopback_forward` writer |
| Watchers and program loops | utility through `cmux_tui_platform::qos::spawn_raisable` | `mux-history-feed`, `mux-agent-chat-notices`, `mux-agent-message-handover`, `mux-agent-message-prompt`, `mux-idle-close`, `mux-terminal-reap`, `mux-inventory-watch`, `mux-host-replica-changes`, `mux-host-replica-chief`, `mux-fs-stream-close`, `mux-launch-snapshot`, `mux-remote-events`, `mux-project-sources`; front end `dev-orphan-exit`, `idle-exit` | No person waits on them (Chromium `kUtility`) |
| Background | background | none started by name: the idle `work` workers (`mux-<lane>-idle`) only | Nothing ever waits |

A thread declared utility or background is raised to user-initiated while it waits for or holds a ranked lock
(`LockBoost`, the same raise a request lowered by a `WorkQos` gets), so a request never waits behind a watcher
holding the registry or a terminal lock. `spawn_raisable` starts the thread at default instead where the process
could not take utility back (Linux without root or an `RLIMIT_NICE` that allows nice 0): an unprivileged Linux
thread at nice 5 could never be raised. Where the creator cannot reach default either (a daemon started under
`nice -n 10`), it starts at the highest class at or below default the creator reaches (`cmux_threads::reachable`),
its own, so its start is never a refused change.

`mux-ws-server`, `mux-ws-conn` and `mux-ws-out` keep the classes of the rows above (accept and writer
user-initiated, the connection thread following its connection's class, task 224). The p05-ipc spec named
them utility; a WebSocket can carry the person (`CredentialMatch::Person`), so the connection class, not
the transport, sets their class.

No user-interactive daemon thread is added. The sequenced pool of task 073 starts its input and control
workers (`mux-seq-input`, `mux-seq-control`) at user-initiated, its bulk workers (`mux-seq-utility`) at utility
and its background workers (`mux-seq-background`) at background (`SequencePriority::qos`); its input workers run at user-interactive only through a row of the closed user-interactive list, with the
reason "IO thread every key passes" (Chromium's IO thread).

Holder (`cmux-holder`, its own process): one `poll` loop on its main thread; it forks the user's shell from that
thread. Waits on: `poll` (the PTYs and the daemon link). QoS today: not set. Target: user-interactive (closed
list) after task 223 makes the forked shell start at default (task 207). Bound: 1 MiB ring per terminal, 1 MiB
link queue, 512 KiB credit window; with the daemon attached the holder stops reading the PTY (the shell
blocks); with no daemon the ring keeps the newest bytes.

acpmux (its own process): tokio multi-thread runtime with `acpmux-socket-read` / `-write` bridges and
`acpmux-accept`. Waits on: socket I/O on its runtime. QoS today: not set. Target: task 218 (above). Bound: in 256
/ out 4096 per connection, a full outbox drops (`try_send`), oversized notices become `_acpmux/lagged`; hub
broadcast 8192 with `lagged {dropped}`. Owner PL-acpmux (cmux-4f).

Per-stream lanes (PL-conn, `pl-conn`) are not on feat-cmux-next yet; they get a row here when they land.

## Why the daemon keeps thread-per-connection

The daemon keeps one reader thread per connection and one writer per output stream; it does not move to one
reactor (epoll or kqueue) thread:

- The reader is the echo path of the app's UI connection. A thread of its own gets the QoS of its client (task
  224): the person's connection reads at user-interactive and an agent's at utility. In one reactor, every
  client shares one thread and one QoS, and a burst of automation would wait in front of a key.
- cmux differs from Chrome here on purpose. Chrome's browser process runs every renderer's Mojo channel on one
  IO thread (`BrowserThread::IO`, content/browser/browser_thread_impl.cc), a single message pump
  (base/message_loop/message_pump_kqueue.cc, message_pump_epoll.cc) that only reads and routes messages, and
  input passes through it too; the work runs on task runners by priority. That reactor works for Chrome because
  its IO thread runs no handler: it only routes, so no message waits behind another message's work. The daemon
  runs a request on the thread that read it (or on its scheduler's request thread), and the person's UI
  connection and an agent's CLI share one process. A thread per connection gives each client its own QoS
  without a second hop; a reactor would need Chrome's route-then-post split first.
- A blocking call on a reader stalls only that client, and the detector (`disallow_blocking`) names it. In a
  reactor, one blocking call stalls every client.
- The count is bounded: at most 64 connections (over: `server.busy`), and threads sleep in `read` (0 idle wakes).

Per-terminal threads must not grow. Today a terminal costs at most these threads:

| Mode | Threads per terminal | Names |
|---|---|---|
| Daemon PTY | 0 | None of its own: its output reads on the owner's `mux-terminal-io` loop and `mux-terminal-read` workers (p07-memory-095), 2 threads for any number of terminals at idle; its exit on `mux-reaper` (task 237) |
| Terminal host (daemon side) | 2 | `surface-<id>-host`, `surface-<id>-host-frames` (its exit: `mux-reaper`) |
| Terminal host (host process, one per terminal) | 4 echo threads plus about 6 lifecycle threads, and per client one `terminal-host-client-control` once it sends a frame that waits for the parser | `terminal-host-pty`, `-parser`, `-client`, `-client-input`, `-client-control` (a client's resize, default-color, cell-metric, Kitty-limit and clear-history commits wait for the parser, so they run there, in the client's frame order, never on the echo thread `-client-input`); `-child`, `-exit`, `-signals`, `-terminate`, `-clipboard`, `-record-mirror`, `-publication-sync` |

Task 230 turned the per-terminal one-shots (`terminal-adopt-<id>`, `template-complete-<id>`,
`terminal-exit-detach-<id>`, `terminal-clean-<id>`, `terminal-respawn-<id>`, `terminal-restart-<id>`,
`terminal-grid-hold`, `creating-input-expiry`) into `work` items, retries and delayed items: a start's adoptions wait
for ready with no thread, and at most 8 replay at once (`Mux::terminal_replays` permits, inside `will_block`).
Per-id threads kept on purpose, each a loop or a wait with no bound that would hold a `will_block` slot of the
System lane (64 per lane, `MAX_BLOCKED`) for as long as it lasts:

| Thread | Why it stays a thread |
|---|---|
| `terminal-unadoptable-<id>` | Waits with no timeout on the host's live-marker lease until an unadoptable host exits (as long as the host lives) |
| `browser-surface-<id>-bootstrap` (provider bootstrap only) | Waits with no bound for the provider to register its target, then retries until the surface dies |
| `mux-resource-terminal-wait` (one per `terminal.wait` / `terminal.wait_exit`) | A wait with no timeout when the request names none; up to 64 server-wide (`RESOURCE_WAITS_SERVER_CAPACITY`), as many as the System lane's `MAX_BLOCKED`, so as work items they could take every out-of-count slot. It becomes a terminal-state observer, not a work item |

Task 237 removed every per-child wait thread (one `mux-reaper` per process), so a daemon-PTY
terminal costs no thread of its own. A change that adds a thread per terminal, per tab or per
request needs a row here and a measured reason; a one-shot is a `work` item, not a thread.

## Process task roles and spawn QoS

Each cmux process states its Mach task role and the QoS its parent spawns it at; its launchd `ProcessType` is in
[Process roles](#process-roles-p02-threads-234). Chrome's model: `base::Process::SetPriority`
(`base/process/process_mac.cc`) sets the task role and `DARWIN_BG`; a child never inherits a display-critical
thread's QoS. Task 235 changes the task roles, tasks 207 and 223 the spawn QoS.

The app spawns its own children on a `ChildProcessLauncher` (task 037): "Spawn QoS today" names the launcher
priority, which sets the QoS of the spawning thread (how fast the spawn runs), and the clamp. The seam sets a
child's QoS only as that clamp (`posix_spawnattr_set_qos_class_np`, best effort and idle); Darwin does not
document that a child takes the spawning thread's QoS, so a user-initiated target for a cmux child is its own
task role (task 235), never the launcher's thread. Where the code and this table disagree, this table wins and
the code is the bug.

| Process | Started by | Task role today | Target task role | Spawn QoS today | Target spawn QoS |
|---|---|---|---|---|---|
| App (cmux-next) | LaunchServices | foreground app (AppKit) | same | n/a | n/a |
| Daemon (`cmux server`, owner session) | the app (`cmux server ensure`, detached), or launchd | not set | `TASK_FOREGROUND_APPLICATION` (`set_default_role`, task 235) | the app's caller thread (`ProcessRunner`) | user-initiated (task 207) |
| Holder (`cmux-holder`) | the daemon | not set | `TASK_FOREGROUND_APPLICATION` (task 235) | the daemon's thread | user-initiated; its own main user-interactive after task 223 (task 207) |
| Terminal host (one per terminal) | the daemon (`cmux_process`) | not set | foreground; background-suppressed (`PRIO_DARWIN_BG`) while its workspace is hidden (tasks 235, 236) | the daemon's thread | user-initiated |
| acpmux | the app (`AcpmuxDaemonLauncher`, `posix_spawn`) | not set | foreground | user-blocking launcher, no clamp | user-initiated (its role, task 235) |
| Chromium host prototype | the app (`ChromiumHostLauncher`) | not set; an accessory app, so App Nap applies unless it holds an activity: `NSActivityUserInitiatedAllowingIdleSystemSleep` while cmux shows one of its pages, plus `NSActivityLatencyCritical` while cmux is the active app, none while cmux is hidden, or shows no page while another app is active (p14-energy-128, p01-process-222; host_page_activity.h; each change of level goes to the host log); its main thread (Chromium's UI thread) user-interactive | foreground; background while every page is hidden (Chrome `RenderProcessHostImpl::UpdateProcessPriority`) | user-blocking launcher, no clamp (`ChromiumHostLauncher.priority`; `posix_spawnattr_set_qos_class_np` is only a clamp and refuses user-interactive, so the host sets its own main thread's QoS) | user-initiated (task 235 Swift twin) |
| CEF helpers (renderer, GPU, utility) | Chromium | set by Chromium | set by Chromium | Chromium's | Chromium's |
| Daemon bridge (`cmux link dial`) | the app (`DaemonBridge`, `posix_spawn`) | not set | foreground | user-blocking launcher, no clamp | user-initiated (task 207) |
| Link agent `com.cmuxterm.link` (`cmux link serve`) | launchd | not set | foreground (its launchd job is `Interactive`; task 235) | launchd | launchd |
| Remote host (`cmux host serve`) | launchd | not set | foreground (its launchd job is `Interactive`; task 235) | launchd | launchd |
| Server helper `com.cmux.server.helper` | launchd (`SMAppService.daemon`) | not set | as today (launchd's default) | launchd | launchd |
| Computer Use helper v2 | the app (`ComputerUseHelperV2Spawner`, responsibility disclaimed) | not set | foreground | user-blocking launcher, no clamp | user-initiated |
| Agent pane shell commands (`!` in the composer, `AgentPaneShell`) | the app | inherited | inherited | user-visible launcher, no clamp | default, never an echo thread's |
| Shell-mode completion (Tab, `CompletionProcess`) | the app | inherited | inherited | user-blocking launcher, no clamp: the person waits for the list | as today |
| Crash watcher (`CrashWatcher`, `/bin/zsh` that runs `sample`) | the app, at launch | inherited | inherited | best-effort launcher, clamped to utility (with `sample`) | as today |
| User shells and agents | the daemon, the holder or a terminal host | inherited | inherited | the spawning thread's (an echo thread: user-interactive) | default, never an echo thread's (task 223) |
| Helper commands (git, `ss`/`netstat`, hooks, plugins) | the daemon or the app | inherited | inherited | the spawning thread's | utility (`cmux_threads::process::spawn_qos`, task 223); app: `WorkPriority.processQoS` |

Main-thread work has one more rule than "never block": every task that is not the synchronous change in the input's
own turn is posted with a class and an owner (`mainWork.post`, `node.queue(_:owner:on:).post`,
`work.run(...).reply(on:class:owner:)`, a `MainDeadline`; `postIdle` and `MainDelivery(class:owner:)` once p06 tasks
005 and 217 land). A raw hop (`DispatchQueue.main.async`, `Task { @MainActor`, a main-inherited `Task {`,
`MainActor.run`, `CFRunLoopPerformBlock`) is an unattributed job that the scheduler cannot order behind the
person's input. `p06_queue.py` counts them (queues Q1, Q1b, Q1c, Q7); the hook's `main-async` rule refuses a new
`DispatchQueue.main.async`, and its `main-hop` rule (task 014, landed) refuses the rest. The classes, the posting forms and the
recipes are in [main-thread-budget.md](main-thread-budget.md).

cmux pages (chrome-parity p13-webui) add no thread or queue: every page deadline is a `MainDeadline` on the one
main wake-up queue, with no polling and at most one armed entry per owner. `webui.lifecycle` (`PageLifecycle`,
background class): the next planner pass over hidden pages only, armed for the earliest freeze or discard, none
with no hidden page. `webui.preload.refit` (`PagePreloadSlot`, background): the one quiet deadline after a size
change of the parked page; each later refit pushes it back. `webui.preload.cover` (`PagePreloadSlot`, visible):
the limit of a claim's cover when the page shows no live frame. `NewTabPreload.warm` and `NewTabPreload.fit`
(background): the New Tab preload after quiet input and its follow of the pane's size. Chromium's spare windows
are built in `ChromiumWarmup`'s idle task (`MainWorkScheduler.postIdle`, 500 ms `maxDelay`), never in a key's turn.

In the daemon (p06 tasks 030, 034 and 035, spec'd), a request's cause (`EventCause`: frontend, program,
automation; from `RequestOrigin`) decides lock admission and QoS: automation yields the state and registry locks
to a waiting frontend caller and is admitted at least every 4 ms; lock takers stay USER_INITIATED, and automation
work outside the locks runs at UTILITY with a boost while it holds a lock. The cause is for scheduling only;
authorization never reads it.

## QoS and task priority (PL-qos, 2026-10-24)
One priority model. Main thread: MainWorkClass (PL-main). Off main: WorkPriority, derived from it (CmuxNextWakeups).

| WorkPriority | from MainWorkClass | GCD QoS | Swift TaskPriority | Use |
|---|---|---|---|---|
| userBlocking | input, frame | userInitiated | high | a person waits now: the result of a key, click or open; omnibar DNS |
| userVisible | visible | userInitiated | medium | shows on screen soon: icon, thumbnail, a file a page shows |
| bestEffort | automation, background | utility | utility | saves, agent/CLI/MCP work off main, gh/git polls |
| idle (opt-in) | none | background | background | nothing ever waits: indexing, telemetry upload, prefetch, cache cleanup. Never the journal, quit work, or anything a UI path awaits later |

The GCD QoS column follows Chrome (p02-threads-115): its thread pool runs user-blocking and user-visible tasks on
one foreground group of `ThreadType::kDefault` threads, and `ThreadTypeToQoSClass`
(`base/threading/platform_thread_apple.mm`) maps `kDefault` to user-initiated, so userVisible runs at
user-initiated; the lanes' order and the reserved slot, not the QoS, put
userBlocking first. Chrome's best-effort group runs at `kBackground` (background QoS); cmux keeps bestEffort at
utility because it carries saves, the journal and block-shutdown work quit waits for, which background QoS would
disk-throttle and move to efficiency cores. Work that may wait without limit uses idle, at Chrome's best-effort QoS.
The mapping is for threads only: a userVisible child process (`processQoS`, a `ChildProcessLauncher` spawn at
`MayBlockPriority.qos`) stays at default, as Chrome sets a child's priority from what it shows
(`RenderProcessHostImpl::UpdateProcessPriority`), not from its thread pool; so do the bulk `loopback_forward` writer
and the agent pane shell commands (the process table above).

userInteractive: only the threads and queues of the [closed user-interactive list](#closed-user-interactive-list):
the main thread, the frame and deadline threads, and the key echo path (the daemon reader thread and `SocketWriter`
`com.cmuxterm.next.daemon.write` of the key-carrying connection only, role `terminal_attach`; every other connection's
reader and writer, `control` included, run below it; LocalPTY read and write queues; p02-threads-030, p04-input-059,
tests SocketWriterQoSTests, LineTransportTests and LocalPTYQoSTests). Most typed keys go on `terminal_attach`
(`TerminalAttachment.enqueueInput`); two key paths still go on `control` and run at user-initiated: `send {terminal_id}`
from `CreatingTerminalInput` before a new split's attach target is known (until p04-input-058 buffers it until attach),
and `send-key` for a TUI's Command chords from `TerminalHooks`. No BackgroundWork lane, process queue or child process runs at it.

Blocking work never runs on the cooperative pool: a process wait uses AsyncProcess (no thread waits); file I/O uses lane
.files (4/3/2/1 by priority; ordered writes through a `WorkSequence`); a sync system call (getaddrinfo, Security, Launch Services, AX, window lists) uses lane
.system (6 at once, the width of Chrome's DNS pool kDefaultMaxSystemTasks; 1 slot reserved for uncapped userBlocking
items, as Chrome's PrioritizedDispatcher reserved slots, counting every busy slot; host resolution through
`runHostResolution` capped at 4, cmux's own cap since DNS shares the lane); long CPU work uses lane .cpu (P-cores
minus 1). ShutdownBehavior: skipOnShutdown (default), continueOnShutdown, blockShutdown (quit awaits BackgroundWork.shutdown()).

Donating waits (allowed for a short main-thread wait): os_unfair_lock, OSAllocatedUnfairLock, CmuxNextCompat.Mutex,
dispatch_sync onto a serial queue (GCD sync QoS override), awaiting a Task value (Swift escalation), BackgroundWork.run
(boost at the call; macOS 26+ also on a later escalation). Non-donating (never on a hot main-thread path):
DispatchSemaphore.wait, DispatchGroup.wait, NSCondition.wait, Rust std mpsc/Condvar waits. BackgroundWork has no
synchronous wait.

Guardrail `task-priority` (pre-push; the full list is PATTERNS.md P14): only CmuxNextWakeups may use Task.detached
(with priority:) or DispatchQueue.global (with qos:); other code uses `work.task(priority) { }`, `work.run` or a plain
Task { }, which is not counted. DispatchQueue(label:) names qos: or target:. A Thread (or Thread subclass) and an
OperationQueue set `.name` and `.qualityOfService` on their own variable, at a level that is not .userInteractive,
.background or .default; Thread.detachNewThread and `delegateQueue: nil` are refused. Escape `// qos-allow: <why>`.
Guardrail `pool-blocking` refuses a blocking call (PL-blocking's BLOCKING_* list) on a shared pool thread.

Daemon: `cmux_threads::ThreadQos` is one table for every daemon thread (Chromium's ThreadType,
`base/threading/platform_thread_apple.mm`): UserInteractive = the echo path (closed list), UserInitiated = request
dispatch a person waits on and `work` foreground workers, Default = only a child shell or agent at its fork,
Utility = automation, watchers and best-effort workers, Background = idle workers. Linux uses nice 0/0/0/5/10.
A thread's role is a `ThreadType` (`cmux-tui-core/src/thread_qos.rs`, p04-input-060): InputCritical (the key and
echo path), Interactive, UnclassifiedClient (a client not classed yet), Utility, Background. `ThreadType::qos` is the
one map from a role to a `ThreadQos`; `ECHO_PATH_QOS`, `REQUEST_THREAD_QOS` and `CONNECTION_READER_QOS` come from it.
cmux-holder's `link::LINK_READER_QOS` is set outside the map (cmux-holder does not depend on cmux-tui-core), and
`thread_qos_tests.rs` keeps it equal to `ThreadType::InputCritical.qos()`. A thread that does not start through `cmux_threads::spawn` calls `thread_qos::set` as the first statement of its body.
Registered today: the echo threads, the connection readers, the accept loops (`mux-server`, `mux-ws-server`), the
request threads (`mux-seq-input`, `mux-seq-control`, `mux-ws-conn`, blocking disallowed), the writers
`mux-ws-out` and `mux-events-out` (all user-initiated, p02-threads-211), the `work` workers and the request
watchdog, the `mux-terminal-work` workers (user-initiated), and the journal and storage threads, `mux-output-store-writer` and `journal-hook-stdin` included (p02-threads-212); [Daemon threads](#daemon-threads-cmux-tui) gives every other thread its target. The journal writer
runs at user-initiated while a request waits for one of its receipts or for lane space and, with `daemonRequestQos`
on, at utility otherwise; the output store writer, maintenance and retention run each pass at utility the same way,
so a lock they hold raises them (the registry lock's owner boost is task 226).

Request classes (p06-scheduler-035, `cmux_tui_platform::qos`, `crate::request_qos`; behind the default-off daemon
feature `daemonRequestQos`): a request runs at the class of its cause. A verified-app request runs at userInitiated, an
automation request (CLI, script, agent, page, remote, or an app line whose `origin` claim narrows it) at utility, on the
`mux-conn` reader, a `mux-seq-control` pool worker, a clear-history `work` item, a creation job and
commit on the `mux-terminal-work` pool, the `cmux-script` and `mux-agent-start` work items, and the app and script
routers' calls; one `CauseScope` enters the cause and the class together, and the thread gets its own class back when
the request ends. A thread lowered to utility is raised to userInitiated before it waits for any ranked lock (registry,
connection, state, `pty.*`, leaf) and while it holds one (`HeldRank::acquire` takes the `LockBoost` before the wait; the
outermost hold raises, the last release lowers), so a lock that hands itself to a parked waiter never goes to a starved
utility thread, and neither a frontend request nor the PTY echo path waits behind one. The thread raises its own request
(`pthread_set_qos_class_self_np`, Chromium's `ScopedBoostPriority`), not an override:
`pthread_override_qos_class_start_np` is for raising another thread. A thread started during a request runs at its
creator's own class, not the request's: a registered thread (`cmux_threads::spawn`, `echo_thread::spawn`) sets its
declared class at start, and the unregistered ones (`surface-<id>-wait`, the agent message pump) start through
`spawn_outside_request`. On Linux, utility is nice 5 and is never entered when the process
could not take it back (no root and an `RLIMIT_NICE` that does not allow nice 0, asked once per thread): the request
then runs at the thread's own nice value, no refusal is counted, and nothing needs a raise.

Connection classes (p02-threads-224, server/connection_qos.rs; the same feature): a connection is classed when its hello
window closes (its origin is final then), again after each `set-client-info` and `client.metadata.update`, and when a
connection of its process proves itself the verified app. `person` is the verified app's connection and the app's other
connections without a hello (`terminal_attach`, `journal_read`, `agent_session_attach`, ...): its kernel peer key, fixed
at accept, is a verified app connection's (as `origin.confirmation.issue` pairs a page relay with its app). Every other
origin, the app's page relays, a `remote: true` lane and a link peer are `automation`; a `kind` label never raises a
connection. A person's reader (`mux-conn`, `mux-ws-conn`) rests at user-interactive (it reads the person's keys) and its
dispatcher and clear workers at user-initiated; an automation connection's threads rest at utility; a connection not
classed yet at user-initiated. Each thread reads the class at one point of its loop, before a line or a request, and
enters it as a `WorkQos`, so a request's class nests inside it and a resting utility thread is raised for a ranked lock.
The thread's registry row shows it as `desired` and `effective`; `spawn_outside_request` starts a thread at its
creator's declared class, never the class it rests at. The connection's writer keeps the echo class: a backpressured
producer must never wait behind a utility writer. A `cmux.protocol/2` request's optional `priority` (`user` |
`automation`, `request-priority-v1`) narrows its class inside the connection's like an `origin` claim and never raises it.

Blocking rule for the two "donating waits" above (lead decision 2026-10-24): a short `Mutex` critical
section on the main thread is allowed (a contended wait over 2 ms is recorded), but a `dispatch_sync` from the
main thread (`blockingSync`) is still reported: the QoS override bounds the inversion, yet the main thread
still waits for everything queued before it on that queue.

Reviewed lock site, remote view frame gate (`RemoteFrameGate`, CmuxNextRemoteView, p07-memory-085): one
`CmuxNextCompat.Mutex<Bool>` per started session of a remote desktop or remote browser pane. The decode
task takes it once per frame and holds it across `presenter.present`, which only posts to the presenter's
`LatestFrameMailbox` (its own `Mutex`, then at most one main-actor task spawn; never a wait). The main
thread takes it in `close()` when the tab hides or closes, and waits at most for that one post. Lock order
is gate, then mailbox; nothing takes them the other way. The lock is what makes "after `pause()` returns,
no frame of that session reaches the presenter" hold, as Chrome's `RenderWidgetHostImpl::WasHidden`
(content/browser/renderer_host/render_widget_host_impl.cc) stops a hidden widget's frames before it returns;
an atomic flag alone would let a frame that passed the check before the close be presented after it.

## Process roles (p02-threads-234)

Every cmux process, its launchd `ProcessType` and whether a person's input passes through it. Rule: no
process on the input path runs as `Background`. launchd.plist(5): `Background` puts the job under darwinbg
(low CPU priority, throttled I/O and network); `Standard` keeps launchd's daemon limits; `Interactive` gets an
app's limits (none); `Adaptive` is `Background` except while an XPC message is in flight. cmux processes talk
over Unix sockets and QUIC, not XPC, so `Adaptive` would leave them at `Background`: a launchd job on the
input path is `Interactive`. This is Chrome's model: a process the person uses is never lowered, only a hidden
renderer drops below the browser (base/process/process_mac.cc `Process::SetPriority`, from
content/browser/renderer_host/render_process_host_impl.cc `UpdateProcessPriority`). The Rust table is
`cmux_server_core::units::LaunchdJob`; each plist generator reads it and has a test that asserts its value.
launchd reads a plist only at bootstrap, so each installer also upgrades a plist an older cmux wrote: the
remote host's `service::restart` sets the role before its bootstrap, and `cmux host serve` and `cmux link
serve` set it at start (it applies from the next bootstrap: a restart, `install-agent` or login); acpmux's
`host update` sets it with `plutil` before its bootstrap; the server agents are rewritten by their install
(`write_if_changed`, then bootout and bootstrap) and the app's bundled agent ships in the bundle. A chatmux
relay plist an older relay wrote gets the role at its next `cmux-relay --autostart`.

| Process | Started by | launchd ProcessType | Input path |
|---|---|---|---|
| App (`cmux.app`, CmuxNext) | Launch Services | none (an app; the system's app policy) | yes: every key and click |
| Daemon `cmux host run`: `com.cmux.server` agent and daemon (cmux-server-core `launch_agent_plist`, `launch_daemon_plist`), the app's `<bundle id>.server` (`app_service_agent_plist`, stamped by scripts/cmux-next/bundle-server-helper.sh, registered by ServerLaunchAgent.swift) | launchd | `Interactive` (was `Standard`) | yes: every terminal key and frame |
| Link `cmux link serve` (`com.cmuxterm.link`, cmux-tui link/launchd.rs) | launchd | `Interactive` (was `Background`) | yes: a paired peer's session streams |
| Remote host `cmux host serve` (`com.cmuxterm.host-remote`, cmux-tui remote_host/service.rs) | launchd | `Interactive` (was `Background`) | yes: a remote client's keys |
| Holder (`cmux-holder`) | the daemon | none: runs in the daemon's launchd job | yes: PTY bytes |
| acpmux daemon `acpmux daemon run` on a host set up by `acpmux hosts` (`com.acpmux.daemon`, acpmux cli/hosts.rs `launchd_plist`) | launchd | `Interactive` (was none, launchd's default limits) | yes: agent sessions a person prompts and watches |
| acpmux started on demand (`cmux acp`, `acpmux daemon start`) | the app, the daemon or an agent CLI | none: runs in its parent's job | agent sessions a person watches |
| acpmux session harness (Claude, Codex) | the acpmux daemon | none: runs in the acpmux daemon's job | the agent's output a person watches |
| chatmux relay `cmux-relay` (`com.chatmux.relay`, chatmux-relay autostart.rs `launchd_plist`) | launchd (`--autostart`) | `Interactive` (was none, launchd's default limits) | yes: a paired chat client's terminal keys |
| Chromium helpers and the out-of-process browser host | the app | none: run in the app's job | yes: page input |
| Other helpers (`cmux-server-helper`, CLI calls) | the app or a shell | none: run in the parent's job | short-lived |

A process with no launchd job of its own runs in its parent's. Mach task roles (`TASK_CATEGORY_POLICY`,
foreground or background per process) are task 235. On Linux the server, link and remote-host systemd units set
no CPU or I/O class, so those processes run at the default priority. acpmux puts each session harness in its
own `systemd-run --user --scope` with a lower `CPUWeight` (default 50, systemd's own is 100;
`ACPMUX_SESSION_CPU_WEIGHT`, 0 turns it off) and a `MemoryMax` (acpmux session_scope.rs), so a busy agent
session yields the CPU to the rest of the machine.

## Renderer QoS (rendering-DESIGN R5)

Threads that produce frames, by state. Chrome sets the QoS of a thread from its thread type
(`base/threading/platform_thread_apple.mm`). Chrome lowers a hidden renderer through its process priority:
`RenderProcessHostImpl::UpdateProcessPriority` (`content/browser/renderer_host/render_process_host_impl.cc`) calls
`base::Process::SetPriority` (`base/process/process_mac.cc`: task role and `DARWIN_BG`). cmux follows the same split:
what a person sees gets the frame priority, hidden producers get utility and draw nothing.

| Producer | Visible and focused | Visible, not focused | Hidden or occluded | Source and status |
|---|---|---|---|---|
| Main thread (AppKit, CA commit) | user-interactive | user-interactive | user-interactive (no frame work: R6) | system |
| VSyncHub (one per display) | user-interactive | user-interactive | paused link, no wake | p03-rendering-014, feature `vsyncHub` (off) |
| Ghostty renderer (one per surface) | user-interactive | user-initiated | utility; no frame drawn, no wake: output parses and marks rows dirty only (no renderer wake, no `reset_cursor_blink` message), the cursor blink timer stops at its next tick, the scrollback-compression recheck runs at most once a second (Chromium's throttled wake-up interval for hidden pages, `third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc`); shown again, the `.visible` message rebuilds, draws and restarts the blink | ghostty-next `src/renderer/Thread.zig` `setQosClass`, `blinkTick`, `blinkRearms`, `blinkChange`, `Compression.idleInterval`; `src/termio/Termio.zig` `processOutputLocked`. Counted by `ghostty_surface_render_counters` `thread_wakes` / `hidden_thread_wakes` (p03-rendering-088, ghostty-next branch `cp/p03-rendering-088`; in the app with the pin bump of p03-rendering-079). Measure: `bench_idle.py --scenarios hidden-printing` (10 hidden printing terminals), CPU lower than the pin before it |
| Ghostty IO (one per surface) | not set (GhosttyKit default) | not set | not set | removed for manual-IO surfaces by p03-rendering-086 |
| Remote view render `cmux.remote-view.render` | user-interactive | user-interactive | user-interactive (no change by state yet; p03-rendering-114) | `MetalYUVRenderer` queue |
| Chromium GPU, compositor and renderer threads | set by Chromium from the thread type | set by Chromium | Chromium lowers a renderer only when it knows the page is hidden: visibility from the embedder, p03-rendering-058 | Chromium: thread QoS from the thread type (`base/threading/platform_thread_apple.mm`); hidden renderer priority from `RenderProcessHostImpl::UpdateProcessPriority` (`content/browser/renderer_host/render_process_host_impl.cc`) and `base::Process::SetPriority` (`base/process/process_mac.cc`) |

## Registered threads and queues

A new thread or queue in `Packages/macOS/CmuxNext/Sources` needs its label here (the `thread-doc` guardrail
matches the label's literal text; `<x>` matches an interpolation). Labels from other packages linked into the app
(`com.cmuxterm.home.cache`, `cmux.screen.capture`) are listed too; the guardrail does not scan them. Each label
has an owner row in [Threads and queues](#threads-and-queues) (grouped rows name several) with what it waits on,
its QoS and its target.
The parentheses after each label start with its declared QoS (chrome-parity p02-threads section C's tiers), and
with OperationQueue for an OperationQueue name (Foundation labels the queue an operation runs on with the name,
a space and the operation). `per-item` marks a queue whose every item, run or caller states the QoS (a lane slot,
a process run, a child launcher): it runs at any tier below user-interactive. A library's own threads are in a
`Library` bullet: `by-visibility` gives the QoS while the surface is focused, visible and hidden, and
`set-by-library` says the library picks each thread's QoS from its own table.
`ThreadRegistry.app` (CmuxNextCompat) holds the same rows, `debug.threads` compares each live thread's requested
QoS with them, and ThreadsControlTests fails when a label or QoS here and there differ.

- Main and frame: `cmux-next main-thread watchdog` (user-interactive), `cmux-next quit deadline` (user-interactive),
  `cmux-next crash deadline` (user-interactive), `cmux-next vsync <display>` (user-interactive; VSyncHub)
- Lanes and processes (CmuxNextWakeups): `com.cmuxterm.next.work.<lane>.<slot>` (per-item), files
  `com.cmuxterm.next.work.files.<priority>.<slot>` (per-item; BackgroundWork slot queues, the
  item's QoS), `com.cmuxterm.next.process.<name>` (per-item; ProcessRun, the run's QoS), ProcessLauncher queues
  `com.cmuxterm.next.sleepy-lock` (user-initiated), `com.cmuxterm.next.now-playing` (default),
  `com.cmuxterm.next.android-screen` (default), `com.cmuxterm.next.relaunch` (user-initiated),
  `com.cmuxterm.next.find-in-directory` (user-initiated; Find in Directory's `rg`),
  `com.cmuxterm.next.diff-sidecar` (default; one diff sidecar child per request),
  `com.cmuxterm.next.daemon.process` (per-item; ProcessRunner, one per run, the caller's QoS; p02-threads-040)
- Child launchers (CmuxNextCompat `ChildProcessLauncher`, every raw `posix_spawn`, the launcher priority's QoS):
  `com.cmuxterm.next.child-launcher.<owner>` (per-item; `daemon-bridge`, `chromium-host`, `acpmux`,
  `computer-use-helper`, `shell-complete`, `agent-shell`, `crash-watcher`)
- Daemon: `cmux-tui reader <path>` (user-interactive), `com.cmuxterm.next.daemon.write` (user-interactive),
  `com.cmuxterm.next.daemon.bridge-dial` (user-initiated, concurrent; a new bridge's dial line),
  `com.cmuxterm.next.daemon.bridge-reap` (utility; one per `DaemonBridge`, the killed bridge children's exit
  sources, `ChildExitWatch`; p02-threads-128), `com.cmuxterm.next.daemon.path.<machine>` (utility),
  `com.cmuxterm.next.daemon.exit.<pid>` (user-initiated; the reconnect waits on the old daemon's exit before it
  starts the next one), `com.cmuxterm.next.retry-wake` (user-initiated; its socket-folder watch wakes the
  reconnect while terminals are disconnected), `com.cmuxterm.next.process-progress` (utility)
- Control: `com.cmuxterm.next.control.accept` (utility), `com.cmuxterm.next.control.<id>` (utility)
- Terminal: `com.cmuxterm.next.terminal.output` (user-interactive), `com.cmuxterm.next.terminal.attach-input`
  (user-interactive, one per daemon terminal view; the session's input lane drains on it and the attach socket's
  writer targets it, p04-input-058), `com.cmuxterm.next.terminal.input-await` (user-initiated, one per session
  whose IO has no input drain of its own: demos and tests), `com.cmuxterm.next.localpty.read` (user-interactive),
  `com.cmuxterm.next.localpty.write` (user-interactive),
  `com.cmuxterm.next.terminal.link-check` (user-initiated, concurrent, one per surface; `TerminalLinkFilter`'s file check of a
  Cmd-hovered text: a check stalled on a slow volume holds no later check; a concurrent queue targets GCD's width-limited
  root queue, so stalled checks park no more threads than the unnamed root queue did)
- Settings and files: `com.cmuxterm.next.settings.watcher` (utility),
  `cmux.files.fsevents` (utility: a watcher; FolderWatchStream still asks user-initiated, which `debug.threads`
  reports as a mismatch), `cmux.files.tree-fsevents` (utility),
  `com.cmuxterm.home.cache` (user-initiated; the `HomeCache` actor's executor: its file writes block this queue,
  never a pool thread, so the forced quit's last draft write runs with the pool full; CmuxHomeCore, shared with iOS)
- Energy: `com.cmuxterm.next.energy.power-source` (utility; PowerSourceMonitor in CmuxNextEnergy: the notify
  power-source and charge notifications and one IOKit snapshot each; it hops to main only on a new edge)
- Remote and mobile: `com.cmuxterm.next.remote-localhost` (user-initiated),
  `com.cmuxterm.next.cloud-browser-proxy` (user-initiated),
  `com.cmuxterm.next.remote-fetch` (user-initiated; favicons, remote images and agent fetches the person sees),
  `cmux.remote-view.render` (user-interactive; closed list: the remote view's compositor-class motion path,
  Chrome's `kDisplayCritical`; `MetalYUVRenderer`'s serial queue, made with `DispatchQueue.checkedSerial`),
  `cmux.remote-view.rd-transport` (user-initiated; the visible session's input and frames, below the render queue),
  `cmux.remote-view.mock-host` (user-initiated; the Debug host stand-in), `cmux.next.mobile.unix-lane` (user-initiated),
  `com.cmuxterm.next.phone-process.stdin` (per-item; the caller's QoS: a phone tool's stdin DispatchIO channel,
  whose completions only close it, so a large `simctl pbcopy` never holds a thread),
  `cmux.screen.capture` (user-initiated; CmuxVNCWebRTC, p02-threads-146),
  `cmux.vnc.peer-close` (user-initiated, one per `VNCPeerLink`; libwebrtc's close waits there for its signaling
  thread, never on the caller's main, pool or callback thread; CmuxVNCWebRTC), `cmux.vnc.demo-server` (utility; the loopback RFB
  fixture of CmuxVNCDemoServer), `cmux.screen.perf-log` (utility; CmuxScreenKit's opt-in timing log file, opened and
  appended to off the main actor),
  `cmux.home.media-decode` (user-initiated; CmuxHomeRender's attachment thumbnail reads and decodes),
  `cmux.mobile.image-attachment` (user-initiated; CmuxMobileShellModel's attachment downsampling),
  `com.cmux.composer.dictation-audio` (user-initiated; CmuxMobileSupport's dictation audio engine)
- Browser: `com.cmuxterm.next.browser-host.provider.write` (user-initiated),
  `cmux browser-host provider reader` (user-initiated), `com.cmuxterm.chromium-host.read` (user-initiated),
  `com.cmuxterm.chromium-host.write` (user-initiated; serial queue of the input wire's writable source: armed only
  while a full socket holds frames in the input outbox, it flushes them with one non-blocking write per fire and never waits),
  `com.cmuxterm.chromium-host.control` (user-initiated; the control channel's reader in cmux and, same label, in the host;
  waits only in `poll`: input, the socket taking a waiting outbox, a wake byte, the quota ceiling's one deadline),
  `com.cmuxterm.chromium-host.exit` (user-initiated; serial queue for the host's exit source: a crash shows on the page),
  `com.cmuxterm.chromium-host.supervisor` (utility; serial queue of host mode's one Chromium Host's exit source, kqueue
  `NOTE_EXIT` then `waitid(WNOWAIT)`, `ChromiumHostSupervisor`, p01-process-080; its spawn runs on BackgroundWork's `.system` lane),
  `com.cmuxterm.chromium-host.input` (user-interactive; in the host process, fixed: a thread waiting in a plain
  kqueue gets no QoS override from the doorbell's message; the input ring's reader, `HostInput` in
  chromium_host_input_ring.h, p01-process-041, started by the host with task 042: waits only in `kevent64` on the
  Mach doorbell cmux rings when it is parked; one batch at a time waits for the UI thread, so it never grows: a full
  ring makes cmux keep the rest in its writer's backlog, where keys and clicks always wait and only moves and wheel
  ticks are bounded; a reader that ends without Stop (a broken ring, a failed kqueue) ends the host),
  `com.cmuxterm.chromium-host.hang-watcher` (utility; in the host process: the UI thread's hang watcher,
  host_hang_watcher.h, p01-process-084; parks with no deadline while no run loop turn is open, sleeps until an open
  turn is 10 s old, then writes one dump without crashing and parks until the next turn; the UI thread wakes it only
  from a park, at most once per park),
  `com.cmuxterm.app.next.cef-children` (user-initiated; it must add NOTE_EXIT on a new helper before Chromium
  reaps it), `com.cmuxterm.import-history-sync` (utility; a watcher),
  `com.cmuxterm.chromium-runtime.download` (OperationQueue, utility, serial; the runtime download's URLSession
  delegate queue), `cmux-next webkit setup probe` (utility; WebKitSetupGate's one sandbox-extension request),
  `com.cmuxterm.next.browser.certificate-probe` (OperationQueue, user-initiated, serial, one per probe; the TLS
  probe's URLSession delegate queue: the page load waits on it)
- Agents: `com.cmuxterm.app.next.agent-pane.prompt-journal` (utility),
  `com.cmuxterm.app.next.agent-pane.inbound` (user-initiated),
  `cmux.next.agent-pane.acpmux-exit.<pid>` (user-initiated; the version handoff waits on the old daemon's exit),
  `cmux.next.agent-pane.acpmux-log-progress` (utility; a log watcher),
  `cmux.next.agent-pane.acpmux-launch-reap.<pid>` (user-initiated; the launch waits on the shell's exit, `ChildExitWatch`),
  `cmux.next.agent-pane.acpmux-status` (user-initiated; the pane's connect waits on it),
  `cmux.acpmux.checked-line` (user-initiated; approvals: the person proof is made and sent on it, no caller waits for it),
  `cmux.next.agent-pane.acpmux-host` (user-initiated; the `AcpmuxHost` actor's executor: its LocalApp token and
  `daemon.pid` reads and the daemon home's creation block this queue, never a pool thread; the launch shell spawns on
  `com.cmuxterm.next.child-launcher.acpmux`),
  `cmux.agent-activity.socket` (utility), `com.cmuxterm.app.next.chief-settle` (utility; a watcher),
  `com.cmuxterm.app.next.tasks.socket` (user-initiated),
  `com.cmuxterm.app.next.tasks.directory` (utility; the Tasks socket directory's vnode source while the owner is away, `SocketTasksSource`),
  `com.cmuxterm.app.next.agent-pane.socket` (OperationQueue, user-initiated, serial; the agent pane's URLSession
  delegate queue),
  `com.cmuxterm.next.computer-use.helper-reap` (utility; the helper's exit source, `ChildExitWatch`),
  `cua-helper-v2-stdout` (utility),
  `cmux.next.agent-pane.shell-reap.<pid>` (utility; a shell-mode command's exit source, `ChildExitWatch`),
  `cmux.next.agent-pane.shell-complete-reap.<pid>` (user-initiated; a Tab completion shell's exit source, the Tab
  waits on it). Each holds one process-exit source and runs one waitpid that returns at once; no thread waits
  while the child runs (p02-threads-120, p02-threads-128)
- Diagnostics: `cmux-next.hang-episodes` (utility), `cmux-next.hang-episodes.symbols` (utility),
  `com.cmuxterm.app.next.run-marker` (utility), `com.cmuxterm.app.next.crash-forwarder` (utility),
  `com.cmuxterm.app.next.owner-panic-forwarder` (utility), `com.cmuxterm.next.typing-probe` (utility),
  `com.cmuxterm.app.next.invariant-sink` (utility; `InvariantSink`: one block per Invariant site per launch builds
  its Sentry event, debug images by dladdr, and captures it; the failing thread only enqueues, p10-stability-099),
  `com.cmuxterm.app.next.renderer-stability` (utility; `RendererStabilityReporter`: builds and captures one Sentry
  event per rate-limited renderer stability report, at most one per kind, engine and surface an hour; main only
  enqueues, p09-observability-108),
  `com.cmuxterm.app.next.sentry-recorder` (utility; DEBUG and bench builds with `CMUX_NEXT_SENTRY_RECORDER` only:
  `SentryRecorderTransport` writes one envelope file per Sentry event; the capturing thread only serializes, p09-observability-086),
  `com.cmuxterm.app.next.blocking-drain` (utility), `com.cmux.host-pressure` (utility),
  `debug.window_record` (user-initiated),
  `com.cmuxterm.app.next.hang-reports.store` (utility; the `HangReportStore` actor's executor: its small pending,
  outbox and send-log file reads and writes block this queue, never a pool thread),
  `com.cmuxterm.app.next.hang-reports.field-data` (utility; the `HangReportFieldSources` actor's executor, schema 3
  only: earlier launches' metrics files mapped and deleted, and the black-box ring files read, at most once per
  report and per hang or slow key frame; never a pool thread)
- Memory: `com.cmuxterm.app.next.memory.release-sink` (utility)
- Trace and hang watch (Rust thread names, p09-observability; the app adds no thread): `mux-hang-watch`,
  `cmux-trace-open`
- Daemon maintenance clock (Rust thread name, p14-energy-020): `mux-maintenance` (utility), one per process that
  starts a `MaintenanceClock` (the daemon; acpmux since p14-energy-034); it waits on kqueue (macOS) or its channel (Linux) with a 30 s kernel leeway, and with no
  timeout while nothing is registered.
- Daemon request watchdog (Rust thread name, p05-ipc-006): `mux-request-watchdog` (utility). The process's
  one hang watcher (p10-stability-032; no second watcher thread): it owns the scope slots of requests, journal
  writer commits, holder-link frames and the echo threads' items (p02-threads-232: each `mux-line-out` write,
  local `mux-pty-input` write and attach frame encode at 100 ms, never the wait for the next item); a holder's
  `holder-loop` hang arrives on its link and the link's reader only queues it (16 at most, more are dropped and counted): this thread writes it as one hang-log line. It wakes only when a scope opens on a disarmed watchdog and then on
  250 ms grid ticks (at most 4/s plus one, 0 while idle: it parks with no timeout). It blocks only on a stack
  capture of a scope past a tier (`thread_backtrace`, shares its capture mutex; under 1 ms), the
  `slow_requests` ring's short lock, and one append to `owner-hangs-<session>.jsonl` per hang (each scope is
  written once, at its 2 s or 1 s hang tier).
- Server helper (the root `cmux-server-helper` process): `com.cmuxterm.server-helper.files` (user-initiated;
  `FileFixPriorStore` reads and writes, one item per request), `com.cmuxterm.server-helper.fix` (utility; one
  short-lived thread per allowlisted fix that only spawns its child, `Process.runOnOwnThread`; p02-threads-040)
- Launch and misc: `cmux-next resource bundle warm-up` (user-initiated), `cmux-next launch warm-up` (user-interactive, `// qos-allow:`: main reads
  the action catalog it builds before the first frame; p08-startup-092), `cmux-next icon warm-up` (user-initiated; p08-startup-039),
  `cmux-next terminal prefetch` (user-initiated; one per launch with `terminalLaunchPrefetch` on: the Metal device
  and the terminal's fonts before the first surface, `TerminalLaunchPrefetch`, p08-startup-091),
  `cmux.updates.network` (utility), `com.cmuxterm.next.energy.wake-path` (utility; one `NWPathMonitor` per wake
  until its first satisfied path, `SuspendWatch`, p14-energy-120), `cmux.home.fixture.video` (utility; Debug fixture media),
  `cmux.home.promised-files` (OperationQueue, user-initiated; a drop's file promises: the person waits for the
  dropped files),
  `com.cmuxterm.next.workspace-open` (user-initiated, concurrent, one per call; `NSWorkspace` opens and reveals, the person
  waits for the app or the Finder window; concurrent so one slow LaunchServices call never holds the next and a burst
  parks no more threads than GCD's width-limited root queue allows; moving it onto the system lane through an injected
  `MayBlockRunner` is follow-up work: its callers across the packages take no runner today)
- URLSession delegate queues (`OperationQueue.sessionDelegate`, serial, p02-threads-120):
  `com.cmuxterm.next.cloud.app-server` (OperationQueue, user-initiated; a Cloud action the person started waits on it),
  `com.cmuxterm.next.cloud.owner-api` (OperationQueue, user-initiated; a Cloud action the person started waits on it),
  `com.cmuxterm.next.icon-assets.download` (OperationQueue, user-initiated; an icon the person asked for),
  `com.cmuxterm.next.cloud.install-auth` (OperationQueue, utility; install sign-in in the background),
  `com.cmuxterm.next.backdrop.import` (OperationQueue, utility; a long backdrop download written to disk)
- Library GhosttyKit (ghostty-next `src/renderer/Thread.zig` `setQosClass` and `src/termio/Thread.zig`, one of
  each per surface): `renderer` (by-visibility: user-interactive focused, user-initiated visible, utility hidden;
  the renderer sets it again on each focus and occlusion change), `io` (by-visibility: user-interactive focused,
  user-initiated visible, utility hidden; until p03-rendering-086 removes the thread from manual-IO surfaces it
  keeps the QoS it starts with, so the hidden run reports it), `cf_release` (set-by-library; one per surface,
  started by the CoreText shaper, src/os/cf_release_thread.zig, which sets no QoS), `search` (utility; one per
  find, src/terminal/search/Thread.zig sets it), `sentry-init` (set-by-library; src/crash/sentry.zig, once at
  init), `io-reader` (user-initiated; src/termio/Exec.zig, only in an exec-mode surface, which cmux does not start),
  `io-gather` (user-initiated; src/termio/Exec.zig, exec mode only, as io-reader). Each Ghostty thread names
  itself with pthread_setname_np from inside, and the names share no start, so these rows are every name
  ghostty-next sets (723c4ab93); a ghostty-next bump checks its pthread_setname_np calls against them.
- Library CEF (the in-process Chromium browser; Chromium sets each thread's QoS from its `ThreadType`,
  `base/threading/platform_thread_apple.mm`): `Chrome_<thread>` (set-by-library; the IO, DevTools and history
  threads), `ThreadPool<group>` (set-by-library; the foreground, utility and background workers and the service
  thread), `HangWatcher` (set-by-library), `MemoryInfra` (set-by-library), `NetworkConfigWatcher` (set-by-library),
  `CacheThread_BlockFile` (set-by-library), `StackSamplingProfiler` (set-by-library)
- Library WebKit (the `WKWebView` UI-process side; the web content and networking processes are not the app's
  threads): `com.apple.WebKit.<queue>` (set-by-library), `com.apple.IPC.<queue>` (set-by-library),
  `WebCore: <thread>` (set-by-library), `JavaScriptCore <thread>` (set-by-library; the libpas scavenger)
- Library Sentry (sentry-cocoa, CmuxNextCrashReporting): `SentryCrash Exception Handler <role>` (set-by-library;
  the Mach exception handler threads, idle until a crash), `io.sentry.<queue>` (set-by-library; the SDK's queues
  and its app-hang tracking thread)
- Library iroh (iroh-ffi's tokio runtime, CmuxIrohTransport): `async-compat/tokio-1` (set-by-library; uniffi's
  async runtime), `tokio-runtime-worker` (set-by-library; tokio's default worker and blocking-pool name)
- Library WebRTC (WebRTC.framework, CmuxScreenKit, `RTCPeerConnectionFactory`; WebRTC's Thread SetName(name, obj)
  in rtc_base/thread.cc appends " 0x%p" to the name the factory gives): `network_thread <ptr>` (set-by-library),
  `worker_thread <ptr>` (set-by-library), `signaling_thread <ptr>` (set-by-library)
- Every `Thread` and `OperationQueue` sets `name` and `qualityOfService` before it starts; every URLSession
  gets a named delegate queue. None is unnamed (`threading-inventory.py --rule thread-doc` = 0).

CCmuxAppFFI starts no thread on macOS: the remote desktop core, the layout reducer and the palette ranker run
on their caller's thread, and cmux-motion's reduce-motion watcher (cmux-motion-reduce) runs only on Linux and
Windows. A library thread the app sees with no row reads `declared: null` in `debug.threads`: name it here and in
`ThreadRegistry.app`. `debug.threads` counts the threads no row declares as `undeclared`, which always includes
the system's own (idle GCD workers, AppKit's event thread, CoreAudio); of those, `undeclared_cmux` has a cmux
name start and `undeclared_library` is in a linked library's name space (`ThreadRegistry.libraryNamespaces`,
wider than its rows: `Chrome` and `ThreadPool` for CEF; `com.apple.WebKit`, `com.apple.IPC`, `WebCore`,
`JavaScriptCore` and `WTF` for WebKit; `Sentry`, `io.sentry` and `sentry` for Sentry; `tokio` and `async-compat` for
iroh; names containing `_thread 0x` for WebRTC). The RUN-3 target, in STRESS with the window visible and hidden,
is 0 for `undeclared_cmux` plus `undeclared_library`.

Task 032 set the QoS of its group (retry-wake, process-progress, daemon exit and path, settings watcher, CEF
children, provider write, mobile unix-lane, agent-activity socket, updates network). Task 033 set the rest: the
remote-view transport and mock host, remote-fetch, import-history-sync, acpmux, chief-settle and fixture video
queues, each at the QoS listed above. Watchers run at utility; a queue that a visible pane or a waiting caller
needs runs at user-initiated. None goes to user-interactive.

## QoS audit (MQ-15, p02-threads-302)

`scripts/cmux-next/qos-audit.py` reads what runs and judges it against the thread parts of RUN-3 and RUN-4
(chrome-parity/p02-threads.md). Each finding is one task, `p02-threads-R-qos-<process>-<kind>-<thread>`, with
its evidence rows and the spawn sites that spell the name (`qos-tasks.json`). The id stays the same on a rerun.
Chrome keeps the same facts per thread (`ThreadType` to QoS in `base/threading/platform_thread_apple.mm`, thread
type and priority in chrome://tracing metadata).

- App: `qos-audit.py app --app "$NX_APP" --daemon-socket <socket>` (fleet GUI Mac, Debug or bench build)
  builds STRESS (perf-stress-session.py). It reads `debug.threads` and `debug.surfaces` with the window visible,
  then with the app hidden (`showHideAllWindows`), then shows the app again. It finds: `mismatch` (`match`
  false), `hidden-tier` (hidden phase: a Ghostty surface thread not at utility), `hidden-workspace-tier`,
  `undeclared-cmux`, `undeclared-library`, `interactive-outside-closed-list` (a cmux thread at user-interactive
  that the closed list above does not name), `queue-problem`, `undeclared-queue`, `queue-log-overflow` and
  `task-role`. `hidden-workspace-tier` is the visible phase's check of a hidden workspace in a shown window
  (STRESS has 59): Ghostty names its threads without the surface, so the audit counts. Each by-visibility row
  (renderer, io) may have at most as many threads above utility as surfaces draw (`debug.surfaces` `drawing`, the
  visibility `ghostty_surface_set_occlusion` gave). `--daemon-socket` also reads the app's daemon in both phases.
  There it judges the app's UI connection (`ui-connection`): the person's readers must rest at user-interactive
  and their request threads at user-initiated. `unseen` means no verified app connection was found.
- Daemon: `qos-audit.py daemon --bin <cmux-tui> --base-peak <base qos-peak.json>` starts a headless daemon with
  `daemonRequestQos` on and the blocking detector in record mode. It builds STRESS (60 workspaces, 14 panes of 2
  terminals in the measured one, 10 busy terminals) and runs perf-10x-lifecycle's op mix (bench-lifecycle.py's
  creates and closes, 3 warm-up and 40 rounds) on a second connection. During the rounds it reads
  `server-threads` and the process's OS threads by id (Linux `/proc/<pid>/task`, macOS `proc_pidinfo`). From the
  daemon's start to the last round, a thread of the script counts the daemon's OS threads every millisecond. The
  peak is the highest count, so the threads that live only during a create or a close count. Threads shorter
  than the interval can still be missed. The whole run repeats 3 times, each with a new daemon. The base binary
  gets the same runs with `--peak-only`. It finds: `unregistered` (an OS thread with no row; `main` is the first
  thread: the pid on Linux, the lowest thread id on macOS; `unnamed` is a thread that never set its name),
  `mismatch` (`matches` false), `automation-class` (an automation connection's reader or request thread not
  resting at utility), `interactive-outside-closed-list` and `peak-threads` (the head's highest peak not below the
  base's lowest). Run it at nice 0. A Linux daemon inherits the script's nice and cannot lower it again, so the
  script refuses to start under `nice -n`.
- Each connection thread's `server-threads` row names its connection (`connection`: client id, transport,
  origin, peer pid, class). The audit decides from those facts which connection is the person's: origin `user`,
  or `agent` from the verified app's process. It does not use the daemon's class, so a connection the daemon
  classed wrongly is still judged by what it is.
- The verdict has one part per check. RUN-3: `run3_visible`, `run3_hidden_workspaces`, `run3_hidden`. RUN-4:
  `run4_daemon_threads`, `run4_ui_connection` (app mode with `--daemon-socket`), `run4_automation`, `run4_peak`
  (daemon mode). A RUN is true only when all its parts are true, false when one fails, otherwise null. A partial
  read never passes. `qos-audit.py judge` reads saved replies again. Exit 0 means every part the run covers
  passes, 1 means a finding is open, 2 means a part the run covers was not read (`missing`) or a read failed.
  RUN-3 (b) queue literals and RUN-4's crate deny attributes and clippy are static checks (threading-inventory.py,
  task 219); the audit does not read them.

Run 2, Linux daemon only (2026-10-27, 360-core Linux VM, nice 0, Debug `cmux-tui` of this branch on
perf/chrome-parity 3bbdf9d3d6a, with the `connection` field; base feat-cmux-next 772cdfc45ac). The run used the
millisecond sampler, 3 runs per side, perf-10x-lifecycle's op mix and about 22 s and 17,500 counts per run. Peaks:
head 490, 506, 501; base 504, 497, 487. The ranges overlap, so RUN-4's peak part fails: the head is not lower
than the base. Run 1 read the count only between rounds and gave 383 against 389. That method missed the threads
of a create or a close, so its "passes" did not hold. RUN-4 also fails on 21 thread findings: 2 mismatches and 19
unregistered threads. `run4_automation` passes: the script's automation connections ask for utility. On Linux
their nice stays 0, which is the `mismatch` rows below. `run4_ui_connection` is not read because a headless
daemon has no app. The up to 143 `terminal-host-r` threads are the per-child `terminal-host-reaper` (task 237).
Linux cuts names to 15 characters. The deny attributes are on no daemon crate root (task 219 has not landed).
The fleet run is still open: app STRESS visible and hidden with `--daemon-socket` (RUN-3, and RUN-4's UI
connection), and the macOS daemon. Until it is done, this task does not pass.

| Task (`p02-threads-R-qos-daemon-` + suffix) | Thread | Seen | Spawn site |
|---|---|---|---|
| `peak-threads-process` | the process | head peaks 490, 506, 501; base 504, 497, 487 | the threads per terminal (`terminal-host-reaper`, task 237) and the lifecycle's one-shot threads |
| `mismatch-mux-conn` | `mux-conn` | desired utility, applied default: `RestingClass::follow` asks the registry slot for utility before `WorkQos::enter`, which does not lower a class the process cannot raise again (Linux nice without CAP_SYS_NICE) | server/connection_qos.rs, server/listen.rs |
| `mismatch-mux-control-dispatch` | `mux-control-dispatch` | desired utility, applied user-initiated, same cause | server/connection_qos.rs, server/connection_scheduler.rs |
| `unregistered-main` | daemon main thread | no row | cmux-tui/src/main.rs |
| `unregistered-unnamed` | a thread with no name of its own | no row | (by stack) |
| `unregistered-tokio-rt-worker` | an unnamed tokio worker, idle phase | no row; task 228 runtimes name theirs | (by stack) |
| `unregistered-background-chec` | `background-checks` | no row | cmux-tui/src/owner_start/background_checks.rs |
| `unregistered-client-log` | `client-log` | no row | cmux-tui/src/client_log.rs |
| `unregistered-memory-guard` | `memory-guard` | no row | cmux-tui/src/owner_start/memory_guard.rs |
| `unregistered-headless-signal` | `headless-signal` | no row | cmux-tui/src/headless.rs |
| `unregistered-cmux-config-wat` | `cmux-config-watch` (2) | no row | cmux-config/src/watch/inotify.rs, portable.rs |
| `unregistered-notify-rs-inoti` | `notify-rs inotify` (the notify crate's watcher thread) | no row | a `notify` watcher of cmux-config or cmux-tui-core |
| `unregistered-mux-project-sou` | `mux-project-sources` | no row | cmux-tui-core/src/state/project_watch.rs |
| `unregistered-mux-agent-chat` | `mux-agent-chat-*` | no row | cmux-tui-core/src/mux/agent_chat_notices.rs |
| `unregistered-cmux-journal-pl` | `cmux-journal-plugin*` | no row | cmux-tui-core/src/journal_plugin.rs |
| `unregistered-mux-cloud-io` | `mux-cloud-io` | no row | cmux-tui/src/cloud_conversations_backend.rs |
| `unregistered-mux-host-replic` | `mux-host-replica*` (up to 3) | no row | cmux-tui-core/src/server/cloud_host_replica.rs |
| `unregistered-mux-deadline-n` | `mux-deadline-<n>` | no row | cmux-tui-core/src/mux/deadline_fanout.rs |
| `unregistered-mux-idle-close` | `mux-idle-close` | no row | cmux-tui-core/src/mux/idle_close.rs |
| `unregistered-mux-launch-snap` | `mux-launch-snapshot` | no row | cmux-tui-core/src/server/launch_snapshot.rs |
| `unregistered-terminal-host-r` | `terminal-host-reaper` (up to 143) | one thread per child | terminal_host_runtime/sys/unix/spawned_host.rs (task 237) |
| `unregistered-terminal-host-c` | `terminal-host-close` or `-child` (up to 8, during lifecycle closes) | no row | mux/host_close.rs, terminal_host_runtime/shared/host_start.rs |

## Reviewed blocking allowances

`allowBlocking(<reason>)` lets the main thread block for one of these reasons only (Chrome's
`ScopedAllowBlocking` friend list). A new `BlockingAllowance` needs a row here in the same push. It is not for
hot paths: in Debug and bench builds (and Nightly, to come) each outermost scope adds and removes one `CFRunLoopObserver` (it
holds the allowance back while a nested run of the main run loop runs other work). Swift allowances plus
`// blocking-allow:` escapes stay at 3 or fewer (INV-4; arch-ratchet `blocking_allow_escapes`).

| Reason | Why the wait cannot move off the main thread |
|---|---|
| `terminate` | `applicationWillTerminate(_:)` runs on the main thread and the process exits right after it: a bounded final flush there cannot delay a frame (Chrome allows blocking during shutdown the same way). |
| `surfaceTeardown` | `ghostty_surface_free` runs on the main thread in the terminal view's deinit, and its output lane must not be parsing into the surface then: the fence (`TerminalOutputLane.close`) waits for at most the one chunk in flight, since queued work is skipped once the lane closes, on a lane of the main thread's own QoS (user-interactive). Chrome allows bounded teardown waits with `ScopedAllowBaseSyncPrimitivesOutsideBlockingScope`. |

Daemon: `cmux_threads::AllowReason` is the Rust friend list, 3 variants or fewer. `allow_blocking(reason, f)` is
the only way past `disallow_blocking`.

| AllowReason | What it permits | Where |
|---|---|---|
| `Shutdown` | Every kind except ipc-reply, while the daemon flushes state and joins workers on a thread that no longer serves input (Chrome's `PermanentThreadAllowance::AllowBlocking`) | No call site yet (shutdown paths adopt it with tasks 211 and 213-218) |
| `OwnDescriptor` | Only fd-read and fd-write on the descriptor the thread registered (`register_own_descriptor`); call-scoped, never thread-wide; made only by `own_fd_read`, `own_fd_write` and `own_fd_write_all` | Echo threads that own a terminal-host socket (`echo_thread::spawn_host_stream_reader`, `with_own_host_stream`); PTY and control-socket descriptors by task 210b |
