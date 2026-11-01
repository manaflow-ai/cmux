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
  `-DCMUX_BLOCKING_CHECKS`): recorded for `debug.blocking`, never a trap. cmux NEXT Nightly (track
  `nightly-next`): built with `-DCMUX_BLOCKING_CHECKS` (`scripts/cmux-next/lib/nightly-swift-defines.sh`, read
  by `nightly.yml` and `check-release-compile.sh --nightly`); it records each new site once, never traps, has
  no menu, and writes one public unified-log line per site with the kind and the image UUID + offset frames
  only (`BlockingLogSink`, category `blocking`; no path, file or symbol). The opt-in hang reports do not carry
  the sites yet (a report schema change with PL-telemetry). Release: compiled out.
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
| **Frame clock** (`FrameScheduler`: one `CADisplayLink` per window on the main run loop; `MotionClock`, `DisplayLinkDriver`, `DemandTimer` on it) | Frame ticks for clients | Never | main | One link per window, dropped when no client is active; rebuilt after 3 stalls of 100 ms |
| **Main-thread watchdog** thread `cmux-next main-thread watchdog` | Stall/hang detection and stack samples | Its own kqueue (`MainThreadWatchdogAlarm`: a one-shot timer the main thread arms when its run loop wakes and deletes before it sleeps, and a user event for stop and task starts); a main turn shorter than the timer wakes it never | user-interactive | Rings of 128 hangs and 128 over-budget entries |
| **Daemon connection** reader thread `cmux-tui reader <path>`; writer queue `com.cmuxterm.next.daemon.write`; `actor DaemonConnection`; `EventInbox` pump task | Socket read and line split; outbox drain; handshake and reconnect; off-main event buffer | Blocking `read(2)` (reader); `write` (writer) | user-interactive (reader), default (writer) | Line over 64 MiB closes the connection; outbox 64 MiB, past it `write` fails `.backlog`; inbox 4096 events, field events coalesced, overflow collapses to one resync; main drains 32 per slice under the visible budget |
| **Cloud link credentials** `cmux.cloud.link-credential` (CloudLinkLauncher) | Listener lifecycle; Mutex protects peer generation and owned request tasks | Bind and peer inspection on the serial queue; socket reads/writes on utility dispatch workers, never the cooperative pool | utility | At most 32 requests including Worker calls; excess connections close. One 64 KiB line, 5 s read deadline and 5 s write timeout. Stop cancels owned tasks and invalidates the generation; each request closes its descriptor |
| **Terminal attach** (`TerminalAttachment` reader → `TerminalEventQueue`) | One terminal's output stream | The reader waits above 8 MiB queued, resumes below 2 MiB | user-interactive | The daemon's attach mailbox overflows and ends the stream |
| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | Feeding `ghostty_surface_process_output`; local PTY I/O | PTY read/write | user-interactive | 2 MiB high water: the consumer task suspends |
| **Ghostty renderer and IO threads** (per surface, inside GhosttyKit) | Rendering; termio | Renderer mailbox (64, latest-value-wins, never waits); termio queue 64 | focused user-interactive, visible user-initiated, hidden utility | cmux runs surfaces in manual IO mode: no Ghostty read thread |
| **Swift cooperative pool and actors** (`actor`s that own I/O: daemon, cloud, remote, stores; `Task.detached` at `.utility`/`.userInitiated`) | Async I/O and domain state off main | Nothing (never a blocking call on the pool; blocking work belongs on a dedicated thread or queue) | the task's priority | Each actor's own stream bounds (`AsyncStream` with a buffering policy, never `.unbounded`) |
| **DispatchSource handlers** (control socket `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; file watchers; process and signal sources) | Event delivery only | Non-blocking reads | as the queue | Coalesced by the source; main-queue sources only hop |
| **Blocking detector drain** `com.cmuxterm.app.next.blocking-drain` | Resolving violations to image UUID + offset; the Debug log line; the sink | Nothing | utility | Ring of 64 new sites, 128 sites per launch; past either: counted in `overflow` |
| **cmux-tui daemon (Rust)** request path: `mux-server` accept, one `mux-conn` thread per connection (max 64; over: `server.busy`), `mux-control-dispatch` per connection (terminal creates go to the terminal pool, `wait-for` to a `mux-control-wait` thread, so neither holds it), `mux-line-out` writer | Requests, model, snapshots | Socket read on its own thread | not set (PL-qos) | Per connection 256 requests / 16 MiB (over: error, not run); `wait-for` and v2 `terminal.wait` workers 8 per connection / 64 per daemon (over: error, not run); outbound 256 per stream, 4096 per connection (over: the largest stream ends); write timeout 2 s; event bus 4096 per subscriber, then disconnect. Rules D1-D8 in perf-lead.md |
| **Journal writer** `mux-session-journal-writer` (+ `-fanout`, maintenance, hook workers) | Durable session journal | Disk | not set | `sync_channel(1024)` terminal, `(256)` durable: the producer waits for space; durable wait deadline 30 s |
| **Effect / terminal work** (`mux/resource_effects.rs` intents through the journal writer; `mux-terminal-work` pool, 8 workers) | Registry commits; terminal jobs | Disk (writer side) | not set | 1024 queued jobs; a job that does not fit runs inline |
| **Browser event lanes** (cmux-tui `browser/event_lanes.rs`: process-wide pool `browser-events-<n>`, 2 threads; fed by each runtime's router `browser-runtime-events`) | Serving each daemon browser surface's CDP events in order (one lane per surface, at most one thread on it); replaced `browser-surface-<id>-events` (one thread per surface) | Short in-memory locks only: CDP sends are fire-and-forget (`*_detached`); attention, popup adoption and lifecycle registry work pause just their originating lane while its existing command worker runs the effect, preserving event order without occupying the pool | not set (PL-qos) | Per-surface queue `CDP_EVENT_QUEUE_CAPACITY` events / `CDP_EVENT_QUEUE_MAX_BYTES` (over: the route closes); at most one deferred registry effect per route; 32 events per lane turn, then the lane requeues; a panicking handler ends only its lane |
| **Per-stream lanes** | Not on feat-cmux-next yet (PL-conn, `pl-conn`) | | | Added here when it lands |
| **Holder** (`cmux-holder`, one `poll` loop; daemon side `holder-link`) | PTYs that outlive the daemon | `poll` | not set | 1 MiB ring per terminal, 1 MiB link queue, 512 KiB credit window; daemon attached: the holder stops reading the PTY (the shell blocks); no daemon: the ring keeps the newest bytes |
| **acpmux** (tokio multi-thread; `acpmux-socket-read` / `-write` bridges) | Agent sessions | Socket I/O on its runtime | not set | In 256 / out 4096 per connection, full outbox drops (`try_send`), oversized notices become `_acpmux/lagged`; hub broadcast 8192 with `lagged {dropped}`. Owner PL-acpmux (cmux-4f) |
| **Chromium** (in-process browser: UI thread = the app's main thread; Chromium's own IO and worker threads; renderer, GPU and utility helper processes; out-of-process host prototype `com.cmuxterm.chromium-host.read` / `.exit`) | Web pages | Chromium's IO thread blocks on its own sockets, never the UI thread | Chromium's | Child exits on `com.cmuxterm.app.next.cef-children`; host prototype: 256 KiB send buffer, 4096 frames, over: the connection ends |

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
  `com.cmuxterm.next.daemon.exit.<pid>`, `com.cmuxterm.next.retry-wake`, `com.cmuxterm.next.process-progress`
- Control: `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`
- Cloud credentials: `cmux.cloud.link-credential`
- Terminal: `com.cmuxterm.next.terminal.output`, `com.cmuxterm.next.localpty.read`, `com.cmuxterm.next.localpty.write`
- Settings and files: `com.cmuxterm.next.settings.watcher`, `cmux.files.fsevents`, `cmux.files.tree-fsevents`,
  `com.cmuxterm.home.cache` (the `HomeCache` actor's executor, user-initiated: its file writes block this queue,
  never a pool thread, so the forced quit's last draft write runs with the pool full; CmuxHomeCore, shared with iOS)
- Remote and mobile: `com.cmuxterm.next.remote-localhost`, `com.cmuxterm.next.cloud-browser-proxy`,
  `com.cmuxterm.next.cloud-hub-loopback` (Open Desktop's SOCKS connections to the app's WireGuard hub),
  `cmux.cloud.machine-io.stdin` (one Worker machine exec or file call's request into the bundled cmux's stdin,
  one thread per call: its pipe write blocks only it; it ends when the child has read the request or closed its
  stdin, and a kill at the call's deadline or a cancel closes it, so it never outlives the child; CloudMachineIO),
  `com.cmuxterm.next.remote-fetch`, `cmux.remote-view.render`, `cmux.remote-view.rd-transport`,
  `cmux.remote-view.mock-host`, `cmux.next.mobile.unix-lane`, `com.cmuxterm.mobile.paired-devices` (the iPhone
  host's paired-phone list and its Keychain seal, utility, serial: its file and Keychain calls block this queue,
  never main; one item per save, read or withdrawal, each from a person's action or an account change, so no back-pressure;
  the quit awaits it holding no thread, with the agent panes' state files (`AppServices.stateFilesDrained`), after its deadline is armed; that deadline records the files still saving, `AgentPaneStateLoss`)
- Browser: `com.cmuxterm.next.browser-host.provider.write`, `cmux browser-host provider reader`,
  `com.cmuxterm.chromium-host.read`, `com.cmuxterm.chromium-host.exit`, `com.cmuxterm.app.next.cef-children`,
  `com.cmuxterm.import-history-sync`
- Dictation: `com.cmuxterm.dictation.recording` (one dictation session's recording file, utility, serial: its
  file writes block this queue, never the audio tap or main; one write per second of audio heard, each
  one second of 16 kHz PCM, so it keeps up by orders of magnitude; the finish's header patch and read of a
  recording within 4 MiB run here too)
- Design: `com.cmuxterm.next.desktop-picture` (the desktop wallpaper watch's reads, utility, serial: its
  `NSWorkspace.desktopImageURL(for:)` WindowServer round trip and file stat block this queue, never main
  (#26394); one read at a time, and events during it fold into one more read, so no back-pressure)
- Agents: `com.cmuxterm.app.next.agent-pane.prompt-journal`, `com.cmuxterm.app.next.agent-pane.inbound`,
  `cmux.next.agent-pane.acpmux-exit.<pid>`, `cmux.next.agent-pane.acpmux-log-progress`,
  `cmux.next.agent-pane.acpmux-launch-reap.<pid>`, `cmux.next.agent-pane.acpmux-status`, `cmux.acpmux.checked-line`,
  `cmux.next.agent-pane.acpmux-socket-wait` (one person-socket exchange's readiness wait, userInitiated, serial, one
  queue per wait: a dispatch source wakes it, nothing blocks it; it ends at readiness, the daemon's close or the
  caller's cancel),
  `cmux.agent-activity.socket`, `com.cmuxterm.app.next.chief-settle`, `com.cmuxterm.app.next.tasks.socket`,
  `cua-helper-v2-reap`, `cua-helper-v2-stdout`
- Diagnostics: `cmux-next.hang-episodes`, `cmux-next.hang-episodes.symbols`, `com.cmuxterm.app.next.run-marker`,
  `com.cmuxterm.app.next.crash-forwarder`, `com.cmuxterm.app.next.owner-panic-forwarder`,
  `com.cmuxterm.next.typing-probe`, `com.cmuxterm.app.next.blocking-drain`, `com.cmux.host-pressure`,
  `debug.window_record`, `com.cmuxterm.next.busy-watchdog` (the busy watchdog's kernel reads: each
  process's `proc_pid_rusage` and `proc_pidinfo`, the Chromium helper list, the main thread's `thread_info` and
  stack sample; utility, serial; at most one window open or close is pending, so no back-pressure; a read the
  kernel holds delays only the next window). A diagnostic never makes a system call on the main thread: the
  main thread stamps a time or sets an atomic, and the read runs on a queue like this one or a
  `BackgroundWork` system lane (`debug.wakeups`, `debug.new_tab`, `debug.cef`; the crash context's footprint
  is read on `com.cmuxterm.app.next.run-marker` when the run marker is written). v229 (2026-10-30): the busy watchdog's
  window end on main stalled it 1,261 ms in `proc_pidinfo`.
- Launch and misc: `cmux-next resource bundle warm-up`, `cmux-next launch warm-up`, `cmux.updates.network`,
  `cmux.home.fixture.video`
- Unnamed today (base debt; name and list them when you touch them): the URLSession delegate
  `OperationQueue`s in AcpmuxPaneSocket.swift, AgentChatPullRequestReader.swift,
  URLSessionChromiumRuntimeDownloader.swift and HomePromisedFiles.swift, and WebKitSetupGate.swift's
  `Thread.detachNewThread`.

## Reviewed blocking allowances

`allowBlocking(<reason>)` lets the main thread block for one of these reasons only (Chrome's
`ScopedAllowBlocking` friend list). A new `BlockingAllowance` needs a row here in the same push. It is not for
hot paths: in Debug and bench builds (and Nightly) each outermost scope adds and removes one `CFRunLoopObserver` (it
holds the allowance back while a nested run of the main run loop runs other work).

| Reason | Why the wait cannot move off the main thread |
|---|---|
| `terminate` | `applicationWillTerminate(_:)` runs on the main thread and the process exits right after it: a bounded final flush there cannot delay a frame (Chrome allows blocking during shutdown the same way). |
