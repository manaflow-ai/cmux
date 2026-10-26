# Stability: crash search, sanitizers, compile-time safety, traps to zero, Rust daemon discipline

Status: design, 2026-10-25 (Chrome-parity push, program p10). Owner: PL-stability ([OWNERS.md](OWNERS.md)).
Branch: `perf/chrome-parity`, then `feat-cmux-next`.

Related: [crash-elimination.md](crash-elimination.md) (the crash classes, the crash ratchet and phase 3, which this
program carries out), [rust-panic-free.md](rust-panic-free.md) (the Rust panic ratchet and supervisor rules, which this
program finishes), [hang-reports-DESIGN.md](hang-reports-DESIGN.md) (field hang reports), [perf-lead.md](perf-lead.md).
The task list with files, acceptance and dependencies is the program spec
[chrome-parity/p10-stability.md](chrome-parity/p10-stability.md) section 8 (task details) and
`chrome-parity/design-result.json` (`programs["p10-stability"]`). A number in parentheses below, such as (151), is the
task `p10-stability-151` there.

Baseline counts are from feat-cmux-next 772cdfc45ac (2026-10-25), taken with `git grep`, the JSON baselines and the plan
docs. The design passed three adversarial reviews; the spec's "Review disposition" records what each review changed.

The program has six parts:

1. A continuous crash-search lab (Chrome's ClusterFuzz) on every feat-cmux-next tip, on macOS 14/15/26/27.
2. Sanitizer lanes: ASan, TSan, UBSan, LSan, Guard Malloc, MallocProbGuard and cooperative-pool-strict, for Swift, Rust,
   the CEF shim (C++) and libghostty (Zig ReleaseSafe).
3. Compile-time safety across the whole CmuxNext package closure: Swift 6 everywhere, strict memory safety on every target
   (Chrome's unsafe-buffers order: on everywhere, old sites marked, the marks are the queue), no unreasoned escape hatches.
4. Traps and panics: outside input never traps; internal invariants trap only through one reviewed API (Chrome's CHECK /
   NotFatalUntil split); in-process Rust FFI never unwinds into cmux; uncatchable Objective-C exceptions are removed.
5. Rust daemon discipline: blocking calls never on tokio workers (ScopedBlockingCall/MayBlock), every long-lived thread and
   task supervised with a declared failure and shutdown policy, fork safety, child reaping, bounded queues, lock ranks.
6. Containment and field stability: process chaos, GPU crash loops, state corruption, quit storms, hang watching on every
   critical thread, crash keys, unclean-exit metrics.

Every part reports only. Nothing in this program adds a GitHub CI job, step, gate, budget or blocking baseline row
(Lawrence 2026-10-23). Code lands on compile only; tests run in the program's own test phase (Lawrence 2026-10-25), but
the lab is diagnosis that runs on its own from hour 12, so its findings arrive while there is time to fix them.

## 1. Chrome reference

Sources: chromium.googlesource.com / source.chromium.org (paths below are in the Chromium tree).

1. **Hang detection** (`base/threading/hang_watcher.h`, `.cc`). One HangWatcher thread per process watches registered
   threads (UI, IO, ThreadPool, Compositor). `WatchHangsInScope` is RAII; it writes a 64-bit deadline into the thread's
   `HangWatchState` (an `std::atomic<uint64_t>`) with plain atomic stores, and "SetDeadline() ... can never fail". Nested
   scopes restore the outer deadline. `InvalidateActiveExpectations()` covers unbounded waits. The watcher polls on its own
   monitoring period. `kDefaultHangWatchTime` is 10 s; jank is measured separately. On a hang, `RecordHang()` (NOINLINE)
   calls `base::debug::DumpWithoutCrashing()` with crash keys naming the hung threads; `kShouldBlockOnHang` makes the hung
   thread block in `BlockIfCaptureInProgress` so its stack stays valid. Chrome reports a hang; it does not kill.
2. **Blocking** (`base/threading/thread_restrictions.h`, `scoped_blocking_call.h`, `base/task/task_traits.h`).
   `DisallowBlocking()` on UI and IO after init; `AssertBlockingAllowed()` lives inside the blocking primitives (file,
   WaitableEvent, process APIs), so transitive calls are caught at run time. `ScopedAllowBlocking` has a private friend list
   and goes "in the narrowest scope possible in the caller". On ThreadPool, blocking requires the `MayBlock()` /
   `WithBaseSyncPrimitives()` traits, and inside a pool task a `ScopedBlockingCall` (MAY_BLOCK / WILL_BLOCK) makes
   "the thread pool size ... incremented to compensate for the blocked thread". `DisallowUnresponsiveTasks()` also bans CPU
   work over 100 ms.
3. **Checks** (`base/check.h`, `styleguide/c++/checks.md`). "Prefer CHECK() and NOTREACHED() over DCHECK()s." A failed
   invariant "should be seen as Undefined Behavior"; "Do not handle DCHECK() failures. Use CHECK() instead."
   `base::NotFatalUntil::M<n>` dumps without crashing until milestone n, then becomes fatal automatically; "Do not use
   base::NotFatalUntil if there's no reasonable way to recover". `DUMP_WILL_BE_CHECK` is a rare, reviewed exception.
   Chrome runs a slice of Canary with DCHECKs on as non-fatal dumps (DCHECK canary).
4. **Lock order and ownership** (`base/task/common/checked_lock.h`, `base/thread_annotations.h`,
   `base/sequence_checker.h`). CheckedLock validates the predecessor order of acquisitions in DCHECK builds. Swift 6
   data-race checking and Rust Send/Sync are the stronger compile-time analog; `cmux-tui-core/src/lock_rank.rs` already
   matches CheckedLock.
5. **Memory-safety ratchet** (`docs/unsafe_buffers.md`, `build/config/unsafe_buffers_paths.txt`). `-Wunsafe-buffer-usage`
   is on for every file by default; old code is opted out per path or per file (`#pragma allow_unsafe_buffers`,
   `UNSAFE_TODO()`); each `UNSAFE_BUFFERS()` carries a `// SAFETY:` comment; the list only shrinks, so new code complies
   from day one. Spanification and hardened libc++ (`_LIBCPP_HARDENING_MODE`) turn out-of-bounds into a deterministic
   CHECK; Chrome bans unchecked access, never checked access. `base/memory/raw_ptr.md` (MiraclePtr / BackupRefPtr)
   quarantines freed memory so a dangling use is deterministic and not exploitable. Chrome's official compiler flags include
   `-ftrivial-auto-var-init=pattern`, `-fstack-protector-strong` and `-fno-delete-null-pointer-checks`.
6. **Fuzzing** (`testing/libfuzzer/README.md`, google.github.io/clusterfuzz). FuzzTest/Centipede for typed inputs,
   libFuzzer with SanitizerCoverage for bytes, libprotobuf-mutator / MojoLPM for stateful IPC sequences. ClusterFuzz runs
   targets continuously with a persistent corpus per target, prunes (minimizes) it daily, reports fuzzer coverage, forms a
   crash state from the top 3 frames after its stack-frame ignore regexes (allocators, assertion helpers, runtime and libc),
   files one bug per state, bisects the regression range, verifies the fix range and closes the bug.
7. **Sanitizers** (`docs/asan.md`, `build/sanitizers/sanitizer_options.cc`, `tsan_suppressions.cc`,
   `lsan_suppressions.cc`). `is_asan=true` on Release (optimized) builds; bots `mac_chromium_asan_rel_ng`,
   `linux_chromium_asan_rel_ng`, plus TSan, MSan, UBSan. Under ASan Chrome sets `use_partition_alloc_as_malloc=false`.
   GWP-ASan samples allocations in the field.
8. **Containment** (`content/browser/renderer_host/render_process_host_impl.cc`, `docs/security/rule-of-2.md`,
   `services/data_decoder`). Renderer, GPU and utility processes crash alone; `ProcessDied` shows a sad tab; the GPU process
   restarts until `GpuDataManagerImplPrivate::FallBackToNextGpuMode` runs out of modes and calls
   `IntentionallyCrashBrowserForUnusableGpuProcess()` (`LOG(FATAL) << "GPU process isn't usable. Goodbye."`). Untrusted
   JSON, images and XML parse in a sandboxed utility process (Rule of 2: untrusted input, unsafe language, no sandbox: pick at
   most 2). Mojo validates every message; `ReportBadMessage` ends the misbehaving child, never the browser.
   `TaskShutdownBehavior` (CONTINUE_ON_SHUTDOWN / SKIP_ON_SHUTDOWN / BLOCK_SHUTDOWN) is declared on every task.
   `base/files/important_file_writer.h` writes state atomically; `sql::Database` error callbacks and `sql::Recovery`
   raze and recover a corrupt database instead of crashing.
9. **Field stability** (`third_party/crashpad`, `components/crash/core/common/crash_key.h`,
   `components/metrics/clean_exit_beacon.cc`). Out-of-process crash handler; static, preallocated crash keys read at crash
   time; the clean exit beacon counts unclean exits (kills, OOM, Force Quit) that no crash handler saw; stability metrics per
   channel.
10. **Rust in Chromium** (`build/config/compiler/BUILD.gn`, `build/rust/`). All Rust builds with `-Cpanic=abort`
    (official builds `-Cpanic=immediate-abort`): an internal-invariant panic is a CHECK. FFI goes through cxx with no unwind
    across the boundary.

## 2. cmux today

### Swift language mode and escape hatches
- `Packages/macOS/CmuxNext/Package.swift` (tools 6.2, `.macOS(.v14)`) has 157 targets: 154 use `uiSwiftSettings` or
  `daemonSwiftSettings` (`.swiftLanguageMode(.v6)` + NonisolatedNonsendingByDefault, InferIsolatedConformances,
  ExistentialAny, InternalImportsByDefault; UI targets add `defaultIsolation(MainActor)`); 3 are C/ObjC
  (CmuxNextMallocZone, CmuxNextRemoteLayer, CmuxNextTestExitTrace).
- Mac closure (confirmed from `.package(path:)` lines and the Shared/iOS manifests): CmuxGhosttyKit, CMUXAuthCore,
  CmuxInstallAuthCore, CmuxAuthRuntime, CMUXMobileCore, CmuxTheme, CmuxAppAttest, CmuxAgentBrands, CmuxAgentCursor,
  CmuxHomeCore, CmuxFeedPushCore, CmuxHomeRender, CmuxAgentQuestion, CmuxMessagesLab, CmuxIrxTransport (pulls
  CmuxIrohTransport), CmuxVNC, CmuxScreenKit (pulls CmuxVNCWebRTC), CmuxSentryTelemetry, CmuxUpdater, CmuxMobileRPC (pulls
  CmuxTerminalSizing, CmuxMobileShellModel, CmuxMobileSupport), CmuxMobileSSH (pulls CmuxMobileTunnel), plus Sentry,
  Sparkle, swift-atomics. **Not in the closure:** CmuxTerminalClient (iOS only), CmuxSyncStore, CmuxTerminalStream,
  CmuxChiefVoiceCore, CmuxAPIClient. Shared packages deploy to `.macOS(.v14)` / `.iOS(.v17)`, so
  `Synchronization.Mutex` (macOS 15 / iOS 18) is unavailable there; `CmuxNextCompat.Mutex` (os_unfair_lock, same API) is
  visible only inside CmuxNext, and CMUXMobileCore has its own `OSAllocatedUnfairLock+Portable.swift`.
- The hole: `Packages/Shared/CmuxMessagesLab` (Package.swift:1768 of the app manifest) runs 4 targets in `.v5`
  (MessagesLabHome 37,150 lines in 150 files: Vendor/catalyst 18,604, appkit-native 5,163, appkit-port 892, Cmux/ 12,491;
  MessagesLabSidebar 4,650 lines). It draws on background threads.
- Outside the closure: `cmux-next-ios/CmuxMobileKit` CmuxMobileLinkFFI `.v5` (uniffi); `ios/cmux-ios.xcodeproj`
  NotificationService `SWIFT_VERSION = 5.0`.
- No target sets `strictMemorySafety()` or `treatWarning`.
- 258 `@unchecked Sendable` / `nonisolated(unsafe)` lines in `Packages/**/Sources` (176 without a `crash-allow:`
  reason); crash_ratchet's closure row swift.unchecked = 131 (CmuxIrxTransport 14, MessagesLabHome 14 largest).
- 35 `@preconcurrency` (25 Sparkle in CmuxUpdater/CmuxNextUpdater). 257 `MainActor.assumeIsolated` (PL-arch owns these).
- About 1,500 unsafe constructs: 69 unsafeBitCast, 77 Unmanaged pass/take (30 `Unmanaged.passUnretained` in 20 files:
  CEF, Ghostty, RemoteView, FSEvents, IOKit), 219 `@convention(c)`, 373 Unsafe*Pointer lines.
- 247 `with(Checked|Unsafe)(Throwing)?Continuation` sites; 12 private resume-once helper types already exist
  (ResumeOnce, Once, OnceBox, ResumeGuard, InstallOnce, AgentPaneResumeOnce), 2 of them `@unchecked Sendable`.

### Traps
- `try!` is 0 and banned. `scripts/cmux-next/crash-allowlist.json` bans as!, assumeIsolated (except `main-proof:`),
  fatalError, force_unwrap, iuo, objc_observer, objc_selector, precondition and unowned; it still waives 73 unowned,
  8 index_subscript and 3 fatal_error entries. The checkout has 97 safe `unowned` lines and 0 `unowned(unsafe)`.
- index_subscript and int_conversion are banned in only 10 modules (INDEX_MODULES in crash_ratchet.py).
- Untracked trap APIs: uniqueKeysWithValues 72, unguarded removeFirst()/removeLast() 242, Array(repeating:count:) 49,
  index(offsetBy:) 19.
- Uncatchable Objective-C exception sources: `JSONSerialization.data(withJSONObject:` 160 sites (21 guarded by
  isValidJSONObject); 23 legacy FileHandle `availableData` / `seekToEndOfFile()` / `readData(ofLength:)` lines; about 440
  NSRange-taking AppKit/Foundation calls. `CmuxApplication.reportException` sees only exceptions that reach the run loop.
- 69 NSRegularExpression / Regex / `#/` sites (backtracking engines; 2 in the Sentry scrubber). 94
  NSClassFromString / NSSelectorFromString / dlsym sites; `check-objc-selectors.py` covers `super` calls only.
- The crash ratchet runs in CI (scripts/ci/cmux_next_fast_gates.py "crash ratchet" -> crash_ratchet_compare.py, change vs
  base). `guardrails.py` never runs on CI (prepush-gate.py line 52: "never --commits, never under GitHub Actions").
  `prepush-gate.py --commits` does run in cmux-next.yml step "Pushed commits add no violations".

### Rust (cmux-tui: 77 crate dirs, 72 workspace members, toolchain 1.95.0, tokio 1.53.1, panic=unwind)
- `rust-panic-baseline.json`: 69 crates, deny total 6,519 (unwrap 1,678, expect 427, indexing_slicing 4,033,
  string_slice 306, unreachable 70, panic 5). By crate: cmux-tui-core 2,337, cmux-tui 1,597, acpmux 1,118,
  cmux-browser-host 224, cmux-remote 153, chatmux-relay 149, ghostty-vt 104. Tracked: arithmetic 4,390, cast truncation 554.
  The ratchet runs in CI (cmux-tui.yml "Rust panic ratchet"); a workspace member not in the baseline must have 0 hits, so
  cmux-holder, cmux-process, cmux-flow-trace and cmux-kitty-media are already at 0 in production code.
- **Not covered by any ratchet** (separate workspaces): cmux-app-ffi, cmux-rd-ffi, cmux-layout-reducer-ffi (all
  linked in-process as CCmuxAppFFI), cmux-rd-host and cmux-remote-browser-host/-testhost (excluded or separate),
  `Native/OptChat/{optchat-chief,chief-turn,optchat-core,optchat-host,optchat-wasm}` (256 unwrap/expect lines incl.
  tests), `Native/DiffSidecar`, `cmux-next-ios/rust` (cmux-mobile-host is bundled in the Mac app).
- **In-process FFI:** CCmuxAppFFI (Package.swift:168, pin `cmux-app-ffi-ecdb356...`) is the one Rust staticlib in the
  app: cmux-rd-ffi (61 `extern "C" fn`, 28 catch_unwind lines), cmux-layout-reducer-ffi (19, 9), cmux-palette-ranker
  (5, 3), cmux-motion via cmux-app-ffi/src/motion.rs (17, 0). Since Rust 1.81 a panic reaching `extern "C"` aborts, which
  ends cmux. Its release profile is `debug = false, strip = "debuginfo"` (no symbolicated Rust frames).
  `check-app-ffi-pin.sh` fails CI when FFI sources differ from the pinned source sha, so any edit there needs a pin
  republish (app-ffi-release.yml). cmux-terminal-client (35 exports, 0 catch_unwind) is iOS only.
- 444 RecoverPoison uses. No thread or task supervisor (`cmux_panic_log::supervise` does not exist).
- 13 crates use tokio; builder calls: 20 `new_current_thread`, 9 `new_multi_thread` (plus `#[tokio::main/test]`
  flavors). Blocking-signal lines in async files: acpmux 680, cmux-tui 335, cmux-remote 188, chatmux-relay 146.
- 206 statement-level `tokio::spawn(` with the handle dropped (acpmux 130); 194 thread-spawn statements (core 115,
  cmux-tui 52). 54 `pre_exec` lines; 852 `Command::new` lines and 42 `kill_on_drop`; 468 `unbounded_channel` /
  `mpsc::channel()` lines (all raw counts include inline tests).
- No clippy.toml; the workspace denies only `unsafe_op_in_unsafe_fn`; `clippy -D warnings` runs in cmux-tui-spec.yml.
  2,491 `unsafe {` blocks in src, 2,054 SAFETY comments, 21 `unsafe impl Send/Sync`. 39 crates (excluding `-sys`) have no
  `unsafe` in src and none forbids it.
- `cmux-tui-core/src/lock_rank.rs` (RankedMutex, 75 uses vs 324 lock declarations in the crate); acpmux (207 lock
  declarations) and cmux-tui (181) have no rank checks.
- At least 7 private `write_atomic` copies; about 105 production `fs::write` calls write state the daemon reads back.

### Fuzz, sanitizers, hangs, containment
- Swift: 7 seeded fuzz suites with private RNGs (ControlParser, ControlInput, MobileProtocol, RenderIndex, CmxIrohDecoder,
  IrxFrame, TerminalSizingOperation). No coverage guidance (Xcode's toolchain has no Swift libFuzzer runtime).
- Rust: 1 (`cmux-weft/tests/parsers_fuzz.rs`); no `cmux-tui/fuzz`, about 290 pub decode/parse entry points in 40 crates.
- VM UI fuzzer works: `scripts/fuzz/macos-matrix/{fuzz.py,smoke.py,vm.sh,images.json,MATRIX.md}` and
  `scripts/cmux-next/os-matrix.sh` (not in the macos-matrix folder). Found Hang C (#24913, 10 s makeKeyWindow stall on
  14/15) and Crash D (stack overflow on 26, fixed 29804bacb09). Only aws-m4pro-6 holds the 14/15/26 images, one VM at a
  time; no macOS 27 Tart host.
- `scripts/ci/package-test-lane.sh` supports `CMUX_SWIFT_SANITIZE=address|thread|undefined`; nothing runs on a schedule;
  no suppressions; `reload.sh --config` takes `debug|release|bench` only; no Rust ASan/TSan/Miri. CmuxNextAppTests is
  already red on the fleet at the base (signal 11, perf-lead.md 2026-10-24).
- CEF shim `libcmux_cef_shim.dylib` (7,920 lines ObjC++/C++ in `Packages/macOS/CmuxNext/CEFShim`) builds with -O2 and
  -fstack-protector only; libghostty is built `-Doptimize=ReleaseFast` (ensure-ghosttykit.sh:288). In-process CEF
  replaces the default malloc zone with PartitionAlloc (browser-isolation.md:91; CmuxNextMallocZone/early_zone.c).
- MainThreadWatchdog (`CmuxNextControl/Diagnostics`, kqueue alarm, zero idle cost) watches the main thread only;
  ThreadStackSampler already suspends a thread and walks frame pointers. LagSpikeReporter sends stalls >= 250 ms to
  Sentry; appHangTimeoutInterval 8 s. The CEF pump runs on the **main** thread (CEFMessagePump.swift line 6), so the main
  watchdog already covers it. The daemon has no hang watcher; no tokio slow-poll detection.
- Containment scripts exist: child-crash-e2e.py, crash-ends-app-gate.py, action-crash-sweep.py (~900 actions),
  readiness-soak.py, relaunch-e2e.py, update-e2e.py, skew-matrix.py, restore-journey.py, state-roots-baseline.tsv,
  DaemonCrashLoopTests. F2 (CEF browser process in a helper app) is about 10 % done (PL-cefhost); a Chromium
  browser-process CHECK still ends cmux. Holder model (F6): cmux-holder owns PTY fds and byte rings; killing it ends its
  shells by design.
- Webviews: 24 page entry files call `createRoot`; only agent-session has React boundaries (PaneBoundary).
- Field: AppRunMarker / CrashRecoveryService already know "previous run ended unexpectedly"; Sentry
  autoSessionTracking is on; no unclean-exit metric; no crash keys.

## 3. Target design

### A. Stability lab (ClusterFuzz for cmux)
`scripts/cmux-next/stability-lab.py` + `stability-lanes.json`, started by a cron in the hq controller (like perf_cron),
scheduled only through `cmux-ci` (never maclease or macfleet). It never blocks a push, merge or nightly and adds no
GitHub CI job.

- **Hosts.** Long lanes run on dedicated hosts: the M6 minis cmux15-24 except cmux20 (cmux20 is the perf cron's bench
  host), 2 Tart VMs each (macOS 27 hosts), plus one aws-m4pro Tart host per major. A lab step never shares a host with a
  bench-class step. Fast lanes may run on general capacity and are preemptible.
- **Fast lanes, each new tip with a fleet DEV build, within ~30 min:** os-matrix smoke on 14/15/26/27 (with `leaks`
  and private-API probes), child-crash-e2e, process-chaos-e2e, crash-ends-app-gate, Swift fuzz long mode 5 min/suite,
  cargo-fuzz 5 min/target from the stored corpus, update-e2e, skew-matrix, restore-journey.
- **Long lanes on the newest tip:** VM UI fuzz (4 majors x seeds) with diag variants gmalloc, scribble, mtc, probguard,
  coop-strict, asan/tsan/ubsan apps (Chromium off, see risks); chaos suite incl. quit storm; state-corruption lane;
  Swift package tests under TSan/ASan/UBSan/coop-strict; Rust ASan/TSan/LSan, Miri, loom; coverage-guided libFuzzer
  (Rust and Linux Swift); action-crash-sweep; 6 h ASan STRESS soak nightly; swift-diagnostics and the Q10 clippy runs
  (Linux and macOS) per tip, which refresh every machine queue.
- **Signatures** (`crash_signature.py`): .ips, Rust panic JSONL, sanitizer reports, hang samples, slow polls, page JS
  errors, ErrorJournal faults, Invariant events. Frames matching `signature-ignore.txt` (Swift runtime, libsystem,
  libdispatch, Rust panic machinery, CEF/PartitionAlloc CHECK helpers, sanitizer runtime) are dropped; the top 3 remaining
  frames, offsets/generic args/closure numbers stripped, give hash12 (ClusterFuzz crash state).
- **Issues and bisect.** One GitHub issue per signature (label `stability-sig:<hash12>`); bisect by fleet builds and
  replay; close after the fix range is verified on 3 clean tips; reopen on recurrence. Sentry top issues join the same
  flow. Fuzzers whose coverage is flat for 3 runs get a `fuzzer-quality` issue.
- **Per-merge coverage decision (made, not asked):** tip coverage plus bisect. `stability-lab.py coverage` proves every
  landed commit is in a tip that passed the fast lanes. Building every merge needs ~10x the fleet and collides with perf
  and dev builds; bisect assigns each finding to its merge.

### B. Hang watching (HangWatcher analog)
- **Swift.** `HangWatchScope` and a per-thread registry live in **CmuxNextWakeups** (CmuxNextDaemon, CmuxNextTerminal and
  CmuxNextControl all depend on it; CmuxNextControl cannot be imported by them). Entering a scope is two atomic stores
  (deadline set / restore) into the thread's slot; a global open-scope count triggers one `EVFILT_USER` wake of the watcher
  only on 0 -> 1. The watcher (owned by MainThreadWatchdog in CmuxNextControl, injected by the composition root) does a
  timed wait to the earliest deadline it reads and parks with no timeout when the count is 0: no syscall per scope, zero
  idle wakeups. `invalidate()` covers unbounded waits. Two tiers: a jank record at the scope's budget, and a hang dump at
  >= 2 s with the hung thread's stack from ThreadStackSampler (thread_suspend + frame-pointer walk) and crash keys.
  Scopes: daemon reader line handling (LineTransport), terminal output-lane feed (TerminalOutputLane), BackgroundWork
  `.files`/`.system` jobs (BlockingLane). The CEF pump is on main: it gets a phase label in the main watchdog episode, not
  a scope.
- **Rust.** `cmux-panic-log` gets `watch_scope(kind, deadline)` with the same atomic design and one watcher thread
  (condvar park with no timeout while no scope is open). Stacks: on macOS, thread_suspend + frame-pointer walk (arm64
  keeps frame pointers); on Linux, pthread_kill to a handler writing into a preallocated buffer. Scopes: mux-conn
  requests (jank 250 ms, hang 2 s), journal writer loop, holder-link. Reports go to JSONL next to the panic log and are
  forwarded by OwnerPanicForwarder. Lab builds add a tokio slow-poll detector (polls > 2 ms with spawn location).
- **Crash keys** (Swift and Rust): fixed-size, preallocated slots written with atomics (current action id, pane kind, CEF
  state, daemon epoch, hung thread ids), read by the crash handler and hang reporter with no allocation.

### C. Compile-time safety (compiler diagnostics are the queue)
1. **Swift 6 everywhere in the closure.** MessagesLab keeps `.v5` + complete concurrency checking as warnings until its
   queue is 0, then flips. Outside-closure iOS targets are post-push work.
2. **Strict memory safety, Chrome order.** One lander commit per package turns `.strictMemorySafety()` on for every
   target and applies the compiler's `unsafe` fix-its by machine, each marked `// SAFETY-TODO(p10)`. The queue is
   `git grep -c 'SAFETY-TODO(p10)'` per module; module tasks remove the TODOs (refactor to safe APIs, or a real
   `// SAFETY:` argument). External-input modules go first. During the push the setting stays a warning; a local-only
   guardrail refuses added SAFETY-TODO and added unsafe constructs without `unsafe`; the lab's per-tip swift-diagnostics run
   files new unmarked sites. `treatWarning("StrictMemorySafety", as: .error)` lands in one lander commit at about hour 62,
   after a diagnostics run at that tip shows 0 (this avoids the race where a branch that compiled before the flip lands
   after it).
3. `@unchecked Sendable` / `nonisolated(unsafe)` become Mutex<State> (one portable Mutex in CmuxSafeConcurrency), actors or
   Sendable values; the rest is a short reviewed list (signal-handler globals) with written arguments.
4. `@preconcurrency` only in one SparkleSeam file.
5. Package.swift edits are serialized: implementers write `stability-settings.json`; one lander applies it every few hours
   and compile-checks on the fleet. No implementer edits the 157-target manifest by hand.
6. `swift-diagnostics.sh` (fleet only) builds with a clean `--scratch-path` (or reads the `.dia` files) so cached files are
   not undercounted, and emits `diagnostics.jsonl {target, file, line, group, message, fixits}`.
7. **C/C++ and Zig in process.** The CEF shim builds with Chrome's hardening flags and `-Wunsafe-buffer-usage` (queue, then
   `-Werror=unsafe-buffer-usage`), and has an instrumented variant for lab apps. libghostty has a ReleaseSafe lab variant.

### D. Traps: outside input never traps; invariants trap only through one API
- **Classification first** (Chrome's checks.md): every Q09/Q10 hit is classed as *input-reachable* (operand reachable from
  a Q14 decode entry point, a file, a peer frame) or *internal invariant*. Input-reachable sites get validation that
  returns a typed error to a boundary; never clamping, never a silent default. Internal invariants go to the Invariant API.
- **Invariant API** in `Packages/Shared/CmuxSafeConcurrency` (Foundation-free):
  `Invariant.check(cond, id)` traps in every build (the one sanctioned trap; each site needs a `swift.invariant_check`
  allowlist entry with a reason, used where continuing would corrupt shared or persisted state);
  `Invariant.notFatalUntil(cond, id, build: N)` reports once per site per launch until build N, then traps (the ratchet
  refuses a lowered or removed N without a reason); `Invariant.dumpWillBeCheck(cond, id)` reports forever and needs an
  allowlist entry with a written handler. Reports do one atomic dedupe on the caller's thread and hand the event to the
  background crash-reporting lane (no Sentry call or I/O on the caller's thread; consent respected). A `nightly-assert`
  variant reports `assert()` and debug checks from a sampled slice of Nightly (DCHECK canary).
- **Swift checked access stays checked.** The bounds-checked subscript and checked Int conversions are already Chrome's
  goal state; bans apply only to decode paths (Q14 entry points and callees), where the fix is input validation.
- **OnceContinuation** (CmuxSafeConcurrency): resume exactly once; a double resume is a no-op plus a fault; resume with a
  typed error from deinit; **no cancellation by default** (today's semantics), `.cancellable` is an explicit option the
  reviewer checks per site. The 12 private resume-once helpers are deleted.
- **unowned.** Safe `unowned` already traps deterministically (the MiraclePtr property). Each of the 73 allowlisted sites
  becomes either `weak` with an else branch that calls `Invariant.notFatalUntil` and shows the existing error toast (when
  the owner can legitimately die first), or stays `unowned` with a `lifetime:` reason in its allowlist entry. Never a
  silent return.
- **MiraclePtr analog = callback tokens.** C callbacks take CallbackRegistry tokens (generation-checked slot table,
  lock-free lookup for hot Ghostty/CEF callbacks), never `passUnretained(self)`.
- **Objective-C exceptions:** CheckedJSON, throwing FileHandle APIs, checked NSRange helpers.
- **In-process Rust FFI:** every `extern "C" fn` in the CCmuxAppFFI crates runs its body in `ffi_boundary` (catch_unwind,
  record, return the documented error value). Release keeps line tables + dSYM for Sentry.

### E. Rust
- **Panic deny to 0 in every crate of every shipped Rust workspace** (cmux-tui members; cmux-app-ffi, cmux-rd-ffi,
  cmux-layout-reducer-ffi; cmux-rd-host; cmux-remote-browser-host; Native/DiffSidecar; Native/OptChat/*;
  cmux-next-ios/rust cmux-mobile-host), measured by a Linux and a macOS clippy run merged by file:line. An internal
  invariant keeps `expect`/`unreachable!` only as `#[allow(clippy::expect_used, reason = "INVARIANT: <why it holds>")]`
  on the smallest item (`allow`, not `expect`: rust-panic-free.md rule 2, the plain `clippy -D warnings` run does not
  enable these lints, so an `#[expect]` there is unfulfilled and red); a tracked count reports these. Extra-workspace
  rows live in a report-only baseline CI does not read.
- **Supervision** (`cmux_panic_log::supervise_thread/supervise_task`): policy `Fatal` is the default (clean exit; the
  process supervisor restarts the process and the journal restores state). `Restart` (backoff 100 ms .. 30 s, at most
  5/min) only for workers whose state is private, each with a test that a restart rebuilds it. A panic that poisons a lock
  on shared state escalates to Fatal. Per-request catch boundaries only around decode/validation that mutate no shared
  state (ReportBadMessage pattern). Every call names a `ShutdownBehavior` (Continue/Skip/Block with a deadline).
- **cmux-blocking** (ScopedBlockingCall + MayBlock): runtime builders mark workers no-block; `spawn_blocking` and std
  threads may block. Wrappers (`fs`, `process::output`, `sleep`, `recv`, `Condvar::wait`) on a multi_thread worker run the
  call through `block_in_place` (compensation) and count it; on a current_thread runtime they count it and write a
  slow-poll record with the caller location. Debug logs once per site; only cmux-blocking's own tests and the lab
  (`CMUX_BLOCKING_STRICT=1`) panic. Unknown threads (test runtimes) count as unknown, never as no-block.
- **Queues:** clippy `disallowed-methods` from a lab-only config dir (`CLIPPY_CONF_DIR=cmux-tui/lab/clippy`, never the
  workspace clippy.toml, which would turn `-D warnings` red) for blocking std APIs; the syn scanner for dropped handles,
  unsupervised spawns, `pre_exec` bodies, unreaped children and unbounded channels; ast-grep rules (pinned in
  lint-tools.lock) for the local pre-push check on the person's Mac, where `cargo build` is banned.
- **Fork safety** (pre_exec async-signal-safe or posix_spawn), **child reaping** (wait, store or kill_on_drop),
  **bounded queues** (stated overflow policy), **lock ranks** in acpmux and cmux-tui (shared `cmux-lock-rank` crate),
  **ImportantFileWriter** (`write_important`: temp + fsync + rename + dir fsync), **SQLite policy** (busy timeout, corrupt
  database set aside and recreated, one fault), **checked arithmetic** in wire decoders, `#![forbid(unsafe_code)]` in the
  39 unsafe-free crates, SAFETY comments on every unsafe block, loom for the holder ring, Miri for pure crates.

### F. Containment proof
- `process-chaos-e2e.py` (bare metal): SIGKILL daemon, acpmux, a terminal host, Chromium renderer/GPU/utility, WebContent
  and the holder during typing; per-fault expected outcome (holder kill: app up, its panes show ended state with the
  restart action, other holders untouched). Main-thread ping p99 <= 250 ms through every kill.
- GPU crash loop (12 GPU kills in 60 s) must not reach Chromium's FATAL; until F2 lands, a CEF fork patch or switch turns
  the final fallback into GPU-off.
- State corruption lane (every persisted file and DB truncated/flipped/zeroed -> relaunch -> app and daemon start, file set
  aside, fault counted). Quit storm lane. BadMessage API on both sides of the daemon wire and the socket server: a bad peer
  closes only that connection.
- Rule of 2: inventory of untrusted parsers; foreign browser-profile import moves into a sandboxed XPC service.
- Webview sad tab: one error boundary at every page root.
- F2 host kind added to child-crash-e2e when PL-cefhost lands it.

### Schedule (72 h)
- H0-12: lab core and shared APIs (002, 003, 012, 013, 016, 017, 036, 037, 198, 199, 172, 083, 101, 103, 100, 152, 211).
- H12-60: all queues in parallel; lab lanes running continuously; Q15/Q16 fix tasks are part of the push.
- H36 and H58: app-ffi pin republishes (153; procedure in section 4, rule 5).
- H60-66: error flips (079 strict memory safety, 045 MessagesLab v6 if not already), final bans in the local tier.
- H66-72: test phase on the final tip; `stability-final.sh` (151).

## 4. Rules for implementers

1. **No CI gates.** Do not add GitHub jobs, steps, required checks or rows that make CI fail on growth. New ratchet classes
   (trap_api, raw_continuation, objc_raises, invariant_check, target-settings, async-blocking, unsupervised-spawn,
   ffi-guard, SAFETY-TODO) live in the local-only tier (guardrails.py / prepush-gate local rules, skipped under
   GITHUB_ACTIONS and `--commits`) and in report-only baselines (`crash-safety-report-baseline.json`,
   `rust-panic-extra-baseline.json`) that CI never reads. CI-read baselines (`crash-safety-baseline.json`,
   `rust-panic-baseline.json`) may only go down through the existing mechanism.
2. **No local builds.** Never `swift build/test`, `xcodebuild`, `cargo build/test/clippy` or `reload.sh` on a person's Mac.
   Compile-check through `cmux-ci build cmux --ref SHA` or `cmux-ci run --class isolated`; Rust on a Testbox/rbx via
   nx-remote. Landing is compile-only.
3. **Never a silent default for broken state** (REVIEW-STANDARD). Outside input -> typed error to a boundary that logs or
   counts. Internal invariant -> Invariant API / `INVARIANT:` expect. Reviewers reject `.get().unwrap_or_default()`,
   `clamping:`, clamped slices and `?? 0` on broken state unless the diff shows the value is outside input with a defined
   fallback.
4. **Shared files.** Package.swift settings only through `stability-settings.json` + lander (198). Ratchet baselines
   only through `--update-baseline` reruns, never hand merges. Cargo.lock: only tasks 101 (adds cmux-blocking and adds
   `cmux-blocking` / `cmux-panic-log` dependencies to every consumer crate up front, plus the `cmux-stability` feature for
   033) and 103 change it; fuzz, scanner, loom and lab tools have their own workspaces and locks.
5. **FFI pins.** A change under any path listed by `check-app-ffi-pin.sh --list-inputs` lands only through the pin lander
   (153), which batches sources and republishes CCmuxAppFFI in the same PR. Task branches with FFI inputs stay unmerged
   until a lander window (H36, H58). In each window the lander:
   1. Lists the queue: `scripts/cmux-next/check-app-ffi-pin.sh --batch $(git for-each-ref --format='%(refname:short)'
      refs/remotes/origin/cp/)`. It prints each branch whose own commits (since its merge-base with HEAD) change an FFI
      input, with the files.
   2. Merges those branches into one lander branch from the newest big branch, with the Rust tests of the touched FFI
      crates green on a Testbox (`cargo test -p cmux-app-ffi -p cmux-rd-ffi -p cmux-layout-reducer-ffi
      -p cmux-palette-ranker`), and commits the merged sources as source sha S.
   3. Publishes `cmux-app-ffi-S`. The publish job and the `ffi-release` environment admit only `feat-cmux-next`, so S
      lands on `feat-cmux-next` first (its push runs app-ffi-release.yml), or the CI lead publishes it by hand
      (docs/ci/app-ffi-release.md). A tag is immutable: a wrong release cannot be replaced, only superseded.
   4. Pins it in the same lander PR: `scripts/cmux-next/repin-app-ffi.sh S CHECKSUM`, then
      `scripts/cmux-next/check-app-ffi-pin.sh --verify-release` passes and `git merge-base --is-ancestor <152's commit> S`
      exits 0. Then `cmux-ci build cmux --ref <lander head>` and the child-crash-e2e smoke.
   A branch that misses H36 waits for H58; after H58, FFI input changes wait for the push's test phase.
6. **Ownership.** Before a mechanical change in an owned area (OWNERS.md: PL-daemon for cmux-tui-core/cmux-server/
   cmux-pty, PL-acpmux for acpmux, PL-arch for CmuxNextApp, PL-cefhost/PL-cef for CEF, PL-ghostty for Terminal), take a
   per-file lease in COORDINATION.md; if the owner's perf task on that file is in flight, rebase onto it after it lands.
   Tell the owner.
7. **Hot paths.** Any change inside a `// perf-hot:` function (HangWatchScope sites, CallbackRegistry, output lane) is
   benched on the fleet before and after and the result goes in the commit.
8. **Escape comments need proof:** `crash-allow:`, `SAFETY:`, `INVARIANT:`, `lifetime:`, `blocking-allow:`,
   `supervise-allow:`, `unbounded-allow:`, `ffi-nopanic:`, `settings-allow:`, `// motion: allow` style. Each names the
   thread, the bound or the reason it cannot fail.
9. **Each behavior change gets a regression test that fails without it**, run by the agent on the fleet before and after;
   the commit says the result.
10. **Main thread.** No blocking work added on main (Sentry, disk, locks with waits). Invariant reports and crash keys are
    atomics on the caller's thread only.
11. **Secrets.** The Sentry token for stability-health.py comes from the environment (read from ~/.claude/secrets.md by
    the operator), never into code, logs or commits.

## 5. Done checks

Each check is a command with a number. `scripts/cmux-next/stability-final.sh` (151) prints all of them.

1. SWIFT MODE: `git grep -n 'swiftLanguageMode(.v5)' -- Packages/Shared/CmuxMessagesLab Packages/macOS Packages/Shared
   Packages/iOS` prints 0 lines for packages in the mac closure (today 4).
2. UNCHECKED: crash_ratchet swift.unchecked summed over closure modules <= 30 (today 131); `git grep -n -B1 -E
   '@unchecked Sendable|nonisolated\(unsafe\)' -- 'Packages/**/Sources/**/*.swift'` has 0 hits in closure modules without
   `crash-allow:` on the line or the line above (today 176 across all Packages).
3. PRECONCURRENCY: `git grep -n '@preconcurrency' -- 'Packages/**/Sources/**/*.swift' | grep -v SparkleSeam` = 0 in the
   closure (today 35).
4. MEMORY SAFETY: every Swift target in the closure has `.strictMemorySafety()` and
   `treatWarning("StrictMemorySafety", as: .error)`; `swift-diagnostics.sh --summary --group StrictMemorySafety` = 0;
   `git grep -c 'SAFETY-TODO(p10)' -- 'Packages/**/Sources'` = 0 in the external-input modules (Daemon, Control, Mobile,
   MobileHost, Iroh, Irx, VNC, VNCWebRTC, ScreenKit, RemoteView, Phone, BrowserImport, Browser/CEF) and <= 10 % of its
   hour-12 count elsewhere, every remaining one in Q04.
5. CONTINUATIONS: `git grep -n -E 'with(Checked|Unsafe)(Throwing)?Continuation' -- 'Packages/**/Sources/**/*.swift'
   ':!Packages/Shared/CmuxSafeConcurrency'` = 0 (today 247); `git grep -n -E '(class|struct) (ResumeOnce|Once|OnceBox|
   ResumeGuard|InstallOnce|AgentPaneResumeOnce)\b' -- 'Packages/**/Sources'` = 0 (today 12); raw_continuation banned in the
   local tier.
6. UNOWNED AND CALLBACKS: every swift.unowned allowlist entry has a `lifetime:` reason (0 without), and the count is <= 20
   (today 73, none reasoned); `git grep -n 'Unmanaged.passUnretained' -- 'Packages/**/Sources/**/*.swift'` = 0 outside
   `CmuxSafeConcurrency/CallbackRegistry*.swift` (today 30).
7. SWIFT TRAPS: `crash_ratchet.py --report trap_api,index_subscript,int_conversion --classify` shows 0 input-reachable hits
   in closure modules; `git grep -c uniqueKeysWithValues -- 'Packages/**/Sources'` = 0 (today 72); `crash_ratchet.py
   --report objc_raises` = 0 in the modules of 167-170 and `git grep -n -E 'availableData|seekToEndOfFile\(\)|
   readData\(ofLength' -- 'Packages/**/Sources'` = 0 (today 23); every `Invariant.check` / `dumpWillBeCheck` site has an
   allowlist entry.
8. RUST PANICS: in the merged Linux+macOS Q10 run, every deny lint is 0 for every crate of every shipped Rust workspace
   (rust-panic-baseline.json 69 crates today 6,519; rust-panic-extra-baseline.json rows for the 6 separate cmux-tui
   workspaces, Native/OptChat/*, Native/DiffSidecar and cmux-mobile-host). The `INVARIANT:` expect count is reported per
   crate. crash-safety-baseline rust rows for unwrap, expect, panic_macro and exit are 0.
9. FFI: for cmux-app-ffi, cmux-rd-ffi, cmux-layout-reducer-ffi and cmux-palette-ranker, the count of `extern "C" fn` equals
   the count of `ffi_boundary(` plus `ffi-nopanic:` (today 102 exports, 40 catch_unwind lines); the CCmuxAppFFI pin's source
   sha contains tasks 152 and 156; `check-app-ffi-pin.sh` passes.
10. TOKIO BLOCKING AND PROCESSES: `cargo run --manifest-path cmux-tui/tools/async-blocking-scan/Cargo.toml -- --root
    cmux-tui/crates --json` reports 0 blocking-in-async, 0 dropped JoinHandles, 0 unsupervised long-lived spawns, 0
    non-signal-safe `pre_exec` bodies, 0 unreaped children and 0 unreasoned unbounded channels in production code; the lab
    clippy run with `CLIPPY_CONF_DIR=cmux-tui/lab/clippy` shows 0 `disallowed_methods` outside cmux-blocking. Every
    `supervise_*` call names a policy and a ShutdownBehavior.
11. UNSAFE DOCS: tracked `undocumented_unsafe_blocks` = 0 workspace-wide and in the separate workspaces; the 39 unsafe-free
    crates carry `#![forbid(unsafe_code)]`; each of the 21 `unsafe impl Send/Sync` has a SAFETY comment and a test reference.
12. C/C++: `build-cef-shim.sh` warning file shows 0 `-Wunsafe-buffer-usage` warnings and the shim builds with
    `-Werror=unsafe-buffer-usage`, `_LIBCPP_HARDENING_MODE_FAST`, `-ftrivial-auto-var-init=pattern`,
    `-fstack-protector-strong`.
13. SANITIZERS SWIFT: `scripts/cmux-next/sanitizer-sweep.sh --sanitize thread,address,undefined,coop-strict --ref SHA` over
    every closure test target reports 0 sanitizer findings outside the reasoned third-party suppressions (<= 10 lines);
    suites red at the base without a sanitizer are listed separately, not counted.
14. SANITIZERS RUST: `cmux-tui/scripts/sanitize.sh --sanitizer address,thread,leak` reports 0 for cmux-tui-core, acpmux,
    cmux-holder, cmux-pty and ghostty-vt (Linux and macOS for cmux-pty/cmux-holder); Miri passes on cmux-pane-protocol,
    cmux-remote-protocol, cmux-rd-proto, cmux-layout-reducer; loom passes on the holder ring.
15. FUZZ: >= 40 Rust targets (cmux-tui/fuzz + Native/DiffSidecar/fuzz + Native/OptChat/fuzz + cmux-next-ios/rust/fuzz),
    >= 25 Swift suites on CmuxFuzzSupport, >= 6 coverage-guided Swift libFuzzer targets; every target runs >= 30 min CPU on
    the final tip from its stored corpus with 0 crashes, 0 OOMs (`-rss_limit_mb=2048 -malloc_limit_mb=256`) and 0
    timeouts (`-timeout=2`).
16. VM MATRIX: `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15,26,27` prints MATRIX VERDICT PASS; 60 min x 4 seeds per
    major on the final tip gives 0 crashes, 0 deaths and 0 hang samples >= 1 s, not counting signatures linked to an issue
    owned by another program (listed in a separate row with owner and ETA, e.g. #24913 -> PL-cefhost); `vm.sh --suite
    chaos` passes on all 4 majors.
17. CONTAINMENT: process-chaos-e2e.py (incl. `--only gpu-crash-loop`), child-crash-e2e.py, crash-ends-app-gate.py and
    state-corruption-e2e.py exit 0 on the final tip; bare-metal main-thread ping p99 <= 250 ms during every kill; the app
    pid is unchanged through the GPU crash loop.
18. HANGS: a HangWatchScope test counts 0 kevent calls per scope enter/exit in steady state; bench-idle wakeups unchanged
    before/after 031; a blocked-scope test produces one record whose top frame is in the blocked function (Swift and Rust).
19. LAB: `stability-lab.py coverage --since 72h` shows 100 % of landed feat-cmux-next commits in a tip that passed the fast
    lanes; `gh issue list -l stability-sig --state open` shows 0 signatures that are older than 24 h without a fix in
    review (excluding the other-owner row of check 16).
20. SOAK: `readiness-soak.py --hours 24 --agents 10` on bare metal (plus 6 h `--app-config asan`, Chromium off) gives 0
    crashes, 0 hangs, 0 stuck turns, 0 zombie children, app memory slope <= 20 MB/h after hour 2.
21. FIELD (after the push, nightly-next): `stability-health.py --env nightly-next --days 3` shows crash-free sessions >=
    99.9 %, unclean exits without a crash report <= 0.1 % of sessions, 0 hang events >= 2 s not owned by another program,
    lag spikes >= 250 ms <= 1 per 100 session-hours; every spike signature has an issue.

## 6. Machine queues

Each hit (or each file/module group shown) is one task; the generator splits groups to <= 400 changed lines.

- **Q01 swift-v5-targets:** `git grep -n 'swiftLanguageMode(.v5)' -- '*Package.swift'`; then per folder,
  `scripts/cmux-next/messageslab-queue.sh` (fleet: `cmux-ci run --class isolated --ref SHA --script
  scripts/cmux-next/messageslab-queue.sh -- --ref SHA`), which is swift-diagnostics.sh's build with complete checking
  as a build flag. It counts only concurrency diagnostics (Q01 MessagesLab per-folder queue, below).
- **Q02 unchecked-sendable:** `git grep -n -B1 -E '@unchecked Sendable|nonisolated\(unsafe\)' --
  'Packages/**/Sources/**/*.swift'`, grouped by closure module (258 lines total, 131 in the closure ratchet); later
  `crash_ratchet.py --report unchecked`.
- **Q03 preconcurrency:** `git grep -n '@preconcurrency' -- 'Packages/**/Sources/**/*.swift'` (35).
- **Q04 safety-todo:** after task 211, `git grep -c 'SAFETY-TODO(p10)' -- 'Packages/**/Sources'` per module; plus
  `swift-diagnostics.sh --summary --group StrictMemorySafety` for new unmarked sites. Pre-count proxy about 1,500 lines.
- **Q05 (post-push) concurrency-warning-groups:** `swift-diagnostics.sh --summary` concurrency rows on one pinned toolchain.
- **Q06 raw-continuations:** `git grep -n -E 'with(Checked|Unsafe)(Throwing)?Continuation' --
  'Packages/**/Sources/**/*.swift'` (247, by module).
- **Q07 unowned:** `jq -r '.allow[]|select(.class=="swift.unowned")|.path' scripts/cmux-next/crash-allowlist.json | sort |
  uniq -c` (73).
- **Q08 unretained-callbacks:** `git grep -n 'Unmanaged.passUnretained' -- 'Packages/**/Sources/**/*.swift'` (30 in 20
  files), then `git grep -n '@convention(c)'` (219) for review.
- **Q09 swift-trap-api:** `python3 scripts/cmux-next/crash_ratchet.py --report trap_api,index_subscript,int_conversion
  --all-modules --classify` (task 092/205). Proxies: uniqueKeysWithValues 72, removeFirst()/removeLast() 242,
  Array(repeating:) 49, offsetBy: 19.
- **Q10 rust-panic-deny:** Linux rbx/Testbox: `cd cmux-tui && cargo clippy --workspace --lib --bins --locked
  --message-format=json -- $(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags) > c.jsonl`; macOS fleet step
  (`cmux-ci run --class isolated`) the same; extra workspaces via `rust_panic_ratchet.py --manifest <path>` (task 155);
  merge with `rust_panic_ratchet.py --clippy-json linux.jsonl --clippy-json mac.jsonl --queue` (task 210), which emits one
  task per file or file group of <= 50 hits with crate, module, owner and input/invariant class (6,519 + extra rows).
- **Q11 rust-async-blocking:** lab clippy with `CLIPPY_CONF_DIR=cmux-tui/lab/clippy` filtered to `disallowed_methods`
  (task 206), plus `async-blocking-scan --kind blocking` (task 100). Proxy: 1,443 blocking-signal lines in 11 crates.
- **Q12 rust-unsupervised:** `async-blocking-scan --kind spawn` (206 dropped tokio handles, 194 thread spawns).
- **Q13 rust-undocumented-unsafe:** report-only tracked lint `undocumented_unsafe_blocks` from the Q10 run (2,491 unsafe
  blocks, 2,054 SAFETY comments).
- **Q14 fuzz-inventory:** Rust: `git grep -n -E 'pub(\(crate\))? fn (decode|parse|from_bytes|read_frame|from_slice)' --
  'cmux-tui/crates/*/src' 'Native/*/src' 'Native/OptChat/*/src' 'cmux-next-ios/rust/crates/*/src'` minus fuzz targets.
  Swift: modules from `git grep -c -E 'JSONDecoder\(\)|JSONSerialization|PropertyList(Decoder|Serialization)|
  loadUnaligned|withUnsafeBytes' -- 'Packages/**/Sources/**/*.swift'` minus modules with `*FuzzTests.swift`.
- **Q15 sanitizer-findings:** `sanitizer-sweep.sh ... --out findings.jsonl`, `cmux-tui/scripts/sanitize.sh ... --out
  findings.jsonl`; each unique signature is one task.
- **Q16 lab-signatures:** `gh issue list -l stability-sig --state open --json number,title,labels` (through glaeda-gh read
  rules); each signature is one fix task with its repro.
- **Q17 field-signatures:** `scripts/cmux-next/stability-health.py --env nightly-next --top 50 --json`; each Sentry issue
  without a GitHub issue is one task.
- **Q18 ffi-exports:** `git grep -n -A3 'extern "C" fn' -- cmux-tui/crates/{cmux-app-ffi,cmux-rd-ffi,
  cmux-layout-reducer-ffi,cmux-palette-ranker}/src` without `ffi_boundary`/`ffi-nopanic:` (102 exports).
- **Q19 objc-raises:** `crash_ratchet.py --report objc_raises` (160 JSONSerialization, 23 FileHandle, ~440 NSRange).
- **Q20 rust-process:** `async-blocking-scan --kind pre_exec,child,unbounded` (54 pre_exec lines, 852 Command::new vs 42
  kill_on_drop, 468 unbounded/std channel lines, raw counts incl. tests).
- **Q21 invariant-class:** `crash_ratchet.py --classify` and `rust_panic_ratchet.py --classify` (task 205): every hit is
  input-reachable or invariant.
- **Q22 cef-shim-warnings:** the warning file written by `build-cef-shim.sh` (task 162).
- **Q23 lock-decls:** `git grep -n -E 'Mutex<|RwLock<' -- cmux-tui/crates/{acpmux,cmux-tui}/src` (207 + 181 lines).
- **Q24 regex / private-API:** `git grep -n -E 'NSRegularExpression\(|Regex\(|#/' -- 'Packages/**/Sources/**/*.swift'`
  (69); `git grep -n -E 'NSClassFromString|NSSelectorFromString|dlsym' -- 'Packages/**/Sources/**/*.swift'` (94).
- **Q25 state-writes:** `git grep -n 'fs::write(' -- 'cmux-tui/crates/*/src'` (production files) and `git grep -n -E
  'fn write_atomic'`.

### Q01 MessagesLab per-folder queue (task 038)

**Decision: complete checking is a flag of one diagnostics build, not a manifest setting.** The 4 CmuxMessagesLab
targets stay as they are (`.v5`, minimal checking) until 039 and 045 request `.v6` through the lander. CmuxNextHome
depends on MessagesLabHome and MessagesLabSidebar, so the app build compiles them, and `ci-macos.yml` runs
`scripts/swift_warning_budget.py` on that build log against an empty `.github/swift-warning-budget.tsv` (`Packages/` is an
owned root, and its `/vendor/` ignore is lowercase, so `Vendor/catalyst` counts). A manifest
`.enableUpcomingFeature("StrictConcurrency")` would add hundreds of warnings there (risk 6) and fail every PR after the
lander commit; regenerating the budget to hide them would be new debt. So 038 adds no `stability-settings.json` row.

`scripts/cmux-next/messageslab-queue.sh` (fleet only: `cmux-ci run --class isolated --ref SHA --script
scripts/cmux-next/messageslab-queue.sh -- --ref SHA`) runs swift-diagnostics.sh's clean build (036) of the package with
`-Xswiftc -strict-concurrency=complete --build-tests` and prints the table below. Counting rule: a row counts when it is an
error, is in a concurrency group (ActorIsolatedCall, ConformanceIsolation, IsolatedConformances, MutableGlobalVariable,
PreconcurrencyImport, SendableClosureCaptures, SendableMetatypes, SendingClosureRisksDataRace, SendingRisksDataRace,
NonisolatedNonsendingByDefault), or carries the compiler's "this is an error in the Swift 6 language mode" suffix (a
non-Sendable stored property of a Sendable type has no group). Deprecations, unused values and other warnings that stay
warnings in Swift 6 do not count; rows in dependency packages do not count. A Swift 6.3.3 run of the script with the real
036 parser on a `.v5` probe laid out like this package counted 7 of 9 rows (2 mutable globals, 2 sending closures, 1
conformance isolation, 1 Sendable stored property, 1 test-target global; not the deprecation or the unused value).
Tasks 039-044 use the same command for their "0 concurrency diagnostics" acceptance.

Source sizes at perf/chrome-parity f50dd944398 (all 247 target files; `Harness/` is in no target):

| Folder (under CmuxMessagesLab/) | Task | Files | Lines |
| --- | --- | ---: | ---: |
| Sources/MessagesLabHome/Vendor/catalyst/[A-L]* | 040 | 13 | 5,776 |
| Sources/MessagesLabHome/Vendor/catalyst/[M-Z]* | 041 | 22 | 13,072 |
| Sources/MessagesLabHome/Vendor/appkit-native | 042 | 11 | 5,163 |
| Sources/MessagesLabHome/Vendor/appkit-port | 042 | 3 | 892 |
| Sources/MessagesLabHome/Cmux/[A-L]* | 043 | 72 | 8,606 |
| Sources/MessagesLabHome/Cmux/[M-Z]* | 044 | 30 | 3,920 |
| Sources/MessagesLabSidebar | 039 | 12 | 4,657 |
| Tests/MessagesLabHomeTests | 045 | 81 | 10,834 |
| Tests/MessagesLabSidebarTests | 039 | 3 | 412 |

The concurrency diagnostic counts are not recorded yet (section 9: 038 is blocked). The script prints them with a
`(split)` mark on a folder over 400; such a folder is split again (risk 6) before its task starts.

## 7. Risks

1. **Per-merge coverage (decided).** Tip coverage + bisect, proved by `stability-lab.py coverage`. Building every merge
   would need ~10x fleet capacity and starve perf benches and dev builds. If Lawrence wants per-merge builds later, the
   lanes file already allows it.
2. **Fleet capacity.** Today only aws-m4pro-6 has VM images. Task 200 replicates images to the M6 minis (memory: cmux15-24
   minus 20 are ours) and one aws-m4pro host per major; enrolling a mini as a Tart host may need an operator (sudo) and
   agents never use the Keychain password. Check that `lend-worker.sh` is not part of the retired maclease flow before
   using it; if it is, report missing controller support instead.
3. **No CI gate drift.** The crash ratchet (fast gates) and the Rust panic ratchet (cmux-tui.yml) run in CI. Any new
   class, row or lint added to the files CI reads becomes a gate. Task 199 keeps all p10 additions in local-only rules and
   report-only baselines; the workspace clippy.toml is touched only by a commit that also brings every new hit to 0.
4. **Toolchain.** `.strictMemorySafety()` and `.treatWarning(_:as:)` need SwiftPM 6.2 on every fleet worker; Shared
   packages at tools 6.0 move to 6.2 through the lander. Task 037 checks this first. Only named groups become errors.
5. **Strict memory safety churn.** The fix-it pass touches many files that perf programs are rewriting. It lands one
   package per lander commit, generated by script (a conflict is resolved by rerunning the script on the new tip), and the
   error flip waits until hour ~62.
6. **MessagesLabHome** is 37k vendored lines in Swift 5 mode with background renderers; expect hundreds of diagnostics;
   tasks 040-044 may split again from the Q01 counts.
7. **Nightly Rust toolchains** for sanitizers, Miri and cargo-fuzz are pinned separately in `cmux-tui/sanitize/` and
   `cmux-tui/fuzz/` (rust-panic-free.md section 7 records this; the rest of the workspace stays on pinned stable). Linux
   runs miss `cfg(target_os = "macos")` code; macOS runs cover cmux-pty and cmux-holder.
8. **Sanitizer apps vs in-process Chromium.** CEF replaces the default malloc zone with PartitionAlloc and is not
   instrumented; ASan, libgmalloc, MallocScribble and MallocGuardEdges then cover nothing or report false bad-frees.
   Sanitizer and gmalloc runs keep Chromium unloaded (WebKit engine only, early zone registration skipped) and record the
   default zone after launch; a run where PartitionAlloc owns it is marked invalid. Chromium is covered by child-crash,
   process-chaos and the instrumented shim until F2 lands. TSan app runs are Chromium-off only.
9. **Mechanical panic removal** can turn crashes into silent wrong state. Classification (205) comes first; reviewers
   reject defaults on broken state; internal invariants use `INVARIANT:` expects, not invented error paths.
10. **Restart policies** can keep half-mutated shared state alive; Fatal is the default and poison escalates to Fatal.
11. **Lazy approximation (flagged):** Rust per-module counts, blocking-signal lines, pre_exec/Command/channel counts are
    regex counts that include inline `#[cfg(test)]` modules. The real queues come from Q10/Q11/Q20; folder splits in
    120-144 are an index only and the generator (210) rebalances them.
12. **Lazy approximation (flagged):** the Swift unreasoned-unchecked count (176) covers all Packages, including
    outside-closure modules; the closure ratchet row is 131. CmuxTerminalClient and CmuxSyncStore sites were removed from
    tasks 049, 060, 078, 082 and 095.
13. **Field targets depend on other programs.** "A Chromium crash never ends cmux" needs F2 (PL-cefhost, ~10 %); p10
    provides the harness (146), the GPU-loop guard (164) and the FFI boundary (152). #24913 (10 s makeKeyWindow on 14/15)
    needs fork API 30 from PL-cefhost. These are reported in a separate row of done checks 16 and 21.
14. **Hot-path cost.** HangWatchScope and CallbackRegistry sit on per-line and per-frame paths; both are designed
    syscall-free and lock-free, and benched before/after.
15. **iOS-only and outside-closure work** (CmuxMobileLinkFFI v5, NotificationService, CmuxTerminalClient FFI) is out of the
    72 h push except the cheap FFI guard (154).
16. **Sentry data** depends on telemetry consent and a small opt-in Nightly population; field numbers are noisy.
17. **Swarm conflicts** on shared files: baselines (rerun `--update-baseline`), Package.swift (lander), Cargo.lock (two
    tasks only), FFI pin (lander). Generated files are never hand-merged.
18. **VM timing is not perf evidence.** Hang thresholds in VMs are correctness signals; the 250 ms ping check runs on bare
    metal.

## 8. Decisions

Made by the program, not asked (each is also in sections 3 and 7):

1. **Per-merge coverage: tip coverage plus bisect.** The lab tests every new tip, and `stability-lab.py coverage`
   proves every landed commit is in a tip that passed the fast lanes; bisect assigns each finding to its merge. Building
   every merge needs about 10x the fleet and starves perf benches and dev builds. The lanes file allows per-merge builds
   later if Lawrence wants them.
2. **Invariant tiers** (Chrome's `CHECK` / `NotFatalUntil` / `DUMP_WILL_BE_CHECK`, `base/check.h`). Outside input never
   traps: it gets validation and a typed error to a boundary, never clamping or a silent default. An internal invariant
   uses `Invariant.check` (traps in every build, allowlisted with a reason), `Invariant.notFatalUntil(build: N)` (reports
   until build N, then traps) or `Invariant.dumpWillBeCheck` (reports forever, allowlisted with a written handler).
   Reports are one atomic dedupe on the caller's thread; the event goes to the background crash-reporting lane. Swift's
   checked subscript and checked Int conversion stay: Chrome bans unchecked access, not checked access, so the bans apply
   only on decode paths. In Rust, an internal invariant keeps `expect` / `unreachable!` only under
   `#[allow(clippy::expect_used, reason = "INVARIANT: <why it holds>")]` (section 3.E).
3. **Fatal-default supervision.** `supervise_thread` / `supervise_task` default to `Fatal`: a clean exit, the process
   supervisor restarts the process and the journal restores state. `Restart` (backoff 100 ms .. 30 s, at most 5/min) is
   only for workers with private state, each with a test that a restart rebuilds it. A panic that poisons a lock on
   shared state escalates to Fatal. Every call names a `ShutdownBehavior` (Chrome's `TaskShutdownBehavior`). This
   replaces the "restart the worker with backoff" default of crash-elimination.md section 6 and rust-panic-free.md
   section 5.
4. **`panic = "unwind"` stays** in the cmux-tui workspace (rust-panic-free.md section 5), unlike Chromium's
   `-Cpanic=abort`, because the out-of-process daemons use `catch_unwind` and `JoinError::is_panic` for per-request
   boundaries. The in-process FFI crates get `ffi_boundary` on every `extern "C" fn` (152), because a panic that reaches
   `extern "C"` aborts the app.
5. **Strict memory safety in Chrome's order** (`docs/unsafe_buffers.md`): on for every target at once, old sites marked
   `SAFETY-TODO(p10)` by machine, the marks are the queue, external-input modules first; the error flip lands at about
   hour 62 after a diagnostics run at that tip shows 0.
6. **No CI gates.** New ratchet classes live in the local-only tier and in report-only baselines CI never reads (199).
   CI-read baselines only go down.
7. **Sanitizer apps run with Chromium off** until F2 (the CEF browser process in a helper app) lands, because CEF's
   PartitionAlloc owns the default malloc zone and is not instrumented (risk 8).
8. **Nightly Rust toolchains** only in `cmux-tui/sanitize/` and `cmux-tui/fuzz/`, pinned there; everything else stays on
   the pinned stable toolchain (risk 7).

Dropped: concurrency warning groups as errors (Q05, post-push on one pinned toolchain), and CmuxMobileLinkFFI and
NotificationService to Swift 6 (outside the mac closure, post-push).

## 9. Tasks and status

The tasks 001-211 (080 and 149 dropped) and their dependencies are in the spec's task table and in
`chrome-parity/design-result.json`; `chrome-parity/WORK.tsv` lists them with their files. Run order: H0-12 lab core and
shared APIs, H12-60 all queues in parallel with the lab running, H60-66 error flips, H66-72 test phase and
`stability-final.sh` (151), which prints the done checks of section 5.

Status:

- **038 blocked.** The command and counting rule are in section 6 (Q01 MessagesLab per-folder queue), but the
  per-folder counts are not recorded. Two things block it: 036 (`swift_diagnostics.py`) is not on perf/chrome-parity,
  and nobody has run `messageslab-queue.sh` on the fleet at a commit that has 036. Tasks 039-044 do not start until the
  counts table is filled in.
