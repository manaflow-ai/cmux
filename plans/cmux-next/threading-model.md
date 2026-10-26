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
  The same seam call on a shared pool thread (the Swift cooperative pool, `Task.detached`, an actor, a GCD root
  queue such as `DispatchQueue.global`) is a violation too, recorded at its own `pool` site (`debug.blocking`
  `context`, `contexts.pool`; not in the Debug menu); launch a Debug build with `CMUX_BLOCKING_TRAP_POOL=1` to
  stop at it. A `BackgroundWork` `.files` or `.system` item, a named queue, a named thread and `allowBlocking` may
  block. A `.cpu` item may not (the lane is sized to the cores): a seam in it records a `wrong-lane` site in the
  `cpu-lane` context, with the seam's own kind as its `seam_kind`, never a trap; run the item on `.files` for
  `file-io`, on `.system` for any other seam kind (p02-threads task 015). The pool
  is found by the queue label (the `com.apple.root.` prefix, which the cooperative pool's queues share, on a
  thread with no pthread name), which is libdispatch's, not API (p02-threads task 005).
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
| **Main thread** (AppKit, SwiftUI, CEF UI thread via the external message pump `CEFMessagePump`, Ghostty app tick) | All UI state, `@MainActor` models, CA commits, CEF browser-process UI work | Nothing. Only reviewed `allowBlocking` reasons below. CEF's `CefDoMessageLoopWork` slice is 2 ms (`cmux-pump-time-slice-us`). | user-interactive (system) | Input first; everything else through the scheduler below |
| **Main-thread scheduler** (`CmuxNextWakeups`: `MainWorkClass` input > frame > visible > automation > background; `MainFrameBudget`; `FrameBatchQueue`; `MainActorWorkQueue` for control-socket work; owner PL-main) | Order and per-frame budget of main-thread work | Never | main | Budgets per frame: visible 2.5 ms, automation 1 ms, background 0.5 ms (4 ms of an 8 ms target); over budget: the rest runs next frame (no drop). `MainActorWorkQueue`: 1024 pending, 256 per connection; full: the request fails `busy`; expired: `timeout`, never runs |
| **Frame clock** (`FrameScheduler`; `MotionClock`, `DisplayLinkDriver`, `DemandTimer` on it). `DisplayClock` (p03-rendering-010) holds one link per display and every `FrameScheduler` (window, app, budgeted) subscribes to it; with feature `vsyncHub` (p03-rendering-014, off by default) that link is the `VSyncHub`'s, and its ticks reach main as one coalesced post per vsync | Frame ticks for clients | Never | main | One link per display with an active client, 0 at idle; one stall timer per display; a link is rebuilt after 3 stalls of 100 ms (through the hub: `VSyncHub.rebuildLink(display:)`, so the display's off-main subscribers move to the new link too) |
| **VSyncHub** thread `cmux-next vsync <display>`, one per display that got a link (`CmuxNextWakeups/VSyncHub.swift`, p03-rendering-014, feature `vsyncHub`, off by default; Chrome `ui/display/mac/ca_display_link_mac.mm` and `display_link_mac.mm`) | The display's only link, added to its own run loop; its subscriber list (a `Mutex`, held only to copy or change it, never across a callback); off-main `Sendable` vsync callbacks (Ghostty surfaces after p03-rendering-083) and the main fan-out of `DisplayClock` | Nothing: a callback that blocks is a bug. It never touches a layer whose superlayer belongs to an `NSView` | user-interactive (a frame waits on it; `// qos-allow:`) | The thread starts with the display's first link: a display with no screen (`DisplayClock.noDisplay`, a gone screen) gets no thread, however often its link is retried. The link runs while a subscriber is armed, at the fastest rate an armed subscriber asked for, and is paused while none is (`debug.wakeups` `vsync.live_links` counts the displays with an armed subscriber, `vsync.paused_links` the paused ones); it goes with the display's last subscriber, and the thread stays, asleep in its run loop. A paused link is kept, as Chrome keeps a `DisplayLinkMac` while a consumer holds it and only stops its `CADisplayLink` when the last `VSyncCallbackMac` unregisters, so an arm needs no main hop to make a link. Producers arm on dirty content and a tick that returns `.done` disarms them (an arm during the tick wins). Main gets one coalesced tick post (`MainRunLoopBlock`, common modes), at most one pending: a newer vsync replaces a pending one. Hop: `vsync.main_hop_p50_ms` / `main_hop_p99_ms` (post to main take, last 256 ticks). Before `vsyncHub` turns on by default, the round's fleet run records here: typing-frame-bench main tick p99 with the feature on and off, and bench_idle.py wakeups of the `cmux-next vsync` threads with a visible idle terminal (paused link: 0 expected). If the p99 rises >= 0.1 ms, the composition root keeps `DisplayClock()` main links next to the hub (<= 2 links per display; rendering-DESIGN difference 6). Measurement: not yet run, so the feature stays off |
| **Main-thread watchdog** thread `cmux-next main-thread watchdog` | Stall/hang detection and stack samples | Its own kqueue (`MainThreadWatchdogAlarm`: a one-shot timer the main thread arms when its run loop wakes and deletes before it sleeps, and a user event for stop and task starts); a main turn shorter than the timer wakes it never | user-interactive | Rings of 128 hangs and 128 over-budget entries |
| **Daemon connection** reader thread `cmux-tui reader <path>`; writer queue `com.cmuxterm.next.daemon.write`; `actor DaemonConnection`; `EventInbox` pump task | Socket read and line split; outbox drain; handshake and reconnect; off-main event buffer | Blocking `read(2)` (reader); `write` (writer) | user-interactive (reader), default (writer) | Line over 64 MiB closes the connection; outbox 64 MiB, past it `write` fails `.backlog`; inbox 4096 events, field events coalesced, overflow collapses to one resync; main drains 32 per slice under the visible budget |
| **Terminal attach** (`TerminalAttachment` reader → `TerminalEventQueue`) | One terminal's output stream | The reader waits above 8 MiB queued, resumes below 2 MiB | user-interactive | The daemon's attach mailbox overflows and ends the stream |
| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | Feeding `ghostty_surface_process_output`; local PTY I/O | PTY read/write | user-interactive | 2 MiB high water: the consumer task suspends |
| **Ghostty renderer and IO threads** (per surface, inside GhosttyKit) | Rendering; termio | Renderer mailbox (64, latest-value-wins, never waits); termio queue 64 | Renderer: focused user-interactive, visible user-initiated, hidden utility (ghostty-next `src/renderer/Thread.zig` `setQosClass`). IO: not set; removed for manual-IO surfaces by p03-rendering-086 ([Renderer QoS](#renderer-qos-rendering-design-r5)) | cmux runs surfaces in manual IO mode: no Ghostty read thread |
| **Swift cooperative pool and actors** (`actor`s that own I/O: daemon, cloud, remote, stores; `Task.detached` at `.utility`/`.userInitiated`) | Async I/O and domain state off main | Nothing (never a blocking call on the pool; blocking work belongs on a dedicated thread or queue) | the task's priority | Each actor's own stream bounds (`AsyncStream` with a buffering policy, never `.unbounded`) |
| **DispatchSource handlers** (control socket `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; file watchers; process and signal sources) | Event delivery only | Non-blocking reads | as the queue | Coalesced by the source; main-queue sources only hop |
| **Hang watch** (p09-observability, owner PL-telemetry). App: the `HangWatch` slots in CmuxNextTrace (`TraceRuntime.shared.hangWatch`), read by `HangMonitor` on the existing `cmux-next main-thread watchdog` thread's kqueue (no new thread; p02-threads-016, attached by `AppControl.startWatchdog`). Rust: one `cmux-hang-watch` thread per process (cmux-hang-watch crate: daemon, holder, terminal host, acpmux) | Watched threads' and lanes' deadlines; the hang record and stack sample of an overdue slot; app reports go to `debug.hangs` `thread_hangs` (`MainThreadWatchdog.threadHangs`, apart from main-thread stalls) | Its kqueue (app) or a `Condvar` (Rust). Sampling: between `thread_suspend` and `thread_resume` it only reads registers and stack memory into a preallocated buffer, no lock and no allocation | user-interactive (app, the watchdog's); default (Rust) | Opening a scope is a clock read, one store (a lane: two) and one load of the plan; closing one store; no lock and no system call. App: while scopes open and close, one scan per minimum deadline (100 ms); after a scan with no slot changed it sleeps to the earliest open deadline (a 30 s job alone: no periodic wake); with nothing open it parks with no timer (0 idle wakes). A scope whose deadline the plan would see over one minimum deadline late (parked, or sleeping to a later deadline) posts one `EVFILT_USER`. Detection within deadline + minimum deadline. Rust: one one-shot timer per minimum deadline while scopes open (at most 1 wake/s at 1 s), parked after one quiet minimum-deadline period, the first open after that posts one wake. A watcher that wakes over 100 ms late blames nobody. One hang record per overdue scope, kept when a nested scope closes |
| **Trace ring adoption** (p09-observability, owner PL-telemetry). App: a `BackgroundWork` `.files` job at launch and at `trace.start` (no new thread). Rust: one `cmux-trace-open` one-shot thread per process at start | Moving the heap ring into its file: rename the spare file or create one, `mmap` `MAP_SHARED`, copy the heap records, swap the ring pointer; delete dead-pid rings older than 3 days | Disk (open, `ftruncate`, `mmap`, rename, unlink) | utility | Once per process start and once per recording start; the writers keep writing the heap ring until the swap, never wait for it; an `mmap` failure keeps the heap ring and is counted; a recording mapping is never unmapped while the process lives; the directory is capped at 16 MiB |
| **Blocking detector drain** `com.cmuxterm.app.next.blocking-drain` | Resolving violations to image UUID + offset; the Debug log line; the sink | Nothing | utility | Ring of 64 new sites, 128 sites per launch; past either: counted in `overflow` |
| **cmux-tui daemon (Rust)** request path: `mux-server` accept, one `mux-conn` thread per connection (max 64; over: `server.busy`), `mux-control-dispatch` per connection, `mux-line-out` writer | Requests, model, snapshots | Socket read on its own thread | not set (PL-qos) | Per connection 256 requests / 16 MiB (over: error, not run); outbound 256 per stream, 4096 per connection (over: the largest stream ends); write timeout 2 s; event bus 4096 per subscriber, then disconnect. Rules D1-D8 in perf-lead.md |
| **Request watchdog** `mux-request-watchdog` (cmux-tui daemon, one per process; p05-ipc-006, cmux-tui-core server/request_watchdog.rs) | Requests running past 250 ms: every connection frame from its arrival until its handler returns (v2 operations, sniffed handlers, remote-relay frames) and every `cmd` the connection's scheduler runs on another thread; one `slow_requests` entry each with its final duration (server-stats) and a `slow-request` debug-spans line. `wait-for` and other waits by design are counted in `expected_waits`, not recorded | `park` / `park_timeout`, no timer while idle. A request claims one of 256 slots with atomics; only the first request while disarmed unparks the thread, and a run that ends slow before a scan hands its end over through its slot. Armed, it wakes only on a 250 ms grid, records overruns and finished-slow runs, and disarms on a tick with nothing left to watch and no new request | utility (`cmux_threads::spawn`; a failed start is counted in `spawn_failures` and retried by the next arm) | 0 wakes at idle; at most 1 wake per 250 ms (4/s) plus one, under any request spacing; 128-entry ring; a request past 256 busy slots is counted as unwatched, never blocked |
| **Journal writer** `mux-session-journal-writer` (+ `-fanout`, maintenance, hook workers) | Durable session journal | Disk | not set | `sync_channel(1024)` terminal, `(256)` durable: the producer waits for space; durable wait deadline 30 s |
| **Effect / terminal work** (`mux/resource_effects.rs` intents through the journal writer; `mux-terminal-work` pool, 8 workers) | Registry commits; terminal jobs | Disk (writer side) | not set | 1024 queued jobs; a job that does not fit runs inline |
| **Per-stream lanes** | Not on feat-cmux-next yet (PL-conn, `pl-conn`) | | | Added here when it lands |
| **Holder** (`cmux-holder`, one `poll` loop; daemon side `holder-link`) | PTYs that outlive the daemon | `poll` | not set | 1 MiB ring per terminal, 1 MiB link queue, 512 KiB credit window; daemon attached: the holder stops reading the PTY (the shell blocks); no daemon: the ring keeps the newest bytes |
| **acpmux** (tokio multi-thread; `acpmux-socket-read` / `-write` bridges) | Agent sessions | Socket I/O on its runtime | not set | In 256 / out 4096 per connection, full outbox drops (`try_send`), oversized notices become `_acpmux/lagged`; hub broadcast 8192 with `lagged {dropped}`. Owner PL-acpmux (cmux-4f) |
| **Chromium** (in-process browser: UI thread = the app's main thread; Chromium's own IO and worker threads; renderer, GPU and utility helper processes; out-of-process host prototype `com.cmuxterm.chromium-host.read` / `.exit` / `.control`) | Web pages | Chromium's IO thread blocks on its own sockets, never the UI thread | Chromium's | Child exits on `com.cmuxterm.app.next.cef-children`; host prototype: 256 KiB send buffer, 4096 frames, over: the connection ends; in the host one frame queue (moves, wheel deltas and geometry coalesce, keys kept), over 4096: the host ends; one exit queue per launcher (kqueue process source, no thread per host); control channel `com.cmuxterm.chromium-host.control` (one reader thread per end, user-initiated, waits only in `poll`; p01-process-012): sends never block, a refused frame waits in the outbox where state ops coalesce per (op, page); over 256 KiB or 4096 waiting is counted (`quota_excess`) and ends the host only after 60 s over without a break; a malformed frame ends it; replies resume on the reader, other messages reach main as one visible task per batch, and past 4096 unread the reader stops reading until main drains |

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
.files (serial per priority); a sync system call (getaddrinfo, Security, Launch Services, AX, window lists) uses lane
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

Daemon: no cmux-tui thread sets a QoS yet. The journal writer stays at the default QoS while request paths wait on its
durable commit (PL-daemon is removing that wait; then writer = utility, request threads = userInitiated).

Blocking rule for the two "donating waits" above (lead decision 2026-10-24): a short `Mutex` critical
section on the main thread is allowed (a contended wait over 2 ms is recorded), but a `dispatch_sync` from the
main thread (`blockingSync`) is still reported: the QoS override bounds the inversion, yet the main thread
still waits for everything queued before it on that queue.

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
| Ghostty renderer (one per surface) | user-interactive | user-initiated | utility; no frame drawn | today: ghostty-next `src/renderer/Thread.zig` `setQosClass`. p03-rendering-088 adds: `process_output` on a hidden surface sets dirty and does not wake the renderer |
| Ghostty IO (one per surface) | not set (GhosttyKit default) | not set | not set | removed for manual-IO surfaces by p03-rendering-086 |
| Remote view render `cmux.remote-view.render` | user-interactive | user-interactive | user-interactive (no change by state yet; p03-rendering-114) | `MetalYUVRenderer` queue |
| Chromium GPU, compositor and renderer threads | set by Chromium from the thread type | set by Chromium | Chromium lowers a renderer only when it knows the page is hidden: visibility from the embedder, p03-rendering-058 | Chromium: thread QoS from the thread type (`base/threading/platform_thread_apple.mm`); hidden renderer priority from `RenderProcessHostImpl::UpdateProcessPriority` (`content/browser/renderer_host/render_process_host_impl.cc`) and `base::Process::SetPriority` (`base/process/process_mac.cc`) |

## Registered threads and queues

A new thread or queue in `Packages/macOS/CmuxNext/Sources` needs its label here (the `thread-doc` guardrail
matches the label's literal text; `<x>` matches an interpolation). Its owner row above says what it may block on.

- Main and frame: `cmux-next main-thread watchdog`, `cmux-next quit deadline`, `cmux-next crash deadline`,
  `cmux-next vsync <display>` (VSyncHub)
- Daemon: `cmux-tui reader <path>`, `com.cmuxterm.next.daemon.write`, `com.cmuxterm.next.daemon.path.<machine>`,
  `com.cmuxterm.next.daemon.exit.<pid>`, `com.cmuxterm.next.retry-wake`, `com.cmuxterm.next.process-progress`
- Control: `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`
- Terminal: `com.cmuxterm.next.terminal.output`, `com.cmuxterm.next.localpty.read`, `com.cmuxterm.next.localpty.write`
- Settings and files: `com.cmuxterm.next.settings.watcher`, `cmux.files.fsevents`, `cmux.files.tree-fsevents`,
  `com.cmuxterm.home.cache` (the `HomeCache` actor's executor, user-initiated: its file writes block this queue,
  never a pool thread, so the forced quit's last draft write runs with the pool full; CmuxHomeCore, shared with iOS),
  `com.cmuxterm.next.files.table-widths` (the `MarkdownTableWidthRepository` actor's executor, user-initiated),
  `com.cmuxterm.next.onboarding.classic-migration` (the `ClassicMigrationRepository` actor's executor,
  user-initiated), `com.cmuxterm.next.agent-pane.saved-environments` (the `SavedEnvironments` actor's executor,
  user-initiated), `com.cmuxterm.next.hang-reports.store` (the `HangReportStore` actor's executor, utility); each
  actor's file calls block its own queue, never a pool thread (p02-threads-141..144)
- Remote and mobile: `com.cmuxterm.next.remote-localhost`, `com.cmuxterm.next.cloud-browser-proxy`,
  `com.cmuxterm.next.remote-fetch`, `cmux.remote-view.render`, `cmux.remote-view.rd-transport`,
  `cmux.remote-view.mock-host`, `cmux.next.mobile.unix-lane`
- Browser: `com.cmuxterm.next.browser-host.provider.write`, `cmux browser-host provider reader`,
  `com.cmuxterm.chromium-host.read` (user-initiated),
  `com.cmuxterm.chromium-host.control` (user-initiated; the control channel's reader in cmux and, same label, in the host;
  waits only in `poll`: input, the socket taking a waiting outbox, a wake byte, the quota ceiling's one deadline),
  `com.cmuxterm.chromium-host.exit` (user-initiated serial queue for the host's exit source; a crash shows on the page),
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
- Daemon request watchdog (Rust thread name, p05-ipc-006): `mux-request-watchdog` (utility)
- Launch and misc: `cmux-next resource bundle warm-up`, `cmux-next launch warm-up`, `cmux.updates.network`,
  `cmux.home.fixture.video`, `cmux.home.promised-files` (a drop's file promises, user-initiated: the person
  waits for the dropped files)
- Every `Thread` and `OperationQueue` sets `name` and `qualityOfService` before it starts; every URLSession
  gets a named delegate queue. None is unnamed.

## Reviewed blocking allowances

`allowBlocking(<reason>)` lets the main thread block for one of these reasons only (Chrome's
`ScopedAllowBlocking` friend list). A new `BlockingAllowance` needs a row here in the same push. It is not for
hot paths: in Debug and bench builds (and Nightly, to come) each outermost scope adds and removes one `CFRunLoopObserver` (it
holds the allowance back while a nested run of the main run loop runs other work).

| Reason | Why the wait cannot move off the main thread |
|---|---|
| `terminate` | `applicationWillTerminate(_:)` runs on the main thread and the process exits right after it: a bounded final flush there cannot delay a frame (Chrome allows blocking during shutdown the same way). |
