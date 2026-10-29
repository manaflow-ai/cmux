# cmux next: idle wakeups and spin loops (2026-09-30)

User requirements: "make sure it doesn't spinloop", "all polling is bad". The error class is any code that wakes up when nothing changed (an idle wakeup), or loops without making progress (a spin). The budget is architecture.md section 5: 0.0% CPU over 60 s with nothing changing, window visible or hidden.

## 1. Root causes

The spins and idle wakeups found here are design gaps, not concurrency bugs:

1. **No sanctioned way to wait.** Each owner rolled its own display link (9 owners), timer, sleep loop or retry loop. Nothing counted wakeups, so nothing showed which owner woke the app.
2. **Safety-net and polling timers instead of events.** The CEF pump's fixed 30 Hz / 1 Hz fallback, ChromiumWarmup's 250 ms idle poll, fixed-period reconnect loops, and in cmux-tui a 50 Hz accept poll in every terminal host, 100 ms stream-disconnect polls, 250 ms / 500 ms / 1 s / 15 s supervisor ticks.
3. **Level-triggered sources that are not drained or stopped.** A read source on a listener whose `accept` fails with EMFILE, or on a hung-up PTY master, fires again at once forever.
4. **Retries without capped backoff and without a wake event.** Reconnect storms that spawn `cmux-tui server ensure` every 2 s forever, a flapping daemon reconnected at 20 Hz, a mobile accept cycle restarted at once.
5. **"Keep ticking while a flag is set" instead of "tick while something moves".** The layout ticked every vsync while a divider gesture was active even with a still pointer; a gesture that never ended spun at 120 Hz forever (state-audit L1).

## 2. Sanctioned primitives (CmuxNextWakeups)

These are the only allowed ways to wake up. `scripts/cmux-next/check-concurrency.sh` fails on any timer, raw display link, sleep, `while true`, `while !Task.isCancelled` or `repeat {` outside the module unless the line or the comment block above carries `// wakeup-allow: <reason>`.

| Primitive | Contract |
| --- | --- |
| `FrameScheduler` | One per window (`forWindow`, `forView`) plus `FrameScheduler.app` for window-less work. Owns the only display link, runs only while a `FrameClient` is active, drops the link when the last client goes idle. `activeClients` lists owners (debug.wakeups). Stall deadline and link rebuild when frames stop (state-audit D4). |
| `FrameClient` | A reason to receive frames (animation, autoscroll, settle, batch). The tick returns false to go idle. `isAnimation: false` marks batch work (store drain) so the busy watchdog does not excuse it. |
| `DemandTimer` | One-shot deadline on an injected clock: `schedule` (resets), `scheduleIfIdle`, `cancel`. Never repeats. Each fire is one ledger entry. |
| `Backoff` | Exponential, capped, jittered retry spacing; `wait(owner:)` records the wait. A retry first waits for an event that can make it succeed; Backoff only spaces attempts after a real failure. |
| `WakeupLedger` | Counts every primitive's wakeups per owner and reason; rate over the last 10 complete seconds, lazily rolled (no timer). |
| `assignIfChanged`, `UpdateCycleDetector` | Observation updates that settle: a set of the same value does not notify; re-entrant update cycles are counted and logged in debug builds. |
| `ExpectedActivity` | Input, animation-frame and terminal-output counters for the busy watchdog. |
| `ProcessUsage` | `proc_pid_rusage` CPU time and wakeups per process (app, helpers, daemon, hosts). |
| `MainDeadline` (MainDeadline.swift, `TimerAlignment` in TimerAlignment.swift, `MainDeadlineScheduler` in MainDeadlineScheduler.swift; p06-scheduler task 011, landed) | The main-thread deadline: `MainDeadline(owner:, workClass:, alignment:, scheduler:)`. Its wake is an entry of the main thread's one `MainWakeUpQueue` timer; its action runs through `mainWork.post` in its class. `.precise` only under 36 ms (longer falls back to flexible); `.flexible`, the default, is no sooner than the deadline, snapped up to the next 8 ms boundary (32 ms in Energy Saver) below 1 s and to the whole second above; `.whenHidden(node)` aligns to 1 s while the node is hidden, and a repeating or self-re-arming deadline whose node has been hidden 5 minutes shares one wake a minute per node (or one 1 s-aligned wake when the node had none in the last minute). No alignment within 30 s of media activity or while the node is captured. A deadline that a person or a request waits on is never `.whenHidden`. `MainDeadlineScheduler.nextFire` feeds the idle deadline. |
| `Deadline` (Deadline.swift, task 011, landed) | The timeout of a race (an await against a deadline), on the injected clock; it throws `Deadline.Exceeded`. |
| `MainWakeUpQueue`, `AlignedWakeups` (MainWakeUpQueue.swift, AlignedWakeups.swift, tasks 011 and 012, landed) | One `CFRunLoopTimer` for every main-thread deadline, re-armed and never re-created, with a heap ordered by latest time. `AlignedWakeups` places deadlines on its boundaries, so 50 hidden deadlines in one second are 1 wakeup and 20 visible flexible deadlines in one 8 ms bucket are 1 wakeup. `DemandTimer` stays for off-main deadlines; `schedule(after:tolerance:)` has a tolerance by default. Design, policy table and Energy Saver: section 9. |
| `IdleScheduler` (IdleScheduler.swift, task 005, spec'd) | `mainWork.postIdle(owner:, maxDelay:) { deadline in }`. Long idle periods start after 50 ms of quiet (deadline at most 50 ms and never past the next `MainDeadline` fire); short periods use 2 ms or more left before vsync. An empty queue arms no timer (0 wakeups). Idle stops 10 s after the app or the task's node goes hidden. Use it for warmups, spare-window refills and snapshot writes instead of an idle poll. |
| `CPUTimeBudgetPool` (CPUTimeBudgetPool.swift, task 210, spec'd) | Hidden-node work is charged to it: it refills 10 ms per second up to 100 ms, and a negative balance waits for the next aligned wake with budget. Media and capture are exempt. |
| `VisibilityNode` (VisibilityNode.swift, task 020, landed) | The hidden state that `.whenHidden`, the wake-up budget, the CPU-time pool (task 210) and the frame clients read (`isVisible`, `hiddenSince`, `mediaActiveWithin(_:)`, `isCaptured`). Task 047 (spec'd) stops ticking a hidden node's frame client with `visibleOnly:`. |

cmux-tui gets the same rules (section 6): blocking reads and condvar waits with no timeout, one-shot computed deadlines, one shared Backoff.

How to choose (recipe R-timer, [main-thread-budget.md](main-thread-budget.md) section 11): first make the timer an event (a callback, a stream, a source the producer signals). Only if no event exists, use a `MainDeadline` with a class and an alignment on the main thread, or a `DemandTimer` with `tolerance:` off it. A sleep inside a race uses `Deadline`. `scripts/cmux-next/p06_queue.py` counts the open sites (queue Q6, escape `// timer-class-allow: <why>`). The pre-push guardrail `timer-class` (task 014, landed) refuses a new main-actor `DemandTimer` and new `Task.sleep` and `clock.sleep` loops with the same escape. `check-concurrency.sh`'s `// wakeup-allow:` stays the escape for timers and loops outside CmuxNextWakeups.

## 3. Diagnostics

- `debug.wakeups`: ledger owners with rates, each FrameScheduler with its active clients, cumulative CPU and wakeups per process (app, `cef-renderer`, `cef-gpu`, other helpers, `daemon`, `terminal-host`). Diff two calls for rates.
- `debug.hangs` busy records (`kind: busy`, `busy_count`): a 10 s window in which the main thread (> 30% of a core), the process (> 50%) or a Chromium helper (> 50%) used CPU while no input, animation frame or terminal output happened. The record has a main-thread stack sample and the busiest ledger owners. Windows open on a main-run-loop wake and end with one DemandTimer, so an idle app costs nothing.
- `scripts/cmux-next/bench-idle.sh <tag>`: launches the tagged app and measures app, daemon, hosts and helpers in four scenarios (terminals; plus a static Chromium tab; with that tab's workspace hidden; window minimized). Dogfood builds report it.

## 4. Known incidents

| Incident | Root cause | Evidence |
| --- | --- | --- |
| App 1-3% CPU idle whenever a Chromium browser exists | **Proved.** CEFMessagePump re-armed its CFRunLoopTimer after every pass at `CEFPumpPolicy.busyFallback` (1/30 s) while any browser existed, even an idle, hidden or minimized page, and at 1 s forever once CEF started. Fixed by the CEF pump agent (23289d1437c): the pump runs when CEF asks (OnScheduleMessagePumpWork). Fork API 7 (cef-154.0.28-cmux.7, pinned in 190a3095b92) makes MessagePumpExternal demand-driven (it asks again when its slice ends with work left and reports its next delayed task), so the pump has no follow-ups at all. The pump is demand-only for every fork; the follow-up chain for older pins (1/30 ... 1 s) is deleted, and an older fork gets one error log line from CEFRuntime (its leftover slice work and delayed tasks wait for the next CEF request). | Base bench: app 56-62 wakeups/s, 0.6-1.0% CPU with one static tab (terminals only: 0.35-1.35/s). Pump agent: old 28.8-31.4 pump wakeups/s at 0.58-1.33% app CPU; new 0.0-0.93/s after Chromium settles (2.7/s in the first minutes) at 0.02-0.27%; CEF started with no browser 0.27/s at 0.067%; DevTools open ~127/s (CEF asks); 120 fps page 8.8/s. With cmux.7 and no follow-ups: idle static tab 1.3-2.2 pump wakeups/s, all CEF requests (Chromium's own delayed tasks, 1.1-2.2/s, which the old fork hid), 0.18-0.33% app CPU; 120 fps page 4.9/s. These cmux.7 numbers were taken at load average 270-320 and have no quiet re-measure. |
| Chromium Renderer 144-157% and GPU 15-70% after 20-26 min on idle pages | **Not proved.** Hidden tabs are not the cause: in base code a Chromium tab in another pane tab, another workspace, a terminal-selected pane and an offscreen strip column already reports `visibilityState: hidden`, rAF 0, timers ~0.3 Hz and 0% renderer/GPU (measured by the visibility agent). The observed pages were visible. DevTools blamed the page's own animation for one case (example.com now animates its text), and a fresh instance did not reproduce. Remaining candidates: a visible animating page (Chrome behaves the same), a Chromium bug after long uptime, GPU process contention on an overloaded machine (load average 308 during this work). The busy watchdog now records a helper busy for 10 s with no input. | Visibility agent measurements (section 7); no reproduction. |
| Machine load from long-lived test apps and leaked daemons | Leftover tagged apps with Chromium pages keep helpers busy, and every leaked cmux-tui terminal host woke 50 times a second (terminal_host_runtime accept poll), so N leaked hosts cost 50 x N wakeups/s machine-wide. Fixed: host accept blocks (section 6); cleanup rules in AGENT-BRIEF.md; bench-idle ends its daemon's terminals. | cmux-tui audit; `uptime` load 300+ during this work. |

## 5. Inventory: CmuxNext (Swift)

Status: **fixed** (this work), **ok** (event-driven, one-shot, or stops itself), **reviewed** (`wakeup-allow`).

| Site | Owner | Trigger | Stops | Could spin / idle wake | Status |
| --- | --- | --- | --- | --- | --- |
| DisplayLinkFrameScheduler x4 (store drain, presentation, control queue + snapshot publisher, 2 invariant monitors) | App | pending work | paused when empty | paused, not dropped; stall task per enqueue | fixed: `FrameBatcher` clients of `FrameScheduler.app` |
| Layout DisplayLinkDriver | LayoutRootView | springs, gestures | `onFrame` false | ticked while a gesture was active with a still pointer; forever if the gesture never ended (L1) | fixed: FrameClient; frames only while moving or intents pending (red/green IdleFramesTests) |
| ResizeCoordinator | App | pane size change | settle idle | ok (bound to main screen) | fixed: FrameClient on `.app` |
| TabStripView display link | Tabs | springs, drag autoscroll | settled | ok | fixed: FrameClient |
| SidebarListView autoscroll link | Sidebar | pointer in edge zone | zone left or content edge | ok | fixed: FrameClient |
| TabDragSession ghost link | App | drag motion | settled / landing | ok | fixed: FrameClient on the ghost panel |
| DebugFrameProbe | App | `debug.frames start` | `stop` only | ran every frame forever if no `stop` | fixed: FrameClient + 10 min DemandTimer expiry |
| ControlSocketServer accept | Control | listener readable | `stop()` | **spun at 100% on EMFILE/ENFILE** (1,070,431 accepts in 500 ms) | fixed: EAGAIN waits, other failures suspend the source with Backoff 50 ms-2 s (red/green ControlSocketAcceptTests) |
| ControlSocketPathWatch | Control | kqueue write/rename/delete on the socket's directory (the quiet per-user state folder); the compatibility link is followed itself (row below) | `stop()` | one `lstat` per directory change by any process (on /tmp that is every write there, coalesced by dispatch); no timer. A host /tmp cleaner that deletes the link (it sees no holder) gets it re-made. A restore that keeps failing re-triggers itself (its bind stages a directory beside the path), so after 3 failed restores in a row it ignores events and retries on a DemandTimer with Backoff 1-60 s until one works | reviewed (red/green ControlSocketPathRestoreTests) |
| ControlConnection read/write sources | Control | readable/writable | EOF, error, close | ok (EAGAIN keeps the source armed; backpressure suspends) | ok |
| ControlConnection drain timer | Control | half-close | fires once / close | one-shot | reviewed |
| Event stream heartbeat | Control | `events.stream` client | hangup | 15 s keepalive the client requested (`include_heartbeats`) | reviewed (protocol) |
| ControlDeadline, ControlSnapshot barrier, MainActorWorkQueue item deadline | Control | request | answer | one-shot | reviewed |
| MainThreadWatchdog thread | Control | a main turn longer than the sample delay | the turn ends | **two watchdog wakeups per main wake** (semaphore signal, then a 30 ms timed wait that expired after the turn) | fixed (2026-10-23): one kqueue, a one-shot EVFILT_TIMER armed per turn and deleted before the main thread sleeps; a short turn wakes no other thread (red/green MainThreadWatchdogTests.shortMainTurnsDoNotWakeTheWatchdogThread). Cost: 2 `kevent` syscalls on the main thread per main wake (arm on wake, delete before sleep; before: at most one semaphore signal, only while the watchdog was parked), so under STRESS the main thread makes 2 syscalls per turn and no cross-thread wake; not yet measured in the batch bench. Caveat kept: a nested run loop in a non-common mode gives no heartbeats, so the timer armed at the outer wake fires and the watchdog polls once per threshold until the nested loop ends |
| LocalPTYTerminalIO read source | Terminal (debug PTY) | readable | exit source | **spun after the slave side hung up while the shell lived** | fixed: hangup cancels the read source (no test target in CmuxNextTerminal) |
| ChromiumWarmup | App | Chromium likely | idle or 60 s | **polled every 250 ms** up to 240 times | fixed: DemandTimer re-armed for the rest of the quiet period; menu end notification |
| WindowManager save debounce | App | window state change | fires once | one-shot | fixed: DemandTimer |
| DaemonConnection reconnect | Daemon | connection lost | connected / close | **2 s forever, `server ensure` spawn per attempt; flapping daemon at ~20 Hz; a crash loop retried on every new socket** | fixed (reconnect fork, 887b84df5ca): Backoff 50 ms-30 s, 10 timed attempts, then only socket-directory change or RetryWake events; after 3 failed socket-woken attempts only RetryWake events (cx-6so.7) |
| DaemonConnection heartbeat | Daemon | bridged connection, or the app's main local connection (`localHeartbeat`) | close | `identify` every 15 s on a DemandTimer; 2 misses close the transport. A stopped or wedged owner keeps its socket open, so no EOF ever shows it gone (cx-jniyz.4); page relays and short reads do not heartbeat | reviewed (red/green StoppedOwnerTests) |
| DaemonStartup first connect | Daemon | launch | connected | **5 s forever on launch failure** | fixed: 250 ms-30 s, 10 attempts, then events |
| DaemonStore resync | Daemon | snapshot failed | success | **2 s forever while connected** | fixed: 100 ms-10 s, 8 attempts on a DemandTimer, then the next daemon event |
| DaemonService local/remote loops | App | lost connection | stop | remote: 1 s outer loop + inner 2 s, API call and `remote connect` spawn per attempt | fixed: RetryPacer, NWPathMonitor and app activation wake it; startup deadline is a DemandTimer |
| Feed reports reader (AcpmuxMailboxReader) | App | signed in with acpmux | sign-out / stop | **5 s sleep per failed mailbox wait; then (71df51392dc) a socket-appearance wait that spun on the main thread when the folder did not open, and a 250 ms-30 s Backoff forever while a crashed acpmux's socket file stayed** | fixed: off the main actor on RetryPacer + RetryWake (`waitForPeerAfterFailure`): a missing socket arms no timer and wakes on its vnode event (RetryWake follows missing folders down, by identity); a stale socket gets 10 timed attempts, then its replacement or app activation; a socket that replaced it (also during an attempt, when its change wakes nothing) gets timed attempts of its own, at most `socketRetries` times; a folder on the way that does not open counts as unwatched (timed); the watch is armed only while a failed wait is retried, so a reading or ended reader keeps no vnode source (AcpmuxMailboxReaderTests, RetryWakeFolderTests, RetryPacerSocketBudgetTests) |
| SocketWriter | Daemon | queued writes | error | 0-byte write counted as progress | fixed: failure |
| LineTransport reader | Daemon | blocking read | EOF/error | ok | reviewed; request deadlines are DemandTimers |
| WindowStateStore CAS | Daemon | save | 3 retries | bounded | reviewed |
| MobileIrxHost accept cycle | Mobile | endpoint ready | stop | **nil accept restarted at once with failures reset** | fixed: 250 ms-60 s, 10 cycles, then relay-state events (no red test: no seam in IrxEndpointSupervisor) |
| MobileIrxHost endpoint activation | Mobile | start | success | 5 s-300 s forever | fixed: 8 attempts, relay change cuts short |
| UnixSocketLane empty read | Mobile | read | final/error | empty non-final delivery looped the splice pump | fixed: ends the stream |
| ConfigFileWatcher | Settings | kqueue vnode on file and directory | stop | ok: already event-driven (no wait-for-file loop; it watches the nearest existing ancestor) | ok |
| CEFMessagePump | Browser | CEF schedule + fixed fallback | never | **30 Hz / 1 Hz forever** | fixed by the pump agent (23289d1437c): demand-driven. It wakes only when CEF asks, for every fork; an older fork than API 7 (cef cmux.7) gets one error log line from CEFRuntime, no follow-up chain |
| CEFReplyWaiters, CEF shutdown timeout | Browser | DevTools call / quit | reply | one-shot | reviewed |
| Hover card, click-and-hold, double-click, spring-load, record write-back | Tabs, Sidebar, App | UI event | fires once / cancelled | one-shot, injected sleep | reviewed |
| Agent pane render-rate re-apply | AgentPane | rate change (after a settled scroll) | fires twice, then stops | one-shot, injected sleep | reviewed |
| GhosttyRuntime wakeup_cb | Terminal | libghostty | per tick | coalesced by an atomic flag | ok |
| ~25 `for await` over `Observations` | App | model change | owner deinit | no self-writes found; Observations does not dedupe equal writes | ok; `assignIfChanged` for writers |
| ControlSnapshotPublisher `withObservationTracking` | App | model change + every frame after a batch | never cancelled | stacked registrations multiply work under compat reads (not idle) | open |
| ControlSnapshotPublisher model-change delay | App | model change | publish | **a display frame per frame for the 100 ms delay** (about 12 main wakeups per model change at 120 Hz) | fixed by PL-typing (561ee1c4cbf..04346918bc8): the control snapshot is lazy, no 100 ms interval; the merged waiter rule (a waiting reader or new waiter publishes at once, 0 wakeups with no reader) is PL-typing's next change, with PL-idle's 0-wakeup test |
| ControlSocketPathWatch on /tmp | Control | any write in /tmp by any process | stop() | **one accept-queue wakeup and lstat per /tmp change Mac-wide** | fixed (2026-10-23): watches the link itself (O_EVTONLY, O_SYMLINK), its directory only as fallback; a directory watch moves back to the entry on the first event that finds one it can open, and every watch is made on its queue (no install race). Still on /tmp: only a socket-path override in /tmp (this app's own socket file cannot be opened; kept for the cleaner incident hq#1870), logged once. Another app's live socket at the link path (a classic cmux of the same channel or tag) no longer keeps a /tmp watch: the link's watch yields (watches nothing, the link is dropped for this run, logged once). `stopped`/log-once flags are Atomic<Bool>; the test counter is DEBUG-only (red/green ControlSocketPathWatchIdleTests, incl. aLinkPathHeldByAnotherLiveSocketWatchesNothingInTmp) |
| HomeCache writes | Home | every owner event (typing, connection, recovery) | 250 ms later | **rewrote the whole cache with the same bytes** (358 KB/s idle on Home); then still woke the main actor 250 ms later and built and compared the full snapshot | fixed (2026-10-23): the mirror and the intent log count writes to what the cache holds (HomeChangeCount); only a moved count, a draft or a scroll anchor schedules a write, so typing, connection changes and recoveries start no Task and build no snapshot; no retained copy of the written snapshot; equal rows are not assigned (red/green HomeCacheIdleWriteTests.ephemeralOwnerEventsScheduleNoWrite). Review follow-up: an equal inbox refetch no longer moves the mirror's count (HomeMirrorEqualInboxTests); a real write is proportional to the change and off the main actor: HomeCache is an actor, the main actor hands it copy-on-write values, and the files are a small index plus one file per window, of which only the changed ones are rewritten (HomeCacheProportionalWriteTests). Second follow-up: the actor compared the encoded index bytes, and JSONEncoder writes keys and ConversationID-keyed dictionaries in hash order, so an equal state still rewrote home.json (the flaky aMessageInOneConversationRewritesOnlyItsWindow); it now compares the index value (sorted keys order only struct and String keys; the ConversationID-keyed dictionaries still encode in hash order, so the compare must stay a value compare) (red/green anEqualStateBuiltInAnotherOrderDoesNotRewriteTheIndex). Home disk B/s with agents active (light and STRESS) is not measured yet: the 358 KB/s row is not claimed until then |
| Media observer page script (both engines, every frame of every page) | Browser | page load | never | **setInterval 1 s in every frame for the page's life**, idle or hidden | fixed (2026-10-23): the timer runs only while the frame's report plays or waits for the binding. Reports carry a per-document frame id and the tab keeps one per frame (BrowserMediaFrames), so one frame's null no longer erases another's paused report (what the 3 s re-send hid); pagehide drops the frame's report. Review follow-up: no DOM watch at all (the subtree MutationObserver kept while a paused report was live ran on every mutation of a busy page for hours): a removed paused element reports null at the next media event or show; a report waiting for the binding retries at most 10 looks, then at the next media event or show; a pagehide null that waits is retried too (red/green BrowserMediaObserverIdleTests, BrowserMediaFramesTests) |
| Verification detector page script (both engines, top frame of https pages) | Browser | DOM change, 10 min after load | report / 10 min | **whole-page `innerText` (forced layout) up to 1/s on a hidden page; a missing binding retried at 4 Hz forever** | fixed (2026-10-23): a hidden page's changes are noted and checked once on show; a page found waiting before the binding exists keeps no timer and reads no text, and reports when CEFVerificationBridge calls its ready hook (once per document, at .finished, after that document's addBinding) or at the next show. There is no timed binding wait (an earlier 10 s cap was replaced by the ready hook). The 10-minute end disconnects the observer and the visibility listener (red/green VerificationDetectorHiddenTests, CEFVerificationBridgeCallsTests). Open: that background tabs of both engines really report `visibilityState: hidden` on macOS 14/15/26/27 is a runtime check for the batch run (JSC tests fake it) |
| HostPressureMonitor read timer (cmuxterm-hq#2995) | HostPressure | 15 s timer (2 s leeway) for load, swap and acpmux's `host_pressure`, which have no event; memory pressure is a DispatchSource event | Runs only while the feature `hostPressure` (default off, cmux#22662; the Debug toggle `hostPressure.enabled` overrides it at launch) is on and at least one window can be seen. Each window's indicator unsubscribes when its window hides, minimizes, is fully occluded or closes (`HostPressureSampling`); the last unsubscribe, and app quit, call `stop()`, which cancels the source, timer and read. Cleanup: the indicator removes its window observers and cancels its forced-level and level observations on leaving the window and in deinit | one timer for the app, not one per window: 4 wakeups a minute while a window with the feature on is visible, 0 while off or hidden; one sysctl batch each; a missing acpmux verdict is retried every 20th read, not every read | reviewed |

### Polling sites removed

CEF safety-net timer (pump agent), ChromiumWarmup 250 ms poll, DebugFrameProbe unbounded run, the four always-available display links' per-enqueue stall tasks (now one per scheduler), DaemonConnection 2 s reconnect, DaemonStartup 5 s retry, DaemonStore 2 s resync, DaemonService remote 1 s loop, MobileIrxHost activation 5-300 s loop and immediate accept restart, WindowManager ad hoc sleep debounce, and in cmux-tui the items in section 6.

## 6. Inventory: cmux-tui (Rust)

The daemon uses std threads, blocking IO, mpsc channels and condvars; each terminal is a separate `__terminal-host` process.

Fixed in dc5cb26c16d (failing idle test `cmux_next_daemon_idle_has_no_periodic_wakeups`) and 51b68635143 (fixes); hosted CI red run 36692729021 (macOS daemon 34.2 wakeups/s, host 43.4/s; Linux daemon 37/s, host 49.9/s), green on Linux run 36696885418 (daemon 0 and host 1 context switches in 10 s).

| Site | Before | After |
| --- | --- | --- |
| Server accept loop (server.rs `mux-server`) | `let Ok(stream) = listener.accept() else { continue }`: 100% CPU on EMFILE/ENFILE/ENOBUFS | shared capped, jittered `cmux_tui_core::backoff` for persistent errors (also provider-management, WebSocket and remote accept loops) |
| Terminal host accept loop (terminal_host_runtime.rs) | non-blocking listener + `poll(fd, 20 ms)` for the life of every terminal: 50 wakeups/s per host | polls the listener plus an accept waker (socket pair) written by exit and last-stream-close; the launch-owner deadline is a one-shot timeout until it passes |
| Headless main loop (main.rs) | `recv_timeout(250 ms)` on an All-events subscription (4 Hz plus every output) | condvar signalled by signals, shutdown requests and the remote runtime's end |
| Stream threads (terminal/browser/sidebar attach, notifications, events-out, attach-out, browser frames) | `recv_timeout(100 ms)` to notice a closed writer: ~10 wakes/s per stream | writer close, stream close and attach cancel fire a StreamInterrupt that wakes the blocked receive |
| Session event and journal streams | 1 s epoch waits | wait for a journal event or the stream's close |
| Journal fanout tailer, hook dispatcher | 1 s waits | wait for a commit, a worker completion, shutdown or a scheduled retry; backoff after failures |
| Journal plugin supervisor | 500 ms waits, 500 ms `try_wait` poll | condvar; a `waitid(WNOWAIT)` thread reports the child's exit |
| Idle-close reaper | 15 s tick with no policy | sleeps until the next policy deadline; woken by policy changes and detaches |
| Unplaced-terminal reaper | a failing scan left a past-due deadline: hot loop | due deadlines deferred with growing spacing |
| Hosted-surface reconnect | new backoff per loss; immediate reconnect on accept-then-drop or resync | losses within 10 s of a reconnect share one backoff |
| Host forced drain | busy loop on a hung-up waiter for 100 ms | waiter dropped from the poll set |
| Kitty image budget worker | identical wave re-ran at once | counts as a failure and backs off |
| Local PTY reader | WouldBlock slept 1 ms | Interrupted retries, WouldBlock backs off |
| Remote runtime bootstrap (50 ms), browser proxy parent check (250 ms), parent-exit wait (100 ms) | polls | select on the owner channel and signal pipe; kqueue NOTE_EXIT / pidfd |
| Writer waiting on a full stream | 100 ms re-check | left: only while a stream is full (backpressure), not idle |

## 7. Measurements

Idle benchmark, same machine, 60 s windows after 20 s settle. Machine load average was about 300 (shared by many agents), so absolute CPU numbers are noisy; wakeups per second are the stable signal.

### Base (`nospinb`, origin 4c2ec798a99: primitives only, no behavior change)

| Scenario | app | daemon | each terminal host | Chromium helpers |
| --- | --- | --- | --- | --- |
| terminals | 0.006-0.05% CPU, 0.35-1.35 wakeups/s | 0.03% CPU, 35-46 wakeups/s | 0.05% CPU, 47-48 wakeups/s | none |
| + static Chromium tab (selected) | 0.63% CPU, 61.9 wakeups/s | 0.03%, 36.7/s | 0.05%, 48.5/s | each < 0.04% CPU, < 2 wakeups/s |
| Chromium tab in a hidden workspace | 1.02% CPU, 56.1 wakeups/s | 0.05%, 56.4/s | 0.05%, 48.3/s | each < 0.03%, < 1/s |

The app's ~60 wakeups/s with Chromium is the CEF pump's fixed 30 Hz fallback (plus its twin wakeups); it does not drop when the tab is hidden. The daemon and every terminal host wake 35-66 and 47-49 times a second at idle: the cmux-tui polls in section 6.

### After (`nospina`, 98d5750d09e: Swift primitives and fixes, demand-driven CEF pump 23289d1437c, cmux-tui pin 51b68635143), `--fresh`

| Scenario | app | daemon | each terminal host | Chromium helpers |
| --- | --- | --- | --- | --- |
| terminals | 0.010-0.013% CPU, 0.28-0.45 wakeups/s | 0.000%, 0.03/s | 0.000%, 0.00/s | none |
| + static Chromium tab (selected) | 0.16% CPU, 2.95 wakeups/s | 0.000%, 0.03/s | 0.000%, 0.00/s | each <= 0.023% CPU, < 1 wakeup/s |
| + a second workspace selected | 0.011-0.021%, 0.38-0.65/s | 0.000%, 0.03-0.05/s | 0.000%, 0.00/s | (see note) |
| window minimized | 0.011-0.018%, 0.32-0.45/s | 0.000%, 0.03/s | 0.000%, 0.00/s | (see note) |

Every scenario meets the pass criteria. Note: in the two final bench runs the first Chromium tab did not open inside the bench (the action missed the 2 s control deadline during a cold CefInitialize on the loaded machine, and no renderer appeared in 90 s), so the hidden-workspace and minimized rows there have no Chromium tab; the static-tab row is a manual 60 s measure on the same build after opening the tab through the socket. With the pump fix alone (6ce646ac01a, old cmux-tui) a static tab measured 2.37-3.23 app wakeups/s at 0.35-0.38% CPU, and the pump agent measured 0.0-0.93 pump wakeups/s once Chromium settles. The busy watchdog opened one window per 10 s only while the old pump kept the main thread awake (ledger `BusyWatchdog.window` 0.1/s); with the new pump the app sleeps and it opens none.

cmux-tui hosted CI idle test (10 s, context switches per second): macOS daemon 34.2 -> 0, host 43.4 -> 0.1; Linux daemon 37.0 -> 0, host 49.9 -> 0.1 (red 36692729021, green 36699544372, pin verification 36704549440).

### Chromium visibility (visibility agent, tagged `nospincef`, base code, CEF 154.0.28-cmux.4, 60 s per case)

| Case | visibilityState | rAF | 10 ms timer | renderer / GPU CPU |
| --- | --- | --- | --- | --- |
| Animated page, selected | visible | 127 Hz | 105 Hz | 12.9% / 7.4% |
| Static page, selected | visible | 0 | 1 Hz (its own) | 0.02% / 0.0% |
| Other Chromium tab selected in the pane | hidden | 0 | 0.3-1.3 Hz | 0.03% / 0.0% |
| Terminal tab selected in the pane | hidden | 0 | 0.3 Hz | 0.05% / 0.0% |
| Tab in another workspace | hidden | 0 | 0.7-1.3 Hz | 0.03% / 0.03% |
| Window minimized | hidden | 0 | 0-0.5 Hz | 0.02% / 0.01% |
| Offscreen strip column | hidden | 0 | 0.8 Hz | 0.05% / 0.13% |

Every case returns to visible when shown. No visibility change was needed: the fork's tab strip hides inactive tabs (Chromium engine behavior), hidden content hides the page's host view, and a minimized parent hides the page window (occlusion). UNVERIFIED: fully covered window, window on another Space, app hidden, audio in a hidden tab (reaching them needs moving the user's windows or system input).

### Tab lifecycle (tagged `tlnext`, 2dbaac77833, `bench-idle.sh --fresh`, 30 s per case, load average about 275)

| Case | App wakeups/s | App CPU | Daemon wakeups/s | Renderers |
| --- | --- | --- | --- | --- |
| terminals | 0.63 | 0.010% | 0.03 | none |
| chromium-static | 3.07 | 0.242% | 0.03 | 0.33 and 0.93 wakeups/s, under 0.01% CPU |

Within the base range (0.28-0.45 and about 3). The ledger shows only `BusyWatchdog.window:deadline` (0.1/s): the content lifecycle, parked workspaces and hibernation add no periodic wakeup (hibernation arms one one-shot `DemandTimer` for the earliest page deadline, 60 min by default, and listens to the memory pressure dispatch source). chromium-hidden was skipped: its `workspace new` request missed the 2 s control deadline on the loaded machine.

## 8. Status and open items

Landed on feat-cmux-next: primitives 4c2ec798a99; display-link migration, L1 red/green, accept backoff red/green, local PTY hangup, ChromiumWarmup, debug.wakeups, busy watchdog, gate rules, bench (this agent, f2d6ff9e9d2 through the bench commits); reconnect and IO loops ad7db2fa600, 887b84df5ca, 2f862b32b3e; CEF pump 15d83591310, 23289d1437c; cmux-tui dc5cb26c16d, 51b68635143, pin 98d5750d09e; minimize action bd75453ec9b.

Open:
- Past the retry budget, a local daemon that fails with no event (no socket change, no app activation, no network change) stays disconnected until one happens (decision: no timed retry forever).
- Closed (cx-6so.7): a daemon crash loop was limited only by launch time, each new socket a real event that retried at once. After 3 failed attempts that a new socket woke (`RetryPolicy.socketRetries`, until a connection stays healthy) socket changes stop waking the retry loop; app activation, a network change or a reconnect action (`RetryWake.fire`) still retries, one attempt each (red/green DaemonCrashLoopTests).
- Closed: the CEF pump is purely demand-driven with the cmux.7 pin (fork API 7). The follow-up chain remains only for older pins. The remaining idle pump wakeups with a static tab (about 1-2/s) are Chromium's own delayed UI-thread tasks that CEF reports; reducing them is Chromium work, not the pump.
- The events.stream heartbeat (15 s, client-requested) and cmux-tui's backpressure re-check (100 ms, only while a stream is full), coderouter usage poll (5 min, remote API has no push), remote protocol heartbeats and the Windows plugin child-exit check remain.
- The busy watchdog does not know which tab a Chromium renderer serves (the record names the helper kind), and misses a background-thread spin that never wakes the main thread after its first window.
- ControlSnapshotPublisher stacks withObservationTracking registrations (extra work under compat reads, not idle).
- MainActorWorkQueue/ControlDeadline/ControlSnapshot deadlines and the UI one-shot delays still sleep in their own Tasks (reviewed `wakeup-allow`); moving them onto DemandTimer would put them in the ledger.
- The bench's first Chromium tab can miss the 2 s control deadline on a loaded machine (cold CefInitialize); the bench waits for a renderer but that also failed twice.
- UNVERIFIED: fully covered window, window on another Space, app hidden, audio in a hidden tab; cmux-tui remote, browser-proxy and Windows paths (compiled on CI only).

## 9. Idle budget, wake coalescing and Energy Saver (p14-energy)

This section is the design of the chrome-parity program p14-energy as built
([chrome-parity/p14-energy.md](chrome-parity/p14-energy.md) is the full spec, with its done checks D1-D17 in
sec. 5). It has five parts: one budget file that every idle measurement checks, Chrome's delay policy and leeway,
one main-thread timer for every deadline, nothing periodic outside a short reviewed list, and an Energy Saver that
follows Chrome's battery saver. [docs/energy-saver.md](../../docs/energy-saver.md) tells the person what the saver
does. In the tables, "landed" means the task is on perf/chrome-parity; a task number alone is spec'd only.

### 9.1 The budget file

[`scripts/cmux-next/idle-budget.json`](../../scripts/cmux-next/idle-budget.json) (schema v2, p14-energy-002 and
003) is the contract. `scripts/cmux-next/idle-budget.py` measures one or more sessions; with `--gate` it refuses
every value over its limit. It is a check that the agent runs on the fleet in the program's test phase. It is not
a CI gate, and no CI job runs it (Lawrence 2026-10-23).

- Limits per process kind, and per session where a session overrides them: interrupt wakeups/s (`wakeups_per_s`,
  the counter of Chrome's `GetIdleWakeupsPerSecond`, p14-energy-047), main run-loop wakes/s, CPU %, CPU and billed
  energy (mW), GPU ms/s, disk bytes/s, log lines, threads and the Darwin process role. Sum rules (`app+daemon`, the
  tree), ratio rules against Google Chrome (`ratio_to_chrome`, from the `chrome-static` session) and `goals`
  (reported, not judged).
- Kinds: every process of the tree has a kind (`kinds`: app, daemon, holder, terminal-host, acpmux, agent-harness,
  the `cef-*` Chromium processes, the `webkit-*` processes, crashpad, crash-watcher, cua-helper and the others in
  the file). A process with no kind fails `--gate`.
- Sessions: light-webkit, light, light-hidden, minimized, occluded, home, tabs-static, stress-static, stress,
  energy-saver, energy-saver-auto, signed-in, signed-in-display-sleep, app-quit, external-churn, agent-idle,
  agent-working-visible, busy-hidden and chrome-static.
- `--gate` refuses a Debug build and a run whose Energy Saver state (`debug.energy` at the two ends of the window)
  is not the state that the session asks for. A run whose thermal state reached serious or critical is marked
  `thermal_marked` (IDLE-BUDGET-THERMAL) and is not comparable. The gate does not refuse it.
- Counters: since p14-energy-047 (2026-10-25) `wakeups_per_s` counts interrupt wakeups only. Earlier numbers,
  Chrome's included, counted package-idle wakeups two times and are not comparable.
- Measurement (p14-energy.md sec. 4, rule 10): a quiet host (`--max-load 4`), the median of 3 windows, Release with
  `CMUX_BENCH_HOOKS`, the shipping occlusion draw, an activated app and Sentry on. Wakeups/s is the judged number;
  CPU and mW count only on a quiet host.

`allowed_periodic` lists the only periodic wakes that idle code may keep: at most 6 entries, each with a period of
15 s or more, an owner and a reason. `wakeup-audit.py` checks these limits, and a `periodic` escape must name one
of these owners (9.6). The list now:

| Owner | Period | Why it stays |
| --- | --- | --- |
| `ErrorJournalService.harvest` | 300 s | It collects the crash and error reports that other processes write; `NSBackgroundActivityScheduler` runs it (tolerance 120 s), and a run reads the log files and crash reports only when a watched folder changed or a read stopped at its bound; the unified log, which has no change signal, on every run (p14-energy-066a, landed) |
| `GitHubFeedSource.refresh` | 120 s | GitHub has no push for the feed; p14-energy-032 (landed) stops it while no cmux window shows, 066b moves it to `NSBackgroundActivityScheduler` |
| `DeviceHubSocket.ping` | 30 s | The device hub keepalive (PROTOCOL.md); p14-energy-066c sends it only after silence |
| `ControlEventBus.heartbeat` | 15 s | The `events.stream` `include_heartbeats` keepalive, only while a client asks for it and stays connected |

### 9.2 Delay policy and leeway

`DelayPolicy` (DelayPolicy.swift) and `WakeLeeway` (WakeLeeway.swift), p14-energy-011, landed. The policies are
Chromium's (`base/task/delay_policy.h`): `flexibleNoSooner` (the default: never before the deadline, at most the
leeway after it), `flexiblePreferEarly` (at most the leeway before the deadline, never after it: a lease renewal)
and `precise`. Instants are `CLOCK_UPTIME_RAW` nanoseconds, the origin of Chromium's `TimeTicks` on macOS, so a
grid boundary is the same instant for every queue of the app, and for the daemon (`cmux_tui_core::wake::Ticks`).
A wake fires at the first grid boundary at or after its earliest time, but never after its latest time
(`std::min(aligned, latest_time)` in `MessagePump::AdjustDelayedRunTime`).

| Delay and policy | Policy used | Leeway | Grid |
| --- | --- | --- | --- |
| 0 or less | precise (due now) | 0 | none |
| precise, below 36 ms | precise | 0 | none |
| precise, 36 ms or more | flexibleNoSooner (`MaybeOverrideDelayPolicy`, `kDefaultMaxPreciseDelay`) | as flexible | as flexible |
| flexible, below 1 s | as asked | 8 ms (`kDefaultLeeway`); 32 ms in Energy Saver | the same 8 or 32 ms, read at wake time |
| flexible, 1 s or more | as asked | min(10% of the delay, 1 s) | one uptime second |
| hidden (`MainWakeUpQueue.insertHidden`, `MainDeadline` `.whenHidden`) | flexibleNoSooner | 1 s | one uptime second |
| the caller's own tolerance (`WakeLeeway.own`: the CEF pump's delayed requests) | flexibleNoSooner | the tolerance | the tolerance; Energy Saver does not change it |

`Backoff` (p14-energy-015, landed) sleeps with a tolerance of max(8 ms, 10% of the step) and keeps its jitter;
it has no 1 s cap. An off-main `DemandTimer` (p14-energy-012, landed) sleeps with
`clock.sleep(for:tolerance:)` and the table's leeway. The Rust `wake::deadline` (p14-energy-020, landed) gives the
same window from the same table, and `wake::EnergyMode` sets its 8 or 32 ms.

### 9.3 MainWakeUpQueue

`MainWakeUpQueue` (MainWakeUpQueue.swift, MainWakeUpHeap.swift, MainWakeUpTimer.swift; p14-energy-013, 023 and
037, and p06-scheduler 011 and 012, landed) holds every main-thread deadline on one timer, so deadlines that are
close share one wake. It copies the delayed work of Chromium's UI thread (`base/message_loop/message_pump_apple.mm`,
`base/task/sequence_manager/wake_up_queue.h`):

- One `CFRunLoopTimer` on the main run loop in common modes, made once and parked at a far fire date. Each arm is
  `CFRunLoopTimerSetNextFireDate` with the tolerance set first. An arm to the date that is armed now is skipped
  (`delayed_work_scheduled_at_`).
- One heap of the pending entries (`MainWakeUpHeap`), ordered by latest time, in a `Mutex`. `insert` and `cancel`
  work from any thread and re-arm the timer only when the fire date changes; an insert behind the top costs no
  wake. Cancel is O(log n).
- Fire date = min(the earliest flexible deadline aligned up to its grid, the earliest latest time). Precise entries
  are never aligned. The sub-second grid is `EnergyPolicy.wakeAlignment` at wake time; an entry keeps the leeway
  that it was inserted with, as Chrome keeps `PendingTask::latest_delayed_run_time`.
- The timer's callout runs no entry. It queues one common-modes run-loop block, so a nested run loop in an entry
  can not stop the timer (Chromium's `RunDelayedWorkTimer` signalled its work source for the same reason).
- A fire runs the due entries in latest-time order for at most 2 ms (`fireBudget`). The entries that are still due
  run in a continuation armed for now with no tolerance, after the pending input (Chrome's `RunWork` runs one
  `DoWork` batch and signals its source again).
- Hidden entries are in a second heap and run only in a fire at or after their whole uptime second (Blink's
  `WakeUpBudgetPool`), so hidden work never rides a visible fire before its boundary.
- Each fire writes one ledger record `MainWakeUpQueue` `fire`, and one record per owner that ran (`debug.wakeups`).
  `debug.energy` shows the pending entries and `coalescedFires`, the wakes that ran more than one entry.

Users: `MainDeadline` (p06-scheduler 011); `DemandTimer` made with `mainWork:` (p14-energy-014: a main-actor action
runs from the fire with no pool thread, `scheduleOnMain` runs inline, p14-energy-133 moved the sync call sites); the
CEF pump's delayed requests (p14-energy-016: the pump's work runs in its own run-loop block after the cmux entries
of the same fire). No task and no pool thread take part. The thread row is in
[threading-model.md](threading-model.md#threads-and-queues).

### 9.4 Nothing periodic

An idle loop becomes an event (a kqueue vnode or `NOTE_EXIT` source, pidfd, FSEvents, `NWPathMonitor`), a one-shot
deadline (9.2, 9.3), `NSBackgroundActivityScheduler` for maintenance in the app, or in Rust a job on the process's
one `MaintenanceClock` (`cmux_tui_core::wake`, p14-energy-020, landed; no job is registered on it yet, p14-energy-034
moves acpmux's catalog refresh, health view and upload sweep to it). The clock runs every job on a 5-minute
wall-clock grid with a 30 s leeway that the kernel sees (`NOTE_LEEWAY`; `PR_SET_TIMERSLACK` on Linux) and waits with
no timeout while nothing is registered. Jobs that bound data loss after a crash (output store flush and snapshot,
journal checkpoint and maintenance) are refused there: they stay dirty-triggered one-shot `wake::deadline`s. What
can not become one of these goes into `allowed_periodic` (9.1).

### 9.5 Energy Saver

The saver is behind the Labs feature `energySaver`
([schemas/features/features.d/energySaver.json](../../schemas/features/features.d/energySaver.json)), off by default
in dev, nightly and release. While the feature is off the saver never turns on.

Inputs. Only the composition root (`CmuxNextApp`) imports the service target `CmuxNextEnergy` (p14-energy-021,
landed). `EnergyMonitor` holds `EnergyInputs`: Low Power Mode (`LowPowerMode`), the power source
(`PowerSourceMonitor`, an IOPS run-loop source on the main run loop now; p14-energy-058 moves it to a utility queue
that hops to main only on an edge), the battery charge (`BatteryLevel`: current over full capacity; a Mac with no
battery has `hasBattery` false; read from the same IOPS snapshot as the power source) and the thermal state
(`ThermalStateWatch`).
`debug.energy.simulate` (Debug and bench builds, p14-energy-123) lays simulated inputs over these, because fleet
Macs have no battery.

Policy. `EnergyPolicyResolver` (p14-energy-022, landed) is pure: the `energy.saver` setting
(`EnergySaverMode`) and the inputs give on or off and the reason.

| `energy.saver` | On when | Reason |
| --- | --- | --- |
| `auto` (default) | Low Power Mode (plugged in too); or on battery below 20% (strictly, `kLowBatteryThresholdPercent`); or on battery with the thermal state serious or critical, held until the Mac cools to nominal or is plugged in | `lowPowerMode`, `battery`, `thermal` |
| `onBattery` | The Mac runs on battery | `setting` |
| `always` | Always | `setting` |
| `off` | Never | none |

"Turn Off Energy Saver for Now" (action `energy.saver.turnOffForNow`, p14-energy-025) keeps the saver off until the
Mac's own power source goes from battery to AC, or until the setting changes (Chrome's
`SetTemporaryBatterySaverDisabledForSession`). `energy.saver.turnOnNow` ends it before that. `EnergyPolicyDriver`
(p14-energy-024) is the one writer of the app's one `EnergyPolicySource`, which `MainWorkScheduler` owns (`energy`)
and every consumer reaches through its scheduler or an injected closure: there is no shared instance. The driver
publishes nothing until it knows both the setting and the inputs. While the feature is off, Low Power Mode sets
`EnergyPolicy.lowPowerFallback`, so the page consumers that followed Low Power Mode before the saver existed
(`pageSaver`) keep doing so.

`EnergyPolicy` (CmuxNextWakeups, p14-energy-023): `isSaver`, `reason`, `wakeAlignment` (8 ms, 32 ms),
`ambientMaxFPS` (none, 30), `webFrameRate` (none, 30), `pollStretch` (1, 4), `suspended`, `screensAsleep`,
`onBattery` and `lowPowerFallback`.

| Consumer | Under the saver | Task | State |
| --- | --- | --- | --- |
| `MainWakeUpQueue`, `MainDeadline`, `DemandTimer` | Flexible sub-second wakes on a 32 ms grid with 32 ms leeway | 023, 012, 014 | landed |
| `FrameScheduler` `.ambient` clients | At most 30 fps; they stop while the displays sleep. `.motion` clients (every client today) do not change | 028 | landed; no client opted in yet |
| Motion loops (spin, step, sweep, breath, pulse) | The static glyph shows; movement and fades that the person starts do not change | 027 | landed |
| Chromium (`cmux_cef_set_energy_saver`) | Frame sinks at 30 Hz except a page with input in the last 1 s and cmux's own `cmux-page` pages; wake leeway 32 ms (`OverrideAlignWakeUpsState`); `SetBatterySaverMode` on every child process | 029, 030 | landed in cmux; works with a fork pin that has the API (136); `debug.energy` `cef.energySaver` is `applied` (else `unsupported`) |
| Chromium child wake alignment (`--enable-features=AlignWakeUps,BatterySaverModeAlignWakeUps`) | Children align their wakes | 040 | spec'd |
| WebKit render rate, hibernation neighbor radius, page lifecycle | WebKit near 60 fps, no neighbor tab kept awake, hidden cmux pages freeze sooner (`pageSaver`) | 031 | landed |
| Background polls: GitHub feed, error journal harvest, Cloud access asks, web updates | Each wait is 4 times longer | 032 | landed |
| Sidebar footer indicator, hover card with the reason and "Turn Off for Now", palette actions | Shows only while the saver is on | 025, 026 | landed |
| Hidden tabs that use much CPU | Freeze on the next wake (Chrome's `FreezingPolicy` CPU rule) | 039 | spec'd |
| Daemon and acpmux (`energy.set`, `cmux energy`, MCP) | `wake::EnergyMode` flips; skippable maintenance runs at 4 times its period | 033, 034, 137 | spec'd (`EnergyMode` landed with 020) |
| KeepAwake, ghostty-next animation wakes, webviews `data-cmux-energy`, sleep and screen sleep | Shared power source; animation wakes 33 ms or more; static ambient CSS; keepalives parked | 035, 114, 134, 120 | spec'd |
| Settings page row and release-notes highlight | The row is hidden from the page and the palette until then | 129 | spec'd |

The saver never changes the key-to-frame time of native UI, motion that the person starts, the frames of a
Chromium page with input in the last 1 s, cmux's own Chromium pages or terminal output. WebKit browser tabs are the
exception: WebKit has no input exemption, so under the saver every WebKit tab renders near 60 fps, the lowest rate
of its render-rate feature, also the tab that the person types in (p14-energy-031). Done check D8 measures this (bench-typing for a
native terminal and the Chromium composer, split-spring, a Chromium scroll in saver).

### 9.6 Escape vocabulary

Three static checks read the same rules:

- `scripts/cmux-next/check-concurrency.sh` refuses a timer, raw display link, sleep or spin loop in
  `Packages/macOS/CmuxNext/Sources` outside CmuxNextWakeups unless it has `// wakeup-allow: <reason>` (section 2).
- The pre-push guardrail `wakeup-ext` (p14-energy-006, landed) refuses such a hit in added lines of the
  app-linked Shared packages, CmuxUpdater, the cmux-tui crates' `src`, `webviews/src` and the CEF shim and Chromium
  host C++/ObjC, with the closed vocabulary below.
- `python3 -I scripts/cmux-next/wakeup-audit.py --strict` (p14-energy-005, landed) audits the full tree in the test
  phase (done check D1); `--queue` prints the work list, with each hit's shape (`loop` or `oneshot`).

An escape is `wakeup-allow: <word> <reason>` on the statement or in the comment block directly above it. The
reason is required, and the word must match the shape of the code. A reviewer refuses an escape that only passes
the check.

| Word | Use it for | Code shape it needs |
| --- | --- | --- |
| `deadline` | A single deadline: a timeout, a debounce, a delayed show or hide | `oneshot`: it does not run again by itself |
| `backoff` | Retry spacing after a real failure | Capped and jittered, through `Backoff`; the retry waits for an event first |
| `bounded` | A loop or wait that ends: a compare-and-swap retry, a read until EAGAIN, a wait with a deadline | Each pass makes progress or blocks on an event, and a deadline or a count ends it |
| `cli-only` | Code that runs only in a CLI process, never in the idle app or daemon | Not reached from the app, the daemon or a host |
| `fixture` | Test fixtures, galleries and Debug stand-ins | Not in a shipping path |
| `debug` | Diagnostics that a person starts (Debug menu, `debug.*` methods) | Off while nobody uses it |
| `periodic <owner>` | A periodic wake that must stay | `<owner>` is in `allowed_periodic` (9.1) |

`--strict` refuses any other word, an escape with no reason, and a `periodic` escape whose owner is not in
`allowed_periodic`. A periodic loop does not get `tolerance:` to pass: it becomes an event, a deadline or a
`MaintenanceClock` job (p14-energy.md sec. 4, rule 4). The guardrail `timer-class` (p06-scheduler 014) also refuses
a new main-actor `DemandTimer` and new sleep loops (escape `// timer-class-allow: <why>`).

### 9.7 Chrome references

Paths are in chromium/src at main, read 2026-10-25 (p14-energy.md sec. 1 has the quotes).

- Timer and pump: `base/message_loop/message_pump_apple.mm` (one `delayed_work_timer_`, tolerance before the fire
  date, `RunWork` yields to input), `base/message_loop/message_pump.cc` (`AdjustDelayedRunTime`, `kAlignWakeUps`),
  `base/message_loop/message_pump_kqueue.cc` (`NOTE_LEEWAY`).
- Delayed work: `base/task/sequence_manager/wake_up_queue.h` (one wake for a thread's delayed work),
  `base/task/delay_policy.h` (policies, `MaybeOverrideDelayPolicy`), `base/task/task_features.{h,cc}`
  (`kDefaultLeeway` 8 ms, `kDefaultMaxPreciseDelay` 36 ms, `kTimerSlackMac`, `kRunTasksByBatches`),
  `docs/threading_and_tasks.md` (`TaskPriority::BEST_EFFORT` for long delays).
- Background pages: `third_party/blink/renderer/platform/scheduler/common/features.h` and
  `throttling/wake_up_budget_pool.{h,cc}` (1 s wake-up budget, intensive throttling after 5 min).
- Energy Saver: `chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc` (modes, 20%
  threshold, the session off switch, `StartThrottlingAllFrameSinks(30 Hz)`),
  `components/performance_manager/freezing/freezing_policy.cc` (`kFreezingHighCPUProportion`),
  `content/child/child_thread_impl.cc` and `content/public/common/content_features.cc`
  (`SetBatterySaverMode`, `kBatterySaverModeAlignWakeUps`, disabled by default).
- Power and processes: `base/power_monitor/power_monitor.h`,
  `components/power_monitor/battery_state_sampler_mac.cc` (IOPS notification, no timer on Mac),
  `base/process/process_mac.cc` (`Process::SetPriority`), `base/process/process_metrics_apple.mm` (interrupt and
  package-idle wakeups), `base/threading/hang_watcher.h` (one hang watcher per process).

### 9.8 Where cmux differs from Chrome

| Chrome | cmux | Why | Task |
| --- | --- | --- | --- |
| Every delayed task has an 8 ms leeway | Flexible delays of 1 s or more align to whole uptime seconds with min(10%, 1 s) of leeway | Most cmux deadlines are debounces, retries and timeouts of seconds, which an 8 ms grid never puts in one wake (Apple's Energy Efficiency Guide, Blink's 1 s pool) | 011, landed |
| `kBatterySaverModeAlignWakeUps` (32 ms) is an experiment, disabled by default | 32 ms alignment is on whenever the saver is on | Fewer wakes in saver; flexible wakes only, never precise ones | 023 landed, 029/030 landed, 040 |
| The saver turns on from the pref, the power source and the battery level | `auto` also turns on in Low Power Mode, and on battery when the Mac is serious or critical, held until nominal | The person asked macOS to save power; a hot Mac on battery drains fast. Thermal never turns it on while plugged in, so builds and benches do not change | 022, landed |
| `StartThrottlingAllFrameSinks` throttles every frame sink | Pages with input in the last 1 s and cmux's own pages keep their frame rate; Chrome's own battery saver can not turn on inside CEF | Typing and scrolling are never slowed (D8); cmux is the one writer of the throttle | 029, 030, landed |
| A batch of UI tasks runs for up to 8 ms (`kRunTasksByBatches`) | A queue fire runs for at most 2 ms, the CEF pump slice too | A quarter of a 120 Hz frame, so input runs between | 037, landed |
| Blink runs throttled tasks that fall due in the 3 ms after a wake-up | Hidden entries wait for their own whole second | A hidden owner that re-arms runs at most once per second | p06-scheduler 012, landed |
| No app-level polls | Background polls stretch 4 times in saver | cmux has polls that Chrome does not have | 032, landed |
| Power notifications are handled on the UI thread | Power inputs arrive on a utility queue; main hears only an edge | Fewer main wakes on battery | 058 |
| The browser process can not App Nap | The Chromium Host may App Nap while every page it hosts is hidden; idle agent harnesses of hidden sessions freeze | The same rule as `FreezingPolicy`, applied to processes Chrome does not have | 128, 117 |

## 10. Hidden main wakes (p14-energy-095)

speed-of-sound-DESIGN.md sec. 5/7 measured the Release app's main thread at 107 wakes/s while the app was hidden,
more than in view (cmux20). This section names who wakes it. No source changes here; the fixes are Q9 tasks
(p14-energy-092 and the other Q9 slots), one per `HIDDEN-WAKE` owner of basis `callout-count`.

### Method

`scripts/cmux-next/idle-budget.py --sessions light-hidden,minimized` launches each session in the shipping
measurement mode of p14-energy-100 (`bench_launch.shipping_env`: shipping occlusion draw, Sentry and hang reports
on, no `CMUX_NEXT_NO_ACTIVATE`) and activates the app once. The mode needs p14-energy-100 on the measured commit:
without it the app ignores `CMUX_NEXT_BENCH_SHIPPING_DRAW`. The session then hides the app (Show/Hide All Windows
`hidden=true`; the action toggles, so it needs the activation) or minimizes its window (`minimizeWindow`), settles,
and measures one window with no input.

A hidden-wake session fails (`IDLE-BUDGET-SESSION-FAILED`) and prints no `HIDDEN-WAKE` line when:

- the build has no sha (`bench_launch.build_sha`: Info.plist `CMUXCommit` or `CMUX_CI_SHA`), checked before the launch;
- the hide or minimize action replies with an error;
- `debug.window_list` at the start or the end of the window, or after the wake trace, shows a visible main window
  (light-hidden) or a main window that is not miniaturized (minimized).

When p14-energy-100's applied fields do not confirm the shipping app (not activated, `draws_when_occluded`, no
Sentry thread, no main-thread watchdog), or when atos did not name a callback of a counted source (`atos failed: N
callbacks unnamed`), the source lines are `HIDDEN-WAKE-UNCONFIRMED`, and no Q9 task comes from them.

Right after the window (a 1 s quiet gap, then the trace, then the hidden-state check, then `/usr/bin/sample`, so the
sample tool's suspensions never precede the trace), three bases count wakes and one names frames. A source can show
under several bases, so each basis is its own list and they are never added:

| Basis | What it reads | per_s |
| --- | --- | --- |
| `callout-count` | DTrace on the main thread for `--wake-trace` s (30), its span from `BEGIN` (after the probes are enabled) to `END`. A wake is a return from a run-loop wait that can block (`__CFRunLoopServiceMachPort` with a timeout other than 0). Each wake goes once to the first non-observer callout after it, keyed per item: a timer by callback and `CFRunLoopTimerRef`, a source by perform function and info, a block by its invoke, and each main-queue drain item by its dispatch function, block invoke or Swift job resume function | wakes/s over the trace span (the rows and `no-callout` add up to the traced wakes), with `calls_per_s` (callout entries/s) beside it. Owner (`owner_from`): `callback` when atos names it in an owner image; `timer` when the run-loop timer at the same address has a naming callout; `item-stack` from the item's own 997 Hz stacks (`multiplexed` when they show several owners: their shares are time, not rates); else `none` |
| `unattributed` | with a trace, its wakes no callout claimed before the next wait (`CFRunLoopWakeUp` with no work, a wait timeout), on the same span; without a trace, the window's main wakes less the run-loop timer fires, both over the window | wakes/s no counted source covers |
| `run-loop-timer` | the main run loop's `CFCopyDescription` at both ends of the window: each repeating timer's next fire date advances one interval per fire, by timer address; an `__NSFireTimer` timer is "unnamed NSTimer" (its callout names Foundation) | fires/s (upper bound under App Nap); a timer at one end only is `unpaired` with per_s null |
| `ledger` | `debug.wakeups` owners (DemandTimer, FrameScheduler, Backoff), every owner | fires/s on any thread (`thread: any`) |
| `sample-time` (`HIDDEN-WAKE-FRAME`) | 3 x `--sample` s (10) of `/usr/bin/sample`, added: below each outermost callout, the first frame in an owner image (images are OS by their `Binary Images:` path: /System, /usr/lib), wait frames dropped, OS-only samples to the first non-trampoline frame on their own path | null: samples measure time, not wakes; share of callout time only, no floor |

DTrace's pid provider needs root (`sudo -n`) and a process it may trace; atos runs with the same right. When
DTrace can not run, the `HIDDEN-WAKE-TOTAL` line has `trace.ok: false` with the reason, and the uncounted wakes are
in `unattributed`. The `debug.hangs` main wakes around the dtrace run (`trace.rpc_main_wakes_per_s` over
`trace.rpc_seconds`, which include dtrace's start and exit) are given beside the traced rate, never subtracted from
it. Callback addresses are OS or owner by the sample report's `Binary Images:` ranges, so that decision never rests
on atos.

Observers (`__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__`) run on every wake that another source
causes, so they are listed (`HIDDEN-WAKE-OBSERVER`) and never counted as a cause. This is the split Chromium's
`MessagePumpCFRunLoopBase` makes (base/message_loop/message_pump_apple.mm: a work source and a delayed-work timer
wake the loop, observers only bracket it). The per-item key follows Chrome's TaskAnnotator, which keys each task by
its own `posted_from` location (base/task/common/task_annotator.cc), not by the pump that runs it.

Output for each hidden session: one `HIDDEN-WAKE {json}` line per source above 0.1/s and basis (`session`, `basis`,
`owner`, `owner_from`, `kind`, `per_s`, `calls_per_s`, `item`, `top` frame), `HIDDEN-WAKE-FRAME` and
`HIDDEN-WAKE-OBSERVER` lines, and one `HIDDEN-WAKE-TOTAL` line with the build `sha`, `host`, main wakes/s, the
trace's state and span, `unattributed_per_s`, `unnamed`, `samples_taken`, `sources_by_basis`, `confirmed` and
`problems`. The JSON report keeps them under
`sessions.<session>.hidden_wake`.

Run (Q9, a quiet fleet host, Release with bench hooks):

    cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
      --ref <sha> --arg=--suite=idle-budget --arg=--config=bench --arg=--sessions=light-hidden,minimized

(No `--` before `--sessions`: idle-budget.py reads its options with argparse, which takes every word after
`--` as a positional argument and would run the default sessions.)

### Report

Not measured yet, so p14-energy-095 is not done. It stays open until the Q9 run of the command above, on a
Release build with bench hooks, fills this table: sha, host and every `HIDDEN-WAKE` line above 0.1/s for both
sessions, with `confirmed: true`, `trace.ok: true` and `unnamed: 0`. Until then, the 107/s figure has no named owner.

| Session | sha | host | main wakes/s | basis | owner | kind | per_s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| light-hidden | | | | | | | |
| minimized | | | | | | | |
