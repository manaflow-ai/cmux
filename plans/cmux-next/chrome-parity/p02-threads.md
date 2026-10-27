# p02-threads: Chrome-grade thread rules for cmux-next (app and cmux-tui daemon)

Program owner: p02 fixer. Measured at `/Users/lawrence/fun/wt/chrome-parity`, tip `772cdfc45ac`
(2026-10-25), with rg, git and cat only. This spec applies the three adversarial reviews to the
p02 design. Section 9 ("Review disposition") lists each review finding and what was done with it.
Reviewer counts were checked again in the checkout; where a count differed, this spec uses the
re-measured number.

Items 1, 3 and 5 of the threading list. Four parts:

1. A ScopedBlockingCall / ThreadRestrictions detector. It records in Debug and bench during the push,
   traps in Debug after the sweep is clean (task 021), sends a non-fatal report in Nightly, has an
   opt-in crash mode in Nightly, and is compiled out of Release.
2. No blocking calls on the main thread, on the Swift cooperative pool or on GCD root queues. No
   long CPU work on main.
3. Task traits (priority, may-block lane, shutdown behavior) for every off-main item. Blocking work
   runs on BackgroundWork lanes (app) or `cmux_threads::work` (daemon). A best-effort fence holds
   low-priority work until launch settles.
4. A declared QoS on every queue, thread, task, child process and process role, with no priority
   inversion: waiters boost owners and producers, and shutdown raises block-shutdown work.

---

## 1. Chrome reference

Read on chromium.googlesource.com, main.

1. **base/threading/thread_restrictions.h.** `base::AssertBlockingAllowed()` is called by every
   blocking primitive. `DisallowBlocking()` / `ScopedDisallowBlocking` mark a thread on which blocking
   is forbidden. `ScopedAllowBlocking` has a private constructor: only listed friend classes can make
   one (BrowserProcessImpl, RenderProcessHostImpl, crypto::ScopedAllowBlockingForNSS and others, each
   platform friend behind a BUILDFLAG). The friend list has a section "Usage that should be fixed"
   with crbug links: a reviewed allowlist in one file. `DisallowBaseSyncPrimitives()` /
   `ScopedAllowBaseSyncPrimitives(OutsideBlockingScope)` do the same for WaitableEvent,
   ConditionVariable, Join and Process::WaitForExit. `PermanentThreadAllowance::AllowBlocking()` is
   used only at shutdown. `DisallowUnresponsiveTasks()` sets THREE flags: blocking, base sync
   primitives, and `tls_cpu_intensive_work_disallowed` (`AssertLongCPUWorkAllowed`).
   thread_restrictions.cc says that DUMP_OR_DCHECK is "temporarily a DCHECK" and is meant to become a
   non-fatal dump in official builds.
2. **content/browser/browser_main_loop.cc** PreMainMessageLoopRun: "If the UI thread blocks, the whole
   UI is unresponsive. Do not allow unresponsive tasks from the UI thread", then
   `base::DisallowUnresponsiveTasks()` and a `responsiveness::Watcher`. InitializeMojo calls
   `mojo::SyncCallRestrictions::DisallowSyncCall()` for the whole browser process.
3. **base/threading/scoped_blocking_call.h.** `ScopedBlockingCall(FROM_HERE, MAY_BLOCK | WILL_BLOCK)`
   is required "in every scope where a blocking call is made"; the scope is tight. Blocking //base APIs
   make their own scope, so call sites do not wrap them. It is compiled into all builds: it drives pool
   compensation, IO-jank monitoring (`EnableIOJankMonitoringForProcess`) and trace events.
4. **base/task/task_traits.h.** TaskPriority BEST_EFFORT ("only start running when machine resources
   are available"), USER_VISIBLE, USER_BLOCKING (default). TaskShutdownBehavior CONTINUE_ON_SHUTDOWN,
   SKIP_ON_SHUTDOWN (default), BLOCK_SHUTDOWN ("only to save critical user data"; background threads
   are raised to normal priority at shutdown). `MayBlock()` is required for file I/O, pipes, sockets
   and directory listing. WithBaseSyncPrimitives is deprecated.
5. **base/task/thread_pool/** (thread_group.cc, thread_pool_impl.cc, task_tracker.cc). The six-entry
   environment table in environment_config.h applies only to PooledSingleThreadTaskRunnerManager. In
   the ThreadPool, MayBlock and non-MayBlock tasks SHARE one ThreadGroup per priority class
   (foreground, background); blocking is absorbed by compensation (`max_tasks_++` after
   `may_block_threshold` for MAY_BLOCK, at once for WILL_BLOCK). `kMaxBestEffortTasks = 2`.
   task_tracker.cc RunTask: a task without MayBlock runs under ScopedDisallowBlocking, and a task
   without WithBaseSyncPrimitives runs under ScopedDisallowBaseSyncPrimitives even with MayBlock. At
   StartShutdown the run policy is recomputed so "BLOCK_SHUTDOWN tasks run with a normal thread
   priority". `ThreadPool.TaskLatencyMicroseconds` records post-to-start latency per priority.
   `BeginBestEffortFence()` holds best-effort work. Ordered work uses a SequencedTaskRunner on the
   shared group, never a serial worker. Jobs (`base::PostJob`) call `JobDelegate::ShouldYield()`.
   `UpdateableSequencedTaskRunner::UpdatePriority` raises queued work.
6. **content/browser/scheduler/browser_task_queues.h.** Best-effort browser-thread queues stay off
   until `OnStartupComplete()`; chrome/browser/after_startup_task_utils.h defers start-up work.
7. **base/threading/platform_thread_apple.mm** ThreadTypeToQoSClass. kBackground ->
   QOS_CLASS_BACKGROUND, kUtility -> UTILITY, kDefault -> USER_INITIATED, kPresentation and
   kAudioProcessing -> USER_INTERACTIVE. Set with `pthread_set_qos_class_self_np`. Boosts use
   `pthread_override_qos_class_start_np/end_np` (SetThreadTypeOverride; ScopedBoostablePriority in
   scoped_thread_priority.h). USER_BLOCKING and USER_VISIBLE pool tasks both run at kDefault
   (USER_INITIATED); BEST_EFFORT at kBackground.
8. **base/process/process_mac.cc, launch_mac.cc.** Children call `SetCurrentTaskDefaultRole`
   (TASK_FOREGROUND_APPLICATION, latency and throughput tier 0). `Process::SetPriority` moves a child
   between foreground, background and background-with-suppression (lowpri_cpu, disk_throttle,
   LATENCY_QOS_TIER_5 timers). Launch uses posix_spawn and sets no QoS at spawn.
9. **base/threading/hang_watcher.h/.cc.** One HangWatcher thread per process. Threads opt in with
   RegisterThread. `WatchHangsInScope(timeout)` does one clock read and one relaxed store into a
   per-thread 64-bit atomic (HangWatchDeadline packs flags and deadline): no lock, no syscall. The
   watcher checks all registered threads every monitoring period. An overrun calls
   `base::debug::DumpWithoutCrashing`; kShouldBlockOnHang freezes the hung thread until capture ends.
10. **mojo/public/cpp/bindings/sync_call_restrictions.h.** Sync IPC is disallowed process-wide;
    ScopedAllowSyncCall is friend-only ("DO NOT ADD ANY OTHER FRIEND STATEMENTS").
11. **docs/threading_and_tasks.md.** "You should pretty much never be creating your own base::Thread".
    Prefer sequences. Keep UI and IO threads free. Tasks without explicit traits "cannot block".
12. **base/check.h DCHECK_IS_CONFIGURABLE.** Some Canary builds ship DCHECKs on but non-fatal (a dump,
    no crash). This is cmux's Nightly model.
13. **base/memory/singleton.h, ScopedDisallowSingleton, LazyInstance rules.** No blocking in lazy
    singletons.
14. **base/message_loop / CurrentThread::ScopedAllowApplicationTasksInNativeNestedLoop.** Nested run
    loops are allowed only in reviewed scopes.

What cmux copies: the friend-list allowance (BlockingAllowance; Rust `AllowReason`); ScopedBlockingCall
in seams, not at call sites; a type-level permit so the compiler finds the call sites (task 111);
DisallowUnresponsiveTasks with all three flags on main; DisallowBlocking on every shared pool (Swift
cooperative pool and GCD root queues); the sync-primitive restriction on lanes; the HangWatcher
per-thread atomic slot; the ThreadType-to-QoS table; the best-effort cap and fence; priority raise
and owner boost; BLOCK_SHUTDOWN raise; post-to-start latency histograms in all builds;
DCHECK-in-Debug plus non-fatal reports in Nightly; no sync IPC on main; process task roles.

## 2. cmux today

Measured at `772cdfc45ac`.

**Size.** Packages/macOS/CmuxNext/Sources: 6,743 .swift files, 636,401 lines, 113 non-test targets
(76 main-actor by default through `uiSwiftSettings .defaultIsolation(MainActor.self)`, 37 not).
CmuxNext also links Shared and iOS packages (Package.swift lines 1751-1786) whose code runs in the app:
CmuxHomeCore, CmuxMessagesLab, CMUXMobileCore, CmuxIrohTransport, CmuxIrxTransport, CmuxVNC,
CmuxVNCWebRTC, CmuxAuthRuntime, CmuxAgentQuestion, CmuxScreenKit, CmuxSentryTelemetry, CmuxHomeRender,
macOS/CmuxUpdater, macOS/CmuxComputerUseHelper, iOS/CmuxMobileRPC, iOS/CmuxMobileSSH. No count below
includes them (task 130).

**Detector (exists, partial).** CmuxNextCompat/Threading has 31 files, 1,493 lines:
`assertBlockingAllowed(kind,fileID,line)`, `allowBlocking(BlockingAllowance)` with one allowance
(`terminate`), 8 BlockingKinds (file-io, socket-read, socket-write, sync-wait, ipc-reply, process-wait,
process-spawn, lock-wait). Mutex records contended main waits over 2 ms (Mutex.lock/unlock are
internal; only withLock/withLockIfAvailable are public). Per-site table (128 sites, 64-entry ring,
utility drain queue), debug.blocking, Debug menu, log lines. Mode `record`; traps only with
CMUX_BLOCKING_TRAP=1 in Debug. Nightly is NOT wired (no workflow passes -DCMUX_BLOCKING_CHECKS). No
sink is installed (BlockingDetector.install(sink:) has no caller). Release compiles it out. Only the
main thread is checked.

**Seam adoption.** FileManager.checked: 4 sites in 3 files; other blocking* seams: 3 sites. 7 seam
calls can run on main (task 006).

**Raw blocking primitives** (guardrails.py RAW_BLOCKING): 974 hits in 390 files, 674 in main-actor
targets. FileManager.default ops 538 in 255 files; Data(contentsOf:) 148; .write(to:) 110;
.resourceValues 68; String(contentsOf:) 38; .availableData 16; .sync{} 9; posix_spawn 7; readToEnd 5;
waitUntilExit 2; readDataToEndOfFile 2.

**Not seen by any rule (confirmed):**
- FileManager through a variable: 217 hits for the receivers `manager.`, `fileManager.`, `fm.`,
  `files.` plus 25 `FileManager()` instances.
- POSIX open/read/write/fsync/flock/rename/unlink/stat/realpath/access, FileHandle open and
  write(contentsOf:), CGImageSource/Destination URL I/O, sqlite3_*, sysctl/proc_pid*: about 470 hits in
  about 210 files (stat/access/realpath 158, sysctl/proc_pidinfo 49).
- `try x.run()` 23 (+ chained `try box.process.run()` at CmuxNextDaemon/Launch/ProcessRunner.swift:74),
  Process() 28. screen.close stalled main 807 ms on a spawn (2026-10-24).
- Security SecItem*/SecTrust*/SecCode* 93 in 27 files; NSWorkspace sync calls 91 in 61;
  CGWindowList/SCShareableContent 13; AX 8; getaddrinfo 10. The INV-2 command gives 128 lines.
- SMAppService: 16 hits; ServerLaunchAgent.swift and ServerStopServing.swift declare
  `status: @MainActor () -> SMAppService.Status` and call register() synchronously (IPC to launchd).
- `.runModal(`: 7 in 6 files (nested run loops on main).
- `DispatchQueue.global(`: 8 in 6 files; `URLSession(... delegateQueue: nil)`: 6.
- Ghostty C ABI: GhosttyRuntime.swift:199-208 calls ghostty_config_load_file /
  load_recursive_files on main at launch and on every reloadConfig.
- DaemonBridge.swift:113-121: `BridgeChild.terminate()` runs from `deinit`, sends SIGKILL and calls a
  blocking `waitpid(pid,&status,0)` INSIDE `state.withLock`.
- CPU on main: `JSONDecoder()` 190, `JSONSerialization.jsonObject` 225, image decode about 70,
  NSRegularExpression 23 (all targets; no rule).
- Blocking static/lazy/global initializers: 11 (for example CEFRuntime.swift, AppSymbolMap.swift:34,
  PairingWords.swift:14).

**Pool.** 204 Task.detached, 99 with no priority. 24 detached bodies call raw blocking code. Actor
files: 112 raw-blocking lines; @concurrent functions: about 148. 1,643 `Task {` sites. 48
`priority: .low|.utility|.background` Task sites (latency inversion when main awaits them).
maybe-main-blocking: 30 warnings. No actor in CmuxNext Sources has a custom executor; the only example
is `Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeCache.swift:21-32`.

**Task traits.** CmuxNextWakeups/BackgroundWork.swift (WorkPriority, BlockingLane files|system|cpu,
ShutdownBehavior, LaneScheduler): 8 run(mayBlock:) call sites and 1 post. `.files` is serial per
priority (BlockingLane.swift:9). WorkPriority.qos: userBlocking -> userInitiated, userVisible ->
default, bestEffort -> utility, idle -> background; no best-effort cap; no fence; no priority raise
(the doc accepts the inversion on macOS 14/15). QuitCoordinator never awaits work.shutdown().
UpdaterService.swift:209 and MarkdownLiveShareServer.swift:42 build private BackgroundWork instances.
Files, ChromiumRuntime, CrashReporting, CLIInstall and HangReports cannot reach BackgroundWork.

**QoS.** 47 DispatchQueue(label:), 25 with no qos or target, including the key echo path
(SocketWriter.swift:33, LocalPTYTerminalIO.swift:25) and the control socket (ControlSocketServer:89,
ControlConnection:53). 12 Thread creations, 5 with no qualityOfService. 4 unnamed OperationQueue().
`cmux.remote-view.render` (MetalYUVRenderer.swift:13) is userInteractive. 0
posix_spawnattr_set_qos_class_np.

**Inversion.** 9 queue.sync, 1 NSCondition, 2 DispatchSemaphore, 21 OSAllocatedUnfairLock (several on
audio taps with lock()/unlock(), for example SpeechAnalyzerAudioInput.swift:31-45), 3 NSLock. 133
Mutex sites; lock-wait is recorded only for the Compat Mutex.

**Hang watch.** MainThreadWatchdog watches only main (2 s hang -> crash report; >= 250 ms lag ->
Sentry and opt-in hang reports). No other thread is watched.

**Guardrails.** guardrails.py rules main-blocking, raw-blocking, thread-doc, task-priority (refuse) and
maybe-main-blocking (warn), on ADDED lines only. arch-ratchet blocking_allow_escapes = 0. ast-grep
no-main-thread-block.yml covers sleep/semaphore/wait/readToEnd/waitUntilExit/NSWorkspace.open.

**Rust (cmux-tui).** 0 QoS calls. 301 `thread::spawn(` and 285 `thread::Builder::new()`. Per-id thread
names in cmux-tui-core: 16 `name(format!(` (surface-{id}-reader, surface-{id}-host,
browser-surface-{id}-*, ...). 0 `on_thread_start` for 29 tokio runtimes; 84 non-test `block_on(`. No
clippy.toml. cmux-tui is a binary crate (src/main.rs; no lib.rs); cmux-holder and cmux-host have lib.rs
and main.rs. 9 of 77 crates do not take `lints.workspace`. `.github/workflows/cmux-tui-spec.yml:157-167`
runs a blocking `clippy -D warnings --all-targets` on the WHOLE workspace when the clippy config
changes. cmux-holder is single-threaded and forks the user's shell from its main thread
(cmux-holder/src/pty.rs:26-72). RegistryConnection is a parking_lot ReentrantMutex
(registry_connection.rs:22), held by the journal writer across commit and fsync. cmd_server.rs:291 runs
`ss`/`netstat` with Command::output() inside a request. rusqlite: 122 non-test files in cmux-tui-core.
`com.cmuxterm.link` (link/launchd.rs:20) and `host serve` (remote_host/service.rs:355) run with
launchd ProcessType Background; server-core units use Standard. Debug-only lockdep exists
(lock_rank.rs RankedMutex, 60 uses vs 472 std Mutex).

**Chromium.** In-process; the CEF pump runs on cmux's main thread (F2, owned by the CEF helper-app
program). Chromium's ThreadRestrictions are DCHECK-only, so they are off in shipped CEF.

## 3. Target design

### A. Thread restrictions (Swift)

- Every blocking primitive goes through one CmuxNextCompat/Threading seam. Each seam passes
  `#fileID/#line` and runs inside `blockingCall(kind)` (task 004), which in Debug/bench/Nightly
  checks the context and, when it records, measures wall time per site.
- Seams take a `borrowing BlockingPermit` that only `work.run` / `MayBlockRunner` bodies and
  registered dedicated threads can give (task 111). Permit-less seams are deprecated and `noasync`, so
  the compiler lists every call site that has no lane: Jarred's method applied to MQ-1 and MQ-3.
- Contexts: **main** (blocking, sync primitives and long CPU work disallowed); **pool** (Swift
  cooperative pool, label suffix `.cooperative`, and GCD root queues, prefix `com.apple.root.`:
  blocking disallowed); **lane** (BackgroundWork slot: blocking allowed, sync primitives disallowed:
  task 119); **dedicated** (a named thread or queue listed in threading-model.md: all allowed).
- New kinds: system-call, sleep, ipc-reply for SMAppService/XPC/AppleScript, fs-metadata, sqlite,
  process-reap, system-query, ffi, cpu-intensive (size-gated), wrong-lane (seam in a .cpu job),
  priority-inversion (awaited low work in an input turn), lane-sync.
- Allowances stay a friend list (BlockingAllowance static lets with doc rows), ratcheted by
  arch-ratchet blocking_allow_escapes (3 or fewer).
- Modes. **Debug**: record during the push, with an os_log fault and a Debug-menu badge per new site;
  after RUN-1 and RUN-5 pass once, task 021 flips main and pool to trap
  (CMUX_BLOCKING_TRAP=0 off switch). **Bench**: record. **Nightly**: compiled in with
  -DCMUX_BLOCKING_CHECKS, record, one non-fatal report per new site to opt-in hang reports and (only
  with crash-report consent) Sentry, capped at 5 per launch and 1 per site per 24 h; opt-in crash mode
  CMUX_BLOCKING_TRAP=1. **Release**: the assert is compiled out; Release keeps only the trace hook
  (one relaxed atomic load) and lane latency stats.
- Migration rule: a task that moves a raw call onto a seam must, in the same commit, move it off main
  and off the pool. A seam call on main is always a new bug.

### B. Task traits and scheduling (Swift)

- One BackgroundWork per process, built in AppServices and passed by init (P1). `MayBlockRunner`
  protocol in Compat for modules below Wakeups; `Packages/Shared/CmuxThreading` leaf for code shared
  with iOS (task 130).
- API: `work.run(priority, mayBlock: .files|.system|.cpu, shutdown:)`, `work.post(...)`,
  `work.task(priority, shutdown:) { async }` (task 012), `work.runHandle(...)` with `raise(to:)`
  (task 117), `work.sequence(label)` (task 116), `work.job(priority) { delegate in }` with
  `shouldYield` (task 125).
- QoS of lane levels (Chrome table, task 115): userBlocking and userVisible -> USER_INITIATED;
  bestEffort -> UTILITY (cmux differs from Chrome's BACKGROUND; reason: these items carry saves that
  must reach disk before a crash and get no shutdown raise on a crash; the cap of 2 below gives the
  person's I/O room); idle -> BACKGROUND.
- Lanes: `.files` width 4/3/2/1 by priority, ordered work through WorkSequence (task 116); `.system`
  width 6, 1 slot reserved for userBlocking, DNS capped at 4 (task 059); `.cpu` P-cores minus 1, no
  blocking (wrong-lane check, task 015). Best-effort plus idle at most 2 running per shared lane, idle
  at most 1 (task 115). Best-effort fence until launch settles (task 114).
- Shutdown: quit cancels skip items, awaits block items inside the quit deadline, and raises pending
  and running block items to USER_INITIATED (task 118). `.blockShutdown` is only for one bounded write
  (< 50 ms, atomic replace); Debug records a block item that runs > 250 ms. Migrations are resumable
  and use skip or continue.
- Task.detached is written by hand only inside CmuxNextWakeups. Children go through
  ProcessLauncher/AsyncProcess and `blockingPosixSpawn(qos:)`.
- Release keeps lane post-to-start and run-time log2 histograms per lane and priority (task 123) and
  trace intervals when tracing is on (task 124).

### C. QoS table (platform_thread_apple.mm)

- **userInteractive** (closed list in threading-model.md): main, frame clock, watchdog, quit/crash
  deadline, `cmux.remote-view.render` (compositor-class motion path, task 131), and the key echo path:
  app daemon reader, daemon socket writer, localpty read/write, terminal output lane; daemon mux-conn
  reader of the app's UI connection, mux-line-out, mux-pty-input, mux-attach-out,
  mux-render-attach-out, terminal-host-pty, terminal-host-parser, terminal-host-client-input,
  surface-{id}-reader, surface frames/host_frames, holder poll loop. Per-terminal echo threads of a
  hidden workspace drop to utility (task 236).
- **userInitiated**: request dispatch of the UI connection, userBlocking and userVisible lanes, daemon
  process main, mux-terminal-work, journal writer while a request can wait on it.
- **utility**: automation (control socket, CLI/MCP/hook/agent/remote daemon connections: task 224),
  bestEffort lanes, watchers, journal writer after PL-daemon removes the durable wait.
- **background**: idle only.
- Every DispatchQueue states qos: or target:, every Thread/OperationQueue sets qualityOfService and a
  name, every Task.detached states a priority, every URLSession has a named delegate queue, every
  tokio runtime sets thread_name and on_thread_start QoS. Child processes never inherit an echo
  thread's QoS (task 223). Each cmux process states its launchd ProcessType and Mach task role
  (tasks 234, 235).
- Rust leaf crate `cmux-tui/crates/cmux-threads`: ThreadQos, `spawn(name, qos, f)`, `set_current`,
  `with_qos`, registry (name, declared qos, desired qos slot, tid, pthread), blocking detector, checked
  wrappers, `work` lanes, hang watch, sync wrappers, tokio builder, process roles, reaper.
- clippy.toml disallowed-methods: std::thread::spawn, Builder::spawn, Builder::spawn_scoped,
  Builder::spawn_unchecked, std::thread::scope, std::thread::sleep. The workspace sets the lint to
  allow; each daemon crate opts in to deny in the same commit that empties its queue (task 202).

### D. No priority inversion

- Main-thread waits are only donating ones: Mutex (os_unfair_lock) with the 2 ms record, and
  `blockingSync` onto a serial queue of greater or equal QoS that is not on the key path.
- queue.sync onto a lower-QoS queue is refused (inventory rule sync-inversion).
- Main never awaits work started below userBlocking during an input turn: runtime check (task 112) and
  static rule (task 113). Keyed loads raise the priority of queued and running work (task 117).
- Rust: channel waits record the producer's QoS, and a higher-QoS waiter boosts the producer with
  `pthread_override_qos_class_start_np` (tasks 206, 238). The parking_lot RegistryConnection lock
  boosts its owner (task 226). std Mutex/RwLock/Condvar and RankedMutex record waits over 2 ms on
  request and echo threads (tasks 222, 227). SQLite and connection-lock chokepoints are checked scopes
  (task 225).
- threading-model.md gets a "waits on (QoS)" column for every row and a process-roles table.

### E. Hang watcher

- Chrome's per-thread atomic slot, not a timer per scope. `HangWatchScope` enter = one clock read
  plus one relaxed store of {deadline, mach port from `pthread_mach_thread_np(pthread_self())`} into
  the thread's slot (slots allocated on first use, bounded at 512 with an overflow counter). A global
  armed-scope count wakes the watchdog only on 0 -> 1. While the count is above 0, the watchdog
  sleeps until the earliest deadline and scans slots; at 0 it parks with no timer (0 idle wakes).
  Enter plus leave < 50 ns p99, no syscall.
- App scopes: daemon reader line handling (100 ms), TerminalOutputLane feed (100 ms, `// perf-hot:`),
  BackgroundWork lanes (files 5 s, system 30 s, cpu 10 s). Overrun -> sample that thread's stack,
  report kind + thread name to debug.hangs and the hang-report sink.
- Daemon `mux-hang-watch` thread, same design, watches request (250 ms) and echo threads plus the
  holder loop (100 ms); reports through server.stats.hangs, the panic log and a pushed
  `server.diagnostic_site` event to the app's sink (task 233). It never crashes.
- debug.hangs count250 and count100 are the Nightly readout.

### F. Daemon thread restrictions

- `cmux_threads::blocking`: `disallow_blocking()` at the entry of request and echo threads;
  `allow_blocking(AllowReason, f)` with `enum AllowReason { Shutdown, OwnDescriptor }`;
  OwnDescriptor is call-scoped (`own_fd_read(fd, buf)` / `own_fd_write`), never thread-wide;
  `#[track_caller] scoped_blocking_call(kind, f)`.
- Kinds include fs, process, recv/join/condvar/sleep, sqlite, block-on, ipc-reply (cross-process round
  trips to holder, terminal host, browser host: no exception on request and echo threads),
  lock-wait, priority-inversion.
- Debug default is RECORD during the push (CMUX_DAEMON_BLOCKING=panic opts in); task 021 flips it to
  panic after MQ-13 is empty. Release records per-site counters (256 sites + overflow).
- Work that may block moves to `cmux_threads::work` (Files, System, Cpu lanes; priority; shutdown).
  One-shot per-operation threads become work items (task 230). Child exits go through one kqueue
  reaper (task 237).

### G. Proof tools

threading-inventory.py (whole tree, JSONL, enclosing function, isolation, async, fan-in, file-ownership
graph), debug.threads / server.threads (requested QoS, effective priority, task role, declared row),
debug.blocking / server.blocking, debug.work (lane histograms), blocking-probe.sh (app + daemon +
Chromium bucket), lifecycle-sweep.py. No CI gates, jobs, steps or budget rows are added (Lawrence
2026-10-23); every check is pre-push or a fleet run the agent does.

## 4. Rules

R1. No blocking primitive outside a CmuxNextCompat/Threading seam (Swift) or a `cmux_threads` checked
    form (Rust). This includes FileManager through any receiver, POSIX, FileHandle, ImageIO URL I/O,
    sqlite3, sysctl/proc, Security, AX, DNS, WindowList, Launch Services, SMAppService, sync XPC,
    NSAppleScript, process launch and reap, and Ghostty config loads (ffi kind).
R2. A seam call runs on a lane or a listed dedicated thread, never on main, the cooperative pool or a
    GCD root queue. Move it in the same commit that adds the seam.
R3. Keep the input's turn synchronous (P4): show the change, then reconcile. A sync main function with
    fan-in above 3 reads a snapshot refreshed off main; it does not become async.
R4. Actor methods that block use a custom serial executor on a named queue at the actor's QoS (the
    HomeCache pattern, `// executor: <label>`). Use `await work.run` in an actor method only when it
    reads no actor state after the await.
R5. No hand-written Task.detached outside CmuxNextWakeups; no DispatchQueue.global; no
    `delegateQueue: nil`; no nested `runModal(` (NSPrintOperation's sheet form with `delegate:` is not
    one); no blocking in static, lazy or global initializers.
R6. Every queue, thread, OperationQueue, tokio runtime, child process and launchd plist states its QoS
    or role, and the label is in threading-model.md.
R7. `.blockShutdown` only for one bounded write (< 50 ms). Migrations are resumable.
R8. Awaited work from an input turn starts at userBlocking, or its handle is raised.
R9. No lock covers I/O, waitpid, kill or close.
R10. Allowances: Swift BlockingAllowance and Rust AllowReason total 3 or fewer each, each with a doc row.
R11. No new CI gate. Each fix has a regression test written red-first; tests run in batched fleet
     waves (section 7), not per task.
R12. Compat changes land in one early batch (wave 0) and Compat is then frozen for 24 h, so later
     tasks do not rebuild every target.

## 5. Done checks

- **INV-1** `python3 scripts/cmux-next/threading-inventory.py --count` on the head: raw-blocking = 0
  (974 today); raw-blocking-ext = 0 (about 700 today); main-blocking = 0 (7); pool-blocking = 0
  (about 284); maybe-main-blocking = 0 (30); task-priority = 0 (about 133 plus 8 global plus 6
  delegateQueue nil); thread-doc = 0; sync-inversion = 0; once-blocking = 0 (11); cpu-intensive = 0;
  awaited-low-priority = 0; the linked Shared/iOS package section has the same rules at 0.
- **INV-2** `rg -n --glob '!**/CmuxNextCompat/Threading/**' --glob '!**/CmuxNextCompatAppKit/Threading/**' --glob '!**/CmuxNextCompatAppKit/NSWorkspace+Background.swift' -e 'SecItem(CopyMatching|Add|Update|Delete)\(|SecTrustEvaluate|SecStaticCodeCheckValidity|SecCodeCopy|AXUIElement(Copy|PerformAction|SetAttributeValue)|getaddrinfo\(|CGWindowList(Copy|Create)|LSCopy|NSWorkspace\.shared\.(open\(|activateFileViewerSelecting|selectFile|urlForApplication|urlsForApplications|icon\()|SMAppService\.(agent|daemon)\([^)]*\)\.(status|register\(|unregister\()|AuthorizationCopyRights|synchronousRemoteObjectProxy|executeAndReturnError' Packages/macOS/CmuxNext/Sources`
  = 0 lines (128 today for the first part).
- **INV-3** `rg -n 'try [\w.]+\.run\(\)|\.waitUntilExit\(\)|readDataToEndOfFile\(\)|posix_spawnp?\(|(?<![\w.])waitpid\([^)]*,\s*0\)' -P Packages/macOS/CmuxNext/Sources --glob '!**/CmuxNextWakeups/Process*.swift' --glob '!**/CmuxNextWakeups/AsyncProcess.swift' --glob '!**/CmuxNextCompat/Threading/**'` = 0 (35+ today).
- **INV-4** Swift `blocking-allow:` plus allowBlocking( total 3 or fewer, each with a row in
  threading-model.md "Reviewed blocking allowances"; arch-ratchet blocking_allow_escapes 3 or fewer.
  Rust: `rg -c 'AllowReason::' cmux-tui/crates --glob '!**/cmux-threads/**'` sites are listed in the
  doc and the enum has 3 or fewer variants.
- **INV-5** `rg -n --pcre2 'DispatchQueue\.global\(|delegateQueue: *nil|\.runModal\((?![^)]*delegate:)|OSAllocatedUnfairLock|NSLock\(' Packages/macOS/CmuxNext/Sources --glob '!**/CmuxNextWakeups/**' --glob '!**/CmuxNextCompat/**'`
  = 0, except audio-tap locks marked `// lock-allow: realtime audio tap`.
- **RUN-1** Fleet Debug build: every-action-sweep light and STRESS, then lifecycle-sweep (RUN-12), with
  CMUX_BLOCKING_TRAP=1 and CMUX_BLOCKING_TRAP_POOL=1, exit 0 with 0 traps. `debug.blocking` reports
  main, pool, lane-sync, wrong-lane, cpu-intensive, priority-inversion and lock-wait sites = 0,
  overflow = 0.
- **RUN-2** `scripts/measure/blocking-probe.sh --config=bench` (STRESS): 0 main-thread waits >= 1 ms
  whose first cmux frame is cmux code; main off-CPU time in cmux frames < 0.5 ms per action at p99.
  The app_chromium bucket total is reported as an OPEN number against the "0 main-thread blocking"
  target and filed to the CEF helper-app program; the target is not called met while it is above 0.
- **RUN-3** (a) threads: `debug.threads` in STRESS, window visible and once hidden/occluded: 100% of
  cmux-created threads registered; requested QoS (THREAD_QOS_POLICY, overrides excluded) equals
  declared; effective priority (THREAD_EXTENDED_INFO pth_curpri) and process task role are reported;
  0 cmux threads at USER_INTERACTIVE outside the closed list; third-party threads (Ghostty, CEF,
  WebKit, iroh, WebRTC, Sentry) have "declared by library" rows, and Ghostty threads of a hidden
  workspace read UTILITY. (b) queues: every DispatchQueue init has a qos/target literal equal to its
  doc row (inventory), and `DispatchQueue.checked(label:qos:)` lists them in debug.threads.
- **RUN-4** Daemon `server.threads`: 0 unregistered daemon threads; echo threads user-interactive for
  the UI connection and utility for automation connections; dispatch user-initiated (UI) / utility
  (automation); tokio workers named and registered; peak thread count under perf-10x-lifecycle STRESS
  recorded and lower than the base. Each daemon crate root (lib.rs and main.rs) has
  `#![cfg_attr(not(test), deny(clippy::disallowed_methods))]`; `cargo clippy` gives 0 errors; the
  cmux-tui-spec clippy script (`-D warnings --all-targets`, whole workspace) is green on the fleet.
- **RUN-5** Daemon Debug in panic mode: `cargo test -p cmux-tui-core -p cmux-tui` pass with 0 blocking
  panics on request or echo threads. perf-10x-lifecycle part=daemon: 0 `server.blocking` sites and
  every op p95 no worse than the base (PL-daemon target < 2 ms).
- **RUN-6** Key echo: SocketWriter, LocalPTY read/write, TerminalOutputLane and the daemon reader are
  .userInteractive in unit tests; no echo hop runs on a `.cooperative` thread (task 133);
  bench-typing STRESS key-to-frame p99 no worse than the base (target p50 <= 8.3 ms, p99 <= 16.7 ms).
- **RUN-7** Shutdown: quit awaits `work.shutdown()`; a .blockShutdown save posted 1 ms before quit is on
  disk after quit; .skipOnShutdown items queued at quit never run; block items read
  QOS_CLASS_USER_INITIATED after shutdown starts (Swift and Rust).
- **RUN-8** Hang watch: an injected 150 ms stall on a registered thread (100 ms deadline) and a 6 s
  .files item each give exactly one report naming the thread and kind; with no scope armed, 0 watchdog
  wakeups in 5 s; enter+leave < 50 ns p99.
- **RUN-9** Nightly: the nightly-next app contains BlockingViolationTable symbols
  (blocking-checks.sh --expect nightly); a violation reaches the hang-report sink with no path
  strings; a pre-install launch violation is replayed; a daemon site reaches the app sink; a 60-minute
  STRESS soak of a Nightly-config build gives 0 blocking reports and debug.hangs count250 = 0.
- **RUN-10** macOS 14 and 15 Tart VMs: the app launches; a Task.detached seam call and a
  DispatchQueue.global seam call are classified pool; lane jobs are lane; priority raise works.
- **RUN-11** Release: blocking-checks.sh release mode reports 0 detector assert symbols;
  check-release-compile.sh passes.
- **RUN-12** lifecycle-sweep.py (launch cold/warm, quit, sleep/wake, display change, appearance
  change, daemon kill -9 and reconnect, Chromium helper crash, update install) with traps: exit 0.
- **RUN-13** `debug.work` in STRESS: userBlocking queue-wait p99 <= 2 ms on every lane; launch bench
  cold and warm no worse than the base with the best-effort fence (targets 300 / 150 ms).

## 6. Machine queues

Each hit or row is one task item; the orchestrator chunks at 25 hits by call-graph root
(`--group root`) and merges chunks that share a file (task 110).

- **MQ-1 raw-blocking (Swift).** `python3 scripts/cmux-next/threading-inventory.py --rule raw-blocking --group root --max-hits 25` (before task 001: the rg pattern in guardrails RAW_BLOCKING; 974 hits). Tasks 060-101.
- **MQ-2 main-blocking.** `--rule main-blocking --jsonl` (7 today, task 006); afterwards any hit is a regression.
- **MQ-3 pool-blocking.** `--rule pool-blocking --group module --max-hits 25` (task 010). About 284 today. Tasks 047-052.
- **MQ-4 maybe-main-blocking.** `--rule maybe-main-blocking` (30). Task 053.
- **MQ-5 task-priority.** `--rule task-priority --group module --max-hits 22`: 99 detached + 25 queues + 5 threads + 4 OperationQueues + 8 global + 6 delegateQueue nil. Tasks 030-034, 041-045, 120.
- **MQ-6 process launch.** INV-3 command plus `\bProcess\(\)`. Tasks 037-040, 128.
- **MQ-7 Apple synchronous APIs.** INV-2 command, grouped by API family. Tasks 054-057, 059, 140.
- **MQ-8 sync waits and locks.** `rg -n --glob '!**/CmuxNextCompat/**' -e '\.sync\s*(\{|\(execute:)|DispatchSemaphore\(|NSCondition\(|NSLock\(\)|NSRecursiveLock|OSAllocatedUnfairLock|[\w)\]]\.wait\((timeout:|wallTimeout:)?[^)]*\)' Packages/macOS/CmuxNext/Sources | rg -v 'await '`. Tasks 035-036.
- **MQ-9 thread-doc.** `--rule thread-doc`. Tasks 034, 022.
- **MQ-10 runtime Swift (test phase).** every-action-sweep and lifecycle-sweep in record mode, then `debug.blocking` JSON; each (fileID, kind, context) site grouped by module is one task p02-threads-R<n>.
- **MQ-11 runtime probe (test phase).** blocking-probe.sh bench STRESS; each first-cmux-frame with total wait >= 1 ms is one task; app_chromium rows go to the CEF program.
- **MQ-12 Rust thread spawns.** Fleet: `cd cmux-tui && cargo clippy -p <crate> -- -W clippy::disallowed_methods 2>&1 | rg 'disallowed method'`. Diff reviewer: `rg -n -g '*.rs' -g '!*tests*.rs' -g '!**/tests/**' -e 'thread::Builder::new\(\)|thread::spawn\(|thread::scope\(' cmux-tui/crates/<crate>`. Tasks 210-218, 229.
- **MQ-13 runtime daemon (test phase).** Daemon Debug record mode running the test suites plus perf-10x-lifecycle; `server.blocking` JSON; each (location, kind, thread) is one task.
- **MQ-14 static daemon request-path primitives.** `rg -n -B1 --no-heading -g '*.rs' -g '!*tests*' -e 'std::fs::|fs::(write|read|read_to_string|create_dir_all|remove_file|rename|metadata|read_dir)\(|File::(open|create)\(|OpenOptions::new|\.sync_all\(|\.sync_data\(|Command::new\(|thread::sleep|\.recv\(\)|\.recv_timeout\(|\.join\(\)|rusqlite|\.flock|flock\(|\.block_on\(' <paths> | awk '/mq14-allow: /{allow=1; next} /^[^:]+:[0-9]+:/{if(!allow)print} {allow=0}'`. `sync_*` matches std's method form only: the checked form `files::sync_all(&file)` (cmux_threads::checked::fs) does not. A hit on a thread that is not a request path (a writer, watcher or start thread waiting for its own queue or spawning its own child) carries `// mq14-allow: <the thread and why>` on the line directly above, as the repo's other `<rule>-allow:` escapes; review checks the reason. Paths: server/, mux/ (tasks 220-221) and workspace_registry/, state/, terminal_host_runtime/, git_ops/, apps/, journal_*, chief_*, conversation_*, output_store/, resource_router/, fs_ops/, holder_runtime/ (task 231).
- **MQ-15 runtime QoS audit.** debug.threads / server.threads rows with declared=false or mismatch. Task 302.
- **MQ-16 raw-blocking-ext.** `--rule raw-blocking-ext --group module --max-hits 25` (task 126; about 700). Tasks 141-144.
- **MQ-17 linked Shared/iOS packages.** `--rule raw-blocking --rule raw-blocking-ext --rule pool-blocking --rule task-priority --paths <linked package list> --group module`. Task 146.
- **MQ-18 cpu-intensive.** `--rule cpu-intensive --group module --max-hits 25` (task 121). Task 145.
- **MQ-19 awaited-low-priority.** `--rule awaited-low-priority` (task 113; 48 low-priority Task sites are the base). Task 147.
- **MQ-20 std lock types in daemon request paths.** clippy disallowed_types for std::sync::{Mutex,RwLock,Condvar} opted in per module in server/ and mux/. Task 227.
- **MQ-21 one-shot daemon threads.** Spawns whose closure has no loop, and every `name(format!(` per-id thread (16 in cmux-tui-core). Task 230.
- **MQ-22 once-blocking.** `--rule once-blocking` (11). Task 122.
- **MQ-23 compiler permit queue.** After task 111: `swift build 2>&1 | rg 'is deprecated: Pass the BlockingPermit|unavailable from asynchronous'` on the fleet. Each diagnostic is an MQ-1/MQ-3 item; the queue is empty when INV-1 is.

## 7. Schedule and test phases (72 h)

- **Wave 0 (h0-6), one Compat batch then freeze:** 003, 004, 005, 014, 016 (Compat protocol), 111,
  119 (Compat part), 121 (seams), 127. Tooling in parallel: 001, 002, 010, 011, 110, 113, 122 (rule),
  126. Rust: 200, 201, 202, 204.
- **Wave 1 (h6-30):** scheduler (012, 013, 114-118, 123-125), 006, 007, 008, 030-037, 128, 129,
  132, 133, 140, Rust 203, 205, 206, 210, 211, 223, 225, 226, 228, 234, 235, 237.
- **Wave 2 (h12-48):** machine queues MQ-1, -3..-8, -16..-22 by file-ownership graph; Rust 212-218,
  220, 221, 224, 227, 229-233, 236, 238.
- **Test phase (h40-72), batched, per the "speed over gates" rule:** implementers land after diff
  review plus a T0 compile. Each module wave runs its new tests once at the base (expect red) and
  once at the head (expect green) on the fleet.
  - T0: compile / static (inventory, rg, pytest of scripts locally).
  - T1: batched unit wave on the fleet (`cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-test-with-hang-sampler.sh` with the wave's filters; Rust `cargo test -p ...` on the fleet).
  - T2: every-action-sweep and lifecycle-sweep (`cmux-ci run --class exclusive`).
  - T3: benches and probes (bench-typing, blocking-probe, perf-10x-lifecycle, launch bench, Tart).
  - T4: Nightly build and soak.

## 8. Risks

1. Debug trap during the push would stop many agents' dogfood builds. Mitigation: record by default,
   loud fault plus badge; flip in task 021 only after RUN-1 and RUN-5 pass once.
2. Sync-to-async changes ordering. Mitigation: R3 snapshot recipe; reviewers check every entry point
   (cmux-shared-behavior); inventory emits fan-in so chunks follow call-graph roots.
3. Actor reentrancy: a new await inside an actor method can lose updates. Mitigation: R4 executor
   default; reviewer check "no actor-state read after a new await".
4. Merge conflicts: about 100 tasks share files (for example AcpmuxEnvironment+BuildHomeAdoption.swift
   in 036/038/047/060; LaneScheduler.swift in 005/015/017/114-119/123/125). Mitigation: task 110
   computes one owner per file per wave; directory-wide tasks run last in their module.
5. Compat changes rebuild 83 targets. Mitigation: R12 wave-0 batch and freeze.
6. Pool detection by libdispatch label (`.cooperative`, `com.apple.root.`) is not API. Task 305
   checks macOS 14 and 15; fallback is task-local plus not a registered queue.
7. nightly.yml (task 007) is risk:high: it needs an independent `Review (...): SHIP at <sha>`
   receipt and a green compile, or Nightly record mode slips past 72 h.
8. Too many userInteractive threads cost energy. Mitigation: closed list, automation connections at
   utility (224), hidden-workspace demotion (236), child QoS reset (223).
9. Adding clippy.toml turns the whole-workspace clippy job red unless the workspace sets
   `disallowed_methods = "allow"` in the same commit (task 202). Run the cmux-tui-spec clippy script on
   the fleet before push.
10. Owner coordination (OWNERS.md): cmux-tui-core is PL-daemon, holder_runtime PL-holder, acpmux
    PL-acpmux, CmuxNextWakeups the Performance Lead. Tasks 212, 216, 218, 226, 231 tell the owner.
    Journal writer QoS depends on PL-daemon removing the durable wait.
11. The in-process Chromium pump (F2) still runs Chromium on cmux's main thread. RUN-2 reports it as
    open; the fix is the CEF helper-app program.
12. Text heuristics in pool-blocking, once-blocking and awaited-low-priority can misjudge generic or
    nested contexts. The runtime detector and the compiler permit (111) are the real guards.
13. The BlockingPermit (111) depends on `~Copyable` borrowing closure parameters and `noasync` under
    Swift 6.2 tools with a macOS 14 target. A 1-hour prototype decides; fallback is a non-Sendable
    final class with an internal init.
14. No CI gates (Lawrence 2026-10-23): a regression after push is caught by the perf cron and
    Nightly reports, not at merge.
15. Release keeps the main-context assert compiled out for the 72 h (decision below). Chrome plans a
    non-fatal dump in official builds; cmux follows only after Nightly shows 0 reports for a week.
16. Lowering the journal writer to Utility without the owner boost (226) makes every request wait on a
    throttled thread. Task 212 depends on 226.

## 9. Review disposition

Review 1 (coverage):

- raw-blocking blind to FileManager variables, POSIX, FileHandle, ImageIO, sqlite3, sysctl:
  CONFIRMED (217 + 25 + about 470). Applied: tasks 126 (rule), 127 (seams), 141-144 (MQ-16).
- Scope limited to CmuxNext Sources: CONFIRMED (Package.swift links Shared/iOS). Applied: 130, 146.
- Holder fork inherits UserInteractive: CONFIRMED (pty.rs:26-72). Applied: 223 (merged with
  review 2's 208); 207 depends on it.
- All daemon connections at echo QoS: Applied: 224.
- Registry lock does not donate: CONFIRMED (parking_lot ReentrantMutex). Applied: 226; 212 depends on
  it; 227 for std locks.
- MQ-14 too narrow, no rusqlite/flock/block_on; git_ops and cmd_server.rs:291 on the request thread:
  CONFIRMED. Applied: 225, 231, MQ-14 pattern extended.
- Lint roots wrong (cmux-tui has no lib.rs) and missing crates: CONFIRMED. Applied: 202, 219, 229.
- Thread per operation; tokio runtimes without QoS; block_on: CONFIRMED (16 per-id names, 0
  on_thread_start, 84 block_on). Applied: 228, 230.
- Quit waits on low-QoS block items: Applied: 118 (merged with review 3's 405).
- Rust work idle-exit contradiction: Applied in 204 (timed wait only above the minimum count).
- MQ-6 regex misses chained receivers: CONFIRMED (ProcessRunner.swift:74). Applied: INV-3, 002, 040.
- Pre-install violations not replayed: Applied in 008.
- remote-view render userInteractive not on the list; third-party threads: CONFIRMED. Applied: 131.
- Lifecycle events not swept; Ghostty config loads on main; waitpid under a lock in deinit:
  CONFIRMED. Applied: 307, 129, 128.
- HomeCache path outside scope: CONFIRMED. Applied: real path in 010, 047 and R4.
- Missing tasks 400-429: all applied (renumbered: 126, 127, 141-144, 128, 120, 129, 130, 131, 132,
  114, 118, 125, 113, 133, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 307).

Review 2 (feasibility):

- clippy.toml turns workspace clippy red: CONFIRMED (cmux-tui-spec.yml:157-167). Applied: 202 now
  sets workspace allow in the same commit; per-crate deny when the queue is empty; "warn now" stage
  dropped.
- Lint roots: applied (see above).
- Holder fork QoS: applied (223).
- Daemon panic default contradicts 211: Applied: record default in 201; flip in 021.
- Debug trap during the push: Applied: 006 no longer flips; 021 flips both after the sweep.
- MQ-1 sync functions spreading async: Applied: 001 emits enclosing function, isolation, async and
  fan-in; chunk by root; R3 snapshot recipe.
- Actor reentrancy: Applied: R4 and the 047 recipe.
- Hang watch kqueue timer per scope; daemon min-heap: Applied: per-thread atomic slot in 016 and 205.
- File overlap between tasks: CONFIRMED. Applied: 110.
- INV-2 never reaches 0 and wrong baseline: CONFIRMED (128). Applied: exclusion and baseline; 057
  and 058 merged into 057.
- SMAppService and sync IPC missing: CONFIRMED (16 hits). Applied: 002, 003 seams, 140, INV-2.
- 036 premise wrong (OSAllocatedUnfairLock already donates): Applied: 036 narrowed to main-reachable
  locks; audio-tap locks keep `// lock-allow:`.
- RUN-3 queue audit meaningless at runtime: Applied: RUN-3 split (threads runtime, queues static).
- 015 vs 004 contradiction: Applied: compensation dropped; 015 becomes the wrong-lane check. Release
  blockingCall = body plus a trace-flag load (124).
- pool-blocking misses `Task {}` in nonisolated code and DispatchQueue.global: Applied: 010, 011, 120.
- Latency inversion left to reviewers: Applied: 112 (runtime) and 113 (static), 117 (raise).
- Control socket at utility skews benches: Applied: 031 checks bench input timestamps on main.
- Sentry volume and consent: Applied: 008 consent gate and caps.
- Linux renice cannot go down: Applied in 204 (fixed workers per priority) and 200.
- Per-task fleet tests vs "speed over gates": Applied: section 7 batched waves.
- 065 migrations as blockShutdown: Applied: R7, 065, 012 Debug check.
- AllowReason OwnDescriptor not in 201: Applied in 201; Rust INV-4.
- Chromium excluded from RUN-2: Applied: RUN-2 open number; 301 and 306 hand off.
- Missing 002b, 003b, 023, 059b, 208, 209, 025: applied as 110, 111, 112, 140, 223, 202, 021.
- Missing 224 (clippy disallowed fs/Command/recv per module): DROPPED. Reason: clippy has one
  `disallowed_methods` lint and one workspace clippy.toml; once a crate denies the lint for thread
  spawns (202), listing fs/Command/recv would fire on every one of the 592 + 872 fs sites in those
  crates, not only server/ and mux/. MQ-14 rg plus the runtime detector cover it.

Review 3 (Chrome fidelity):

- Chrome reference item 5 misread; serial files lane: CONFIRMED. Applied: reference corrected; 116
  (parallel files lane plus WorkSequence). Compensation for .files/.system: DROPPED. Reason: cmux
  lanes are split by kind, so the width already budgets for blocking; compensation needs a Release
  hook and hides misclassified work. 059 reserves a userBlocking slot and caps DNS instead.
- QoS mapping differs from Chrome: Applied in 115: userVisible -> USER_INITIATED and the cap of 2.
  bestEffort stays UTILITY with a written reason (design B). This is a decision for the user (see
  the result).
- Hang watch cost: applied (016, 205).
- GCD root queues are pools: applied (005, 120).
- Sync primitives on lanes: applied (119).
- CPU-intensive work on main: applied (121, 145).
- No priority raise; waiter boost: applied (117, 238).
- Shutdown raise: applied (118).
- No startup fence: applied (114, merged with review 1's 412).
- OwnDescriptor thread-wide; thread per child wait: applied (201 call-scoped wrapper, 237 reaper).
- Echo threads missing from 210; hidden terminals at UserInteractive: CONFIRMED
  (surface-{id}-reader at spawn.rs:325). Applied: 210 list, 236.
- Child task roles: applied (235).
- RUN-3 reads requested QoS only; ProcessType Background: CONFIRMED (link/launchd.rs:20,
  remote_host/service.rs:355). Applied: RUN-3, 234 (merged with review 1's 428).
- Release compiled out, no lane data: partly applied (123, 124). The assert stays out of Release for
  the push (risk 15).
- Static initializers: applied (122).
- DNS shares the system lane: applied (059).
- Disallowed list misses scope/spawn_scoped and tokio blocking pool: applied (202, 218, 228).
- ipc-reply in the daemon: applied (201).

## 10. Task table

Size S <= 150 lines, M <= 400, L = a machine-queue task split into <= 25-hit chunks by the
orchestrator. "MQ-1 recipe" is defined in task 060. Tests are written red-first and run in the batched
waves of section 7.

| id | title | size | depends on | queue |
| --- | --- | --- | --- | --- |
| 001 | Whole-tree threading inventory (queue generator, call-graph fields) | M | | MQ-1..5, 9 tooling |
| 002 | Guardrails see every blocking primitive class (incl. SMAppService, XPC, chained run) | S | 003 | |
| 003 | Seams for system calls (Security, AX, DNS, WindowList, Workspace, SMAppService, sleep) | M | | |
| 004 | blockingCall scope with wall-time stats | M | | |
| 005 | Pool context: cooperative pool and GCD root queues; lanes are MayBlock | M | 004 | |
| 006 | Fix the 7 seam calls on main; record mode with fault and badge | M | 001 | MQ-2 |
| 007 | Nightly compiles the detector in | S | | |
| 008 | Blocking sink: hang reports + gated Sentry non-fatal, replay | M | 004 | |
| 009 | Nightly opt-in crash mode | S | 008 | |
| 010 | pool-blocking rule | M | 001 | MQ-3 generator |
| 011 | task-priority rule: threads, OperationQueues, detached, global, delegateQueue nil | S | 012 | |
| 012 | BackgroundWork.task; quit awaits work.shutdown(); blockShutdown bound | M | | |
| 013 | One BackgroundWork per process | S | | |
| 014 | MayBlockRunner protocol in Compat | S | | |
| 015 | Wrong-lane check: blocking seam in a .cpu job | S | 004, 005 | |
| 016 | HangWatchScope with per-thread atomic slots | M | | |
| 017 | Hang scopes on key-path threads and lanes | S | 016 | |
| 018 | debug.threads: requested QoS, effective priority, role, registry | M | | |
| 019 | Hang 250 ms / 100 ms counters | S | | |
| 020 | blocking-probe: daemon, thread filter, Chromium bucket | M | | |
| 021 | Flip Debug and daemon defaults to trap/panic after the sweep | S | 300, 303, 052 | |
| 022 | threading-model.md final tables (app, daemon, process roles) | S | 034, 210, 234 | |
| 030 | Key echo queues at user-interactive | S | | MQ-5 |
| 031 | Control socket queues at utility; bench timestamps on main | S | | MQ-5 |
| 032 | QoS on unstated queues, group 1 | S | | MQ-5 |
| 033 | QoS on unstated queues, group 2 | S | | MQ-5 |
| 034 | Threads and OperationQueues: QoS and names | S | | MQ-5, MQ-9 |
| 035 | Sync waits that cross QoS; sync-inversion rule | M | | MQ-8 |
| 036 | Main-reachable locks to Mutex; no I/O under a lock | M | | MQ-8 |
| 037 | posix_spawn: seam, off main, child QoS | M | 223 | MQ-6 |
| 038 | Process.run migration part 1 | M | 014 | MQ-6 |
| 039 | Process.run migration part 2 | M | | MQ-6 |
| 040 | Process.run migration part 3 (+ ProcessRunner, UpdateDropBack) | M | 014 | MQ-6 |
| 041-045 | Task.detached without priority, parts 1-5 | M | 012 | MQ-5 |
| 047-052 | pool-blocking by module | M | 005, 010 | MQ-3 |
| 053 | maybe-main-blocking | M | 001 | MQ-4 |
| 054-055 | Security calls off main, parts 1-2 | M | 003 | MQ-7 |
| 056 | NSWorkspace queries off main | M | 003 | MQ-7 |
| 057 | NSWorkspace.open/reveal to background variants (merged 057+058) | S | | MQ-7 |
| 059 | WindowList, SCShareableContent, AX, DNS, LSCopy off main; DNS cap | M | 003 | MQ-7 |
| 060-101 | raw-blocking by module (MQ-1 recipe) | M | 006 (+014/013/041) | MQ-1 |
| 110 | File-ownership graph for the task set | S | 001 | |
| 111 | BlockingPermit: compiler-enforced MayBlock scope | M | 004, 014 | MQ-23 generator |
| 112 | Debug check: awaited low-priority work in an input turn | S | 004 | |
| 113 | awaited-low-priority static rule | S | 001 | MQ-19 generator |
| 114 | Best-effort fence until launch settles | S | 012 | |
| 115 | Best-effort cap and Chrome QoS mapping | S | | |
| 116 | Files lane parallel per priority + WorkSequence | M | 115 | |
| 117 | WorkHandle.raise: queued move and running override | M | 012 | |
| 118 | Shutdown raises block-shutdown work (Swift and Rust) | S | 117, 204 | |
| 119 | Sync primitives disallowed on lanes and Rust workers | M | 005, 201 | |
| 120 | Migrate DispatchQueue.global and delegateQueue nil | S | 005, 011 | MQ-5 |
| 121 | CPU-intensive seams and rule | M | 001, 004 | MQ-18 generator |
| 122 | once-blocking rule and the 11 initializers | M | 001 | MQ-22 |
| 123 | Lane queue-wait and run histograms in all builds | S | | |
| 124 | Trace intervals for blocking scopes and lane jobs | S | 004 | |
| 125 | Yieldable CPU jobs (ShouldYield) | M | 115 | |
| 126 | raw-blocking-ext rule | M | | MQ-16 generator |
| 127 | POSIX, FileHandle, ImageIO, SQLite, sysctl, SMAppService, LAContext seams | M | 004, 126 | |
| 128 | Blocking reaps: no waitpid under a lock or on global queues | S | 127 | MQ-6 |
| 129 | Ghostty config loads off main | M | 004 | |
| 130 | Linked Shared/iOS packages: inventory and CmuxThreading leaf | M | 001, 126 | MQ-17 generator |
| 131 | Registry rows for third-party threads; remote-view render | S | 018 | |
| 132 | No nested modal run loops | S | | |
| 133 | Key echo path never hops through the pool | M | 030 | |
| 140 | SMAppService / launchd IPC off main | S | 003 | MQ-7 |
| 141-144 | raw-blocking-ext chunks (App; AgentPane+HomeEngine; Control..Design; rest) | L | 127, module tasks | MQ-16 |
| 145 | cpu-intensive chunks | L | 121 | MQ-18 |
| 146 | Shared/iOS package fix chunks | L | 130 | MQ-17 |
| 147 | awaited-low-priority fix chunks | M | 113, 117 | MQ-19 |
| 200 | Rust crate cmux-threads: ThreadQos, spawn, registry | M | | |
| 201 | cmux-threads::blocking (record default, friend list, ipc-reply) | M | 200 | |
| 202 | clippy.toml + workspace allow; per-crate opt-in deny | S | 200 | MQ-12 generator |
| 203 | server.threads and server.blocking | S | 201 | |
| 204 | cmux-threads::work lanes | M | 200 | |
| 205 | Daemon hang watch, atomic slots | M | 200 | |
| 206 | Channel inversion detection (std + crossbeam) | S | 201 | |
| 207 | Daemon and holder process QoS | S | 200, 037, 223 | |
| 210 | Echo-path daemon threads at UserInteractive; disallow blocking | M | 201 | MQ-12 |
| 211 | Request dispatch threads; disallow blocking | S | 201 | MQ-12 |
| 212 | Journal, storage and maintenance thread QoS | S | 200, 206, 226 | MQ-12 |
| 213-218 | Spawn migration by crate area | M/L | 202 | MQ-12 |
| 219 | Final check: deny on every daemon crate root | S | 216, 217, 218, 229 | |
| 220-221 | Checked primitives on request path: server/, mux/ | L | 201, 204 | MQ-14 |
| 222 | RankedMutex contention timing | S | 201 | |
| 223 | Child processes never inherit echo-path QoS | S | 200 | |
| 224 | Daemon connection QoS by client class | M | 210, 211 | |
| 225 | SQLite and connection-lock chokepoints are checked scopes | M | 201 | MQ-13 feeder |
| 226 | Registry connection lock boosts its owner | M | 200 | |
| 227 | std Mutex/RwLock/Condvar timing wrappers | L | 201 | MQ-20 |
| 228 | tokio runtimes named and QoS-set; block_on checked | M | 200, 201 | |
| 229 | Spawn migration for missed daemon-linked crates | L | 202 | MQ-12 |
| 230 | One-shot daemon threads become work items | L | 204, 213 | MQ-21 |
| 231 | Request-path blocking outside server/ and mux/ | L | 201, 204, 225 | MQ-14 |
| 232 | Hang scopes on daemon echo threads and holder loop | S | 205 | |
| 233 | Daemon diagnostic sites pushed to the app's reports | M | 008, 203, 205 | |
| 234 | launchd ProcessType per process role | S | | |
| 235 | Mach task roles for cmux processes | S | 200 | |
| 236 | Hidden workspaces demote per-terminal daemon threads | M | 210 | |
| 237 | One kqueue reaper for child exits | M | 200, 204 | |
| 238 | Waiter boosts its producer on cross-QoS waits | S | 206 | |
| 300-306 | Test phase (sweep, probe, QoS audit, daemon panic, soak, Tart, results) | M/S | see detail | MQ-10, 11, 13, 15 |
| 307 | Test phase: lifecycle sweep with traps | M | 300 | MQ-10 |

### Task details

Paths are relative to the repo root. `S/` means `Packages/macOS/CmuxNext/Sources/`, `T/` means
`Packages/macOS/CmuxNext/Tests/`, `R/` means `cmux-tui/crates/`.

**p02-threads-001 Whole-tree threading inventory.** Files: scripts/cmux-next/threading-inventory.py,
scripts/cmux-next/tests/test_threading_inventory.py. Change: import guardrails.py as a module (rules
unchanged) and judge every line of HEAD with main-blocking, raw-blocking, maybe-main-blocking,
task-priority, thread-doc (base = empty tree 4b825dc6). JSONL {rule, path, line, module, ui_target,
text, enclosing_func, is_async, isolation (main/pool/nonisolated/actor), caller_count (rg on the
function name)}. Flags --rule, --paths, --count, --group module|root --max-hits N, --jsonl. Later
tasks add rules. Acceptance: on 772cdfc45ac --count gives raw-blocking within 5% of 974 and
task-priority >= 120; guardrails.py unchanged; fixture has one hit per rule and an `await x.wait(` non-hit;
a sync main function with 4 callers reports caller_count 4; no network, no file writes. Test: T0 pytest.

**002 Guardrails see every blocking primitive class.** Files: guardrails.py, tests/test_guardrails.py.
Change: add Process launch (`try [\w.]+\.run\(\)` with a Process receiver, `.launch()`),
waitUntilAllOperationsAreFinished, asyncAndWait, pthread_join, pthread_cond_wait, NSConditionLock,
`.lock(whenCondition:`, SecItem*/SecTrustEvaluate*/SecStaticCodeCheckValidity/SecCodeCopy*,
AXUIElement*, getaddrinfo, CGWindowList*, LSCopy*, NSWorkspace query calls, SMAppService
status/register/unregister, AuthorizationCopyRights, synchronousRemoteObjectProxy,
NSAppleScript.executeAndReturnError. SEAM_BLOCKING gets the task 003 seams. Keep the await exemption.
Acceptance: each new primitive is refused as main-blocking in a main-actor fixture and raw-blocking in a
nonisolated fixture; seam calls off main are not refused; 60,000-line speed test < 1.0 s. Test: T0.

**003 Seams for system calls.** Files: S/CmuxNextCompat/Threading/{BlockingKind, Security+Blocking,
Accessibility+Blocking, HostResolution+Blocking, WindowList+Blocking, NSWorkspace+Blocking,
ServiceManagement+Blocking}.swift, T/CmuxNextCompatTests/BlockingSystemSeamTests.swift. Change: kinds
system-call, sleep, ipc-reply use (stable raw values); seams blockingSecItem*, blockingSecTrustEvaluate,
blockingSecStaticCodeCheckValidity, blockingAX*, blockingGetaddrinfo, blockingWindowList*,
NSWorkspace.blockingURLForApplication/blockingIcon, blockingSMAppServiceStatus/Register/Unregister,
blockingAuthorizationCopyRights. Each forwards #fileID/#line through blockingCall. Acceptance: each seam
< 15 lines with DocC; main-actor test records exactly one site per seam with the caller's line; off main
0; no other file changes. Test: T1 wave 0.

**004 blockingCall scope.** Files: S/CmuxNextCompat/Threading/{BlockingCheck, BlockingSite,
BlockingViolationTable}.swift, S/CmuxNextControl/Diagnostics/BlockingControl.swift,
T/CmuxNextCompatTests/BlockingCheckTests.swift. Change: `@inlinable func blockingCall<R,E>(_ kind:,
fileID:, line:, _ body: () throws(E) -> R) throws(E) -> R`; it asserts and, only while recording a
violation, measures with mach_absolute_time into atomics (count, total, max). Existing seams route
through it. debug.blocking prints total_ms, max_ms. Release: body plus one relaxed load of the trace
flag (task 124). Acceptance: BlockingCheckCostTests pass (off-main path one pthread_main_np + one branch,
no clock read); a 5 ms usleep inside blockingCall(.sleep) on main reports max_ms >= 5;
check-release-compile.sh passes. Test: T1 wave 0.

**005 Pool context.** Files: S/CmuxNextCompat/Threading/{BlockingCheck, BlockingViolation,
BlockingViolationTable, BlockingContext}.swift, S/CmuxNextWakeups/LaneScheduler.swift,
S/CmuxNextControl/Diagnostics/BlockingControl.swift, T/CmuxNextCompatTests/BlockingPoolContextTests.swift.
Change: BlockingContext {main, pool, lane, dedicated}. Off main: read thread-local flags (mayBlock,
syncAllowed) first; else read dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL): suffix
`.cooperative` or prefix `com.apple.root.` is pool. LaneScheduler sets mayBlock around each job;
`DispatchQueue.checked(label:qos:)` and registered threads set dedicated. Pool mode records unless
CMUX_BLOCKING_TRAP_POOL=1. debug.blocking splits by context. Acceptance: Task.detached seam call -> 1
pool site; DispatchQueue.global().async seam call -> 1 pool site; inside work.run(.userVisible,
mayBlock: .files) -> 0; named serial queue -> 0; fast path one TLS read + at most one label compare (50
ns p99). Debug and bench only. Test: T1 wave 0; RUN-10.

**006 Fix the 7 seam calls on main.** Files: S/CmuxNextAgentPane/AgentPaneFileDrag.swift,
S/CmuxNextApp/DeepLinks/CmuxAppLinks.swift, S/CmuxNextApp/Pages/Files/MarkdownShare/MarkdownLiveShareServer.swift,
S/CmuxNextTerminal/LocalPTYTerminalIO.swift, S/CmuxNextDaemon/Launch/TerminalEnvironment.swift,
S/CmuxNextCompat/Threading/{BlockingViolationTable, BlockingMode}.swift, plans/cmux-next/threading-model.md.
Change: move each call (AgentPaneFileDrag:67, CmuxAppLinks:45, MarkdownLiveShareServer:183,
LocalPTYTerminalIO:196, TerminalEnvironment:102/112) into work.run(.userBlocking, mayBlock: .files) or
resolve it ahead of the input turn. Debug mode stays record; each new site also logs an os_log fault and
sets a Debug-menu badge. The trap flip is task 021. Acceptance: --rule main-blocking = 0; each site has a
red-first main-actor test with 0 violations; mode resolution read once at table init. Test: T1; T2.

**007 Nightly compiles the detector in.** Files: .github/workflows/nightly.yml,
scripts/measure/blocking-checks.sh. Change: append -DCMUX_BLOCKING_CHECKS to the nightly-next track's
OTHER_SWIFT_FLAGS; blocking-checks.sh gets `--app PATH --expect nightly` (nm). risk:high: Review SHIP
receipt on the exact head. Acceptance: only the nightly-next flags and the script change; the main-track
nightly is unchanged; the script exits non-zero when symbols are missing. Test: T4.

**008 Blocking sink.** Files: S/CmuxNextApp/HangReports/{BlockingReportSink, WatchdogReporting}.swift,
S/CmuxNextHangReports/{HangReportCollector, HangSample}.swift, T/CmuxNextHangReportsTests/BlockingSampleTests.swift.
Change: BlockingReportSink (final, Sendable, Mutex) copies kind, context and frames (image UUID +
offset) into HangReportCollector.noteBlocking (source .blocking). Sentry non-fatal only when crash-report
consent is on; cap 5 per launch and 1 per site per 24 h (kept on disk through the bestEffort lane). At
install, one drain pass replays sites already in the table. Install line in WatchdogReporting.install.
Acceptance: fake violation -> one HangSample with no String paths (PrivacyLeakScanner); duplicate site
adds nothing; a pre-install violation is replayed; the global cap holds; the sink runs on the drain
queue; one install line. Test: T1.

**009 Nightly opt-in crash mode.** Files: BlockingViolationTable.swift, BlockingMode.swift,
T/.../BlockingCheckTests.swift, threading-model.md. Change: in CMUX_BLOCKING_CHECKS non-DEBUG builds,
CMUX_BLOCKING_TRAP=1 (read once) flushes the sink synchronously (bounded 50 ms), os_log fault,
__builtin_trap. Default record. Document the DCHECK_IS_CONFIGURABLE model. Acceptance: no env records;
env=1 resolves to trap (mode value tested); Release compiles none of it. Test: T1 via blocking-checks.sh.

**010 pool-blocking rule.** Files: guardrails.py, threading-inventory.py, tests/test_guardrails.py.
Change: refuse an added raw or seam blocking call in a Task.detached body, a `Task {` body inside a
nonisolated function of a non-UI target, a method of an `actor` type (not a global actor, not one with
`// executor: <label>`), or an @concurrent function. Escape `// blocking-allow:` (ratcheted). The
executor fixture copies `Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeCache.swift:21-32`
(DispatchSerialQueue executor). Acceptance: fixtures for each context refused; work.run closure not
refused; executor actor not refused; --count printed. Test: T0.

**011 task-priority rule.** Files: guardrails.py, tests/test_guardrails.py, plans/cmux-next/PATTERNS.md.
Change: refuse a Thread with no `.qualityOfService =` within 40 lines, OperationQueue() without
qualityOfService and name within 10 lines, new Task.detached outside S/CmuxNextWakeups (unless
`// qos-allow:`), new `DispatchQueue.global(`, new `delegateQueue: nil`. P14 names work.task. Acceptance:
fixtures for each refusal and the escape; existing hits not refused. Test: T0.

**012 BackgroundWork.task; quit awaits shutdown.** Files: S/CmuxNextWakeups/{BackgroundWork,
BackgroundWork+Task}.swift, S/CmuxNextApp/Quit/QuitCoordinator.swift,
T/CmuxNextWakeupsTests/BackgroundWorkTaskTests.swift. Change: `func task<T: Sendable>(_ priority:,
shutdown: = .skipOnShutdown, _ op: sending @escaping @isolated(any) () async throws -> T) ->
Task<T, any Error>` registered in the drain state; shutdown() cancels skip, lets continue run, awaits
block. QuitCoordinator awaits services.work.shutdown() once after the journal flush, inside its
deadline. Debug: a .blockShutdown item that runs > 250 ms records a violation. DocC: blockShutdown is
for one bounded write only. Acceptance: block task finishes before shutdown returns; skip task sees
cancellation; post-shutdown non-block task gets CancellationError; 0 registered after 1,000 tasks; the
250 ms check fires in a test. Test: T1.

**013 One BackgroundWork per process.** Files: S/CmuxNextUpdater/UpdaterService.swift,
S/CmuxNextApp/Pages/Files/MarkdownShare/MarkdownLiveShareServer.swift, S/CmuxNextApp/AppServices.swift.
Change: remove the default `BackgroundWork(label:)` arguments; AppServices passes `work`. Acceptance:
`rg -n 'BackgroundWork\(' S` only in AppServices.swift (tests excluded); no new stored property. Test: T0;
T1.

**014 MayBlockRunner protocol.** Files: S/CmuxNextCompat/Threading/MayBlockRunner.swift,
S/CmuxNextWakeups/BackgroundWork+MayBlockRunner.swift, T/CmuxNextWakeupsTests/MayBlockRunnerTests.swift.
Change: `public protocol MayBlockRunner: Sendable` with runFiles/runSystem/postFiles
(MayBlockPriority mirrors WorkPriority); BackgroundWork conforms; Files, ChromiumRuntime,
CrashReporting, CLIInstall, HangReports take `any MayBlockRunner` by init. Acceptance: < 120 lines;
mapping identical to WorkPriority.qos; arch-layers.py clean. Test: T1 wave 0.

**015 Wrong-lane check.** Files: S/CmuxNextWakeups/LaneScheduler.swift,
S/CmuxNextCompat/Threading/{BlockingContext, BlockingKind}.swift,
T/CmuxNextWakeupsTests/LaneWrongLaneTests.swift. Change: replaces the compensation design. A blocking
seam inside a .cpu lane job records kind wrong-lane (Debug/bench); the fix is to move the job to .files
or .system. Acceptance: a .cpu job with Data(blockingContentsOf:) records 1 wrong-lane site; a .files job
records 0; Release has no extra code. Test: T1.

**016 HangWatchScope with per-thread atomic slots.** Files: S/CmuxNextControl/Diagnostics/{HangWatchScope,
MainThreadWatchdog}.swift, S/CmuxNextCompat/Threading/HangWatching.swift,
T/CmuxNextControlTests/HangWatchScopeTests.swift. Change: protocol HangWatching in Compat
(`enter(_ name: StaticString, deadline:) -> HangWatchToken`, `leave`). Each thread gets a slot on first
use (bounded 512, overflow counter) holding Atomic<UInt64> deadline and the mach port from
`pthread_mach_thread_np(pthread_self())`. Enter = clock read + relaxed store; a global armed count wakes
the watchdog on 0 -> 1 only. While armed, the watchdog sleeps to the earliest deadline and scans; at 0 it
parks with no timer. Overrun: thread_get_state sample, report {thread, kind: hang, ms} to onHang and
debug.hangs. Acceptance: 100 ms scope + 150 ms sleep -> one report naming the thread; 50 ms -> none; 0
watchdog wakes in 5 s with no scope; enter+leave < 50 ns p99 and 0 syscalls (cost test); < 400 lines.
Test: T1 wave 0 (Compat part).

**017 Hang scopes on key-path threads and lanes.** Files: S/CmuxNextWakeups/{LaneScheduler,
BackgroundWork}.swift, S/CmuxNextDaemon/Connection/LineTransport.swift,
S/CmuxNextTerminal/TerminalOutputLane.swift, S/CmuxNextApp/AppServices.swift. Change: BackgroundWork
takes `hangs: (any HangWatching)?`; job scopes files 5 s, system 30 s, cpu 10 s; daemon line handling
(not the read wait) 100 ms; TerminalOutputLane feed 100 ms marked `// perf-hot: 50ns terminal-feed`.
Acceptance: no scope around read(2) or a queue wait (diff review); a fake HangWatching sees enter/leave
with 5 s for a files job; no behavior change when nil. Test: T1; T2.

**018 debug.threads.** Files: S/CmuxNextCompat/Threading/ThreadRegistry.swift,
S/CmuxNextControl/Diagnostics/ThreadsControl.swift, S/CmuxNextControl/ControlService.swift,
T/CmuxNextControlTests/ThreadsControlTests.swift. Change: ThreadRegistry (Debug/bench) holds declared
{name or prefix, qos, kind: cmux|library} rows from threading-model.md; `DispatchQueue.checked(label:qos:)`
registers queues by declaration. debug.threads enumerates task_threads: pthread_getname_np, requested QoS
(THREAD_QOS_POLICY tier, overrides excluded), effective priority (THREAD_EXTENDED_INFO pth_curpri),
dispatch label, CPU time, plus the process task role (task_policy_get TASK_CATEGORY_POLICY). Output
{name, label, requested_qos, effective_pri, declared, match}; queues listed from the registry.
Acceptance: named .utility Thread -> one row requested utility, declared utility, match true; undeclared
-> declared null; DEBUG or CMUX_BENCH_HOOKS only. Test: T1; RUN-3.

**019 Hang counters.** Files: MainThreadWatchdog.swift, S/CmuxNextControl/Diagnostics/HangLog.swift,
scripts/cmux-next/perf-cron.py. Change: count250 and count100 since launch/reset in debug.hangs (the hang
report CoarseCounts half is 024, after the server change 023); perf-cron prints count250 (read only, no gate). Acceptance: injected 300 ms and 120
ms stalls -> count250=1, count100=2. Test: T1.

**020 blocking-probe.** Files: scripts/measure/blocking-probe.sh, scripts/measure/blocking-probe/probe.c,
scripts/measure/blocking-probe-report.py. Change: CMUX_PROBE_THREADS prefix filter; load the probe into
the daemon with CMUX_PROBE_THREADS=mux-conn,mux-control-dispatch,mux-line-out,mux-pty-input,mux-attach-out,surface-;
report sections app_main, app_chromium, daemon_request. Acceptance: self-test row present; the three
sections exist; nothing links into cmux. Test: T3.

**021 Flip Debug and daemon defaults.** Files: S/CmuxNextCompat/Threading/{BlockingMode,
BlockingViolationTable}.swift, R/cmux-threads/src/blocking.rs, threading-model.md. Change: after RUN-1
and RUN-5 pass once in record mode: Swift Debug main and pool modes trap (CMUX_BLOCKING_TRAP=0 off);
daemon debug panics (CMUX_DAEMON_BLOCKING=record off). Acceptance: only two default values and the
mode paragraph change; main-blocking = 0, pool-blocking = 0, MQ-13 empty at the head. Test: T2 sweep 0
traps; T1r 0 panics.

**022 threading-model.md final tables.** Files: plans/cmux-next/threading-model.md, PATTERNS.md. Change:
thread/queue table with target QoS and "waits on (QoS)"; daemon table of every registered thread; the
closed userInteractive list; process-roles table (launchd ProcessType, task role, spawn QoS); seams,
contexts, modes, allowances (Swift and Rust), lane widths and the sequence rule; why the daemon keeps
thread-per-connection instead of a reactor, and the per-terminal thread count that must not grow. Remove
"Unnamed today". Acceptance: --rule thread-doc = 0 unlisted; no userInteractive outside the closed list;
STE. Test: T0.

**023 Hang report server accepts the stall counts.** Files: web/services/hangReports/wireSchema.ts,
web/tests/hang-reports-route.test.ts. A separate web/ PR against main. Change: the strict decoder
(onExcessProperty "error") accepts optional whole-number count100 and count250 under counts, bounded, and
the stored report keeps them. It lands and deploys before 024: before that, the server refuses every
NIGHTLY report that has the keys. Acceptance: counts.count100=2, count250=1 decodes and is stored; a
report without them still decodes; a negative, fractional or string value is refused. Test: T1 (bun test).

**024 Hang report CoarseCounts carry the stall counts.** Depends 019, 023. Files:
S/CmuxNextHangReports/CoarseCounts.swift, S/CmuxNextApp/HangReports/WatchdogReporting.swift,
HangReportWireFormatTests.swift. Change: the CoarseCounts half of 019 (019 did debug.hangs only, because
of 023): optional count100 and count250, encoded only when present, from watchdog.stallCounts in
WatchdogReporting.counts. Acceptance: 300 ms and 120 ms stalls -> counts.count250=1, count100=2; a report
without a watchdog encodes no key. Test: T1.

**030 Key echo queues.** Files: S/CmuxNextDaemon/Connection/SocketWriter.swift,
S/CmuxNextTerminal/LocalPTYTerminalIO.swift, T/CmuxNextDaemonTests/SocketWriterQoSTests.swift,
threading-model.md. Change: qos .userInteractive with `// qos-allow: key echo path`; internal queueQoS for
tests. Acceptance: tests read .userInteractive for both; exactly two inits change. Test: T1; RUN-6.

**031 Control socket at utility.** Files: S/CmuxNextControl/{ControlSocketServer, ControlConnection}.swift,
threading-model.md, T/CmuxNextControlTests/ControlSocketQoSTests.swift. Change: accept and per-connection
queues qos .utility; main hop keeps MainWorkClass.automation. A test asserts that debug.key and bench
injection take the input timestamp on main at injection, not at socket accept. Acceptance: two init
changes plus the qos test and the timestamp test; existing bench injection test green. Test: T1; T3
bench-typing STRESS before and after.

**032 / 033 QoS on unstated queues, groups 1 and 2.** Files and QoS as in the design (032:
RetryWake, ProcessRunner, DaemonVersionHandoff, DaemonService, ConfigFileWatcher, CEFChildProcessMonitor,
ProviderConnection, UnixSocketLane, AgentActivityLineConnection, UpdaterService+Flow; 033:
RemoteRdStreamTransport, MockRemoteStreamSource, RemoteFetchPinnedTransport, ImportHistorySync,
AcpmuxLogProgress, AcpmuxDaemonLauncher, AcpmuxCheckedLine, AcpmuxVersionHandoff, AcpmuxStatusClient,
ChiefSettleNotice, HomeFixtureMedia). Use `DispatchQueue.checked(label:qos:)` where available. No
.userInteractive. Acceptance: --rule task-priority --paths <files> = 0; every label in the doc with the
same QoS. Test: T0; RUN-3.

**034 Threads and OperationQueues.** Files: WebKitSetupGate, ComputerUseHelperV2Spawner,
ChromiumHostLauncher, ChromiumHostConnection, AcpmuxPaneSocket, AgentChatPullRequestReader,
URLSessionChromiumRuntimeDownloader, HomePromisedFiles, threading-model.md. Change as in the design (named
threads with QoS; 4 delegate OperationQueues named with QoS). Acceptance: task-priority and thread-doc 0
in these files. Test: T0; RUN-3.

**035 Sync waits that cross QoS.** Files: ConfigFileWatcher, RunMarkerFile, RemoteRdStreamTransport+Service,
AcpmuxCheckedLine, TerminalOutputLane, TypingLatencyProbe, HangEpisodeRecorder, TerminalEventQueue,
QuitDeadline, threading-inventory.py. Change: queue.sync -> blockingSync onto >= QoS or Mutex state;
NSCondition.wait -> blockingWait; QuitDeadline semaphores -> blockingWait on its dedicated thread; rule
sync-inversion. Acceptance: MQ-8 rg 0 raw .sync/.wait outside Compat; sync-inversion = 0; ConfigFileWatcher
start/stop from main records 0. Test: T1; T2.

**036 Main-reachable locks to Mutex.** Files: the 20 files of the design list. Change: the inventory marks
a lock main-reachable (declared in a main-actor-default target or used in a @MainActor member); only those
become Compat Mutex (lock-wait recorded). Audio-tap and realtime locks (Dictation
SpeechAnalyzerAudioInput, SFSpeechDictationTranscriber, DictationAudioRecording, DictationAudioLevelMeter)
keep OSAllocatedUnfairLock with `// lock-allow: realtime audio tap, os_unfair_lock donates`.
ServerFixPriorStore: file I/O moves out of the lock onto work.post(.bestEffort, mayBlock: .files).
Acceptance: INV-5 lock part = 0 except lock-allow lines; no lock body has an MQ-1 primitive;
global_mutable_statics does not grow. Test: T0; T1 Dictation/HostPressure.

**037 posix_spawn sites.** Files: AcpmuxDaemonLauncher, ComputerUseHelperV2Spawner,
AgentPaneShellCompletionProcess, AgentPaneShell, ChromiumHostLauncher, CrashWatcher, DaemonBridge,
S/CmuxNextCompat/Threading/ProcessSpawn+Blocking.swift. Change: blockingPosixSpawn(qos:) sets
posix_spawnattr_set_qos_class_np; calls from a .system lane or dedicated thread. Child QoS: daemon and
Chromium host USER_INITIATED; acpmux, agent shell, Computer Use DEFAULT; shell completion, crash watcher
UTILITY. Acceptance: `rg 'posix_spawnp?\('` outside Compat/Threading = 0; spawning /usr/bin/true from a
lane records 0 main violations. Test: T1; T2.

**038 / 039 / 040 Process.run migration.** Files as in the design; 040 also takes
S/CmuxNextDaemon/Launch/ProcessRunner.swift (chained `try box.process.run()`) and
S/CmuxNextUpdater/UpdateDropBack.swift. Change: run-to-end children through AsyncProcess, long-lived
through ProcessLauncher; QoS from WorkPriority.processQoS; Files uses an AsyncProcess-like protocol in
Compat; ServerHelperDeadline uses a dedicated .utility thread. Acceptance: INV-3 command 0 in these
files; fake-launcher tests assert QoS and 0 main violations. Test: T1.

**041-045 Task.detached without priority, parts 1-5.** Files as in the design. Change: blocking bodies
-> work.run(priority, mayBlock: lane); async bodies -> work.task(priority, shutdown:). Focus and
CreationInputCoordinator: no new await before the visible change. History writes .bestEffort,
.blockShutdown only for a single bounded write. Acceptance: task-priority = 0 and pool-blocking = 0 in
the files; no new Task.detached; HomeChiefAvatars test asserts lane .files and .userVisible; 044 app net
lines do not grow. Test: T1.

**047-052 pool-blocking by module** (047 AgentPane; 048 HomeEngine + Home; 049 CmuxNextApp; 050 Browser,
BrowserImport, BrowserCore, BrowserAutomation, Design; 051 Daemon, DaemonService, Mobile, Remote, Cloud,
Settings, MacScreen; 052 the rest, after 047-051). Change (actor recipe, R4): an actor whose job is I/O
gets a custom serial executor on a named queue at its QoS (copy HomeCache.swift:21-32, DispatchSerialQueue,
macOS 14 OK), marked `// executor: <label>` and listed in the doc; the blocking call stays synchronous.
`await work.run` only when the method reads no actor state after the await. Detached and @concurrent
bodies use work.run. Known sites as in the design. Acceptance: --rule pool-blocking = 0 for the module;
reviewer check "no actor-state read after a new await"; RUN-1 pool sites from the module = 0. Test: T1;
T2 with CMUX_BLOCKING_TRAP_POOL=1.

**053 maybe-main-blocking.** As in the design: move into work.run; @concurrent alone is not a fix.
Acceptance: rule = 0, pool-blocking does not grow. Test: T1.

**054 / 055 Security calls off main.** As in the design, through the 003 seams on .system; credentials
read on an input path come from a cache warmed at launch; SecStaticCodeCheckValidity cached per path and
mtime. Acceptance: MQ-7 Security pattern = 0 outside Compat; fake-keychain tests 0 main violations.
Test: T1; T2.

**056 NSWorkspace queries off main.** As in the design: seams on .system, bounded LRU, prefetch for the
visible list. Acceptance: query pattern = 0 outside Compat; open-with menu opens from cache with 0 main
violations. Test: T1; T2.

**057 NSWorkspace.open/reveal to background variants (057+058 merged, 11 sites).** Files: the call
sites from `rg -n 'NSWorkspace\.shared\.(open\(|activateFileViewerSelecting|selectFile)' S --glob '!**/NSWorkspace+Background.swift'`.
Change: openInBackground/revealInBackground. Acceptance: that rg = 0. Test: T0; T2.

**059 WindowList, SCShareableContent, AX, DNS, LSCopy off main.** Files: MQ-7 hits for these APIs plus
S/CmuxNextWakeups/LaneScheduler.swift. Change: 003 seams on .system; .system reserves 1 slot for
userBlocking; DNS has its own cap of 4 inside .system (a hung resolver never holds keychain or AX work);
picker window lists prefetched on open intent; AX in Computer Use on the helper thread or .system.
Acceptance: pattern = 0 outside Compat; a test with 6 hung DNS items still starts a userBlocking
SecItem item at once; Computer Use test 0 main violations. Test: T1; T2.

**060 MQ-1 recipe (AgentPane A: Acpmux*.swift, AgentChatPullRequestReader.swift).** For each hit:
(1) replace the raw primitive with its seam (FileManager.checked.<op>, Data/String(blockingContentsOf:),
blockingWrite, blockingResourceValues, FileHandle.blocking*, ProcessLauncher/AsyncProcess,
blockingPosixSpawn), passing the permit (task 111) once it lands. (2) In the same commit, if the code can
run on main or on a pool, move the call onto `try await work.run(<priority from the caller's
MainWorkClass>, mayBlock: .files)` or `work.post(.bestEffort, mayBlock: .files, shutdown:
.blockShutdown)` for one bounded save; ordered saves use a WorkSequence (task 116). If the enclosing
function is sync, main-isolated and has fan-in above 3 (inventory caller_count), do NOT make it async:
keep a value snapshot refreshed off main (FolderWatch or a launch load) and read it synchronously. Actor
members follow R4. Take `work` (or `any MayBlockRunner`) by init from AppServices. (3) Keep the input's
turn synchronous (P4). Never add allowBlocking, blocking-allow:, sleeps, polling or a Task hop that keeps
the same wait. Acceptance: `--rule raw-blocking --rule main-blocking --rule pool-blocking --paths <files>`
= 0; no new allowBlocking, blocking-allow: or Task.detached; each changed user-reachable main path has a
red-first test (main actor, test table, 0 violations). Test: T1 wave; T2.

**061-101 raw-blocking by module.** Same recipe and acceptance; files and notes as in the design:
061-063 AgentPane B-D; 064-067 HomeEngine A-D (065: migrations are resumable, write to temp plus atomic
rename per step, `.continueOnShutdown`, never blockShutdown); 068-074 CmuxNextApp (app net lines do not
grow); 075-076 BrowserImport; 077-078 Updater (depends 013); 079-080 Browser; 081 Design; 082 Files
(MayBlockRunner, depends 014); 083 Daemon; 084 Mobile; 085 Diff; 086 Onboarding; 087 Cloud; 088
Control; 089 Settings; 090 Phone; 091 ChromiumRuntime + CLIInstall (014); 092 Pages + Home; 093
BrowserAutomation + BrowserCore; 094 CrashReporting + HangReports + ErrorJournal (014); 095 Terminal +
Remote; 096 DesignTokens, Palette, FilesUI, Icons, FileGrid; 097 ImportSuggestions, ImportCards,
Bookmarks, History, Screenshots; 098 Wakeups, Apps, MobileHost, ComputerUse, ServerHelper; 099
RemoteBrowser, HostedChief, NowPlaying, MacScreen, AgentActivity, DaemonService; 100 the tail; 101
leftovers after 100 (INV-1 raw-blocking = 0). Dependencies: 006 for main-actor modules; 066 also 041.

**110 File-ownership graph.** Files: threading-inventory.py, tests/test_threading_inventory.py. Change:
`--task-graph tasks.json` expands each task's file list (directories and chunk placeholders resolved from
the inventory) and prints {file, tasks[], resolution}: depends_on edges or merges so each file has one
owner per wave (order by task id; directory-wide tasks after per-file tasks of the same module).
Acceptance: on 772cdfc45ac the output lists AcpmuxEnvironment+BuildHomeAdoption.swift under
036/038/047/060 and LaneScheduler.swift under its tasks; after the edges are applied, 0 shared files per
wave; no network, no writes. Test: T0.

**111 BlockingPermit.** Files: S/CmuxNextCompat/Threading/{BlockingPermit, MayBlockRunner}.swift,
S/CmuxNextWakeups/BackgroundWork.swift, T/CmuxNextCompatTests/BlockingPermitTests.swift. Change: Chrome's
friend-class ScopedAllowBlocking as a type: `public struct BlockingPermit: ~Copyable` (non-Sendable;
init package-internal to Compat/Wakeups and the dedicated-thread registry). work.run and MayBlockRunner
bodies receive `borrowing BlockingPermit`. Seam overloads take the permit; permit-less seams are
`@available(*, deprecated)` and every seam is `@available(*, noasync)`. First a 1-hour prototype under
Swift 6.2 tools, macOS 14 target; fallback non-Sendable final class. Acceptance: `work.run(...) { permit in
try Data(blockingContentsOf: url, permit) }` compiles and records 0; a compile-fail fixture shows the
noasync diagnostic from an async function; existing seam sites compile with warnings only;
check-release-compile.sh passes. Test: T1 wave 0.

**112 Awaited low-priority runtime check.** Files: S/CmuxNextWakeups/BackgroundWork.swift,
S/CmuxNextCompat/Threading/BlockingKind.swift, T/CmuxNextWakeupsTests/BackgroundWorkInversionTests.swift.
Change: in DEBUG and CMUX_BENCH_HOOKS, awaited run (not post) called on main while an input action is
open (ActionBudgetMonitor or MainWorkClass.input) with priority < .userBlocking records kind
priority-inversion (record only). Acceptance: input turn + .bestEffort -> 1 site; .userBlocking -> 0;
outside an input turn -> 0; Release unchanged. Test: T1; T2 lists sites.

**113 awaited-low-priority static rule.** Files: guardrails.py, threading-inventory.py,
tests/test_guardrails.py. Change: rule refuses a Task/Task.detached created at .utility/.low/.background
(or work.task(.bestEffort/.idle)) whose `.value`/`.result` is awaited in main-actor code in the same file
or through a stored property of the same type. Acceptance: fixtures: stored-handle await refused;
fire-and-forget low task not refused; userInitiated awaited from main not refused; --count recorded.
Test: T0.

**114 Best-effort fence.** Files: S/CmuxNextWakeups/{BackgroundWork, LaneScheduler}.swift,
S/CmuxNextApp/AppServices.swift, S/CmuxNextApp/LaunchSettle.swift,
T/CmuxNextWakeupsTests/BestEffortFenceTests.swift. Change: beginBestEffortFence() at AppServices init,
endBestEffortFence() from LaunchSettle after the first committed frame plus settle, with a 3 s cap. While
up, .bestEffort and .idle stay queued in order; shutdown() lifts it first. Acceptance: pre-fence
bestEffort item starts only after release (within 5 ms); userBlocking starts at once; the cap releases
with no frame; one begin site and one end site; no timer while the fence is down. Test: T1; T3 launch
bench before and after.

**115 Best-effort cap and QoS mapping.** Files: S/CmuxNextWakeups/{LaneScheduler, WorkPriority}.swift,
T/CmuxNextWakeupsTests/LaneBestEffortCapTests.swift, threading-model.md. Change: at most 2 running
.bestEffort+.idle per shared lane, at most 1 .idle (Chrome kMaxBestEffortTasks); userVisible qos and
processQoS -> userInitiated (Chrome kDefault); bestEffort stays utility with the written reason.
Acceptance: system width 6 with 10 bestEffort runs at most 2 at once; userBlocking starts at once; a lone
bestEffort item runs with cpuWidth 1; WorkPriority.userVisible.qos == .userInitiated. Test: T1.

**116 Files lane parallel + WorkSequence.** Files: S/CmuxNextWakeups/{LaneScheduler, BackgroundWork,
BlockingLane, WorkSequence}.swift, T/CmuxNextWakeupsTests/FilesLaneSequenceTests.swift,
threading-model.md. Change: .files width 4/3/2/1 by priority; `work.sequence(label) -> WorkSequence`
runs its items in order, never two at once, on any slot, each at its own priority. Acceptance: two
userBlocking files items, first blocked 200 ms, second done < 10 ms; 100 sequenced writes in order with no
overlap; doc lane table updated. Test: T1.

**117 WorkHandle.raise.** Files: S/CmuxNextWakeups/{LaneScheduler, LaneJob, BackgroundWork}.swift,
T/CmuxNextWakeupsTests/LanePriorityRaiseTests.swift. Change: `work.runHandle(...)` returns a handle with
`raise(to:)`: a queued item moves to the higher list; a running item gets
pthread_override_qos_class_start_np on its slot thread (recorded at start), ended in the done path.
Replace the "no later escalation" doc paragraph. Acceptance: raised queued item starts before 5 others;
one override start and one end (test hook); equal/lower raise does nothing. Test: T1; T3 Tart.

**118 Shutdown raises block-shutdown work.** Files: S/CmuxNextWakeups/{BackgroundWork,
LaneScheduler}.swift, R/cmux-threads/src/work.rs, T/CmuxNextWakeupsTests/ShutdownQoSTests.swift.
Change: shutdown() requeues pending block items at userBlocking and starts a USER_INITIATED override on
running ones; Rust work::shutdown sets the worker's QoS before join. Acceptance: an .idle blockShutdown
item reads QOS_CLASS_USER_INITIATED after shutdown starts; a running bestEffort block item gets exactly one
override; skip behavior unchanged; Rust twin test. Test: T1; T1r; RUN-7.

**119 Sync primitives disallowed on lanes.** Files: S/CmuxNextCompat/Threading/{BlockingKind,
BlockingCheck, BlockingContext}.swift, S/CmuxNextWakeups/LaneScheduler.swift,
R/cmux-threads/src/blocking.rs, T/CmuxNextCompatTests/BlockingSyncPrimitiveTests.swift. Change: kinds
sync-wait, lock-wait > 2 ms and ipc-reply are the syncPrimitive class; lanes set mayBlock but not
syncAllowed, so such a wait records context lane-sync; dedicated threads allow it. Rust work workers: same
for recv, recv_timeout, join, condvar wait. Acceptance: .files job with blockingWait -> 1 lane-sync; with
blockingContentsOf -> 0; dedicated thread -> 0; Rust work item checked recv -> 1 in record mode. Test: T1;
T1r.

**120 Migrate DispatchQueue.global and delegateQueue nil.** Files: S/CmuxNextCompat/NSWorkspace+Background.swift,
S/CmuxNextTerminal/TerminalLinkFilter.swift, S/CmuxNextCrashReporting/CrashWatcher.swift,
S/CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift, S/CmuxNextAgentPane/{AgentPaneShell,
AgentPaneShellCompletionProcess}.swift, and the 6 `delegateQueue: nil` files (CloudOwnerAPIClient,
InstallHTTPTransport, CertificateProbeResult, BackdropUserImages+Import, CloudService+AppServer,
IconAssetStore). Change: global dispatches -> work lanes or a named registered queue
(NSWorkspace+Background on .system); URLSession gets a named OperationQueue with qualityOfService.
Acceptance: `rg -n 'DispatchQueue\.global\(|delegateQueue: *nil' S` = 0 outside CmuxNextWakeups. Test: T0;
RUN-3.

**121 CPU-intensive seams and rule.** Files: S/CmuxNextCompat/Threading/{BlockingKind,
CPUIntensive+Blocking}.swift, threading-inventory.py, T/CmuxNextCompatTests/CPUIntensiveSeamTests.swift.
Change: kind cpu-intensive; size-gated seams blockingDecode(JSONDecoder, from:) and blockingJSONObject
(> 64 KiB), blockingImageDecode (> 256 KiB), blockingCompress/Decompress, blockingRegexMatches (> 32 KiB
text). Rule cpu-intensive for raw JSONDecoder().decode, JSONSerialization.jsonObject, CGImageSourceCreate*,
NSImage(data:|contentsOf:), NSRegularExpression in main-actor targets. Acceptance: 100 KiB decode on main
-> 1 site, 1 KiB -> 0, off main -> 0; --count printed (base: 190, 225, about 70, 23). Test: T1 wave 0; T0.

**122 once-blocking rule and the 11 initializers.** Files: guardrails.py, threading-inventory.py and the
11 sites (S/CmuxNextApp/Control/DebugTimings.swift, S/CmuxNextApp/Onboarding/BrowserExportSource.swift,
S/CmuxNextApp/Pages/SettingsPageProvider.swift, S/CmuxNextAppPermissions/Policy/AppScopeTable.swift,
S/CmuxNextBrowser/CEF/CEFBuiltInExtensions.swift, S/CmuxNextBrowser/CEF/CEFRuntime.swift,
S/CmuxNextBrowser/Omnibox/HostTypoFixup.swift, S/CmuxNextBrowserImport/Sources/BrowserSourceRegistry.swift,
S/CmuxNextControl/Diagnostics/AppSymbolMap.swift, S/CmuxNextServer/Model/PairingWords.swift,
S/CmuxNextUpdater/WebUpdates/WebUpdatePointer.swift). Change: rule once-blocking (static/lazy/global
initializer closure with an MQ-1 or MQ-7 primitive); each site loads on a lane at warm-up and the value
is injected (P1), or the accessor becomes async. Acceptance: rule = 0; fixtures for static let closure,
lazy var closure (refused) and literal (not refused); first main access of each fixed site records 0.
Test: T0; T1.

**123 Lane histograms.** Files: S/CmuxNextWakeups/{LaneScheduler, LaneStats}.swift,
S/CmuxNextControl/Diagnostics/WorkControl.swift, T/CmuxNextWakeupsTests/LaneStatsTests.swift. Change:
queue wait (submit to start) and run time per lane and priority in log2 buckets (relaxed atomics, two
mach_absolute_time per job), in all builds; debug.work prints p50/p95/p99/max; hang report CoarseCounts
carries userBlocking queue-wait p99. Acceptance: 100 jobs of 1 ms -> run p50 1-2 ms; a 50 ms wait shows
max >= 50 ms; per-job cost 2 clock reads + 4 atomic adds; present in Release. Test: T1; RUN-13.

**124 Trace intervals.** Files: BlockingCheck.swift, LaneScheduler.swift, plans/cmux-next/trace.md.
Change: when trace recording is on, blockingCall emits an interval (kind, site) and each lane job an
interval (lane, priority, queue wait); off = one atomic load. Acceptance: tracing on -> 1 + 1 intervals;
off -> 0 and the cost bound unchanged; trace.md lists the names. Test: T1.

**125 Yieldable CPU jobs.** Files: S/CmuxNextWakeups/{BackgroundWork+Job, LaneScheduler}.swift,
T/CmuxNextWakeupsTests/LaneYieldTests.swift. Change: `work.job(priority) { delegate in ...
delegate.shouldYield ... }` (atomic "higher priority queued on this lane"); a yielding job requeues its
rest; convert the 3 longest .cpu users from the sweep (named in the commit). Acceptance: cpuWidth 1, a
bestEffort job of 100 x 5 ms chunks, a userBlocking item queued at 12 ms starts within 6 ms;
shouldYield < 10 ns. Test: T1.

**126 raw-blocking-ext rule.** Files: guardrails.py, threading-inventory.py, tests/test_guardrails.py.
Change: per-file binding scan (`let|var X = FileManager.default`, `X: FileManager`, `FileManager()`)
makes `X.<FILE_OPS>(` a hit; add free functions with a `(?<![\w.])` lookbehind: open(...O_),
Darwin.read/write/pread/pwrite/open, fsync, flock, ftruncate, rename, unlink, mkdir, rmdir, lstat,
stat(path, realpath, access, chmod, symlink, readlink, opendir/readdir, waitpid/wait4/waitid without
WNOHANG, FileHandle(forReading*/forWriting*/forUpdating*), .write(contentsOf:, .read(upToCount:,
.seekToEnd(, .synchronize(), CGImageSourceCreateWithURL, CGImageDestinationCreateWithURL,
CGImageDestinationFinalize, sqlite3_open/open_v2/prepare_v2/step/exec/close, sysctl/sysctlbyname,
proc_pidinfo/proc_pidpath/proc_listpids, LAContext evaluatePolicy/canEvaluatePolicy, getpwuid/getpwnam,
Host.current(), processInfo.hostName. New rule name raw-blocking-ext. Acceptance: fixtures: fm variable
refused; `menu.removeItem(at:)` with no binding not refused; `var st = stat()` not refused;
`stat(path, &st)` refused; WNOHANG waitpid not refused; --count >= 600 on 772cdfc45ac; speed < 1.0 s.
Test: T0.

**127 POSIX/FileHandle/ImageIO/SQLite/sysctl seams.** Files: S/CmuxNextCompat/Threading/{Posix+Blocking,
FileHandle+Blocking, ImageIO+Blocking, SQLite+Blocking, ProcessInfo+Blocking}.swift,
T/CmuxNextCompatTests/BlockingPosixSeamTests.swift, guardrails.py (SEAM_BLOCKING). Change: thin seams
through blockingCall: blockingOpen/Read/Write/Fsync/Flock/Rename/Unlink/Stat/Lstat/Realpath/Access/Mkdir,
blockingWaitpid, FileHandle.blocking*, blockingImageSource(url:), blockingImageDestinationFinalize,
blockingSQLite(open/step/exec/close), blockingSysctl, blockingProcPid*, LAContext.blockingEvaluate. Kinds
fs-metadata, sqlite, process-reap, system-query. Acceptance: each < 15 lines with DocC; one site per seam
on main with the caller line; 0 off main; cost tests unchanged. Test: T1 wave 0.

**128 Blocking reaps.** Files: S/CmuxNextDaemon/Connection/DaemonBridge.swift,
S/CmuxNextComputerUse/ComputerUseHelperV2Spawner.swift, S/CmuxNextAgentPane/{AgentPaneShell,
AgentPaneShellCompletionProcess, AcpmuxDaemonLauncher}.swift. Change: SIGKILL then a
DispatchSource.makeProcessSource(.exit) on a utility reap queue that calls waitpid(WNOHANG), no lock held
(DaemonBridge.swift:113-121 holds `state.withLock` across waitpid today). Acceptance:
`rg -nP '(?<![\w.])waitpid\([^)]*,\s*0\)' S` = 0; no withLock body has waitpid, kill or close; dropping a
BridgeChild on main records 0 and the child is reaped (kill(pid,0) -> ESRCH). Test: T1.

**129 Ghostty config off main.** Files: S/CmuxNextTerminal/{GhosttyRuntime, GhosttyRuntime+Background,
GhosttyRuntime+Theme}.swift, S/CmuxNextCompat/Threading/BlockingKind.swift,
T/CmuxNextTerminalTests/GhosttyConfigLoadTests.swift. Change: kind ffi with `blockingFFI(_:)`; build the
ghostty_config_t on .files at .userBlocking from a value snapshot (theme, font, opacity lines), apply on
main with one ghostty_app_update_config; launch uses the warm-up thread, not main. Doc row: drawFrame's
GPU wait on main belongs to PL-ghostty G1. Acceptance: no ghostty_config_load_* reachable from @MainActor
(reloadConfig test on main, 0 violations, red first); every load inside blockingFFI; theme toggle and new
terminal rows no worse. Test: T1; T2; launch bench.

**130 Linked Shared/iOS packages.** Files: threading-inventory.py, guardrails.py,
Packages/Shared/CmuxThreading/ (new leaf: MayBlockRunner, Mutex, blockingCall hook with no-op default),
S/CmuxNextCompat/Threading/SharedThreadingBridge.swift (installs the hook at launch). Change: inventory
and guardrails cover the macOS-linked package list from Package.swift (lines 1751-1786) in a separate
section. Acceptance: --count reports the section; the iOS build of the shared packages compiles (fleet iOS
lane); the hook is installed once. Test: T0; T1 macOS and iOS compile.

**131 Third-party thread rows; remote-view render.** Files: ThreadRegistry.swift,
S/CmuxNextRemoteView/Present/MetalYUVRenderer.swift, threading-model.md. Change: "declared by library"
rows for GhosttyKit (renderer/IO, focused userInteractive, visible userInitiated, hidden utility), CEF,
WebKit, Sentry, iroh tokio, WebRTC, CCmuxAppFFI; `cmux.remote-view.render` joins the closed list as a
compositor-class motion path (Chrome kDisplayCritical). Acceptance: debug.threads STRESS 0 rows with
declared=null; hidden-workspace Ghostty threads read UTILITY; the doc names the render queue. Test: RUN-3.

**132 No nested modal run loops.** Files: S/CmuxNextAgentPane/AgentPaneSavePanel.swift,
S/CmuxNextFilesUI/FilesPrompts.swift, S/CmuxNextScreenshots/ScreenshotsCommands.swift,
S/CmuxNextHomeEngine/HomeChiefSettingsView.swift, S/CmuxNextBrowser/Engine/BrowserPagePrint.swift,
guardrails.py. Change: beginSheetModal or begin(completionHandler:); alerts move to CmuxDialogSpec; add
`runModal(` to ALWAYS_BLOCKING. Reviewed exception: NSPrintOperation's sheet form
`runModal(for: window, delegate: ...)` returns once the sheet shows (AppKit documents it as document-modal), so
BrowserPagePrint keeps it, with `canSpawnSeparateThread = true` so the job spools off main. Acceptance:
`rg -n --pcre2 '\.runModal\((?![^)]*delegate:)' S` = 0; fixture refuses a new one and accepts the sheet form.
Test: T0; T2.

**133 Key echo path never hops through the pool.** Files: S/CmuxNextDaemon/Connection/{DaemonConnection,
LineTransport}.swift, T/CmuxNextDaemonTests/EchoPathHopTests.swift. Change: map the hops of a
terminal-output or key-ack event from the reader thread to main; deliver echo-class events from the
reader straight to MainActorWorkQueue (input class) or the userInteractive TerminalOutputLane, with no
cooperative-pool job (TaskPriority.high is only USER_INITIATED). Other events stay on the actor.
Acceptance: a probe records every hop's thread; none ends in `.cooperative`; bench-typing STRESS p99 no
worse (numbers recorded). Test: T1; T3.

**140 SMAppService / launchd IPC off main.** Files: S/CmuxNextApp/Server/{ServerLaunchAgent,
ServerStopServing, ServerHelperClient}.swift. Change: `status` and `register` closures become async and
run on work.run(.userBlocking, mayBlock: .system) through the 003 seams; callers show a pending state
first (P4). Acceptance: the SMAppService part of INV-2 = 0 outside Compat; fake-service test drives the
Server toggle on main with 0 violations; app net lines do not grow. Test: T1; T2.

**141-144 raw-blocking-ext chunks (MQ-16).** 141 CmuxNextApp (about 132 hits: ImageIO writers in
Control/AppBrowserPage+Screenshot, Hibernation/HibernationSnapshots, IconAssets/IconAssetStore,
Pages/SettingsIconAssets; FileManager variables). 142 AgentPane (about 89) + HomeEngine (about 64): flock
in AcpmuxQuitProof.swift:150 and ChiefMigration.swift:221, fsync AgentPaneTurnUndo.swift:183, sqlite3
in ChiefAdoption+SQLite and ChiefMigration+Read, ImageIO in AgentPaneCapture, AgentPaneReplyImages,
HomeChiefFiles, HomeAttachmentCache. 143 Control, Daemon, ComputerUse, Wakeups, Cloud, Design,
DesignTokens (RecoveryDraftStore.swift:142, MacInstallStore.swift:70). 144 the rest (History
HistorySQLite.swift, BrowserImport SQLiteSnapshot/ImportDestination, BrowserDownloadHistoryStorage.swift:49;
Files, ChromiumRuntime, HangReports with MayBlockRunner). Recipe: MQ-1 recipe with the 127 seams.
Depends on 127 and on the module's MQ-1 task (one owner per file). Acceptance: `--rule raw-blocking-ext
--rule main-blocking --rule pool-blocking --paths <module>` = 0; red-first tests for changed main paths.
Test: T1 wave; T2.

**145 cpu-intensive chunks (MQ-18).** Recipe: replace with the 121 seams and move decodes above the
size gate to .cpu at the caller's priority, keeping a value snapshot for main. Acceptance: --rule
cpu-intensive = 0 per chunk; RUN-1 cpu-intensive sites = 0. Test: T1; T2.

**146 Shared/iOS package chunks (MQ-17).** One chunk per package (CmuxHomeCore 53 raw; CmuxMessagesLab
51 locks + 24 queues/threads/detached + 15 raw; CMUXMobileCore; Iroh/Irx transports 31 raw + 3 `.sync {`;
CmuxUpdater 15 raw + 1 waitUntilExit; CmuxVNCWebRTC 11 NSLock + 1 Thread; iOS CmuxMobileRPC 14,
CmuxMobileSSH 9). Recipe: MQ-1 recipe through the CmuxThreading leaf. Acceptance: raw-blocking,
raw-blocking-ext, pool-blocking, task-priority = 0 in the package; `rg -n 'NSLock\(|OSAllocatedUnfairLock|DispatchSemaphore' <pkg> --glob '!**/Tests/**'`
= 0; iOS compiles. Test: T1 macOS and iOS.

**147 awaited-low-priority fixes (MQ-19).** Recipe: start the work at the waiter's priority, or use
work.runHandle and raise it when main awaits. Acceptance: --rule awaited-low-priority = 0; RUN-1
priority-inversion sites = 0. Test: T1; T2.

**200 cmux-threads crate.** Files: R/cmux-threads/{Cargo.toml, src/lib.rs, src/qos.rs, src/spawn.rs,
src/registry.rs}, cmux-tui/Cargo.toml. Change: leaf crate (libc only). ThreadQos with the Chrome mapping;
Linux: nice 0/0/0/5/10, and a request that would lower nice is ignored and recorded (unprivileged threads
cannot renice down). `spawn(name, qos, f)`, `set_current(qos)`, `with_qos(qos, f)` (save, set, run,
restore), registry {name, declared qos, desired qos atomic, tid, pthread}, `snapshot()` with live QoS.
Acceptance: a Utility thread reads QOS_CLASS_UTILITY on macOS; registry row present while running and gone
after join; with_qos restores; libc only. Test: T1r wave 0.

**201 cmux-threads::blocking.** Files: R/cmux-threads/src/{blocking, checked, lib}.rs. Change:
thread-local disallowed + allowance; `enum AllowReason { Shutdown, OwnDescriptor }` (doc rows);
OwnDescriptor only through `own_fd_read/own_fd_write` (call-scoped); `#[track_caller]
scoped_blocking_call(kind, f)`. Debug default RECORD; CMUX_DAEMON_BLOCKING=panic panics with location,
kind and thread. Release records 256 sites + overflow. Checked wrappers: fs, process
output/status/wait, recv/recv_timeout/join/condvar wait, sleep, block_on; kind ipc-reply for
cross-process round trips (holder, terminal host, browser host) with no allowance on request and echo
threads. Acceptance: disallowed thread: checked read records 1 site (record) and panics with caller
file:line (panic); ordinary thread 0; allowed fast path one TLS read (< 5 ns). Test: T1r wave 0.

**202 clippy.toml and lint plumbing.** Files: cmux-tui/clippy.toml, cmux-tui/Cargo.toml, roots of the 9
crates without `lints.workspace` (add `lints.workspace = true` or `#![allow(clippy::disallowed_methods)]`).
Change: in ONE commit: `disallowed_methods = "allow"` under [workspace.lints.clippy], then clippy.toml
with std::thread::spawn, Builder::spawn, Builder::spawn_scoped, Builder::spawn_unchecked,
std::thread::scope, std::thread::sleep (reason: use cmux_threads). Each migration task adds
`#![cfg_attr(not(test), deny(clippy::disallowed_methods))]` to its crate roots (lib.rs and main.rs) when
its queue is empty. Acceptance: the cmux-tui-spec clippy script (`-D warnings --all-targets`, whole
workspace) is green on the fleet at this commit; `cargo clippy -p cmux-tui-core -- -W
clippy::disallowed_methods` lists the MQ-12 sites. Test: T1r fleet clippy.

**203 server.threads and server.blocking.** As in the design (snapshots; no lock across I/O; listed in
capabilities; < 1 ms). server.threads also reports effective priority and process role. Test: T1r.

**204 cmux-threads::work.** Files: R/cmux-threads/src/{work, lib}.rs. Change: lanes Files (4/3/2/1 by
priority), System (6, 1 reserved for UserBlocking), Cpu (P-cores minus 1); Priority and Shutdown enums;
post/run. Workers by priority are fixed per priority class (Linux cannot renice down). An idle worker
waits with a 30 s timeout only while above the minimum count (0), exits on that timeout, and the last
waiter waits with no timeout. Workers are MayBlock, not syncAllowed (119). shutdown() drops skip, joins
block (raised, 118). Acceptance: priority order; block runs during shutdown, skip does not; 0 threads after
idle exit and 0 wakeups after the exits; on Linux a UserBlocking item runs on a nice-0 worker after an Idle
item. Test: T1r wave 0.

**205 Daemon hang watch.** Files: R/cmux-threads/src/hang.rs,
R/cmux-tui-core/src/server/{connection_frame, server_stats}.rs. Change: thread_local slot (AtomicU64
deadline) + AtomicUsize armed count; notify the `mux-hang-watch` (Utility) condvar only on 0 -> 1; watcher
waits to the earliest deadline while armed, no timeout at 0; overrun -> ring of 128 in server.stats.hangs
and one panic-log line; never panics; handle_request_with_cancellation wraps each request in 250 ms.
Acceptance: 300 ms handler -> one row with method name; 10 ms -> none; 10,000 requests -> < 10 watcher
wakeups; idle 5 s -> 0. Test: T1r.

**206 Channel inversion detection.** As in the design, also wrapping crossbeam_channel. Test: T1r.

**207 Daemon and holder process QoS.** Files: R/cmux-tui/src/main.rs, R/cmux-holder/src/main.rs,
S/CmuxNextDaemon/Connection/DaemonBridge.swift. Change: daemon main set_current(UserInitiated); holder
main set_current(UserInteractive) only AFTER its shell fork path is wrapped by 223; DaemonBridge passes
USER_INITIATED through blockingPosixSpawn. Acceptance: server.threads main user-initiated; holder test
reads USER_INTERACTIVE; its child reads DEFAULT. Test: T1r; RUN-4.

**210 Echo-path daemon threads.** Files: R/cmux-tui-core/src/server/{listen, line_connection, cmd_attach}.rs,
R/cmux-tui/src/pty_input.rs, R/cmux-tui-core/src/terminal_host_runtime/shared/{host_serve, host_start}.rs,
R/cmux-tui-core/src/surface/{frame_producer, spawn, host_frames}.rs. Change: mux-conn reader, mux-line-out,
mux-pty-input, mux-attach-out, mux-render-attach-out, terminal-host-pty, terminal-host-parser,
terminal-host-client-input, surface-{id}-reader, surface frames and host_frames through
cmux_threads::spawn(UserInteractive) + disallow_blocking(); their own descriptor I/O through own_fd_read /
own_fd_write. Acceptance: server.threads rows user-interactive; record-mode suite lists other sites (MQ-13);
no other behavior change; crate deny attributes added when the crate queue is empty. Test: T1r; T3
bench-typing.
As landed: terminal-host-client (the host's output writer) is also an echo thread; its handshake may
block, its output loop writes through own_fd_write with blocking disallowed. mux-conn and
mux-remote-conn are registered at Default with blocking disallowed, not raised: they run request
handlers inline that spawn children (223 not landed) and serve automation clients (224 raises the UI
connection). Own-descriptor I/O covers the terminal-host sockets only (client-input, client output,
host_frames).

**210b Echo-thread PTY and control-socket I/O through the own-descriptor path.** Files:
R/cmux-tui-platform/src/platform/transport.rs (an `as_fd` on `Stream`),
R/cmux-tui-core/src/server/{line_connection, bounded_outbound}.rs, R/cmux-tui/src/pty_input.rs,
R/cmux-tui-core/src/terminal_host_runtime/shared/{host_start, host_serve}.rs, R/cmux-tui-core/src/surface/spawn.rs.
Change: each echo thread registers the descriptor it owns before disallow_blocking and does its reads or
writes through own_fd_read / own_fd_write_all: mux-conn's socket read_line, mux-line-out's socket writes,
terminal-host-pty's and surface-{id}-reader's PTY reads (and their readiness polls), mux-pty-input's PTY
writes. A shared, locked PTY writer (client-input's `command_host.writer`) is not an own descriptor: it
moves to the owning thread or stays a recorded site. Acceptance: with fd reads and writes checked, the
record-mode suite shows no site on an echo thread's own descriptor. Depends 210. Test: T1r; T3
bench-typing.

**211 Request dispatch threads.** As in the design (dispatch, ws and events writers UserInitiated, accept
Utility, disallow in dispatch; record default from 201). Test: T1r.

**212 Journal, storage, maintenance QoS.** As in the design; depends on 226 so a lowered writer is boosted
by waiting requests; tell PL-daemon. Acceptance adds: 0 request-to-writer inversions (206) and the writer
reads USER_INITIATED while a request waits (226 test). Test: T1r; T3.

**213-218 Spawn migration.** As in the design (213 server/ rest; 214 mux/, surface/, resource_router/;
215 journal*, chief_brains, browser*, state, provider_management, apps; 216 terminal_host_runtime,
holder_runtime (tell PL-holder), terminal_backend, shell_integration + deny on cmux-tui-core lib.rs; 217
cmux-tui binary (deny on src/main.rs); 218 browser-host, remote-browser-host, cdp, host (lib.rs and
main.rs), holder (lib.rs and main.rs), pty, process, git, tasks, config, acpmux (tell PL-acpmux; tokio
on_thread_start Default, blocking pool Utility, max_blocking_threads 16, thread_name)). Each adds the
crate deny in the commit that empties its crate. Acceptance: 0 disallowed_methods (non-test) for the
paths; attribute present on every root of an emptied crate. Test: T1r.

**219 Final deny check.** Files: crate roots of the daemon crates (cmux-tui-core/src/lib.rs,
cmux-tui/src/main.rs, cmux-holder/src/{lib,main}.rs, cmux-pty/src/lib.rs, cmux-browser-host/src/lib.rs,
cmux-host/src/{lib,main}.rs and the 229 crates). Change: add any missing deny attribute. Acceptance:
RUN-4 clippy part: 0 errors; workspace clippy script green. Test: T1r.

**220 / 221 Checked primitives on the request path (server/, mux/).** As in the design, with the
extended MQ-14 pattern (rusqlite, flock, block_on). Acceptance: MQ-14 rg 0 in the paths outside the 225
chokepoints; each moved request path has a red-first test on a disallowed thread in panic mode. Test:
T1r; T3.

**222 RankedMutex contention timing.** As in the design. Test: T1r.

**223 Child processes never inherit echo-path QoS.** Files: R/cmux-threads/src/process.rs,
R/cmux-holder/src/{pty, main}.rs, R/cmux-pty/src/{macos, lib}.rs, R/cmux-holder/src/pty_tests.rs. Change:
wrap each fork / spawn_command of a user shell or agent in `with_qos(Default, ...)` (parent side), or in
the single-threaded holder call pthread_set_qos_class_self_np(QOS_CLASS_DEFAULT) in the forked child
before execve; `cmux_threads::process::spawn_qos` for helper Commands (git, ss/netstat, hooks: UTILITY).
Acceptance (macOS): a child spawned through the holder and through cmux-pty from a UserInteractive thread
reads QOS_CLASS_DEFAULT; the parent thread's QoS is restored; Linux unchanged. Test: T1r.

**224 Daemon connection QoS by client class.** Files: R/cmux-tui-core/src/server/{listen,
command_dispatch, connection_scheduler, resource_clients}.rs, connection_qos_tests.rs. Change: after
SetClientInfo (command_dispatch.rs:76; client_kind resource_clients.rs:140) the connection's threads call
set_current: the app's UI connection keeps UserInteractive reader and UserInitiated dispatch;
cli/mcp/hook/agent/remote use Utility for both; UserInitiated until SetClientInfo arrives; optional
request field `priority` (user|automation). Acceptance: server.threads shows the split; a burst of 500 cli
requests raises the app client's request p95 by no more than 10%. Test: T1r; T3.

**225 SQLite and connection-lock chokepoints.** Files: R/cmux-tui-core/src/workspace_registry/registry_connection.rs,
src/state/{router, commit}.rs, src/{conversation_store, chief_registry}.rs, src/apps/storage.rs,
R/cmux-threads/src/blocking.rs. Change: RegistryConnection::get/pin, the router read closure, the commit
path and the conversation/chief/apps connections enter scoped_blocking_call(Sqlite) (#[track_caller]) and
record connection-lock waits over 2 ms with the holder's thread name. Acceptance: a disallowed test thread
registry read records 1 sqlite site (record) and panics with the caller location (panic); allowed thread
0; fast path one TLS read. Test: T1r.

**226 Registry connection lock boosts its owner.** Files: registry_connection.rs,
R/cmux-threads/src/qos.rs, registry_connection_tests.rs. Change: record the owner's pthread at lock; a
waiter of higher declared QoS starts pthread_override_qos_class_start_np on the owner, ended at unlock (or
an os_unfair_lock-based reentrant lock on macOS). Tell PL-daemon. Acceptance (macOS): Utility owner spins
20 ms, a UserInitiated waiter arrives, the owner reads USER_INITIATED while holding and utility after.
Test: T1r.

**227 std lock timing wrappers (MQ-20).** Files: R/cmux-threads/src/sync.rs, clippy.toml
(disallowed-types std::sync::{Mutex, RwLock, Condvar}, workspace allow), module attributes
`#![cfg_attr(not(test), deny(clippy::disallowed_types))]` in server/mod.rs and mux/mod.rs when migrated.
Change: same-API wrappers; debug: a wait > 2 ms on a disallowed thread records lock-wait; release plain
std. Acceptance: 5 ms holder + disallowed waiter -> 1 site, 0.1 ms -> 0; 0 disallowed_types in server/
and mux/ (non-test); workspace clippy green. Test: T1r.

**228 tokio runtimes.** Files: R/cmux-tui-core/src/apps/egress.rs, R/cmux-tui/src/{link/mod,
remote_runtime, cloud_conversations_backend, coderouter_usage, owner_start/background_checks,
owner_start/crash_forward, link/machine_update, remote_wg_hub}.rs, R/cmux-server/src/pairing/network.rs,
R/cmux-terminal-client/src/lib.rs, R/cmux-threads/src/tokio.rs. Change: `cmux_threads::tokio::builder(name,
qos)` sets thread_name, on_thread_start(set_current) and registration; daemon-side block_on inside
scoped_blocking_call(BlockOn); CLI-only binaries exempt. Acceptance: server.threads shows every tokio
worker named and registered; `rg -n 'runtime::Builder::new_(multi|current)_thread'` in daemon-linked crates
only in cmux_threads::tokio. Test: T1r; RUN-4.

**229 Spawn migration for missed daemon-linked crates.** Files: R/{cmux-tui-platform, cmux-tui-util,
cmux-flow-trace, cmux-tui-cloud-conversations, cmux-tui-image-paste, cmux-app-host, cmux-tui-hooks,
cmux-server, cmux-holder-v3, cmux-mux2, cmux-coderouter, cmux-terminal-client, cmux-remote,
cmux-worktree-care, cmux-rd-host}/src/. Change: cmux_threads::spawn with QoS from the table; deny
attribute on each root. Acceptance: MQ-12 rg = 0 for these crates; clippy 0 disallowed_methods. Test: T1r.

**230 One-shot daemon threads become work items (MQ-21).** Files: R/cmux-tui-core/src/server/,
R/cmux-tui-core/src/mux/, connection_scheduler.rs. Change: each spawn whose closure has no loop
(mux-surface-control per request at connection_scheduler.rs:408, terminal-adopt-{id},
template-complete-{id}, terminal-exit-detach-{id}, terminal-exit-settle, terminal-host-close,
mux-agent-*, mux-url-open, mux-loopback-open, mux-browser-runtime-start/stop, mux-cloud-request,
mux-chief-inspect, mux-fs-stream-close, mux-launch-snapshot, about 60 names) -> cmux_threads::work::post
at the priority of the request it serves. Loops stay threads. Acceptance: `rg -n -g '!*tests*'
'name\(format!\(' cmux-tui/crates/cmux-tui-core/src` = 0 except per-terminal loop threads listed in the doc;
peak thread count under perf-10x-lifecycle STRESS lower than the base; op p95 no worse. Test: T1r; T3.

**231 Request-path blocking outside server/ and mux/.** Files: R/cmux-tui-core/src/{workspace_registry/,
state/, terminal_host_runtime/, git_ops/, apps/, journal_ingress.rs, chief_registry.rs,
conversation_store.rs, conversation_attachments.rs, output_store/, resource_router/, fs_ops/,
holder_runtime/, server/cmd_server.rs}. Change: task 220 recipe in chunks of 25; git_ops::dispatch
(status, branches, commit, push, worktree apply) to work System with an async answer; cmd_server.rs:291
ss/netstat to work System. Tell PL-daemon. Acceptance: extended MQ-14 rg = 0 (non-test) outside the 225
chokepoints; a git push request on a disallowed thread in panic mode does not panic (red first). Test:
T1r; T3.

**232 Hang scopes on daemon echo threads and holder loop.** Files: line_connection.rs,
R/cmux-tui/src/pty_input.rs, cmd_attach.rs, R/cmux-holder/src/main.rs. Change: hang::scope(100 ms) around
each write batch, input write, frame and holder loop pass (never around poll/read/recv); the holder reports
through its link. Acceptance: injected 150 ms line-out stall -> one row naming mux-line-out; idle 5 s -> 0
watcher wakeups. Test: T1r.

**233 Daemon diagnostic sites to the app's reports.** Files: server_stats.rs, R/cmux-threads/src/blocking.rs,
S/CmuxNextApp/HangReports/BlockingReportSink.swift, S/CmuxNextDaemon/Connection/DaemonConnection.swift.
Change: a first-time daemon site (blocking, hang, inversion) emits one `server.diagnostic_site` event per
daemon life; the app forwards it to BlockingReportSink with source=daemon (crate + file hash + line).
Event-driven only. Acceptance: fake event -> one HangSample source daemon, duplicate -> none;
PrivacyLeakScanner passes; idle wakeups unchanged. Test: T1; T1r; T4.

**234 launchd ProcessType per process role.** Files: R/cmux-tui/src/link/launchd.rs,
R/cmux-tui/src/remote_host/service.rs, R/cmux-server-core/src/units/launchd.rs,
S/CmuxNextApp/Server/ServerLaunchAgent.swift, threading-model.md. Change: process-roles table (app,
daemon, holder, acpmux, browser host, link, remote host, server units, helpers); link and `host serve`
move from Background to Adaptive (person's input passes through them), or the doc states they are off
the input path. Acceptance: each plist generator sets the table's value with a test asserting it; no
process on a person's input path is Background; units_golden fixture updated in the same commit. Test:
T1r.

**235 Mach task roles.** Files: R/cmux-threads/src/process_role.rs, R/cmux-tui/src/main.rs,
R/cmux-holder/src/main.rs, server_stats.rs, S/CmuxNextCompat/Threading/ProcessRole.swift. Change:
set_default_role() (TASK_CATEGORY_POLICY TASK_FOREGROUND_APPLICATION) at daemon and holder start; the
Chromium host gets the Swift twin; set_role(Foreground|Background|BackgroundSuppressed) with PRIO_DARWIN_BG
for suppressed; server.stats reports the role. Acceptance (macOS): role reads foreground after
set_default_role; suppressed then foreground clears PRIO_DARWIN_BG; Linux no-ops. Test: T1r; RUN-4.

**236 Hidden workspaces demote per-terminal daemon threads.** Files: R/cmux-threads/src/{registry, qos}.rs,
R/cmux-tui-core/src/surface/spawn.rs, terminal_host_runtime/shared/host_start.rs,
src/server/cmd_workspace_visibility.rs. Change: desired-QoS atomic per registry row;
`apply_pending_qos()` at the top of each loop (syscall only on change); hidden workspace -> Utility,
shown -> UserInteractive; uses the app's existing visibility signal (named in the PR) or a one-field op.
Acceptance: hide a workspace with 2 terminals, write 1 byte each, reader and parser read utility; show and
write, user-interactive again; 0 wakes only for QoS; bench-typing p99 of the visible terminal no worse.
Test: T1r; T3.

**237 One kqueue reaper.** Files: R/cmux-threads/src/reaper.rs, R/cmux-tui-core/src/surface/spawn.rs,
R/cmux-tui-core/src/terminal_host_runtime/sys/unix/spawned_host.rs (+ chief-brain-wait,
cmux-journal-plugin-wait). Change: one `mux-reaper` (Utility) on kqueue EVFILT_PROC NOTE_EXIT (macOS) or
pidfd+epoll (Linux); waitpid(WNOHANG); completion on work. Acceptance: 50 terminals start and exit with the
same statuses; server.threads shows 1 reaper and 0 per-child wait threads; idle 5 s -> 0 wakeups. Test:
T1r; T3.

**238 Waiter boosts its producer.** Files: R/cmux-threads/src/{sync, registry, qos}.rs. Change: a blocking
recv on a thread of higher declared QoS than the registered producer starts
pthread_override_qos_class_start_np on the producer for the wait. Acceptance: UserInteractive consumer on a
Utility producer -> one start and one end; equal QoS -> 0; 0 open overrides with no waiters; Linux
record-only. Test: T1r.

**300 TEST PHASE: Swift sweeps (MQ-10).** Files: scripts/cmux-next/every-action-sweep.py. Change:
`--blocking-report` saves debug.blocking JSON per session; run record mode, file each site group with the
MQ-1 recipe, then rerun with traps. Depends: 101, 052, 059, 141-145. Acceptance: RUN-1 passes or every
site is filed, fixed and rerun. Test: T2.

**301 TEST PHASE: probe (MQ-11, MQ-13).** Depends 020, 300. app_main -> MQ-11 tasks; daemon_request ->
MQ-13; app_chromium -> CEF helper-app program with the total recorded as open. Acceptance: RUN-2 and RUN-5
numbers in perf-lead.md section 5 with sha, host, macOS. Test: T3.

**302 TEST PHASE: QoS audit (MQ-15).** Depends 018, 131, 203, 219, 228. Window visible and hidden runs.
Acceptance: RUN-3 and RUN-4. Test: T3.

**303 TEST PHASE: daemon panic mode + lifecycle bench.** Depends 220, 221, 231, 210, 211, 225.
Acceptance: RUN-5. Test: T1r + T3.

**304 TEST PHASE: Nightly soak.** Depends 007, 008, 019, 024, 233, 300. Acceptance: RUN-7, RUN-8, RUN-9.
Test: T4.

**305 TEST PHASE: Tart macOS 14/15.** Depends 005, 018, 117. Checks both pool label shapes and the
priority raise. Acceptance: RUN-10; a label change files a fix to 005. Test: T3.

**306 TEST PHASE: inventory zero and results log.** Depends 300-305, 307. Files: perf-lead.md,
threading-model.md. Acceptance: INV-1..INV-5, RUN-11, RUN-13 recorded; the before/after table and the
Chromium open number committed. Test: T0 + T1 release compile.

**307 TEST PHASE: lifecycle sweep.** Files: scripts/cmux-next/lifecycle-sweep.py,
every-action-sweep.py. Change: trigger launch cold/warm, quit, debug.simulate.wake, debug.simulate.display,
appearance toggle, kill -9 daemon and Chromium host, update install, with traps; read debug.blocking and
debug.hangs; file sites with the MQ-1 recipe. Depends 300, 128, 129. Acceptance: RUN-12 exit 0. Test: T2.

**308 mux-line-out's idle wait.** Found by p15-oracle-069 on the VM: a debug daemon panics on every Unix line
connection at `bounded_outbound.rs` `recv` (condvar-wait on thread mux-line-out, an echo thread with blocking
disallowed), so the oracle's daemon cases need `CMUX_DAEMON_BLOCKING=record`. The writer waits for its own queue
when idle; that is not blocking work. Chromium: `WaitableEvent::declare_only_used_while_idle()`
(base/synchronization/waitable_event.h), which MessagePumpDefault's event uses, so a thread idle at the bottom
of its stack is not a ScopedBlockingCall. Change: an idle-wait primitive in cmux_threads::checked that records no
violation, used by the outbound queue's recv only. Acceptance: a debug daemon under CMUX_DAEMON_BLOCKING=panic
serves `cmux raw operation session.snapshot` with no panic. Test: cmux-threads tests; T1r.

**309 origin_gate on mux-conn.** Found by p15-oracle-069: a debug daemon panics on every accepted Unix connection
at `origin_gate.rs` `is_bundled_mobile_host_path` (fs: canonicalize of the peer executable on thread mux-conn,
blocking disallowed). Chromium does file work in a MayBlock task (base/task/task_traits.h), never on an IO
thread. Change: resolve the peer executable on a may-block worker before the connection dispatches, or compare
without a file-system call. Acceptance: as 308, no fs site on mux-conn in `server.blocking`. Test: T1r.
