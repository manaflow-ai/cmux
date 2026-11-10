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
  ratchet's `blocking_allow_escapes` row: to come, PL-arch). It also refuses `main-hop` (cmux-ad m35): a new
  direct hop onto the main actor (`Task { @MainActor in`, `MainActor.run {`) in a UI target, which runs outside
  the main-thread scheduler; use `FrameBatchQueue.enqueue`, `MainDelivery().run`, `AfterFrameCommit().run` or an
  `await` of an `@MainActor` function. Escape: `// main-hop-allow: <why no scheduler path fits and what bounds
  the work>`. Old hops are not refused; the count only goes down. `guardrails.py --main-thread-counts [REV]`
  prints the hop, scheduler-entry, raw-blocking and checked-seam counts.

## The model on one page (2026-11-10)

Leo, 2026-11-10: "lawrence was talkin bout how we wanted to fix the root cause of a lot of this main thread
stuff which was to borrow chrome's model". The hangs (the Dock's Application Not Responding, a wedged app, chat
rows that lag when they open and close) are symptoms. The cause is a main thread that anything may call into
and block. This section states the rule. The tables below say who owns each thread. Lawrence's full program
is `plans/cmux-next/chrome-parity/p02-threads.md` on `perf/chrome-parity` (tasks `p02-threads-NNN`, not
merged into feat-cmux-next). "To come" below names its task.

Leo, 2026-11-10: "let's write some of that stuff down... maybe even in the docs? getting inspired by chrome or
whatever". The public version is [docs/cmux-next/main-thread.md](../../docs/cmux-next/main-thread.md).

Chromium sources:
- [Threading and Tasks in Chrome](https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks.md)
  and its [FAQ](https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks_faq.md):
  the UI thread never blocks, `SequencedTaskRunner`, `PostTaskAndReply`, task traits.
- [scoped_blocking_call.h](https://chromium.googlesource.com/chromium/src/+/main/base/threading/scoped_blocking_call.h)
  and [thread_restrictions.h](https://chromium.googlesource.com/chromium/src/+/main/base/threading/thread_restrictions.h):
  the assertion.
- [hang_watcher.h](https://chromium.googlesource.com/chromium/src/+/main/base/threading/hang_watcher.h): the hang
  watcher.

**What may run on the main thread.** Chrome's browser UI thread handles input and paints. Ours does the same
three things (main-thread-budget.md):
- dispatching the person's input;
- the smallest change to visible state;
- the Core Animation commit.
Anything else that still lands on main runs as a scheduled task (`MainWorkClass`, `MainFrameBudget`): about
4 ms of each frame in all, 2.5 ms of that for visible work. The main thread never waits on:
- a disk, network or socket call;
- spawning a process, or waiting for one;
- a synchronous call into another process: sync XPC, `SMAppService`, AppleScript, `NSWorkspace` queries,
  Security, Launch Services, `CGWindowList`, AX;
- `getaddrinfo`;
- a semaphore, group, condition or `queue.sync` onto a queue of lower QoS;
- a lock held across work (only a short `Mutex` section, recorded past 2 ms);
- a nested run of the main run loop (`runModal`, `RunLoop.run(until:)`; since #39850 one parked past 2 s with no
  input taken is reported as a hang);
- CPU work longer than its class's per-frame share (a large `JSONDecoder`, `JSONSerialization` or image
  decode).

**Named sequences.** Each kind of work has one owner off main. Never start a new thread for a call.

| Work | Where it runs (Chrome's equivalent) |
|---|---|
| Daemon I/O | `cmux-tui reader <path>` thread, `com.cmuxterm.next.daemon.write`, `actor DaemonConnection`. The `EventInbox` coalesces events, and one frame-class batch per frame applies them on main (the browser's IO thread plus `PostTask` to UI). |
| Disk | `BackgroundWork` lane `.files`, serial per priority. A store that owns its files keeps a dedicated serial queue listed below (for example `agent-pane.tail-disk`). Ordered work per object: `WorkSequence` (to come, p02-threads-116; Chrome's `SequencedTaskRunner`). |
| Synchronous system calls | Lane `.system`: 6 at once, Chrome's `kDefaultMaxSystemTasks`. DNS, Security, Launch Services, `NSWorkspace` queries and AX go here (to come for most call sites: p02-threads-054..059). |
| CPU-heavy work | Lane `.cpu`: P-cores minus one, and nothing on it may block. Parsing, diffing and large decodes. |
| Processes | `AsyncProcess` (no thread waits). The launcher sequence is to come (p02-threads-037..040, `ChildProcessLauncher`). |
| Cloud and network | Async `URLSession` calls on actors on the cooperative pool, which never blocks. Listeners on their own listed queues (`cmux.cloud.link-credential`). |
| Web bridge (WebKit) | WebKit delivers every script message on main, and that cannot be changed. The handler checks trust, then hands the message off in O(1) and answers through `replyHandler` from wherever the work finished. It never decodes a large payload, reads a file or waits on main. Native-to-page calls (`evaluateJavaScript`, `callAsyncJavaScript`) are never awaited on an input turn. |
| Chromium (CEF) | Chromium's UI thread is our main thread. `CEFMessagePump` gives it a 2 ms `CefDoMessageLoopWork` slice per pump. Its IO and worker threads, and its renderer, GPU and utility processes, are Chromium's own. The out-of-process host (p01-process-001) moves the browser process off our main thread. Chromium's own `ThreadRestrictions` are DCHECK-only, so they are off in shipped CEF. |
| Isolation | WebContent, Chromium renderers and GPU, the cmux-tui daemon, acpmux and the holder are separate processes. A slow one may delay its own reply, never freeze our main thread, because we never wait for that reply on main. |

**The reply pattern** (Chrome's `PostTaskAndReply`). Main-actor code awaits the work, so the main thread keeps
running and the await resumes on main:

```swift
let text = try await work.run(.userVisible, mayBlock: .files) { try String(blockingContentsOf: url) }
guard generation == current else { return }  // a stale reply is dropped, not applied
model.apply(text)
```

- Fire and forget: `work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { ... }`.
- A result from a thread that is not main reaches visible state through the scheduler:
  - `FrameBatchQueue.enqueue` (budgeted);
  - `MainDelivery().run` (a callback whose thread nobody controls);
  - `AfterFrameCommit().run` (after the frame a key asked for).
- Never through a new `Task { @MainActor in }` or `MainActor.run`: the `main-hop` guardrail refuses them.
- Never a semaphore or group that waits on main for an async result.
- Start the work at the priority of whoever waits for it (QoS table below). Work started low stays low on
  macOS 14 and 15.

**Enforcement, layer by layer.** No new CI gates, jobs, steps or budget rows (Lawrence 2026-10-23).

| Layer | Today on feat-cmux-next | To come (p02-threads) |
|---|---|---|
| Compile time | none | `BlockingPermit` (111): a seam takes a permit that only a lane body or a listed thread can give, so the compiler lists every call site with no lane |
| Pre-push, on added lines | `main-blocking`, `raw-blocking`, `main-hop`, `thread-doc`, `task-priority` (refuse) and `maybe-main-blocking` (warn). CI step "Pushed commits add no violations" (cmux-next.yml) names the commit that adds one | rules for every primitive class (002, 010, 113, 122, 126) |
| Runtime detector (Chrome's `ScopedBlockingCall`) | Checked seams record each main-thread call site once (`#fileID:#line`) in Debug, bench and Nightly (`-DCMUX_BLOCKING_CHECKS`). Nightly writes one unified-log line per site (`log show --predicate 'category == "blocking"'`). `CMUX_BLOCKING_TRAP=1` traps. It sees only seam calls: 217 checked lines against 914 raw ones (`guardrails.py --main-thread-counts` at 9941161a4c2) | `blockingCall` scope with wall time per site (004); pool context (005); sites in hang reports (008); Debug traps by default once the sweep is done (021) |
| Hang watcher (Chrome's `HangWatcher`) | `MainThreadWatchdog`: stalls over 50 ms are sampled into `debug.hangs`; a hang of 2 s or more is reported while it runs (hang file, opt-in hang report, Sentry); a Debug build asserts at 10 s of busy main; a nested run loop parked with no input taken counts as a hang (#39850) | `HangWatchScope` slots on the daemon reader, the terminal output lane and the lanes (016, 017); counters at 250 ms and 100 ms (019) |
| Proof | `scripts/cmux-next/bench-stalls.py` (per-action stalls), `scripts/measure/blocking-probe.sh` (an interposer that finds raw calls in a running app) | `threading-inventory.py` (001) |

**Order of work.**
1. Rank the blockers from hang files and the Nightly `blocking` log.
2. Move the top ones off main, one PR each, with before and after numbers from `bench-stalls.py`.
3. Carry p02-threads 004 and 008 forward, so that a hang names its blocking call site in Nightly.
4. Run the raw-blocking sweep in module order (060..101).
5. Flip Debug to trap (021).

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
| **Remote-localhost peer scan** `com.cmuxterm.next.remote-localhost.peer-scan` (`PeerProcess.isTrustedOffPool`) | Whether a machine listener's peer is this app or a helper | `proc_pidinfo`/`proc_pidfdinfo` over the app's and its children's sockets, one scan at a time | user-initiated | A caller waits at most 2 s, or less if cancelled, then counts as untrusted and its queued scan is skipped; at most 32 scans pending, past that a caller is untrusted at once |
| **Terminal attach** (`TerminalAttachment` reader → `TerminalEventQueue`) | One terminal's output stream | The reader waits above 8 MiB queued, resumes below 2 MiB | user-interactive | The daemon's attach mailbox overflows and ends the stream |
| **Terminal output lane** `com.cmuxterm.next.terminal.output`; local PTY `com.cmuxterm.next.localpty.read` / `.write` | Feeding `ghostty_surface_process_output`; local PTY I/O | PTY read/write | user-interactive | 2 MiB high water: the consumer task suspends |
| **Ghostty renderer and IO threads** (per surface, inside GhosttyKit) | Rendering; termio | Renderer mailbox (64, latest-value-wins, never waits); termio queue 64 | focused user-interactive, visible user-initiated, hidden utility | cmux runs surfaces in manual IO mode: no Ghostty read thread |
| **Swift cooperative pool and actors** (`actor`s that own I/O: daemon, cloud, remote, stores; `Task.detached` at `.utility`/`.userInitiated`) | Async I/O and domain state off main | Nothing (never a blocking call on the pool; blocking work belongs on a dedicated thread or queue) | the task's priority | Each actor's own stream bounds (`AsyncStream` with a buffering policy, never `.unbounded`) |
| **DispatchSource handlers** (control socket `com.cmuxterm.next.control.accept`, `com.cmuxterm.next.control.<id>`; file watchers; process and signal sources) | Event delivery only | Non-blocking reads | as the queue | Coalesced by the source; main-queue sources only hop |
| **Blocking detector drain** `com.cmuxterm.app.next.blocking-drain` | Resolving violations to image UUID + offset; the Debug log line; the sink | Nothing | utility | Ring of 64 new sites, 128 sites per launch; past either: counted in `overflow` |
| **cmux-tui daemon (Rust)** request path: `mux-server` accept, one `mux-conn` thread per connection (max 64; over: `server.busy`), `mux-control-dispatch` per connection (terminal creates go to the terminal pool, `wait-for` to a `mux-control-wait` thread, so neither holds it), `mux-line-out` writer | Requests, model, snapshots | Socket read on its own thread | default; user-interactive for the three threads of a connection that carries the person's keys to a terminal it can type into (not a read-only viewer; server/input_qos.rs) | Per connection 256 requests / 16 MiB (over: error, not run); `wait-for` and v2 `terminal.wait` workers 8 per connection / 64 per daemon (over: error, not run); outbound 256 per stream, 4096 per connection (over: the largest stream ends); write timeout 2 s; event bus 4096 per subscriber, then disconnect. Rules D1-D8 in perf-lead.md |
| **Journal writer** `mux-session-journal-writer` (+ `-fanout`, maintenance, hook workers) | Durable session journal | Disk | not set | `sync_channel(1024)` terminal, `(256)` durable: the producer waits for space; durable wait deadline 30 s |
| **Agent roster owner** `cmux-agent-roster` (cmux-tui `mux/agent_roster_worker.rs`) | Every fold of the journal into the agent roster, its snapshot saves and plugin roster deltas; a request (agent hook, terminal close, direct report echo) only records its work and wakes it | Disk: its own read-only journal reader, the snapshot save on the journal writer's connection; the roster lock while it applies a page, the registry and state locks while it commits a plugin delta | not set (the default), on purpose: its passes hold locks that request paths take (the roster lock, the journal writer's connection, the registry lock for a plugin delta), and a throttled holder of those locks is a priority inversion that stalls the requests waiting on them (the journal writer's rule below) | One record of requests (the highest sequence asked, the closed terminals, a catch-up flag), taken whole by each pass; a request records in O(1) and never waits; the maintenance tick's catch-up waits for its pass; shutdown waits 2 s |
| **Effect / terminal work** (`mux/resource_effects.rs` intents through the journal writer; `mux-terminal-work` pool, 8 workers) | Registry commits; terminal jobs | Disk (writer side) | not set | 1024 queued jobs; a job that does not fit runs inline |
| **Browser event lanes** (cmux-tui `browser/event_lanes.rs`: process-wide pool `browser-events-<n>`, 2 threads; fed by each runtime's router `browser-runtime-events`) | Serving each daemon browser surface's CDP events in order (one lane per surface, at most one thread on it); replaced `browser-surface-<id>-events` (one thread per surface) | Short in-memory locks only: CDP sends are fire-and-forget (`*_detached`); attention, popup adoption and lifecycle registry work pause just their originating lane while its existing command worker runs the effect, preserving event order without occupying the pool | not set (PL-qos) | Per-surface queue `CDP_EVENT_QUEUE_CAPACITY` events / `CDP_EVENT_QUEUE_MAX_BYTES` (over: the route closes); at most one deferred registry effect per route; 32 events per lane turn, then the lane requeues; a panicking handler ends only its lane |
| **Per-stream lanes** | Not on feat-cmux-next yet (PL-conn, `pl-conn`) | | | Added here when it lands |
| **Holder** (`cmux-holder`, one `poll` loop; daemon side `holder-link`) | PTYs that outlive the daemon | `poll` | not set | 1 MiB ring per terminal, 1 MiB link queue, 512 KiB credit window; daemon attached: the holder stops reading the PTY (the shell blocks); no daemon: the ring keeps the newest bytes |
| **acpmux** (tokio multi-thread; `acpmux-socket-read` / `-write` bridges) | Agent sessions | Socket I/O on its runtime | not set | In 256 / out 4096 per connection, full outbox drops (`try_send`), oversized notices become `_acpmux/lagged`; hub broadcast 8192 with `lagged {dropped}`. Owner PL-acpmux (cmux-4f) |
| **acpmux event journal** (always on; R-DURABILITY S2/S2c): the `cmux-journal` writer thread, `acpmux-journal-checkpoint` (one thread), `acpmux-journal-folders` (one thread, S3a), one outbound gate task per connection (tokio) | Durable event-log records (group commit); the checkpoint (log syncs, retirement); the sync of `sessions/` after a new chat's folder, before its record counts as durable; holding a connection's lines until what they show is durable | The writer: disk syncs. The checkpointer: log syncs. The folder syncer: one `sessions/` sync per batch of new chats. A gate task: nothing (an async wait on the durable watch). Appends and reads take the appends' lock only around memory work and one buffered log write | The daemon keeps the default disk tier (a reply the person waits for never waits on a throttled sync); the checkpointer runs at utility (thread scope); the folder syncer keeps the daemon's tier (a new chat's reply waits for it) | The writer's queue (a refused append fails the request); a gate waits at most 10 s for the journal, then the store asks the daemon to stop for a restart (exit 74); a checkpoint every 30 s while there is work, past 64 MiB of journal, at shutdown. Owner R-DURABILITY |
| **Chromium** (in-process browser: UI thread = the app's main thread; Chromium's own IO and worker threads; renderer, GPU and utility helper processes; out-of-process host prototype `com.cmuxterm.chromium-host.read` / `.exit`) | Web pages | Chromium's IO thread blocks on its own sockets, never the UI thread | Chromium's | Child exits on `com.cmuxterm.app.next.cef-children`; host prototype: 256 KiB send buffer, 4096 frames, over: the connection ends |

### Open question: per-request dispatch on a daemon connection (owner PL-daemon, 2026-11-04)

A cmux-tui connection runs its requests in order on its one `mux-control-dispatch` thread, so one slow request
holds every later request of that connection (head-of-line). cmux-ad m11 item 2 found the case: a terminal close
waited for the agent roster's fold lock while a maintenance tick read the journal tail under it (5-8 s on #34628's
nightly registry), and five unrelated app requests behind it timed out together; #35075 raised the app's deadline
from 2 s to 30 s for it. No request waits for or runs a roster fold now (R-DURABILITY, `mux/agent_roster_worker.rs`), but
any request that waits in the daemon still holds its connection. Data for the decision: the `head-of-line` scenario of the
bench (#35329) sends a `list-workspaces` right after a `close-surface` on the same connection (pipelined: one reader matches
the replies by id), against the same request on a connection of its own, under agent load; `identify` is the control (the
reader answers a plain `identify` before the queue, so it shows no queue wait). cmux18-perf, ms p50/p95/p99/max:
`list-workspaces` behind the close 9.7/54/87/305, on its own connection 2.7/15/34/65; `identify` the same on both
(0.24/3.3/9-12) (fleet ce07a34858265193980f9cdf). Options: keep in-order dispatch and keep every request path off waiting
locks; or dispatch independent requests per request (ordering only within an object), as the terminal pool and
`wait-for` already do for their requests.

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

Daemon: the `mux-conn`, `mux-control-dispatch` and `mux-line-out` threads of a connection that carries the person's
keys (`send` / `send-key` of a client that can type into the terminal: attached, not only through read-only views) raise
themselves to user-interactive (server/input_qos.rs, STATUS 6593). Every other request thread (CLI, MCP, agents, read-only
viewers) stays at the default, as does every other cmux-tui thread. The journal writer stays at the default QoS while
request paths wait on its durable commit (PL-daemon is removing that wait; then writer = utility; the person's input
threads stay user-interactive and automation's request threads stay at the default, never above the person's).

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
- Cloud credentials: `cmux.cloud.link-credential`, `cmux.cloud.hands.stdin` (the hands engine's JSON lines into
  the bundled `cmux cloud hands` child's stdin, user-initiated, serial: its pipe writes block only it and keep
  their order; a few small lines per answer, level change or token ask, so no back-pressure; a write to an
  engine that exited fails with EPIPE (no SIGPIPE) and the engine is started again; HandsEngine)
- Terminal: `com.cmuxterm.next.terminal.output`, `com.cmuxterm.next.localpty.read`, `com.cmuxterm.next.localpty.write`
- Settings and files: `com.cmuxterm.next.settings.watcher`, `cmux.files.fsevents`, `cmux.files.tree-fsevents`,
  `com.cmuxterm.home.cache` (the `HomeCache` actor's executor, user-initiated: its file writes block this queue,
  never a pool thread, so the forced quit's last draft write runs with the pool full; CmuxHomeCore, shared with iOS),
  `cmux.chief.movedMarker` (the Chief home's `state/moved.json` vnode watch, utility, serial: event delivery only,
  it blocks on nothing; one re-arm per folder change; ChiefMovedMarkerAttachment)
- Remote and mobile: `com.cmuxterm.next.remote-localhost`, `com.cmuxterm.next.remote-localhost.peer-scan`, `com.cmuxterm.next.cloud-browser-proxy`,
  `com.cmuxterm.next.cloud-hub-loopback` (Open Desktop's SOCKS connections to the app's WireGuard hub),
  `cmux.cloud.machine-io.stdin` (one Worker machine exec or file call's request into the bundled cmux's stdin,
  one thread per call: its pipe write blocks only it; it ends when the child has read the request or closed its
  stdin, and a kill at the call's deadline or a cancel closes it, so it never outlives the child; CloudMachineIO),
  `com.cmuxterm.next.remote-fetch`, `cmux.remote-view.render`, `cmux.remote-view.rd-transport`,
  `cmux.daemon-bridge.stream` (one Cloud desktop session's `link dial --service desktop` bridge socket,
  user-initiated, serial: DispatchIO delivers the stream's bytes here and it blocks on nothing; the rd transport
  reads them in order, a few MB/s of H.264 at most, and the session's end closes it; DaemonBridgeStream),
  `com.cmuxterm.mac-screen.rd-stdin` (one Mac Screen session's JSON lines into its bundled `cmux rd`
  process, user-initiated, serial: its pipe writes block only it; a few lines per session, candidates and
  stop, so no back-pressure; MacScreenRdProcess), `com.cmuxterm.mac-screen.rd-socket` (the viewer's
  Unix socket to `cmux rd connect`, user-initiated: Network delivers the stream's bytes here, it blocks on
  nothing, the decode pipeline reads them; MacScreenUnixStream),
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
- Agents: `com.cmuxterm.app.next.agent-pane.tail-disk` (each chat's kept tail on disk, AgentPaneTailDisk, utility,
  serial: its file reads and writes block this queue, never main; saves of one chat coalesce to the newest, at most
  20 files of 1 MiB, and a read waits only behind the saves queued before it; the quit awaits its saves with the
  state files', holding no thread, under the quit deadline),
  `com.cmuxterm.app.next.agent-pane.prompt-journal`, `com.cmuxterm.app.next.agent-pane.inbound`,
  `cmux.next.agent-pane.acpmux-exit.<pid>`, `cmux.next.agent-pane.acpmux-log-progress`,
  `cmux.next.agent-pane.acpmux-launch-reap.<pid>`, `cmux.next.agent-pane.acpmux-status`, `cmux.acpmux.checked-line`,
  `cmux.next.agent-pane.acpmux-socket-wait` (one person-socket exchange's readiness wait, userInitiated, serial, one
  queue per wait: a dispatch source wakes it, nothing blocks it; it ends at readiness, the daemon's close or the
  caller's cancel),
  `cmux.agent-activity.socket`, `com.cmuxterm.app.next.chief-settle`, `com.cmuxterm.app.next.tasks.socket`,
  `cua-helper-v2-reap`, `cua-helper-v2-stdout`, `cmux-remote-device` (one per open channel to cmux Remote's Screen
  Sharing worker: a blocking read(2) that ends at the channel's EOF; answers and hub pushes go to their waiters, pushes
  bounded at 256, docs/cmux-remote.md)
- Input: `com.cmuxterm.next.event-source-processes` (``EventSourceProcesses``: the executable path and start time of
  each process that posts key and mouse events, read once per process with `sysctl(KERN_PROC_PID)`/`proc_pidpath`, user-initiated,
  serial; it also runs that process's exit watch, which removes the entry. The key path only reads the table, never
  a system call; one item per new posting process, so no back-pressure)
- Diagnostics: `cmux-next.hang-episodes`, `cmux-next.hang-episodes.symbols`, `com.cmuxterm.app.next.run-marker`,
  `com.cmuxterm.app.next.crash-forwarder`, `com.cmuxterm.app.next.owner-panic-forwarder`,
  `com.cmuxterm.next.typing-probe`, `com.cmuxterm.app.next.blocking-drain`, `com.cmux.host-pressure`,
  `debug.window_record`, `debug.motion.trace` (a `debug.motion` `trace_stop`/`trace_read` with `path`: the report's JSON serialization and file
  write, utility, serial, one item per call, so no back-pressure), `debug.motion.record` (a `debug.motion` `record_*` movie in DEBUG and bench builds: its
  ScreenCaptureKit frames, the encoder appends and the scanline and frame-list file writes; user-initiated, serial;
  a frame the encoder is not ready for is counted and dropped, never queued, so no back-pressure), `debug.frame_strip.screen`
  (a `debug.new_tab` `frame_strip` with `above` in DEBUG and bench builds, when the process lacks the Screen Recording grant:
  its ScreenCaptureKit frames, each copied and downscaled into the strip; user-initiated, serial; ScreenCaptureKit's own
  queue depth of 8 drops frames the queue has not taken, so no back-pressure; ends with the strip), `com.cmuxterm.next.busy-watchdog` (the busy watchdog's kernel reads: each
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
