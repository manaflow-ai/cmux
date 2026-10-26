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
  per call site (`#fileID:#line`; two seam calls on one line share a site). Debug: one unified-log line per call site
  (`log stream --predicate 'category == "blocking"'`), the Debug menu's "Main-Thread Blocking (N)" and the
  `debug.blocking` socket command; launch with `CMUX_BLOCKING_TRAP=1` to stop at the call (a contended `Mutex`
  wait is always recorded only: it is measured on the wall clock). Bench builds (`reload.sh --config bench`,
  `-DCMUX_BLOCKING_CHECKS`): recorded for `debug.blocking`, never a trap. Nightly: to come with the
  `nightly.yml` flag and PL-telemetry's hang-report sink (kind + image UUID + offset frames only, no paths or
  names); it will never trap and has no log or menu. Release: compiled out.
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

## Threads and queues

The QoS column is what the code sets today; the target model is "QoS and task priority" below (PL-qos owns it
and changes both with the code).

| Thread / queue | Owns | May block on | QoS | Bound and back-pressure |
|---|---|---|---|---|
| **Main thread** (AppKit, SwiftUI, Ghostty app tick; the CEF UI thread only with the in-process backend, through the external message pump `CEFMessagePump`) | All UI state, `@MainActor` models, CA commits; CEF browser-process UI work only in process. In host mode (`browserHost.helper`, on in DEV from p01-process task 100) the main thread is **not** the CEF UI thread: the app does not map the CEF framework and runs no pump (tasks 101, 102); Chromium's UI thread is the Chromium Host's main thread (row "Chromium Host") | Nothing. Only reviewed `allowBlocking` reasons below. In process only: CEF's `CefDoMessageLoopWork` slice is 2 ms (`cmux-pump-time-slice-us`). In host mode no call to the host waits: posts, a main-only mirror cache and async replies (p01-process section 4 rule 1) | user-interactive (system) | Input first; everything else through the scheduler below |
| **Main-thread scheduler** (`CmuxNextWakeups`: `MainWorkClass` input > frame > visible > automation > background; `MainFrameBudget`; `FrameBatchQueue`; `MainActorWorkQueue` for control-socket work; owner PL-main) | Order and per-frame budget of main-thread work | Never | main | Budgets per frame: visible 2.5 ms, automation 1 ms, background 0.5 ms (4 ms of an 8 ms target); over budget: the rest runs next frame (no drop). `MainActorWorkQueue`: 1024 pending, 256 per connection; full: the request fails `busy`; expired: `timeout`, never runs |
| **Frame clock** (`FrameScheduler`: one `CADisplayLink` per window on the main run loop; `MotionClock`, `DisplayLinkDriver`, `DemandTimer` on it) | Frame ticks for clients | Never | main | One link per window, dropped when no client is active; rebuilt after 3 stalls of 100 ms |
| **Main-thread watchdog** thread `cmux-next main-thread watchdog` | Stall/hang detection and stack samples | Its own kqueue (`MainThreadWatchdogAlarm`: a one-shot timer the main thread arms when its run loop wakes and deletes before it sleeps, and a user event for stop and task starts); a main turn shorter than the timer wakes it never | user-interactive | Rings of 128 hangs and 128 over-budget entries |
| **Daemon connection** reader thread `cmux-tui reader <path>`; writer queue `com.cmuxterm.next.daemon.write`; `actor DaemonConnection`; `EventInbox` pump task | Socket read and line split; outbox drain; handshake and reconnect; off-main event buffer | Blocking `read(2)` (reader); `write` (writer) | user-interactive (reader), default (writer) | Line over 64 MiB closes the connection; outbox 64 MiB, past it `write` fails `.backlog`; inbox 4096 events, field events coalesced, overflow collapses to one resync; main drains 32 per slice under the visible budget |
| **Terminal attach** (`TerminalAttachment` reader → `TerminalEventQueue`) | One terminal's output stream | The reader waits above 8 MiB queued, resumes below 2 MiB | user-interactive | The daemon's attach mailbox overflows and ends the stream |
| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | Feeding `ghostty_surface_process_output`; local PTY I/O | PTY read/write | user-interactive | 2 MiB high water: the consumer task suspends |
| **Ghostty renderer and IO threads** (per surface, inside GhosttyKit) | Rendering; termio | Renderer mailbox (64, latest-value-wins, never waits); termio queue 64 | focused user-interactive, visible user-initiated, hidden utility | cmux runs surfaces in manual IO mode: no Ghostty read thread |
| **Swift cooperative pool and actors** (`actor`s that own I/O: daemon, cloud, remote, stores; `Task.detached` at `.utility`/`.userInitiated`) | Async I/O and domain state off main | Nothing (never a blocking call on the pool; blocking work belongs on a dedicated thread or queue) | the task's priority | Each actor's own stream bounds (`AsyncStream` with a buffering policy, never `.unbounded`) |
| **DispatchSource handlers** (control socket `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; file watchers; process and signal sources) | Event delivery only | Non-blocking reads | as the queue | Coalesced by the source; main-queue sources only hop |
| **Hang watch** (p09-observability, owner PL-telemetry). App: the `HangWatch` slots in CmuxNextTrace, read by the hang monitor on the existing `cmux-next main-thread watchdog` thread's kqueue (no new thread). Rust: one `cmux-hang-watch` thread per process (cmux-hang-watch crate: daemon, holder, terminal host, acpmux) | Watched threads' and lanes' deadlines; the hang record and stack sample of an overdue slot | Its kqueue (app) or a `Condvar` (Rust). Sampling: between `thread_suspend` and `thread_resume` it only reads registers and stack memory into a preallocated buffer, no lock and no allocation | user-interactive (app, the watchdog's); default (Rust) | Opening or closing a scope is two atomic stores, no system call. One one-shot timer per minimum deadline while scopes open (at most 1 wake/s at 1 s); parked after one quiet minimum-deadline period (0 wakes at idle), the first open after that posts one wake. A watcher that wakes over 100 ms late blames nobody. One hang record per overdue scope |
| **Trace ring adoption** (p09-observability, owner PL-telemetry). App: a `BackgroundWork` `.files` job at launch and at `trace.start` (no new thread). Rust: one `cmux-trace-open` one-shot thread per process at start | Moving the heap ring into its file: rename the spare file or create one, `mmap` `MAP_SHARED`, copy the heap records, swap the ring pointer; delete dead-pid rings older than 3 days | Disk (open, `ftruncate`, `mmap`, rename, unlink) | utility | Once per process start and once per recording start; the writers keep writing the heap ring until the swap, never wait for it; an `mmap` failure keeps the heap ring and is counted; a recording mapping is never unmapped while the process lives; the directory is capped at 16 MiB |
| **Blocking detector drain** `com.cmuxterm.app.next.blocking-drain` | Resolving violations to image UUID + offset; the Debug log line; the sink | Nothing | utility | Ring of 64 new sites, 128 sites per launch; past either: counted in `overflow` |
| **cmux-tui daemon (Rust)** request path: `mux-server` accept, one `mux-conn` thread per connection (max 64; over: `server.busy`), `mux-control-dispatch` per connection, `mux-line-out` writer (`mux-conn`, `mux-line-out` and `mux-events-out` become the one `mux-io` thread, p01-process task 203; row "Process-model threads") | Requests, model, snapshots | Socket read on its own thread | not set (PL-qos) | Per connection 256 requests / 16 MiB (over: error, not run); outbound 256 per stream, 4096 per connection (over: the largest stream ends); write timeout 2 s; event bus 4096 per subscriber, then disconnect. Rules D1-D8 in perf-lead.md |
| **Journal writer** `mux-session-journal-writer` (+ `-fanout`, maintenance, hook workers) | Durable session journal | Disk | not set (utility once no request path waits on its durable commit, p01-process task 139) | `sync_channel(1024)` terminal, `(256)` durable: the producer waits for space; durable wait deadline 30 s |
| **Effect / terminal work** (`mux/resource_effects.rs` intents through the journal writer; `mux-terminal-work` pool, 8 workers) | Registry commits; terminal jobs | Disk (writer side) | not set | 1024 queued jobs; a job that does not fit runs inline |
| **Per-stream lanes** | Not on feat-cmux-next yet (PL-conn, `pl-conn`) | | | Added here when it lands |
| **Holder** (`cmux-holder`, one `poll` loop; daemon side `holder-link`) | PTYs that outlive the daemon | `poll` | not set | 1 MiB ring per terminal, 1 MiB link queue, 512 KiB credit window; daemon attached: the holder stops reading the PTY (the shell blocks); no daemon: the ring keeps the newest bytes |
| **acpmux** (tokio multi-thread; `acpmux-socket-read` / `-write` bridges) | Agent sessions | Socket I/O on its runtime | not set | In 256 / out 4096 per connection, full outbox drops (`try_send`), oversized notices become `_acpmux/lagged`; hub broadcast 8192 with `lagged {dropped}`. Owner PL-acpmux (cmux-4f) |
| **Chromium, in process** (fallback backend until Release parity, p01-process task 102: UI thread = the app's main thread; Chromium's own IO and worker threads in the app; renderer, GPU and utility helper processes; out-of-process host prototype `com.cmuxterm.chromium-host.read` / `.exit`) | Web pages | Chromium's IO thread blocks on its own sockets, never the UI thread | Chromium's | Child exits on `com.cmuxterm.app.next.cef-children`; host prototype: 256 KiB send buffer, 4096 frames, over: the connection ends |
| **Chromium Host, cmux side** (host mode, p01-process): control reader `com.cmuxterm.chromium-host.control` (task 012), supervisor exit watch `chromium-host.supervisor` (task 080, replaces the prototype's `com.cmuxterm.chromium-host.exit`); the input ring writer runs on main and owns no thread (task 041) | Control replies and events from the host; the host's exit | Blocking `read` (control reader); kqueue `NOTE_EXIT` + `waitid(WNOWAIT)` (supervisor) | user-initiated (control), utility (supervisor) | Control: 256 KiB or 4096 pending; over: state ops coalesce by `(op, browser)`, keys and clicks wait in a cmux-side queue, `quota_excess` counts; never blocks main. Events reach main once per frame under `MainWorkClass.visible`. A bad frame ends the host. Every pending token resolves `.hostGone` in the exit turn (task 091) |
| **Chromium Host process** (`<Product> Chromium Host`, a second executable of cmux.app, p01-process): its main thread is Chromium's browser UI thread (`CrBrowserMain`, `CefRunMessageLoop`); host threads cmux code starts: `chromium-host.input` (input ring reader, task 041), `chromium-host.control` (control reader, task 012, names the prototype's unnamed `ReadWire` thread), `chromium-host.hang-watch` (task 084), `chromium-host.provider-link` (agent DevTools to the daemon, task 233); Chromium's own threads (`Chrome_IOThread`, `ThreadPool*`, `Cr*`) | Chromium's browser process; input dispatch on Chromium's user-input queue (`cmux_shim_post_user_input_task`); hang scopes | Main: nothing but Chromium's own run loop. Input: a kevent workloop on the Mach-port doorbell. Control: blocking `read`. Hang watch: a one-shot deadline, parked with no deadline while no scope is open | user-interactive (main: `posix_spawnattr_set_qos_class_np` at spawn, task 222, never a QoS clamp; input), user-initiated (control), default (hang watch, as Chromium's `HangWatcher` thread, `base/threading/hang_watcher.cc`), utility (provider link) | Input ring 4096 x 64-byte frames; full: keys and clicks spill to the cmux-side queue, moves and wheel coalesce in one slot. While cmux is active the host holds `NSActivityUserInitiated` plus `NSActivityLatencyCritical` (task 222). Host UI-thread hang: banner in cmux at 2 s, hang report over 250 ms, dump at 10 s |
| **Process-model threads** (cmux-tui daemon and holder, p01-process; QoS set by task 139 through `cmux-threads`): `holder-link` (exists today, no QoS yet), `vt-pool-v-<N>` and `vt-pool-h-<N>` (tasks 120, 124), `pty-writer` (task 123), `child-exit` (task 207), `mux-io` (task 203), `browser-runtime-events` and `browser-runtime-worker-<N>` (task 206, replace `browser-surface-<id>-*`) | Holder link: DATA into per-shard queues. VT pool: parsing, visible group and hidden group. PTY writer: every master's pending bytes, key lane first. Child exit: every daemon child's exit. mux-io: every connection fd. Browser runtime: CDP events by surface, an ordered lane per surface | holder-link and mux-io: their own `poll`/kqueue (epoll on Linux); pty-writer: `poll` for POLLOUT; child-exit: kqueue `EVFILT_PROC` (pidfd + epoll on Linux); VT pool and browser workers: their queues, never I/O | user-initiated (holder-link, `vt-pool-v-<N>`, pty-writer, mux-io, browser runtime), utility (`vt-pool-h-<N>`, child-exit) | Visible group min(4, P-cores / 2) threads, hidden group 1-2; parse slices of 64 KiB or 1 ms, requeued, so a hidden flood delays a visible chunk by at most one slice. Per-shard queues bounded with the holder's credit as ACK. 200 idle CLI connections add <= 2 threads (mux-io); 20 browser surfaces add <= 2. Steady and peak daemon threads <= 64 with 172 terminals (done check 13) |

## QoS and task priority (PL-qos, 2026-10-24)
One priority model. Main thread: MainWorkClass (PL-main). Off main: WorkPriority, derived from it (CmuxNextWakeups).

| WorkPriority | from MainWorkClass | GCD QoS | Swift TaskPriority | Use |
|---|---|---|---|---|
| userBlocking | input, frame | userInitiated | high | a person waits now: the result of a key, click or open; omnibar DNS |
| userVisible | visible | default | medium | shows on screen soon: icon, thumbnail, a file a page shows |
| bestEffort | automation, background | utility | utility | saves, agent/CLI/MCP work off main, gh/git polls |
| idle (opt-in) | none | background | background | nothing ever waits: indexing, telemetry upload, prefetch, cache cleanup. Never the journal, quit work, or anything a UI path awaits later |

userInteractive: only the main thread and threads a frame waits for. Today: MainThreadWatchdog, QuitDeadline and
CrashDeadline threads, LineTransport reader (daemon lines), LocalPTY read queue, TerminalOutputLane queue,
MetalYUVRenderer. No BackgroundWork lane runs at it.

Blocking work never runs on the cooperative pool: a process wait uses AsyncProcess (no thread waits); file I/O uses lane
.files (serial per priority); a sync system call (getaddrinfo, Security, Launch Services, AX) uses lane .system (6 at
once, Chrome kDefaultMaxSystemTasks); long CPU work uses lane .cpu (P-cores minus 1). ShutdownBehavior: skipOnShutdown
(default), continueOnShutdown, blockShutdown (quit awaits BackgroundWork.shutdown()).

Donating waits (allowed for a short main-thread wait): os_unfair_lock, OSAllocatedUnfairLock, CmuxNextCompat.Mutex,
dispatch_sync onto a serial queue (GCD sync QoS override), awaiting a Task value (Swift escalation), BackgroundWork.run
(boost at the call; macOS 26+ also on a later escalation). Non-donating (never on a hot main-thread path):
DispatchSemaphore.wait, DispatchGroup.wait, NSCondition.wait, Rust std mpsc/Condvar waits. BackgroundWork has no
synchronous wait.

Guardrail `task-priority` (pre-push): a new Task.detached names priority:, DispatchQueue.global names qos:,
DispatchQueue(label:) names qos: or target:. Escape `// qos-allow: <why>`. A plain Task { } is not counted. Rule (c) (a
blocking call inside a Task) follows PL-blocking's BLOCKING_* list.

Daemon: no cmux-tui thread sets a QoS yet. The journal writer stays at the default QoS while request paths wait on its
durable commit (PL-daemon is removing that wait; then writer = utility, request threads = userInitiated).

Blocking rule for the two "donating waits" above (lead decision 2026-10-24): a short `Mutex` critical
section on the main thread is allowed (a contended wait over 2 ms is recorded), but a `dispatch_sync` from the
main thread (`blockingSync`) is still reported: the QoS override bounds the inversion, yet the main thread
still waits for everything queued before it on that queue.

## Registered threads and queues

A new thread or queue in `Packages/macOS/CmuxNext/Sources` needs its label here (the `thread-doc` guardrail
matches the label's literal text; `<x>` matches an interpolation). Its owner row above says what it may block on.

- Main and frame: `cmux-next main-thread watchdog`, `cmux-next quit deadline`, `cmux-next crash deadline`
- Daemon: `cmux-tui reader <path>`, `com.cmuxterm.next.daemon.write`, `com.cmuxterm.next.daemon.path.<machine>`,
  `com.cmuxterm.next.daemon.exit.<pid>`, `com.cmuxterm.next.retry-wake`, `com.cmuxterm.next.process-progress`,
  `com.cmuxterm.next.process.<name>` (one `ProcessRun`, at the run's `WorkPriority` QoS)
- Control: `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`
- Terminal: `com.cmuxterm.next.terminal.output`, `com.cmuxterm.next.localpty.read`, `com.cmuxterm.next.localpty.write`
- Settings and files: `com.cmuxterm.next.settings.watcher`, `cmux.files.fsevents`, `cmux.files.tree-fsevents`,
  `com.cmuxterm.home.cache` (the `HomeCache` actor's executor, user-initiated: its file writes block this queue,
  never a pool thread, so the forced quit's last draft write runs with the pool full; CmuxHomeCore, shared with iOS)
- Remote and mobile: `com.cmuxterm.next.remote-localhost`, `com.cmuxterm.next.cloud-browser-proxy`,
  `com.cmuxterm.next.remote-fetch`, `cmux.remote-view.render`, `cmux.remote-view.rd-transport`,
  `cmux.remote-view.mock-host`, `cmux.next.mobile.unix-lane`
- Browser: `com.cmuxterm.next.browser-host.provider.write`, `cmux browser-host provider reader`,
  `com.cmuxterm.chromium-host.read` (user-initiated), `com.cmuxterm.chromium-host.exit` (utility),
  `com.cmuxterm.app.next.cef-children`, `com.cmuxterm.import-history-sync`,
  `com.cmuxterm.chromium-runtime.download` (the runtime download's URLSession delegate queue, utility, serial),
  `cmux-next webkit setup probe` (utility; WebKitSetupGate's one sandbox-extension request)
- Agents: `com.cmuxterm.app.next.agent-pane.prompt-journal`, `com.cmuxterm.app.next.agent-pane.inbound`,
  `cmux.next.agent-pane.acpmux-exit.<pid>`, `cmux.next.agent-pane.acpmux-log-progress`,
  `cmux.next.agent-pane.acpmux-launch-reap.<pid>`, `cmux.next.agent-pane.acpmux-status`, `cmux.acpmux.checked-line`,
  `cmux.agent-activity.socket`, `com.cmuxterm.app.next.chief-settle`, `com.cmuxterm.app.next.tasks.socket`,
  `com.cmuxterm.app.next.agent-pane.socket` (the agent pane's URLSession delegate queue, user-initiated, serial),
  `com.cmuxterm.app.next.agent-pane.pull-request` (gh reads for the header chip, utility, 2 at once),
  `cua-helper-v2-reap` (utility), `cua-helper-v2-stdout` (utility)
- Diagnostics: `cmux-next.hang-episodes`, `cmux-next.hang-episodes.symbols`, `com.cmuxterm.app.next.run-marker`,
  `com.cmuxterm.app.next.crash-forwarder`, `com.cmuxterm.app.next.owner-panic-forwarder`,
  `com.cmuxterm.next.typing-probe`, `com.cmuxterm.app.next.blocking-drain`, `com.cmux.host-pressure`,
  `debug.window_record`
- Trace and hang watch (Rust thread names, p09-observability; the app adds no thread): `cmux-hang-watch`,
  `cmux-trace-open`
- Chromium Host, cmux side (p01-process): `com.cmuxterm.chromium-host.control` (user-initiated),
  `chromium-host.supervisor` (utility)
- Chromium Host process (ObjC++, p01-process): `CrBrowserMain` (user-interactive: the host's main thread, Chromium's
  UI thread), `chromium-host.input` (user-interactive), `chromium-host.control` (user-initiated),
  `chromium-host.hang-watch` (default), `chromium-host.provider-link` (utility). Chromium's own threads in the host
  and in its helpers are Chromium's and are not listed one by one: the census judges only the host threads whose
  names start with chromium-host. or com.cmuxterm., plus its main thread
- Process model (Rust thread names, p01-process): `holder-link` (not set today; user-initiated with task 139),
  `vt-pool-v-<N>` (user-initiated), `vt-pool-h-<N>` (utility), `pty-writer` (user-initiated), `child-exit`
  (utility; task 207 replaces the per-scope `cmux-child-exit` threads of unix_process_scope.rs), `mux-io`
  (user-initiated), `browser-runtime-events` (user-initiated), `browser-runtime-worker-<N>` (user-initiated)
- Launch and misc: `cmux-next resource bundle warm-up`, `cmux-next launch warm-up`, `cmux.updates.network`,
  `cmux.home.fixture.video`, `cmux.home.promised-files` (a drop's file promises, user-initiated: the person
  waits for the dropped files)
- Every `Thread` and `OperationQueue` sets `name` and `qualityOfService` before it starts; every URLSession
  gets a named delegate queue. None is unnamed.
- A label followed by parentheses whose first word is a QoS class names the class the thread runs at, spelled
  as cmux-threads' ThreadQos::as_str spells it (background, utility, default, user-initiated, user-interactive).
  process-model-census.py --check-thread-doc (p01-process task 004) reads these pairs. It fails when a live
  thread whose name matches a label with a QoS runs at another class, or when a thread with a p01-process label
  (the Chromium Host and process-model lines above) is not listed. Rust threads named before the program (about 300
  names in cmux-tui, most without a QoS yet: p02-threads moves them onto `cmux-threads`) are not listed one by one;
  the census reports them as unlisted and does not fail on them. The guardrail's thread-doc rule reads the same
  labels for Swift only.

## Reviewed blocking allowances

`allowBlocking(<reason>)` lets the main thread block for one of these reasons only (Chrome's
`ScopedAllowBlocking` friend list). A new `BlockingAllowance` needs a row here in the same push. It is not for
hot paths: in Debug and bench builds (and Nightly, to come) each outermost scope adds and removes one `CFRunLoopObserver` (it
holds the allowance back while a nested run of the main run loop runs other work).

| Reason | Why the wait cannot move off the main thread |
|---|---|
| `terminate` | `applicationWillTerminate(_:)` runs on the main thread and the process exits right after it: a bounded final flush there cannot delay a frame (Chrome allows blocking during shutdown the same way). |
