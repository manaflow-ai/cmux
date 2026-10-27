# p10-stability: crash search, sanitizers, compile-time safety, traps to zero, Rust daemon discipline

Program owner: PL-stability (new OWNERS.md row, task 001). Checkout counts are from
/Users/lawrence/fun/wt/chrome-parity at 772cdfc45ac (feat-cmux-next, 2026-10-25), taken with `git grep`, the JSON baselines and
the plan docs. This spec is the design after three adversarial reviews; section 8 "Review disposition" records what each
review changed, what was confirmed in the code, and what was dropped and why.

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

Every part reports only. Nothing in p10 adds a GitHub CI job, step, gate, budget or blocking baseline row
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
  invariant keeps `expect`/`unreachable!` only as `#[expect(clippy::expect_used, reason = "INVARIANT: <why it holds>")]`
  on the smallest item; a tracked count reports these. Extra-workspace rows live in a report-only baseline CI does not
  read.
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
- H36 and H58: app-ffi pin republishes (153).
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
   (153), which batches sources and republishes CCmuxAppFFI in the same PR.
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
9. FFI: for cmux-app-ffi, cmux-rd-ffi, cmux-layout-reducer-ffi and cmux-palette-ranker, the Q18 test
   `every_export_is_guarded` passes, so every `extern "C" fn` body runs in `ffi_boundary(` or carries `ffi-nopanic:`
   (today 102 exports, 40 catch_unwind lines); the CCmuxAppFFI pin's source sha contains tasks 152 and 156;
   `check-app-ffi-pin.sh` passes.
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
  `scripts/cmux-next/swift-diagnostics.sh --package Packages/Shared/CmuxMessagesLab --summary` (fleet:
  `cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh`).
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
- **Q18 ffi-exports:** the exports that `cmux_ffi_guard::testing::unguarded_exports` reports. It reads each
  `extern "C" fn` body, not a fixed line window (rustfmt puts long parameter lists before the body), and the
  `every_export_is_guarded` test of each crate fails on any hit. Run `cargo test every_export_is_guarded` with
  `--manifest-path cmux-tui/crates/cmux-app-ffi/Cargo.toml`, `.../cmux-rd-ffi/Cargo.toml` and
  `.../cmux-layout-reducer-ffi/Cargo.toml` (separate workspaces), and `cargo test -p cmux-palette-ranker
  every_export_is_guarded` in `cmux-tui`. Q18 = 0 when the four tests pass. Do not compare counts of `ffi_boundary(`
  and `extern "C" fn`: a recovery call inside a guarded body is also an `ffi_boundary(` (102 exports before 152).
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
   `cmux-tui/fuzz/` (rust-panic-free.md section 7 says pinned stable; this changes that for those two folders only). Linux
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

## 8. Task table

Size: S <= 150 changed lines, M <= 400, L > 400 (split before start). Each behavior change commits its failing test
first (CLAUDE.md). All IDs are `p10-stability-NNN`.

### Summary

| ID | Title | Size | Depends on | Queue |
| --- | --- | --- | --- | --- |
| 001 | Program doc stability-DESIGN.md + OWNERS row | S | - | - |
| 002 | crash_signature.py (ignore list, top 3 frames) | M | - | - |
| 003 | stability-lab.py runner + lanes registry | L | 002 | - |
| 004 | stability_issues.py one issue per signature | M | 002 | Q16 |
| 005 | stability_bisect.py | L | 002, 003 | - |
| 006 | hq stability cron (dedicated hosts) | M | 003 | - |
| 007 | Coverage map per landed commit | S | 003 | - |
| 008 | VM fuzz schema-driven args + action coverage | M | - | - |
| 009 | vm.sh --suite chaos (per-fault outcomes) | L | - | - |
| 010 | vm.sh --diag variants (Chromium off) | M | 012 | - |
| 011 | macOS 27 guests | M | - | - |
| 012 | Sanitizer app configs (Release, Chromium off) | M | - | - |
| 013 | sanitizer-sweep.sh (base-red pre-pass) | M | 002 | Q15 |
| 014 | Rust sanitizers + Miri lane | M | 002 | Q15 |
| 015 | readiness-soak sanitizer apps | S | 012 | - |
| 016 | CmuxFuzzSupport | M | - | Q14 |
| 017 | cmux-tui/fuzz + first 6 targets (rss/timeout limits) | L | - | Q14 |
| 018 | Rust fuzz batch 2 (rd-proto, transport, link, wg) | M | 017 | Q14 |
| 019 | Rust fuzz batch 3 (acpmux) | M | 017 | Q14 |
| 020 | Rust fuzz batch 4 (host codec, journal, output store) | M | 017 | Q14 |
| 021 | Rust fuzz batch 5 (input, config, pairing) | M | 017 | Q14 |
| 022 | Swift fuzz Daemon wire | M | 016 | Q14 |
| 023 | Swift fuzz VNC + ScreenKit | M | 016 | Q14 |
| 024 | Swift fuzz RemoteView + Android stream | M | 016 | Q14 |
| 025 | Swift fuzz browser/cookie import | M | 016 | Q14 |
| 026 | Swift fuzz settings + keybindings | M | 016 | Q14 |
| 027 | Swift fuzz Mobile host + device hub | M | 016 | Q14 |
| 028 | Swift fuzz Home render (time budget) | M | 016 | Q14 |
| 029 | Swift fuzz crash/hang report parsers | S | 016 | Q14 |
| 030 | Swift fuzz diff, paths, terminal links | S | 016 | Q14 |
| 031 | HangWatchScope (atomic, CmuxNextWakeups) | L | 207 | - |
| 032 | Rust watch_scope + hung-thread stacks | L | - | - |
| 033 | tokio slow-poll detector (lab) | M | 101 | - |
| 034 | stability-health.py | M | - | Q17 |
| 035 | Sentry signatures to issues | S | 004, 034 | Q17 |
| 036 | swift-diagnostics.sh (clean scratch, fix-its) | M | - | Q04 |
| 037 | stabilitySwiftSettings + toolchain check + target guardrail | S | 036 | Q01 |
| 038 | MessagesLab complete checking as warnings | S | 036, 198 | Q01 |
| 039 | MessagesLabSidebar to Swift 6 | M | 038 | Q01 |
| 040 | MessagesLabHome catalyst A-L | M | 038 | Q01 |
| 041 | MessagesLabHome catalyst M-Z | M | 038 | Q01 |
| 042 | MessagesLabHome appkit-native + appkit-port | M | 038 | Q01 |
| 043 | MessagesLabHome Cmux/ A-L | M | 038 | Q01 |
| 044 | MessagesLabHome Cmux/ M-Z | M | 038 | Q01 |
| 045 | Flip MessagesLabHome to Swift 6 | S | 039-044 | Q01 |
| 046 | One Sparkle seam | M | - | Q03 |
| 047 | Remaining @preconcurrency | S | 046 | Q03 |
| 048 | Unchecked: CmuxIrxTransport | M | 172 | Q02 |
| 049 | Unchecked: CmuxIrohTransport | S | 172 | Q02 |
| 050 | Unchecked: MobileCore, MobileRPC, Tunnel, Support | M | 172 | Q02 |
| 051 | Unchecked: MobileSSH, MobileShellModel | M | 172 | Q02 |
| 052 | Unchecked: CmuxNextTerminal | M | - | Q02 |
| 053 | Unchecked: CmuxNextDictation | S | - | Q02 |
| 054 | Unchecked: HomeRender, HomeCore, MessagesLabSidebar | S | 039, 172 | Q02 |
| 055 | Unchecked: MessagesLabHome | M | 045, 172 | Q02 |
| 056 | Unchecked: RemoteView + Tabs | S | - | Q02 |
| 057 | Unchecked: ServerHelper | S | - | Q02 |
| 058 | Unchecked: Browser, BrowserAutomation, BrowserImport | S | - | Q02 |
| 059 | Unchecked: Daemon + Control | S | - | Q02 |
| 060 | Unchecked: AuthCore, AuthRuntime, Updater | S | 172 | Q02 |
| 061 | Unchecked: CmuxNext singles | M | - | Q02 |
| 062 | Reasoned unchecked: VNCWebRTC, CrashReporting | M | 172 | Q02 |
| 063 | SAFETY-TODO: Daemon, Control, Mobile | M | 211 | Q04 |
| 064 | SAFETY-TODO: Iroh + Irx | M | 211 | Q04 |
| 065 | SAFETY-TODO: VNC + VNCWebRTC + ScreenKit | M | 211 | Q04 |
| 066 | SAFETY-TODO: RemoteView | M | 211 | Q04 |
| 067 | SAFETY-TODO: Browser CEF/ | M | 211 | Q04 |
| 068 | SAFETY-TODO: Browser rest | M | 067 | Q04 |
| 069 | SAFETY-TODO: Terminal | M | 211 | Q04 |
| 070 | SAFETY-TODO: BrowserImport | M | 211 | Q04 |
| 071 | SAFETY-TODO: Phone | M | 211 | Q04 |
| 072 | SAFETY-TODO: App | M | 211 | Q04 |
| 073 | SAFETY-TODO: MessagesLab | M | 211, 045 | Q04 |
| 074 | SAFETY-TODO: Design, Focus, Sidebar | M | 211 | Q04 |
| 075 | SAFETY-TODO: AgentPane + Compat | M | 211 | Q04 |
| 076 | SAFETY-TODO: CrashReporting + HangReports | S | 211 | Q04 |
| 077 | SAFETY-TODO: Files, RemoteFetch, Dictation, Palette | M | 211 | Q04 |
| 078 | SAFETY-TODO: MobileCore, MobileSSH, CuaHelperCore | M | 211 | Q04 |
| 079 | StrictMemorySafety as error (final flip) | S | 063-078, 211 | Q04 |
| 081 | CallbackRegistry + wave 1 | M | 083, 172 | Q08 |
| 082 | CallbackRegistry wave 2 (CEF, Ghostty, misc) | M | 081 | Q08 |
| 083 | CmuxSafeConcurrency: OnceContinuation | M | 172 | Q06 |
| 084 | Continuations: App | M | 083 | Q06 |
| 085 | Continuations: AgentPane + Pages | M | 083 | Q06 |
| 086 | Continuations: Iroh + Irx | M | 083 | Q06 |
| 087 | Continuations: Daemon, Control, Mobile, RemoteLocalhost | M | 083 | Q06 |
| 088 | Continuations: Browser, Automation, Wakeups, HomeEngine, HomeCore | M | 083 | Q06 |
| 089 | Continuations: rest + local ban | M | 084-088, 171 | Q06 |
| 090 | unowned part 1 (weak+report or lifetime reason) | M | 099 | Q07 |
| 091 | unowned part 2 | M | 090 | Q07 |
| 092 | crash_ratchet --report, trap_api, all-modules scan | M | 199 | Q09 |
| 093 | Decode-path index/int wave 1 | M | 092, 205 | Q09 |
| 094 | Decode-path index/int wave 2 | M | 092, 205 | Q09 |
| 095 | Decode-path index/int wave 3 | M | 092, 205 | Q09 |
| 096 | uniqueKeysWithValues | M | 092 | Q09 |
| 097 | removeFirst/removeLast CmuxNext | M | 092, 205 | Q09 |
| 098 | trap_api Shared/iOS + local ban | M | 097 | Q09 |
| 099 | Invariant API (check / notFatalUntil / dumpWillBeCheck) | M | 083 | - |
| 100 | async-blocking-scan (syn, fleet) | L | - | Q11, Q12, Q20 |
| 101 | cmux-blocking + lock-slot commit | M | - | Q11 |
| 102 | Pre-push ast-grep Rust rules | S | 199 | Q11, Q12 |
| 103 | Supervisor (Fatal default, ShutdownBehavior) | M | 101 | Q12 |
| 104 | acpmux blocking: hub/ | M | 100, 101, 206 | Q11 |
| 105 | acpmux blocking: server, claude_stdio, agent_host, store, mailbox | M | 100, 101, 206 | Q11 |
| 106 | acpmux blocking: rest | M | 104, 105 | Q11 |
| 107 | cmux-remote blocking | M | 100, 101, 206 | Q11 |
| 108 | chatmux-relay blocking | M | 100, 101, 206 | Q11 |
| 109 | cmux-tui blocking | M | 100, 101, 206 | Q11 |
| 110 | Small tokio crates blocking | S | 100, 101, 206 | Q11 |
| 111 | Supervise acpmux tasks | M | 100, 103 | Q12 |
| 112 | Supervise cmux-tui-core threads | M | 100, 103 | Q12 |
| 113 | Supervise cmux-tui, remote, relay, small crates | M | 100, 103 | Q12 |
| 114 | Report-only tracked lints + lab clippy conf | S | 199 | Q13 |
| 115 | SAFETY: cmux-tui-core | M | 114 | Q13 |
| 116 | SAFETY: cmux-tui | M | 114 | Q13 |
| 117 | SAFETY: acpmux + ghostty-vt | M | 114 | Q13 |
| 118 | SAFETY: holder, pty, rest | M | 114 | Q13 |
| 119 | loom model of the holder ring (own workspace) | M | - | - |
| 120 | Panic deny: resource_router/topology.rs | M | 205, 210 | Q10 |
| 121 | Panic deny: resource_router/ rest | M | 120 | Q10 |
| 122 | Panic deny: mux/ a-k | M | 205, 210 | Q10 |
| 123 | Panic deny: mux/ l-r | M | 205, 210 | Q10 |
| 124 | Panic deny: mux/ s-z + subfolders | M | 205, 210 | Q10 |
| 125 | Panic deny: surface/ | M | 205, 210 | Q10 |
| 126 | Panic deny: journal_* + workspace_registry/ | M | 205, 210 | Q10 |
| 127 | Panic deny: browser/, apps/, server/, state/ | M | 205, 210 | Q10 |
| 128 | Panic deny: cmux-tui-core rest | M | 120-127 | Q10 |
| 129 | Panic deny: cmux-tui remote_runtime + remote_cli | M | 205, 210 | Q10 |
| 130 | Panic deny: cmux-tui machine_* | M | 205, 210 | Q10 |
| 131 | Panic deny: cmux-tui ui/, app/, cli/ | M | 205, 210 | Q10 |
| 132 | Panic deny: cmux-tui rest | M | 129-131 | Q10 |
| 133 | Panic deny: acpmux hub/ part 1 | M | 205, 210 | Q10 |
| 134 | Panic deny: acpmux hub/ part 2 + server etc. | M | 205, 210 | Q10 |
| 135 | Panic deny: acpmux rest | M | 133, 134 | Q10 |
| 136 | Panic deny: cmux-browser-host | M | 205, 210 | Q10 |
| 137 | Panic deny: cmux-remote | M | 205, 210 | Q10 |
| 138 | Panic deny: chatmux-relay | M | 205, 210 | Q10 |
| 139 | Panic deny: ghostty-vt | M | 205, 210 | Q10 |
| 140 | Panic deny: layout-reducer + palette-ranker (pin lander) | M | 205, 210, 153 | Q10 |
| 141 | Panic deny: cloud-conversations, terminal-client, config | M | 205, 210 | Q10 |
| 142 | Panic deny: server, chat-index, tasks-core | M | 205, 210 | Q10 |
| 143 | Panic deny: rd-core, api-compat, theme-tokens, mux2 | M | 205, 210 | Q10 |
| 144 | Panic deny: remaining small crates | L | 205, 210 | Q10 |
| 145 | process-chaos-e2e.py (per-fault outcomes) | M | - | - |
| 146 | Chromium host kind in child-crash-e2e | S | - | - |
| 147 | Leak check at quit in the smoke | S | - | - |
| 148 | Swift Mutex lock ranks in Debug | M | 172 | - |
| 150 | acpmux + holder panics and hangs reach Sentry | S | 032 | - |
| 151 | stability-final.sh | S | 003, 034 | - |
| 152 | In-app Rust FFI boundary (ffi_boundary) + dSYM | M | - | Q18 |
| 153 | FFI pin lander (scheduled republishes) | S | 152 | - |
| 154 | cmux-terminal-client FFI guard (iOS) | S | 152 | Q18 |
| 155 | Panic ratchet for separate shipped workspaces (report-only) | M | 199 | Q10 |
| 156 | Panic deny: rd-ffi, layout-reducer-ffi, rd-host, remote-browser-host | M | 155, 152, 153 | Q10 |
| 157 | Panic deny: optchat-chief + chief-turn | L | 155 | Q10 |
| 158 | OptChat threads supervised + SAFETY | M | 157, 103 | Q12, Q13 |
| 159 | DiffSidecar panic deny + fuzz target | M | 155, 017 | Q10, Q14 |
| 160 | cmux-mobile-host panic deny + supervised spawns | L | 155, 100, 103 | Q10, Q12 |
| 161 | forbid(unsafe_code) in 39 crates | S | - | - |
| 162 | CEF shim hardening + sanitizer variant | M | 012 | Q22 |
| 163 | CEF shim unsafe-buffer queue to 0 | M | 162 | Q22 |
| 164 | GPU crash loop must not FATAL cmux | M | 145 | - |
| 165 | GhosttyKit ReleaseSafe lab variant | S | 012 | - |
| 166 | objc_raises class (report-only) + checked helpers | M | 092 | Q19 |
| 167 | objc_raises: JSONSerialization | M | 166 | Q19 |
| 168 | objc_raises: legacy FileHandle | S | 166 | Q19 |
| 169 | objc_raises: NSRange in MessagesLabHome | M | 166 | Q19 |
| 170 | objc_raises: NSRange in App, Design, AgentPane, ErrorJournal, rest | M | 166 | Q19 |
| 171 | Delete private resume-once helpers | M | 083 | Q06 |
| 172 | Portable Mutex in CmuxSafeConcurrency | S | - | - |
| 173 | write_important (ImportantFileWriter) | M | - | Q25 |
| 174 | State-corruption chaos lane | M | 003 | - |
| 175 | SQLite error policy | M | - | - |
| 176 | Stateful daemon request fuzzer | L | 017 | Q14 |
| 177 | Stateful ControlRouter fuzz | M | 016 | Q14 |
| 178 | BadMessage API | M | - | - |
| 179 | Swift fuzz AgentPane stream + page bridge | M | 016 | Q14 |
| 180 | Swift fuzz CEF/CDP, appcast, cloud, auth | M | 016 | Q14 |
| 181 | Rust fuzz batch 6 (browser-host, app-host, mobile-host, optchat) | M | 017 | Q14 |
| 182 | Coverage-guided Swift libFuzzer (Linux) | M | 016 | Q14 |
| 183 | Fuzz corpus store, minimize, coverage report | M | 017, 003 | Q14 |
| 184 | Fork safety: pre_exec | M | 100 | Q20 |
| 185 | Child reaping | M | 100 | Q20 |
| 186 | Bounded queues | M | 100 | Q20 |
| 187 | cmux-lock-rank shared crate | M | - | Q23 |
| 188 | Lock ranks: acpmux | M | 187 | Q23 |
| 189 | Lock ranks: cmux-tui | M | 187 | Q23 |
| 190 | unsafe impl Send/Sync review | M | 014 | - |
| 191 | Regex input bounds (ReDoS) | M | 016 | Q24 |
| 192 | Geometry re-entrancy guard | M | - | - |
| 193 | Private API lookups probed per macOS | M | 011 | Q24 |
| 194 | Webview page error boundary | M | - | - |
| 195 | Lab signatures for non-crash failures | S | 002, 003 | Q16 |
| 196 | Lab lanes: update, skew, restore | S | 003 | - |
| 197 | Checked arithmetic in wire decoders | L | 017 | Q10 |
| 198 | Package.swift settings lander | S | 037 | - |
| 199 | Local-only rule tier + report-only baselines | S | - | - |
| 200 | Tart image replication + dedicated lab hosts | M | 011 | - |
| 201 | MallocProbGuard sampling (GWP-ASan analog) | S | 010 | - |
| 202 | nightly-assert variant (DCHECK canary) | M | 099 | - |
| 203 | Unclean-exit metric | S | 034 | Q17 |
| 204 | ShutdownBehavior + quit-storm lane | M | 103, 009 | - |
| 205 | Classify trap/panic sites: input vs invariant | M | 092, 099 | Q21 |
| 206 | Lab clippy disallowed-methods config | S | 101, 114 | Q11 |
| 207 | Crash keys (Swift + Rust) | M | - | - |
| 208 | Rule of 2: inventory + sandboxed browser import | L | - | - |
| 209 | macOS Q10 clippy run + merge | S | - | Q10 |
| 210 | Rust panic queue generator | S | 209 | Q10 |
| 211 | strictMemorySafety on everywhere + SAFETY-TODO fix-its | L | 036, 037, 198 | Q04 |

### Review disposition (fixer)

Confirmed in the code (commands run against 772cdfc45ac):
- CEFMessagePump runs on main (file line 6): **031 loses its CEF scope**; the pump gets a main-watchdog phase label.
- CmuxNextDaemon/Terminal/Control all depend on CmuxNextWakeups, and Control depends on Daemon: **HangWatchScope moves to
  CmuxNextWakeups** (review 1).
- Shared packages deploy to macOS 14 / iOS 17; CmuxNextCompat.Mutex is CmuxNext-only; CMUXMobileCore has its own portable
  lock: **new 172 portable Mutex** (reviews 1+2), 048-062, 081, 083 depend on it.
- CmuxTerminalClient and CmuxSyncStore are not in the mac closure: **removed from 049, 060, 078, 082, 095** (review 1).
  Review 2's claim that cmux-terminal-client is in-process for the Mac app is wrong; it is iOS only -> separate S task 154.
- motion.rs 17 exports / 0 catch_unwind; rd-ffi 61/28; layout-reducer-ffi 19/9; palette-ranker 5/3; app-ffi release
  `debug = false`: **new 152**. `check-app-ffi-pin.sh` fails CI on FFI source drift: **new 153 pin lander**, and 140/156
  route through it (found by the fixer, not in the reviews).
- cmux-holder/process/flow-trace/kitty-media are workspace members and the ratchet already forces them to 0 in production
  (review 1's 34 holder hits are test lines): **review 1's holder/process task dropped**; uncovered are the separate
  workspaces (app-ffi, rd-ffi, layout-reducer-ffi, rd-host, remote-browser-host/-testhost, Native/*, cmux-next-ios/rust):
  **155, 156, 157-160**.
- Crash ratchet runs in CI fast gates; Rust panic ratchet runs in cmux-tui.yml; guardrails never run in CI; prepush-gate
  `--commits` runs in CI: **new 199** (report-only baselines, local-only rules); 114 no longer makes growth fail in CI;
  206 uses a lab-only `CLIPPY_CONF_DIR`, not the workspace clippy.toml (review 3's 164 would have turned
  `clippy -D warnings` red).
- 12 private resume-once types: **171**. 160 JSONSerialization sites, 23 FileHandle lines: **166-170**.
- 39 unsafe-free crates: **161**. 54 pre_exec, 852 Command::new vs 42 kill_on_drop, 468 channel lines: **184-186**.
- 20 new_current_thread vs 9 new_multi_thread: **101 adds block_in_place compensation and the current_thread path**.
- 0 `unowned(unsafe)`, 97 safe unowned: **090/091 rewritten** (review 3).
- 24 page entries with createRoot, only agent-session has boundaries: **194**.
- os-matrix.sh is in scripts/cmux-next: paths corrected in 008-011 and the done checks.

Problems fixed by changing existing tasks: 002 (ignore list, top 3), 009 (per-fault outcomes), 010/012/015 (Release
sanitizer config, Chromium off, malloc-zone check), 013 (base-red pre-pass), 017 (rss/malloc/timeout limits), 031/032
(atomic scopes, no syscall, hung-thread stacks, jank vs hang tiers), 036 (clean scratch / .dia), 063-079 (Chrome order via
211, error flip late), 081/082 (one registry in CmuxSafeConcurrency, lock-free hot path, CEF keeps refcount), 083 (no
cancel by default), 093-098 (decode paths only, validation not clamping), 099 (three tiers, off-main sink), 101 (no new
debug panics, compensation, lock slot up front), 102 (ast-grep, not a cargo build on the Mac), 103 (Fatal default, poison
escalates, ShutdownBehavior via 204), 119 (own workspace), 120-144 (generated from Q10 JSON by 210, INVARIANT expects),
risk 0 (decided: tip coverage + bisect).

Dropped, with reasons:
- **080** concurrency groups as errors: every closure target except MessagesLab is already Swift 6 mode, where data-race
  diagnostics are errors; the leftover groups differ between the two fleet Xcode versions and an error there turns the base
  red on a toolchain change. Post-push, on one pinned toolchain (Q05).
- **149** CmuxMobileLinkFFI and NotificationService to Swift 6: outside the mac closure and every target; changes the iOS
  release project. Post-push.
- Review 1's "panic deny cmux-holder/cmux-process": already 0 in production by the existing ratchet.
- Review 2's "limit strict memory safety to external-input modules as warnings": replaced by Chrome's order (211: on
  everywhere, old sites marked) with the error flip at hour ~62; external-input modules are still first and mandatory in
  done check 4.

### Task details

#### p10-stability-001 Program doc: stability-DESIGN.md
- Files: plans/cmux-next/stability-DESIGN.md, plans/cmux-next/crash-elimination.md, plans/cmux-next/rust-panic-free.md,
  plans/cmux-next/OWNERS.md
- Change: The design doc from this spec (Chrome references, counts, lanes, queues Q01-Q25, done checks, decisions incl.
  tip coverage + bisect, Invariant tiers, Fatal-default supervision). Link it from crash-elimination.md phase 3 and
  rust-panic-free.md section 7 (and correct section 5's claim that FFI edges already catch_unwind; note the nightly pin in
  sanitize/ and fuzz/). Add an OWNERS.md row PL-stability.
- Acceptance: Every queue command is verbatim; every done check has a number; both plans link to it; OWNERS row exists.
- Test phase: none (docs).

#### p10-stability-002 crash_signature.py
- Files: scripts/cmux-next/crash_signature.py, scripts/cmux-next/signature-ignore.txt,
  scripts/cmux-next/tests/test_crash_signature.py, scripts/cmux-next/tests/fixtures/signature/
- Change: Parse .ips JSON (crashed thread, usedImages UUID), Rust panic-log JSONL, ASan/TSan/UBSan/LSan text, hang samples
  into {kind, process, exception, frames[3], hash12}. Drop frames matching signature-ignore.txt (Swift runtime
  `_assertionFailure`, `swift_unexpectedError`, `swift_task_*`; libsystem `__pthread_kill`, `abort`; libdispatch; Rust
  `core::panicking`, `std::rt`, `std::panicking`; CEF/PartitionAlloc CHECK helpers; sanitizer runtime). Normalize offsets,
  generic arguments, closure numbers; unsymbolicated cmux addresses bucket by image+offset.
- Acceptance: Fixtures: .ips trap, NSException, Rust panic, TSan race, ASan UAF, hang. Same bug from two builds with
  different inlining -> same hash; two different force-unwrap traps -> different hashes.
- Test phase: `python3 -I -m pytest scripts/cmux-next/tests/test_crash_signature.py` (laptop OK, no build).

#### p10-stability-003 stability-lab.py runner and lanes registry
- Files: scripts/cmux-next/stability-lab.py, scripts/cmux-next/stability-lanes.json,
  scripts/cmux-next/tests/test_stability_lab.py
- Change: Subcommands plan (newest tip with a fleet build, lanes due), run-lane (submits the cmux-ci step: smoke/fuzz/chaos
  via scripts/cmux-next/os-matrix.sh, sanitizer-swift, sanitizer-rust, rust-fuzz, swift-fuzz-long, crash-e2e,
  action-sweep, soak, diagnostics, clippy-queue), collect (artifacts -> signatures) and report. State in a JSON artifact.
  Lanes declare host class (dedicated lab host vs preemptible), minutes, priority (lowest) and `never_with: bench`.
- Acceptance: run-lane only shells out to cmux-ci and os-matrix.sh; no GitHub workflow change; a wait timeout waits again,
  never resubmits.
- Test phase: pytest with cmux-ci faked; one live tick `stability-lab.py plan && stability-lab.py run-lane smoke`.

#### p10-stability-004 stability_issues.py
- Files: scripts/cmux-next/stability_issues.py, scripts/cmux-next/tests/test_stability_issues.py
- Change: One issue per hash12 (labels stability-sig, stability-sig:<hash12>, kind); body has first/last SHA, count per major,
  repro (minimal.jsonl, seed, test id, fuzz input), bisect result. Close after fix_verified + 3 clean tips; reopen on
  recurrence. gh through glaeda-gh read rules, no polling loops.
- Acceptance: Idempotent (same signature twice -> one issue, count 2); closing needs fix_verified + 3 clean tips.
- Test phase: pytest with gh faked.

#### p10-stability-005 stability_bisect.py
- Files: scripts/cmux-next/stability_bisect.py, scripts/cmux-next/tests/test_stability_bisect.py
- Change: Binary search over first-parent feat-cmux-next commits between good/bad; reuse a published build or `cmux-ci build
  cmux --ref`; replay (vm.sh --replay, test id, fuzz input) N=3; post the first bad commit to the issue.
- Acceptance: Never resubmits after a wait timeout; 1-2 of 3 repro = flaky, not blamed.
- Test phase: pytest with fake builds; one real bisect of 90b3fd18b69..29804bacb09^ (Crash D) on macOS 26.
- Deferred: the fuzz-input replay. No allowlisted fleet step script runs `cargo fuzz` (hq controller
  `ciStepScripts`), and the fuzz workspace (cmux-tui/fuzz, task 017) is not on the branch, so no commit has a
  target to replay. Add `fuzz-input:CRATE_DIR:TARGET:INPUT` after 017 lands and the controller allows its
  single-input script. Until then, replay such a finding as a regression test (`test:PACKAGE:FILTER`). The bisect
  lays that test from the runner ref over each older commit.

#### p10-stability-006 hq stability cron
- Files: cmuxterm-hq: build-fleet/cmd/controller/stability_cron.go, stability_cron_test.go
- Change: Like perf_cron.go. On each new tip with a DEV build, queue fast lanes at background priority; long lanes only on
  hosts tagged `stability-lab` (task 200); never place a lab step on a host running or reserved for a bench-class step
  (cmux20); preempt fast lanes for foreground work.
- Acceptance: Lab jobs never preempt build/dev jobs; label stability-lab; off unless CMUX_CI_STABILITY_CRON=1.
- Test phase: `go test ./build-fleet/cmd/controller/...` in hq.

#### p10-stability-007 Coverage map
- Files: scripts/cmux-next/stability-lab.py
- Change: `coverage --since 72h`: first-parent commits, the lab tips containing them, lanes passed/failed.
- Acceptance: JSON + table; covered only when a later tip passed all fast lanes.
- Test phase: pytest fixture of a 10-commit range.

#### p10-stability-008 VM fuzz schema-driven args and action coverage
- Files: scripts/fuzz/macos-matrix/fuzz.py
- Change: Argument generators from `cmux action list --json` (enum, range edges, huge strings, wrong types, live and bogus
  ids); round-robin every non-excluded action once, then seeded random walk; per-action outcomes in summary.json.
- Acceptance: Same seed + build -> same steps; summary.json actions_covered == eligible count.
- Test phase: `scripts/cmux-next/os-matrix.sh --build JOB --os 26 --suite fuzz --seed 7 --minutes 20`.

#### p10-stability-009 vm.sh --suite chaos
- Files: scripts/fuzz/macos-matrix/vm.sh, scripts/fuzz/macos-matrix/chaos.py, scripts/fuzz/macos-matrix/MATRIX.md
- Change: During a typing + split tour, faults: SIGKILL daemon, acpmux, a terminal host, holder, Chromium renderer/GPU/
  utility, WebContent; `memory_pressure -S -l critical`; `ulimit -n 256` relaunch; full HOME disk (small sparse image);
  network off. Each fault has its own expected outcome: daemon/acpmux/terminal host -> app answers, terminals restored;
  holder -> app up, its panes show the ended state with the restart action, other holders untouched; renderer/GPU -> crash
  page then reload; all -> no cmux .ips.
- Acceptance: One result.json row per fault with expected and ok/FAIL; never pulls images.
- Test phase: `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15,26 --suite chaos`.

#### p10-stability-010 vm.sh --diag variants
- Files: scripts/fuzz/macos-matrix/vm.sh, scripts/fuzz/macos-matrix/fuzz.py, scripts/fuzz/macos-matrix/MATRIX.md
- Change: `--diag gmalloc` (DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib), `scribble` (MallocScribble=1
  MallocGuardEdges=1), `mtc` (host Xcode's libMainThreadChecker.dylib injected), `asan|tsan|ubsan` (sanitizer app),
  `coop-strict` (LIBDISPATCH_COOPERATIVE_POOL_STRICT=1), `probguard` (MallocProbGuard=1). Malloc and sanitizer diags launch
  with Chromium off (browser engine WebKit, early zone registration skipped) and record the default malloc zone after
  launch (malloc_get_all_zones); a run where PartitionAlloc owns it is invalid. Re-sign ad hoc as FUZZ_DYLIB does.
- Acceptance: Each diag records env, Chromium state and default zone in summary.json; MTC violations and sanitizer reports
  are collected.
- Test phase: `os-matrix.sh --build JOB --os 26 --suite fuzz --minutes 15` once per diag.

#### p10-stability-011 macOS 27 guests
- Files: scripts/fuzz/macos-matrix/images.json, scripts/fuzz/macos-matrix/MATRIX.md, cmuxterm-hq: build-fleet controller
  matrixMajors
- Change: Cache the 27 golden image on one aws-m4pro-1..4 worker; add 27 to matrixMajors; document 2 VMs per host with one
  keychain unlock per VM lifetime.
- Acceptance: `scripts/cmux-next/os-matrix.sh --os 27` reaches a verdict.
- Test phase: `os-matrix.sh --build JOB --os 27` smoke PASS.

#### p10-stability-012 Sanitizer app configs
- Files: scripts/reload.sh, cmuxterm-hq: build-fleet build cmux --config
- Change: `--config asan|tsan|ubsan` builds the **Release** configuration with -sanitize=address/thread/undefined, symbols
  kept, runtime embedded (runs in a VM without Xcode), bundle id suffix .asan/.tsan/.ubsan, default launch with Chromium off
  and early malloc zone registration skipped. Release, nightly and RC scripts refuse these configs (like bench hooks).
- Acceptance: Config list debug|release|bench|asan|tsan|ubsan; shipped scripts reject the sanitizer configs.
- Test phase: `cmux-ci build cmux --ref SHA --config asan --tag p10-asan-v1`; VM `--diag asan` smoke passes.

#### p10-stability-013 sanitizer-sweep.sh
- Files: scripts/cmux-next/sanitizer-sweep.sh, scripts/cmux-next/tsan-suppressions.txt,
  scripts/cmux-next/README-sanitizers.md
- Change: Enumerate test targets of CmuxNext and the closure packages; first run once with no sanitizer and record suites
  red at the base (e.g. CmuxNextAppTests signal 11); then run package-test-lane.sh per mode (CMUX_SWIFT_SANITIZE, coop-strict
  = LIBDISPATCH_COOPERATIVE_POOL_STRICT=1). Only reports of kind tsan/asan/ubsan from crash_signature.py count;
  base-red suites go to a separate queue. Suppressions only for third-party code, one reason per line.
- Acceptance: Refuses non-fleet hosts; suppressions <= 10 lines with reasons; base-red list in the output.
- Test phase: `cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- --sanitize thread`.

#### p10-stability-014 Rust sanitizers, Miri lane
- Files: cmux-tui/scripts/sanitize.sh, cmux-tui/sanitize/rust-toolchain.toml, cmux-tui/docs/sanitizers.md
- Change: Pinned nightly (sanitize/ only): `cargo +nightly nextest -Zbuild-std -Zsanitizer=address|thread|leak` for
  cmux-tui-core, acpmux, cmux-holder, cmux-pty, ghostty-vt on Linux, and macOS for cmux-pty/cmux-holder;
  `cargo miri test` for cmux-pane-protocol, cmux-remote-protocol, cmux-rd-proto, cmux-layout-reducer. Output
  findings.jsonl via crash_signature.py.
- Acceptance: Workspace rust-toolchain.toml and Cargo.lock unchanged.
- Test phase: Testbox `cmux-tui/scripts/sanitize.sh --sanitizer address --crate cmux-holder`.

#### p10-stability-015 readiness-soak with sanitizer apps
- Files: scripts/cmux-next/readiness-soak.py
- Change: `--app-config asan|tsan` (Chromium off), keep the sanitizer log path, count reports as crash events; `--stress`
  loads perf-stress-session.py; count zombie children per hour.
- Acceptance: A sanitizer report counts as a crash event; zombie count in the summary.
- Test phase: 6 h ASan soak on a lab mini.

#### p10-stability-016 CmuxFuzzSupport
- Files: Packages/Shared/CmuxFuzzSupport/Package.swift, Packages/Shared/CmuxFuzzSupport/Sources/CmuxFuzzSupport/*.swift,
  the 7 existing *FuzzTests.swift
- Change: Seeded xorshift RNG, byte/token mutators (flip, insert, delete, splice, dictionary), corpus loader, long mode
  (CMUX_FUZZ_SECONDS, CMUX_FUZZ_SEED), failing input to $CMUX_FUZZ_ARTIFACTS, and a `oneInput(Data)` body per suite so 182
  can wrap it for libFuzzer. Move the 7 suites onto it; delete private RNGs. Call these property tests, not FuzzTest.
- Acceptance: No suite defines its own RNG; default iteration counts unchanged; test-only product.
- Test phase: the 7 suites green on the fleet; `CMUX_FUZZ_SECONDS=300` on one suite.

#### p10-stability-017 cmux-tui/fuzz + first 6 targets
- Files: cmux-tui/fuzz/Cargo.toml, cmux-tui/fuzz/Cargo.lock, cmux-tui/fuzz/rust-toolchain.toml,
  cmux-tui/fuzz/fuzz_targets/*.rs, scripts/cmux-next/rust-fuzz.sh
- Change: Own workspace and lock, pinned nightly, overflow-checks and debug-assertions on. Targets: ghostty-vt output,
  terminal_host_protocol::read_frame, cmux-pane-protocol frame decode/parse_header, cmux-remote-protocol frame + rpc
  from_bytes, cmux-config jsonc parse, cmux-holder decode. Seeds from schemas/terminal-corpus and fixtures. rust-fuzz.sh
  passes `-rss_limit_mb=2048 -malloc_limit_mb=256 -timeout=2` by default; an OOM or timeout is a finding.
- Acceptance: Main workspace Cargo.toml/Cargo.lock unchanged; each target builds with `cargo fuzz build`.
- Test phase: Testbox `scripts/cmux-next/rust-fuzz.sh --all --seconds 600`.
- Landing order: 018 landed first and created the workspace (Cargo.toml with the release profile above, Cargo.lock,
  rust-toolchain.toml on nightly-2026-10-20). 017 edits those three files in place: it adds its six `[[bin]]` entries,
  its dependencies and their lock delta, and rust-fuzz.sh. It never adds them again or changes the pin or profile
  without saying why. 019-021, 176 and 181 do the same: `[[bin]]` entries, dependencies and the lock delta only.

#### p10-stability-018 Rust fuzz batch 2
- Files: cmux-tui/fuzz/fuzz_targets/, and the workspace files of 017 (it landed first; see 017's landing order)
- Change: cmux-rd-proto (bulk, clock, datagram, feedback, frame, input decode), cmux-transport (relay_frame, probe, stun
  parse_binding_success), cmux-link (dial parse_request/parse_line, stamp parse), cmux-wg packet paths.
- Acceptance: One target per decoder, each with a seed corpus.
- Test phase: rust-fuzz.sh 10 min per target.

#### p10-stability-019 Rust fuzz batch 3: acpmux
- Files: cmux-tui/fuzz/fuzz_targets/
- Change: acpmux rpc parse, claude_stdio stream-json lines, pairing/ticket decode, catalog/schema parse, routes parse,
  question_answer parse_answers.
- Acceptance: As 018.
- Test phase: rust-fuzz.sh 10 min per target.

#### p10-stability-020 Rust fuzz batch 4: host codec, journal, output store
- Files: cmux-tui/fuzz/fuzz_targets/
- Change: terminal_host_runtime/shared/codec.rs decoders (decode_host_snapshot_payload and the rest), colors_wire decode,
  session_journal decode_record, output_store snapshot replay, server/page_files read_request_head.
- Acceptance: Journal targets assert a bad record gives Err, never a panic.
- Test phase: rust-fuzz.sh 10 min per target.

#### p10-stability-021 Rust fuzz batch 5: input, config, pairing
- Files: cmux-tui/fuzz/fuzz_targets/
- Change: cmux-tui pty_input, browser_input, keys; cmux-config keybindings/schema/store; cmux-server-core pairing
  base32/enrollment.
- Acceptance: As 018.
- Test phase: rust-fuzz.sh 10 min per target.

#### p10-stability-022 Swift fuzz: Daemon wire
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/DaemonWireFuzzTests.swift
- Change: LineTransport line split (64 MiB bound), event and reply decode, EventInbox coalescing with random interleavings.
- Acceptance: Value or typed error, never a trap; CmuxFuzzSupport, seeded.
- Test phase: CmuxNextDaemonTests on the fleet + long mode 5 min.

#### p10-stability-023 Swift fuzz: VNC + ScreenKit
- Files: Packages/Shared/CmuxVNC/Tests/, Packages/Shared/CmuxScreenKit/Tests/
- Change: RFB handshake, framebuffer rectangles (raw, copyrect, zlib, tight), cut text, color map from a hostile server;
  ScreenKit stream frames.
- Acceptance: No trap; out-of-range rectangles refused with a typed error.
- Test phase: package tests + long mode.

#### p10-stability-024 Swift fuzz: RemoteView + Android stream
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextRemoteViewTests/, Packages/macOS/CmuxNext/Tests/CmuxNextPhoneTests/
- Change: Remote-desktop frame/packet decode, AndroidScreenStream parsing.
- Acceptance: No trap; bounded allocation per frame.
- Test phase: fleet suites + long mode.

#### p10-stability-025 Swift fuzz: browser and cookie import
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextBrowserImportTests/ (new if absent)
- Change: Chrome/Firefox/Safari profile parsing (JSON Preferences, plist bookmarks, SQLite row values, cookie blobs) with
  corrupted inputs; after 208, against the service.
- Acceptance: No trap; a corrupt profile reports a per-item skip.
- Test phase: fleet suite.

#### p10-stability-026 Swift fuzz: settings + keybindings
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsFuzzTests.swift
- Change: cmux-next.json load and merge, unknown keys, deep nesting, huge numbers, keybinding strings.
- Acceptance: A bad file never traps and keeps the last good settings.
- Test phase: fleet suite.

#### p10-stability-027 Swift fuzz: Mobile host + device hub
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextMobileHostTests/, Packages/macOS/CmuxNext/Tests/CmuxNextDevicesTests/
- Change: Phone-to-Mac frames, device hub socket frames, signed HTTP replies.
- Acceptance: No trap; a bad frame closes only that peer (BadMessage, 178).
- Test phase: fleet suites.

#### p10-stability-028 Swift fuzz: Home render (time budget)
- Files: Packages/Shared/CmuxHomeRender/Tests/, Packages/Shared/CmuxMessagesLab/Tests/
- Change: Random Markdown token streams, unterminated fences, ZWJ emoji, CRLF, huge lines, edits between measure and draw.
- Acceptance: No trap; each render < 50 ms for 64 KiB.
- Test phase: package tests + long mode.

#### p10-stability-029 Swift fuzz: crash/hang report parsers
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextErrorJournalTests/, Packages/macOS/CmuxNext/Tests/CmuxNextHangReportsTests/
- Change: .ips JSON (SystemCrashReport, CrashReportErrorSource), MetricKit payloads.
- Acceptance: No trap on truncated or garbage reports.
- Test phase: fleet suites.

#### p10-stability-030 Swift fuzz: diff, paths, terminal links
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextFilesTests/, Packages/macOS/CmuxNext/Tests/CmuxNextTerminalTests/
- Change: CmuxNextDiff unified diff parse, CmuxNextFiles path/URL handling, TerminalLinkFilter, OSC parsing.
- Acceptance: No trap.
- Test phase: fleet suites.

#### p10-stability-031 HangWatchScope (atomic, in CmuxNextWakeups)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/HangWatchScope.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/HangWatchRegistry.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/MainThreadWatchdog.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/MainThreadWatchdog+Episodes.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/LineTransport.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalOutputLane.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/BlockingLane.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFMessagePump.swift (phase label only)
- Change: Per-thread slot with an atomic deadline; scope = two atomic stores (set / restore outer); global open-scope count
  triggers one EVFILT_USER wake on 0 -> 1; the watcher (MainThreadWatchdog, injected by the composition root) timed-waits to
  the earliest deadline and parks with no timeout at count 0. `invalidate()` for unbounded waits. Jank record at the scope
  budget (reader line 50 ms, output-lane feed 16 ms, BackgroundWork 2 s); hang dump at >= 2 s with the hung thread's stack
  via ThreadStackSampler and crash keys (207); reports through the LagSpike sink. CEF pump: a phase label in the main
  episode. Scope is a ~Copyable struct with a nonisolated deinit; call sites marked `// perf-hot:`.
- Acceptance: No syscall on scope enter/exit in steady state; no timer or wakeup with no scope open.
- Test phase: CmuxNextControlTests MainThreadWatchdog* + HangWatchScopeTests (kevent count 0 per scope; a blocked scope
  reports once with the blocked function as top frame); bench-idle wakeups unchanged; typing bench before/after.

#### p10-stability-032 Rust watch_scope + hung-thread stacks
- Files: cmux-tui/crates/cmux-panic-log/src/lib.rs, cmux-tui/crates/cmux-panic-log/src/hang.rs,
  cmux-tui/crates/cmux-tui-core/src/server/, cmux-tui/crates/cmux-tui-core/src/workspace_registry/session_journal.rs
- Change: `watch_scope(kind, jank, hang)` with atomic per-thread deadlines and one watcher thread (condvar park with no
  timeout when no scope is open). Stack of the hung thread: macOS thread_suspend + frame-pointer walk; Linux pthread_kill
  to a handler writing into a preallocated buffer; the record names the method. JSONL next to the panic log. Wire
  mux-conn requests (jank 250 ms, hang 2 s), journal writer loop (2 s), holder-link (1 s).
- Acceptance: Idle daemon has 0 watcher wakeups; a blocked-scope test gets one record whose top frame is the blocked fn.
- Test phase: `cargo nextest -p cmux-panic-log -p cmux-tui-core` on Testbox (Linux) and a macOS fleet step.

#### p10-stability-033 tokio slow-poll detector (lab)
- Files: cmux-tui/crates/cmux-blocking/src/poll_watch.rs, cmux-tui/lab/stability.env
- Change: Under cfg(tokio_unstable) + feature cmux-stability (declared in 101's lock commit), on_before/after_task_poll
  record polls > 2 ms with spawn location into the hang JSONL. RUSTFLAGS only in the lab lane.
- Acceptance: Default builds unchanged; no Cargo.lock change in this task.
- Test phase: acpmux under the lab profile with a sleeping task records one slow poll.
- Scope as built: the acpmux daemon's runtime (`$ACPMUX_HOME/hangs.jsonl`) and the cmux-tui owner's remote
  daemon worker (`owner-hangs-<session>.jsonl`; the mux server runs on threads, covered by 032's scopes). The
  first slow poll per spawn site is a `slow_poll` record; the totals are one `slow_poll_summary` when the
  watch ends. Time in compensated `block_in_place` calls is not counted. Not watched, on purpose: acpmux's
  agent host (its own process, no hang log yet), CLI subcommands and short block_on-only runtimes (no tasks);
  other crates' `cmux-stability` features stay unused until a runtime there is watched.

#### p10-stability-034 stability-health.py
- Files: scripts/cmux-next/stability-health.py, scripts/cmux-next/tests/test_stability_health.py
- Change: Sentry API (token from env only) for nightly-next: crash-free sessions/users per release, lag spikes per 1k
  session-hours, hang events >= 2 s, unclean exits (203), top N issues; JSON + table; other-owner row.
- Acceptance: Token never printed or logged.
- Test phase: pytest with recorded responses; one live run by the lead.

#### p10-stability-035 Sentry signatures to issues
- Files: scripts/cmux-next/stability_issues.py
- Change: Import stability-health top issues as signatures (source=sentry).
- Acceptance: One Sentry issue -> exactly one GitHub issue, link kept.
- Test phase: pytest.

#### p10-stability-036 swift-diagnostics.sh
- Files: scripts/cmux-next/swift-diagnostics.sh, scripts/cmux-next/swift_diagnostics.py
- Change: Fleet step: `swift build` of CmuxNext (or --package PATH) with `-Xswiftc -print-diagnostic-groups` and a clean
  `--scratch-path` (or read persisted `.dia` files; mode recorded). Emit diagnostics.jsonl {target, file, line, group,
  message, fixits}; `--summary`, `--group`, `--fixits-out` (for 211).
- Acceptance: Refuses a person's Mac; parses 6.2 and 6.3 formats; mode recorded per row.
- Test phase: `cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh -- --summary`.

#### p10-stability-037 stabilitySwiftSettings + toolchain check + target guardrail
- Files: Packages/macOS/CmuxNext/Package.swift, scripts/cmux-next/guardrails.py
- Change: Verify on the fleet that SwiftPM 6.2 accepts `.strictMemorySafety()` and `.treatWarning(_:as:)` and the group name
  "StrictMemorySafety"; add empty `stabilitySwiftSettings` appended to ui/daemon settings; local-only guardrail
  `target-settings`: a new target in any closure Package.swift without the shared settings or `// settings-allow: <why>` is
  refused (pre-push only).
- Acceptance: Compile unchanged; the rule is in the local tier (199).
- Test phase: compile-check; guardrails self-test.

#### p10-stability-038 MessagesLab complete checking as warnings
- Files: scripts/cmux-next/stability-settings.json (applied by 198 to Packages/Shared/CmuxMessagesLab/Package.swift)
- Change: Keep .v5; add complete StrictConcurrency to all 4 targets; record the per-folder queue counts in
  stability-DESIGN.md.
- Acceptance: Package compiles; counts recorded.
- Test phase: `swift-diagnostics.sh --package Packages/Shared/CmuxMessagesLab --summary`.

#### p10-stability-039 MessagesLabSidebar to Swift 6
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/**, scripts/cmux-next/stability-settings.json
- Change: Fix every concurrency diagnostic (4,650 lines, 12 files); remove the 3 @preconcurrency conformances in
  CmuxSidebarView.swift by isolating the protocols; request .v6 for the target and its tests.
- Acceptance: .v6, 0 concurrency warnings, no new @unchecked Sendable.
- Test phase: MessagesLabSidebarTests on the fleet.

#### p10-stability-040 MessagesLabHome Vendor/catalyst A-L
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/[A-L]*.swift
- Change: Fix Q01 diagnostics: background renderers take Sendable snapshots, shared caches behind Mutex, fonts from
  process-wide caches (render_font rule).
- Acceptance: 0 concurrency diagnostics in the files; no new unchecked or crash-allow.
- Test phase: MessagesLabHomeTests + RenderIndexFuzzTests.

#### p10-stability-041 MessagesLabHome Vendor/catalyst M-Z
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/[M-Z]*.swift
- Change/Acceptance/Test: as 040.

#### p10-stability-042 MessagesLabHome appkit-native + appkit-port
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/**, .../Vendor/appkit-port/**
- Change/Acceptance: as 040 (6,055 lines). Test: MessagesLabHomeTests.

#### p10-stability-043 MessagesLabHome Cmux/ A-L
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/[A-L]*.swift
- Change: Fix Q01 diagnostics; isolate ChatIntents so HomeProjection drops @preconcurrency.
- Acceptance: 0 diagnostics in the files. Test: MessagesLabHomeTests.

#### p10-stability-044 MessagesLabHome Cmux/ M-Z
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/[M-Z]*.swift
- Change/Acceptance/Test: as 043.

#### p10-stability-045 Flip MessagesLabHome to Swift 6
- Files: scripts/cmux-next/stability-settings.json, Packages/Shared/CmuxMessagesLab/Tests/**
- Change: Request .v6 for MessagesLabHome and its tests; fix remaining errors.
- Acceptance: `git grep 'swiftLanguageMode(.v5)' Packages/Shared/CmuxMessagesLab` empty after the lander.
- Test phase: MessagesLabHomeTests, MessagesLabSidebarTests; CmuxNextApp compile-check.

#### p10-stability-046 One Sparkle seam
- Files: Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/SparkleSeam.swift, Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/*.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/*.swift
- Change: SparkleSeam.swift is the only file with `@preconcurrency import Sparkle`; it wraps SPUUpdater, the
  SPUUserDriver/SPUUpdaterDelegate conformances and appcast types in @MainActor types and Sendable values.
- Acceptance: `git grep -l 'import Sparkle' Packages/macOS` lists SparkleSeam.swift only; behavior unchanged.
- Test phase: CmuxUpdater + UpdaterService tests on the fleet; update-e2e (196).

#### p10-stability-047 Remaining @preconcurrency
- Files: Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohSystemBonjour*.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextPhone/Live/SimulatorHIDTransport.swift,
  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenVideoView.swift
- Change: Replace `@preconcurrency import Dispatch/AppKit/XPC` and the RTCVideoViewDelegate conformance with Sendable
  wrappers or isolated conformances.
- Acceptance: Q03 = 0 in the closure apart from SparkleSeam. Test: compile-check; Iroh tests.

#### p10-stability-048 Unchecked: CmuxIrxTransport (14)
- Files: Packages/Shared/CmuxIrxTransport/Sources/**
- Change: Replace each @unchecked Sendable / nonisolated(unsafe) with CmuxSafeConcurrency.Mutex<State>, an actor or a
  Sendable value; a site that must stay (signal-handler state) gets a crash-allow argument.
- Acceptance: Module count down >= 12; `crash_ratchet --update-baseline` lowers the row; no behavior change.
- Test phase: package tests + IrxFrameFuzzTests + TSan sweep.

#### p10-stability-049 Unchecked: CmuxIrohTransport (7)
- Files: Packages/Shared/CmuxIrohTransport/Sources/**
- Change/Acceptance: as 048; down >= 6. Test: package tests + TSan.

#### p10-stability-050 Unchecked: CMUXMobileCore, CmuxMobileRPC, CmuxMobileTunnel, CmuxMobileSupport
- Files: Packages/Shared/CMUXMobileCore/Sources/**, Packages/iOS/CmuxMobileRPC/Sources/**,
  Packages/iOS/CmuxMobileTunnel/Sources/**, Packages/iOS/CmuxMobileSupport/Sources/**
- Change: as 048; CMUXMobileCore's portable lock forwards to CmuxSafeConcurrency.Mutex.
- Acceptance: rows down >= 15. Test: package tests + MobileProtocolFuzzTests + TSan.

#### p10-stability-051 Unchecked: CmuxMobileSSH, CmuxMobileShellModel
- Files: Packages/iOS/CmuxMobileSSH/Sources/**, Packages/iOS/CmuxMobileShellModel/Sources/**
- Change/Acceptance: as 048; down >= 12. Test: package tests + TSan.

#### p10-stability-052 Unchecked: CmuxNextTerminal (7)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/**
- Change: as 048; Ghostty callback state behind Mutex or on the output lane's queue.
- Acceptance: down >= 6; no new main-thread lock wait > 2 ms (blocking detector). Test: CmuxNextTerminalTests + TSan +
  typing bench before/after.

#### p10-stability-053 Unchecked: CmuxNextDictation (6)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextDictation/**
- Change: as 048 for AVAudio and Speech callback state. Acceptance: down >= 5. Test: compile + TSan sweep.

#### p10-stability-054 Unchecked: CmuxHomeRender (5), CmuxHomeCore (1), MessagesLabSidebar (2)
- Files: Packages/Shared/CmuxHomeRender/Sources/**, Packages/Shared/CmuxHomeCore/Sources/**,
  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/**
- Change/Acceptance: as 048; down >= 7. Test: package tests + TSan.

#### p10-stability-055 Unchecked: MessagesLabHome (14)
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/**
- Change/Acceptance: as 048; down >= 12. Test: MessagesLabHomeTests + TSan.

#### p10-stability-056 Unchecked: CmuxNextRemoteView (5), CmuxNextTabs (5)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView/**, Packages/macOS/CmuxNext/Sources/CmuxNextTabs/**
- Change/Acceptance: as 048; down >= 8. Test: suites + TSan.

#### p10-stability-057 Unchecked: CmuxNextServerHelper (5)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextServerHelper/**
- Change: as 048 for XPC listener state. Acceptance: down >= 4. Test: compile + TSan.

#### p10-stability-058 Unchecked: CmuxNextBrowser (4), BrowserAutomation (1), BrowserImport (1)
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextBrowser,CmuxNextBrowserAutomation,CmuxNextBrowserImport}/**
- Change/Acceptance: as 048; down >= 5. Test: suites + TSan.

#### p10-stability-059 Unchecked: CmuxNextDaemon (4), CmuxNextControl (3)
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextDaemon,CmuxNextControl}/**
- Change/Acceptance: as 048; down >= 6. Test: CmuxNextDaemonTests, CmuxNextControlTests + TSan.

#### p10-stability-060 Unchecked: CMUXAuthCore, CmuxAuthRuntime, CmuxUpdater
- Files: Packages/Shared/CMUXAuthCore/Sources/**, Packages/Shared/CmuxAuthRuntime/Sources/**,
  Packages/macOS/CmuxUpdater/Sources/**
- Change: as 048 (3+1+1 sites; CmuxSyncStore removed: outside the closure). Acceptance: down >= 4. Test: package tests.

#### p10-stability-061 Unchecked: CmuxNext singles
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextApp,CmuxNextAgentPane,CmuxNextApps,CmuxNextBridge,CmuxNextDesign,
  CmuxNextHomeEngine,CmuxNextSettings}/**, Packages/Shared/CmuxAgentCursor/Sources/CmuxCuaHelperCore/**
- Change: as 048 for the unreasoned sites. Acceptance: 0 unreasoned unchecked in these modules. Test: suites + TSan.

#### p10-stability-062 Reasoned unchecked: CmuxVNCWebRTC (18), CmuxNextCrashReporting (11)
- Files: Packages/Shared/CmuxVNCWebRTC/Sources/**, Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/**
- Change: Keep only async-signal-safe globals (signal handlers, alternate stacks) with arguments; convert the rest.
- Acceptance: Every remaining argument names the thread and why a lock is impossible.
- Test phase: crash-ends-app-gate.py; VNCWebRTC tests.

#### p10-stability-063 .. 078 SAFETY-TODO removal per module
Common change: remove every `SAFETY-TODO(p10)` in the listed modules: refactor to safe APIs (Span/Data/Array, typed
wrappers, no raw pointers) or replace the TODO with a real `// SAFETY:` argument on the line above the `unsafe`.
Common acceptance: `git grep -c 'SAFETY-TODO(p10)'` = 0 in the listed paths; `swift-diagnostics --group StrictMemorySafety`
= 0 for these targets; no `unsafe` without a SAFETY line above. Common test: listed suites + ASan sweep of the targets.
- **063** Daemon, Control, Mobile: Packages/macOS/CmuxNext/Sources/{CmuxNextDaemon,CmuxNextControl,CmuxNextMobile}/**;
  suites + fuzz suites.
- **064** Iroh + Irx: Packages/Shared/CmuxIrohTransport/**, Packages/Shared/CmuxIrxTransport/** (74 constructs).
- **065** VNC + VNCWebRTC + ScreenKit: Packages/Shared/{CmuxVNC,CmuxVNCWebRTC,CmuxScreenKit}/** (57+).
- **066** RemoteView: Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView/** (65).
- **067** Browser CEF/: Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/**; CmuxNextBrowserTests + ASan app smoke with
  the instrumented shim (162).
- **068** Browser rest: Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/** (non-CEF); as 067.
- **069** Terminal: Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/** (80, Ghostty C API); typing bench before/after.
- **070** BrowserImport: Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/** (71, SQLite C API); import fuzz 025.
- **071** Phone: Packages/macOS/CmuxNext/Sources/CmuxNextPhone/** (55, 25 unsafeBitCast).
- **072** App: Packages/macOS/CmuxNext/Sources/CmuxNextApp/** (74); CmuxNextAppTests + ASan app smoke.
- **073** MessagesLab: Packages/Shared/CmuxMessagesLab/** (62).
- **074** Design, Focus, Sidebar: Packages/macOS/CmuxNext/Sources/{CmuxNextDesign,CmuxNextFocus,CmuxNextSidebar}/** (73).
- **075** AgentPane + Compat: Packages/macOS/CmuxNext/Sources/{CmuxNextAgentPane,CmuxNextCompat}/** (72); + TSan.
- **076** CrashReporting + HangReports: Packages/macOS/CmuxNext/Sources/{CmuxNextCrashReporting,CmuxNextHangReports}/**;
  annotate only (`@unsafe`/`@safe`, `unsafe` + SAFETY); signal handlers otherwise unchanged; crash-ends-app-gate.py.
- **077** Files, RemoteFetch, Dictation, Palette: Packages/macOS/CmuxNext/Sources/{CmuxNextFiles,CmuxNextRemoteFetch,
  CmuxNextDictation,CmuxNextPalette}/** (63).
- **078** MobileCore, MobileSSH, CuaHelperCore: Packages/Shared/CMUXMobileCore/**, Packages/iOS/CmuxMobileSSH/**,
  Packages/Shared/CmuxAgentCursor/** (CmuxTerminalClient removed: outside the closure).

#### p10-stability-079 StrictMemorySafety as error (final flip)
- Files: scripts/cmux-next/stability-settings.json (lander applies to every closure Package.swift)
- Change: At about hour 62, run swift-diagnostics at the tip; if StrictMemorySafety = 0, add
  `treatWarning("StrictMemorySafety", as: .error)` to stabilitySwiftSettings for every closure target in one lander
  commit; remaining small modules' TODOs that are left stay listed in Q04 (they are already `unsafe`-marked, so the error
  does not fire on them).
- Acceptance: Every Swift target in the closure has both settings; diagnostics 0 at that SHA.
- Test phase: compile-check on both fleet Xcode versions; full suite in the test phase.

#### p10-stability-081 CallbackRegistry + wave 1
- Files: Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/CallbackRegistry.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCompat/CallbackRegistry+Reexport.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView/Input/RemoteSystemShortcutTap.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView/Present/SampleBufferPresenter.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextFiles/FolderWatchStream.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextApp/FileExplorer/FileTreeWatchStream.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextPhone/Android/AndroidScreenStream.swift
- Change: One registry (fixed slot table, generation counter, atomic lookup, no lock on the callback path) mapping a token
  to a weak box; the C context is the token. Unknown or freed token: ignored and counted. CmuxNextCompat re-exports it.
  Migrate the 12 sites in these files.
- Acceptance: No passUnretained in these files; a test frees the owner then fires the callback: no crash, counter +1.
- Test phase: CallbackRegistryTests + ASan sweep; perf-hot bench before/after for SampleBufferPresenter.

#### p10-stability-082 CallbackRegistry wave 2
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/{CEFRuntime,CEFPaneHost,CEFPaneHost+PopupWindows,
  CEFDevToolsController}.swift, Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/{GhosttyRuntime,TerminalSurfaceView,
  TerminalLinkFilter}.swift, Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ScreenContentView+{Dock,Canvas}.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextKeepAwake/PowerSourceMonitor.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyboardLayoutObserver.swift,
  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenVideoView.swift,
  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/{TranscriptLinkCursor,AssociationKey}.swift
- Change: As 081 for the remaining sites. CEF objects keep a balanced retain/release at teardown instead of a token where
  CEF already reference-counts; Ghostty wakeup/render callbacks use the lock-free path, marked `// perf-hot:`.
- Acceptance: Q08 = 0 outside CmuxSafeConcurrency/CallbackRegistry*.swift.
- Test phase: suites + ASan app smoke + chaos close-during-callback; typing and frame benches before/after.

#### p10-stability-083 CmuxSafeConcurrency: OnceContinuation
- Files: Packages/Shared/CmuxSafeConcurrency/** (Package.swift, Sources, Tests)
- Change: Foundation-free package (macOS 14 / iOS 17). OnceContinuation<T, E>: resume exactly once (Mutex from 172); a
  double resume is a no-op plus a fault log; deinit without resume resumes with a typed error; no cancellation unless
  constructed `.cancellable` (then CancellationError on task cancel). Local-only crash_ratchet report class raw_continuation
  and guardrail on added lines (199 tier).
- Acceptance: Tests cover double resume, deinit, cancellable and non-cancellable; no CI-read baseline row added.
- Test phase: CmuxSafeConcurrency tests + TSan.

#### p10-stability-084 .. 088 Continuations per module
Common change: move each site to OnceContinuation (choosing `.cancellable` only where the underlying work is cancelled too,
stated in the diff) or to an async API that removes the continuation. Common acceptance: Q06 = 0 in the modules; report
baseline lowered. Common test: module suites.
- **084** Packages/macOS/CmuxNext/Sources/CmuxNextApp/** (41).
- **085** Packages/macOS/CmuxNext/Sources/{CmuxNextAgentPane,CmuxNextPages}/** (24+8).
- **086** Packages/Shared/{CmuxIrohTransport,CmuxIrxTransport}/Sources/** (15+12).
- **087** Packages/macOS/CmuxNext/Sources/{CmuxNextDaemon,CmuxNextControl,CmuxNextMobile,CmuxNextRemoteLocalhost}/** (28).
- **088** Packages/macOS/CmuxNext/Sources/{CmuxNextBrowser,CmuxNextBrowserAutomation,CmuxNextWakeups,
  CmuxNextHomeEngine}/**, Packages/Shared/CmuxHomeCore/Sources/** (32).

#### p10-stability-089 Continuations: rest + local ban
- Files: Packages/**/Sources (VNCWebRTC, MobileRPC, Design, MobileCore, VNC, Diff, Compat, MobileSSH, AuthRuntime, others),
  scripts/cmux-next/guardrails.py
- Change: as 084 for the remaining ~70 sites; ban raw continuations in the local tier.
- Acceptance: Q06 = 0; local ban active. Test: compile-check; suites in the test phase.

#### p10-stability-090 unowned part 1
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextApp/{*.swift (root),History,Windows,Bookmarks,Onboarding,Pages,Screens}/**,
  scripts/cmux-next/crash-allowlist.json
- Change: Per allowlisted site: if the owner can legitimately die first -> `weak` + else branch calling
  `Invariant.notFatalUntil` and the existing error toast for a user action; if the lifetime is structural -> keep `unowned`,
  add `lifetime: <owner holds X for its whole life>` to the entry. Never a silent return.
- Acceptance: Each of ~38 entries is removed or has a lifetime reason; no `guard ... else { return }` without a report.
- Test phase: CmuxNextAppTests.

#### p10-stability-091 unowned part 2
- Files: remaining Q07 files (CmuxNextApp folders, CmuxNextBrowser/CEF, CmuxNextSidebar/Views,
  MessagesLabHome/Vendor/appkit-native), scripts/cmux-next/crash-allowlist.json
- Change: as 090.
- Acceptance: 0 swift.unowned entries without `lifetime:`; total <= 20. Test: suites.

#### p10-stability-092 crash_ratchet --report, trap_api, all-modules scan
- Files: scripts/cmux-next/crash_ratchet.py, scripts/cmux-next/crash-safety-report-baseline.json,
  scripts/cmux-next/tests/crash-ratchet-v2.test.sh
- Change: `--report CLASSES` emits JSON {path, line, class, module}. New report-only class trap_api: uniqueKeysWithValues;
  removeFirst()/removeLast() without an isEmpty/count guard on the line or the line above; Array(repeating:count:) with a
  non-literal count; index(_:offsetBy:) without limitedBy. `--all-modules` scans index_subscript and int_conversion
  everywhere. New rows go only to crash-safety-report-baseline.json (CI does not read it).
- Acceptance: crash-safety-baseline.json unchanged by this task; tests cover each pattern and its guard exemption.
- Test phase: `bash scripts/cmux-next/tests/crash-ratchet-v2.test.sh`.

#### p10-stability-093 .. 095 Decode-path index/int waves
Common change: for hits classed input-reachable by 205 (Q14 entry points and their callees), validate the input and return
a typed error (or BadMessage, 178); no `clamping:`, no clamped slice. Invariant-class hits stay checked or move to
`Invariant.check`. Add the decode files (not whole modules) to the local-tier ban list.
Common acceptance: 0 input-reachable hits in the listed modules; any clamping in the diff shows the value is outside input
with a defined fallback.
- **093** Packages/Shared/{CmuxVNC,CmuxScreenKit}/Sources/**, Packages/macOS/CmuxNext/Sources/{CmuxNextRemoteView,
  CmuxNextPhone}/**; fuzz 023/024.
- **094** Packages/macOS/CmuxNext/Sources/{CmuxNextBrowserImport,CmuxNextCookieImport,CmuxNextDevices,
  CmuxNextMacScreen}/**; fuzz 025/027.
- **095** Packages/macOS/CmuxNext/Sources/{CmuxNextTerminal,CmuxNextErrorJournal,CmuxNextHangReports,CmuxNextDiff}/**
  (CmuxTerminalClient removed); fuzz 029/030.

#### p10-stability-096 uniqueKeysWithValues (72)
- Files: the 56 files from `git grep -l uniqueKeysWithValues -- 'Packages/**/Sources/**/*.swift'`
- Change: Dictionary(_:uniquingKeysWith:) with an explicit rule, or a typed duplicate error at decode boundaries; never
  silently keep the first entry where a duplicate means corrupt input.
- Acceptance: 0 uniqueKeysWithValues in Sources; each site's rule visible in the diff. Test: suites.

#### p10-stability-097 removeFirst/removeLast in CmuxNext
- Files: Packages/macOS/CmuxNext/Sources/** (hits from `crash_ratchet --report trap_api`)
- Change: popFirst/popLast with the empty case handled, or a guard on the same line; invariant-class sites (205) use
  Invariant.check.
- Acceptance: trap_api removeFirst/removeLast rows = 0 for CmuxNext. Test: suites.

#### p10-stability-098 trap_api Shared/iOS + local ban
- Files: Packages/Shared/**/Sources/**, Packages/iOS/**/Sources/**, scripts/cmux-next/guardrails.py
- Change: as 097 plus validated counts and index(_:offsetBy:limitedBy:); ban trap_api in the local tier.
- Acceptance: trap_api = 0 in the closure; local ban active. Test: package tests.

#### p10-stability-099 Invariant API
- Files: Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/Invariant.swift,
  Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Support/CrashGuard.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/InvariantSink.swift, scripts/cmux-next/crash-allowlist.json
- Change: `Invariant.check(cond, id)` (traps in every build; allowlist class swift.invariant_check with reason);
  `Invariant.notFatalUntil(cond, id, build:)` (report once per site per launch until build N, then trap; ratchet refuses a
  lowered N without reason); `Invariant.dumpWillBeCheck(cond, id)` (report; allowlisted with a handler). Report path: one
  atomic dedupe on the caller's thread, event handed to the background crash-reporting lane (sink set by the composition
  root), consent respected. CrashGuard's fault-once path calls notFatalUntil.
- Acceptance: No Sentry call or I/O on the caller's thread (test with a main-thread I/O detector); one event per site per
  launch.
- Test phase: package tests.

#### p10-stability-100 async-blocking-scan (syn, fleet)
- Files: cmux-tui/tools/async-blocking-scan/{Cargo.toml,Cargo.lock,src/main.rs,blocking-paths.toml}
- Change: Own workspace. Kinds: `blocking` (calls from blocking-paths.toml lexically inside async fn/blocks, not inside
  spawn_blocking/block_in_place; std Mutex lock held over .await), `spawn` (statement-level tokio::spawn with dropped handle;
  thread::spawn/Builder outside cmux_panic_log::supervise*), `pre_exec` (non-libc calls in pre_exec closures), `child`
  (spawn() whose Child is not awaited, waited, stored or kill_on_drop), `unbounded` (unbounded_channel / std channel()
  without `unbounded-allow:`). JSON output, `--diff BASE`. Skips #[cfg(test)] and tests/. `--root` accepts several roots
  (Native/*, cmux-next-ios/rust).
- Acceptance: Main workspace lock unchanged; fixture crate tests cover each kind and exemption. Runs on fleet/Testbox only.
- Test phase: cargo test in the tool on Testbox; a full run prints Q11/Q12/Q20 counts.

#### p10-stability-101 cmux-blocking + lock-slot commit
- Files: cmux-tui/crates/cmux-blocking/**, cmux-tui/Cargo.toml, cmux-tui/Cargo.lock, Cargo.toml of every tokio crate
  (acpmux, cmux-tui, cmux-tui-core, cmux-remote, chatmux-relay, cmux-pane-protocol, cmux-weft, cmux-wg, cmux-relay,
  cmux-coderouter, cmux-terminal-client, cmux-server, cmux-host)
- Change: Thread-local may_block (MayBlock/WillBlock). `runtime::builder()` marks workers no-block via on_thread_start;
  `spawn_blocking(f)` sets may_block. Wrappers fs::*, process::output/status, sleep, recv, Condvar wait: on a multi_thread
  worker run through block_in_place and count; on current_thread count and write a slow-poll record with
  `#[track_caller]` location. Debug: log once per site; panic only in its own tests or with CMUX_BLOCKING_STRICT=1.
  Unknown threads count as unknown. In the same commit: add `cmux-blocking` and `cmux-panic-log` as dependencies of every
  consumer crate listed and declare the `cmux-stability` feature (033), so later tasks never touch Cargo.lock.
- Acceptance: The only Cargo.lock change in the queue tasks; tests on both runtime flavors.
- Test phase: `cargo nextest -p cmux-blocking`.

#### p10-stability-102 Pre-push ast-grep Rust rules
- Files: scripts/cmux-next/ast-grep/rules/rust-async-blocking.yml, rust-unsupervised-spawn.yml, rust-ffi-guard.yml,
  scripts/cmux-next/guardrails.py
- Change: Lexical rules for added lines on changed cmux-tui/Native files, run with the pinned ast-grep (lint-tools.lock):
  blocking call in async body, dropped tokio::spawn handle, raw thread::spawn, `extern "C" fn` without ffi_boundary. Escapes
  `// blocking-allow:`, `// supervise-allow:`, `// ffi-nopanic:`. Local tier only.
- Acceptance: No cargo build in the hook; never runs under GITHUB_ACTIONS; < 5 s on a typical push.
- Test phase: guardrails self-tests with fixtures.

#### p10-stability-103 Supervisor in cmux-panic-log
- Files: cmux-tui/crates/cmux-panic-log/src/supervise.rs, cmux-tui/crates/cmux-panic-log/src/lib.rs
- Change: `supervise_thread(name, policy, shutdown, body)` and `supervise_task(name, policy, shutdown, fut)`. Policy
  Fatal (default: record, flush, clean exit so the process supervisor restarts) or Restart (backoff 100 ms .. 30 s, <= 5/min,
  only for workers declared state-private). A panic observed with a poisoned shared lock escalates to Fatal. Task handles
  are kept in a set; JoinError::is_panic handled the same way. ShutdownBehavior from 204.
- Acceptance: Never leaves a live process serving nothing; tests: restart, give-up -> Fatal, poison -> Fatal.
- Test phase: `cargo nextest -p cmux-panic-log`.

#### p10-stability-104 .. 110 Async-blocking per crate
Common change: fix every Q11 hit (clippy disallowed_methods from 206 + scanner kind blocking) with cmux-blocking wrappers in
spawn_blocking, tokio::fs/process equivalents, or the existing single log-writer thread (A1). Common acceptance: Q11 = 0 in
the listed paths; behavior unchanged. Common test: cargo nextest for the crate.
- **104** cmux-tui/crates/acpmux/src/hub/** (acpmux token bench in the test phase).
- **105** cmux-tui/crates/acpmux/src/{server,claude_stdio,agent_host}/**, cmux-tui/crates/acpmux/src/{store,mailbox}*.rs.
- **106** cmux-tui/crates/acpmux/src/** (remaining); Q11 = 0 in acpmux.
- **107** cmux-tui/crates/cmux-remote/src/** (~188 signal lines).
- **108** cmux-tui/crates/chatmux-relay/src/** (146).
- **109** cmux-tui/crates/cmux-tui/src/** (32 async files).
- **110** cmux-tui/crates/{cmux-pane-protocol,cmux-weft,cmux-wg,cmux-relay,cmux-coderouter,cmux-terminal-client,
  cmux-server}/src/**; Q11 = 0 workspace-wide.

#### p10-stability-111 Supervise acpmux tasks (130)
- Files: cmux-tui/crates/acpmux/src/**
- Change: Every statement-level tokio::spawn goes through supervise_task or stores its handle with its owner. Long-lived
  hub tasks: Fatal unless proven state-private; per-request tasks end the request with an internal error.
- Acceptance: Q12 = 0 in acpmux; each call names policy + shutdown. Test: nextest + a panic-injection test per policy.

#### p10-stability-112 Supervise cmux-tui-core threads (115)
- Files: cmux-tui/crates/cmux-tui-core/src/**
- Change: mux-conn, journal writer, terminal work pool, event bus run under supervise_thread; shared-state workers use Fatal;
  lock_rank order unchanged; names kept.
- Acceptance: Q12 = 0 in the crate. Test: nextest + DaemonCrashLoopTests in the test phase.

#### p10-stability-113 Supervise cmux-tui, cmux-remote, chatmux-relay, small crates
- Files: cmux-tui/crates/{cmux-tui,cmux-remote,chatmux-relay,cmux-weft,cmux-wg,cmux-pane-protocol,cmux-relay,
  cmux-coderouter}/src/**
- Change: as 111/112. Acceptance: Q12 = 0 workspace-wide. Test: nextest for these crates.

#### p10-stability-114 Report-only tracked lints
- Files: scripts/cmux-next/rust_panic_ratchet.py, scripts/cmux-next/rust-panic-report-baseline.json,
  cmux-tui/lab/clippy/clippy.toml
- Change: `--report-flags` (lab only, not `--flags`, which CI uses) adds undocumented_unsafe_blocks, large_futures,
  await_holding_invalid_type and counts `INVARIANT:` expects; lab clippy.toml sets await-holding-invalid-types
  (RankedMutex guards; std MutexGuard is already await_holding_lock) and future-size-threshold. The workspace has no
  clippy.toml until a commit brings every hit of a lint to 0.
- Acceptance: CI's `--flags` output unchanged; report baseline from one Linux run. Test: Q10 run on rbx.

#### p10-stability-115 .. 118 SAFETY comments
Common change: every unsafe block gets a `// SAFETY:` comment with its precondition, or becomes a safe API. Common
acceptance: tracked row 0 for the crates. Common test: Q10 report run.
- **115** cmux-tui/crates/cmux-tui-core/src/**. **116** cmux-tui/crates/cmux-tui/src/**.
- **117** cmux-tui/crates/{acpmux,ghostty-vt}/src/**. **118** cmux-tui/crates/{cmux-holder,cmux-pty}/src/** and other
  crates with hits; workspace row 0.

#### p10-stability-119 loom model of the holder ring
- Files: cmux-tui/verify/loom-ring/{Cargo.toml,Cargo.lock,tests/loom_ring.rs}, cmux-tui/crates/cmux-holder/src/ring*.rs
- Change: Separate workspace includes the ring source through `#[path]` with cfg(loom) atomic aliases; a loom test for the
  writer/reader offset protocol, the 'reading' marker and handoff (PL-holder items 1-3).
- Acceptance: cmux-holder stays std+libc; main Cargo.lock unchanged; release code unchanged except the cfg aliases.
- Test phase: `RUSTFLAGS='--cfg loom' cargo test --manifest-path cmux-tui/verify/loom-ring/Cargo.toml` on Testbox.

#### p10-stability-120 .. 144 Rust panic deny (index of generated tasks)
These rows are batch seeds; task 210 generates the real tasks from the merged Q10 JSON (<= 50 hits per task, owner named).
Common change: rust-panic-free.md rule 1 per hit: input-reachable (205) -> typed error to the request/frame boundary
(BadMessage for peers, 178); invariant -> `#[expect(clippy::<lint>, reason = "INVARIANT: <why it holds>")]` on the
smallest item or a restructure that makes the panic impossible; RecoverPoison only with re-validation. No silent defaults.
Common acceptance: the Q10 report shows 0 deny hits in the files; baseline lowered in the same commit
(`--update-baseline`). Common test: cargo nextest for the crate.
- **120** cmux-tui-core resource_router/topology.rs. **121** resource_router/** rest. **122** mux/[a-k]*. **123**
  mux/[l-r]*. **124** mux/[s-z]* and mux/*/. **125** surface/** (output paths first). **126** journal_* and
  workspace_registry/** (bad record -> Err, skipped with a counted fault; fuzz 020). **127** {browser,apps,server,state}/**.
  **128** cmux-tui-core rest; crate row 0.
- **129** cmux-tui {remote_runtime,remote_cli}*. **130** machine_*. **131** {ui,app,cli}/**. **132** rest; crate row 0.
- **133** acpmux hub/[a-l]*. **134** hub/[m-z]*, {server,claude_stdio,agent_host}/**, {store,mailbox}*.rs. **135** rest.
- **136** cmux-browser-host (224). **137** cmux-remote (153). **138** chatmux-relay (149). **139** ghostty-vt (104; fuzz 017).
- **140** cmux-layout-reducer (76) + cmux-palette-ranker (58); keep kani proofs green; lands through the pin lander (153)
  because both are CCmuxAppFFI inputs.
- **141** cmux-tui-cloud-conversations, cmux-terminal-client, cmux-config. **142** cmux-server, cmux-chat-index,
  cmux-tasks-core. **143** cmux-rd-core (pin lander if it is an FFI input), cmux-api-compat, cmux-theme-tokens, cmux-mux2.
- **144** all remaining small crates (cmux-server-core, cmux-tui-util, cmux-tui-image-paste, cmux-tui-platform,
  cmux-agent-pane-policy, cmux-tui-hooks, cmux-tui-cdp, cmux-encode, cmux-terminal-sizing, cmux-conversation,
  cmux-remote-protocol, cmux-focus-core, cmux-remote-transcript, cmux-tasks, cmux-motion (pin lander), cmux-chief,
  cmux-tui-remote-access, cmux-git, cmux-worktree-care, cmux-local-auth, cmux-pty, cmux-link, cmux-app-host,
  cmux-app-manifest, cmux-feed-core, cmux-coderouter, cmux-terminal-iface, cmux-relay, cmux-history, cmux-build-identity,
  cmux-tui/bindings/rust*); split per crate; deny total 0 for all 69 crates.

#### p10-stability-145 process-chaos-e2e.py
- Files: scripts/cmux-next/process-chaos-e2e.py
- Change: Tagged build + debug socket; while debug.key types, SIGKILL daemon, acpmux, a terminal host, holder, Chromium
  renderer/GPU/utility and WebContent one at a time (pids from the app's children). Per-fault expected outcomes as in 009.
  Main-thread ping p99 <= 250 ms through each kill.
- Acceptance: Refuses a non-tagged socket; one JSON line per kill with expected and observed.
- Test phase: bare metal on a lab mini against the final tip.

#### p10-stability-146 Chromium host kind in child-crash-e2e (F2)
- Files: scripts/cmux-next/child-crash-e2e.py
- Change: Kind `host`: with browserHost.helper on, SIGKILL the host and navigate to
  chrome://inducebrowsercrashforrealz; cmux stays up, pages show the crash page and reload after restart.
- Acceptance: Skips with a clear reason when the build lacks the host. Test: `child-crash-e2e.py --only host`.

#### p10-stability-147 Leak check at quit in the smoke
- Files: scripts/fuzz/macos-matrix/smoke.py, scripts/cmux-next/relaunch-e2e.py
- Change: `leaks <pid>` before quit; record leaked bytes and top types.
- Acceptance: result.json has a leaks row; report only. Test: os-matrix smoke on 26.

#### p10-stability-148 Swift Mutex lock ranks in Debug
- Files: Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/MutexRank.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Mutex.swift
- Change: Optional rank; Debug thread-local held-rank stack traps on inversion naming both locks; compiled out in Release.
  Ranks first in Daemon, Terminal, CrashReporting.
- Acceptance: Check under `#if DEBUG` only; test shows an inversion is detected. Test: CmuxNextCompatTests.

#### p10-stability-150 acpmux + holder panics and hangs reach Sentry
- Files: cmux-tui/crates/acpmux/src/daemon.rs, Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/OwnerPanicForwarder.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/RustPanicSource.swift
- Change: acpmux agent hosts install cmux_panic_log like the owner; the forwarder reads acpmux, hang (032) and FFI (152)
  records under the same consent and scrubbing.
- Acceptance: A test panic in acpmux becomes one forwarded event with no paths. Test: crash_forward.rs + forwarder tests.

#### p10-stability-151 stability-final.sh
- Files: scripts/cmux-next/stability-final.sh
- Change: One table: each done check's command, value, target, from git/jq counts, latest lab artifacts, sanitizer findings,
  fuzz summary, stability-health; other-owner rows separate.
- Acceptance: Read-only; exit 0 only when every row meets its target. Test: run by the lead at the end.

#### p10-stability-152 In-app Rust FFI boundary
- Files: cmux-tui/crates/cmux-ffi-guard/{Cargo.toml,src/lib.rs}, cmux-tui/crates/cmux-app-ffi/src/{lib,motion}.rs,
  cmux-tui/crates/cmux-app-ffi/Cargo.toml, cmux-tui/crates/cmux-rd-ffi/src/{lib,bulk_ffi,session_ffi,upstream_ffi,input_ffi,
  rb_client_ffi}.rs, cmux-tui/crates/cmux-layout-reducer-ffi/src/{lib,focus}.rs, cmux-tui/crates/cmux-palette-ranker/src/ffi.rs
- Change: std-only crate `cmux-ffi-guard`: `ffi_boundary(name, default, || body)` = catch_unwind, store the panic message in a
  fixed ring read by an exported `cmux_ffi_take_panic`, return the documented error value. Wrap every exported body;
  pure arithmetic with no panic path gets `// ffi-nopanic: <why>`. app-ffi release profile: `debug = "line-tables-only"`,
  no strip of line tables, dSYM uploaded with the xcframework. The Swift side forwards stored panics (150). Lands through the
  pin lander (153).
- Acceptance: Q18 = 0 (`every_export_is_guarded` passes in each of the four crates); a unit test per crate makes a guarded
  fn panic and gets the error value, not an abort.
- Test phase: cargo test in each FFI crate on Testbox; app compile-check with the new pin; motion and remote-view suites.

#### p10-stability-153 FFI pin lander
- Files: Packages/macOS/CmuxNext/Package.swift (appFFI url + checksum), scripts/cmux-next/check-app-ffi-pin.sh,
  plans/cmux-next/stability-DESIGN.md
- Change: Changes to any `check-app-ffi-pin.sh --list-inputs` path are collected on a lander branch; at about H36 and H58 the
  lander runs app-ffi-release.yml for the batch and bumps the pin in the same PR, so CI's pin check never goes red.
- Acceptance: Both pins name a source sha containing 152 and the landed 140/156/143/144 FFI-input fixes; check-app-ffi-pin.sh
  passes.
- Test phase: `cmux-ci build cmux --ref SHA`; child-crash-e2e smoke on the tagged build.

#### p10-stability-154 cmux-terminal-client FFI guard (iOS)
- Files: cmux-tui/crates/cmux-terminal-client/src/lib.rs, Packages/Shared/CmuxTerminalClient/Package.swift
- Change: Wrap the 35 exports with ffi_boundary; republish the CmuxTerminalClient xcframework pin through its workflow.
- Acceptance: export count == guard count. Test: cargo test -p cmux-terminal-client; iOS compile on the fleet.

#### p10-stability-155 Panic ratchet for separate shipped workspaces
- Files: scripts/cmux-next/rust_panic_ratchet.py, scripts/cmux-next/rust-panic-extra-baseline.json
- Change: `--manifest PATH` runs clippy for a separate workspace and records rows per crate in the extra baseline (CI does
  not read it): cmux-app-ffi, cmux-rd-ffi, cmux-layout-reducer-ffi, cmux-rd-host, cmux-remote-browser-host,
  cmux-remote-browser-testhost, Native/OptChat/{optchat-chief,chief-turn,optchat-core,optchat-host,optchat-wasm},
  Native/DiffSidecar, cmux-next-ios/rust (cmux-mobile-host, cmux-mobile-link). FROZEN_FIXTURES unchanged.
- Acceptance: Rows for every listed crate from one Linux run; rust-panic-baseline.json unchanged.
- Test phase: Q10 run on rbx with the extra manifests.

#### p10-stability-156 Panic deny: rd-ffi, layout-reducer-ffi, rd-host, remote-browser-host
- Files: cmux-tui/crates/{cmux-rd-ffi,cmux-layout-reducer-ffi,cmux-rd-host,cmux-remote-browser-host}/src/**
- Change: as 120 (rd-ffi runs in the app; remote-browser-host owns a Chromium fork). FFI inputs land via 153.
- Acceptance: extra-baseline rows 0. Test: cargo nextest for the 4 crates.

#### p10-stability-157 Panic deny: optchat-chief + chief-turn
- Files: Native/OptChat/optchat-chief/src/**, Native/OptChat/chief-turn/src/**
- Change: as 120 for the Home Chief brain host (61k lines); split per folder by the 210 generator.
- Acceptance: extra-baseline rows 0. Test: cargo test in Native/OptChat on Testbox; chief-*-live.py in the test phase.

#### p10-stability-158 OptChat threads supervised + SAFETY
- Files: Native/OptChat/optchat-chief/src/**, Native/OptChat/optchat-core/src/**
- Change: 52 thread spawns under cmux_panic_log::supervise (path dependency) or `supervise-allow:`; SAFETY comments on its
  50 unsafe blocks.
- Acceptance: scanner spawn kind 0 and undocumented_unsafe 0 for these crates. Test: cargo test on Testbox.

#### p10-stability-159 DiffSidecar panic deny + fuzz target
- Files: Native/DiffSidecar/src/**, Native/DiffSidecar/fuzz/**
- Change: Remove deny hits (157 unwrap/expect lines, 6 panics, incl. tests); add a fuzz target for its request decoder and
  diff parser in its own fuzz dir and lock.
- Acceptance: row 0; fuzz target builds; DiffSidecar/Cargo.lock unchanged. Test: cargo test; rust-fuzz.sh 10 min.

#### p10-stability-160 cmux-mobile-host panic deny + supervised spawns
- Files: cmux-next-ios/rust/crates/cmux-mobile-host/src/**
- Change: Typed errors (a bad phone frame closes that phone only, 178 pattern); every spawn supervised or handle kept;
  split per folder by 210.
- Acceptance: row 0; scanner spawn kind 0 for the crate. Test: cargo test -p cmux-mobile-host; CmuxNextMobileHostTests.

#### p10-stability-161 forbid(unsafe_code) in 39 crates
- Files: src/lib.rs or main.rs of cmux-agent-pane-policy, cmux-api-compat, cmux-app-manifest, cmux-build-identity,
  cmux-chat-index, cmux-chief, cmux-cloud-cli, cmux-cloud-wire, cmux-conversation, cmux-feed-core, cmux-focus-core,
  cmux-history, cmux-layout-reducer, cmux-local-auth, cmux-mobile-core, cmux-mobile-ffi, cmux-panic-log, cmux-rd-core,
  cmux-rd-engine, cmux-rd-proto, cmux-relay, cmux-remote-browser-testhost, cmux-remote-browser, cmux-remote-protocol,
  cmux-remote-transcript, cmux-server-core, cmux-tasks-core, cmux-tasks, cmux-terminal-iface, cmux-terminal-sizing,
  cmux-theme-tokens, cmux-transport, cmux-tui-cdp, cmux-tui-cloud-conversations, cmux-tui-machine-agent-protocol,
  cmux-tui-machine-protocol, cmux-tui-remote-access, cmux-unix-socket, cmux-weft (re-derive the list at the task's SHA)
- Change: Add `#![forbid(unsafe_code)]` to each crate root (FFI-input crates via 153).
- Acceptance: Each root has the attribute; nothing else changes. Test: cargo check --workspace on Testbox.

#### p10-stability-162 CEF shim hardening + sanitizer variant
- Files: scripts/cmux-next/build-cef-shim.sh, Packages/macOS/CmuxNext/CEFShim/src/**, scripts/cmux-next/stability-settings.json
  (cSettings for CmuxNextMallocZone, CmuxNextRemoteLayer)
- Change: Add -Wall -Wextra -Wunsafe-buffer-usage (warnings, queue Q22), -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST,
  -ftrivial-auto-var-init=pattern, -fstack-protector-strong, -fno-delete-null-pointer-checks; CMUX_CEF_SHIM_SANITIZE=
  address|thread|undefined builds an instrumented shim under a separate cache key for lab apps; write a warning count
  file per build.
- Acceptance: Cache key includes flags; a sanitizer shim never enters a Release or nightly bundle (checked like bench hooks).
- Test phase: fleet shim build; CEF browser suites; ASan app smoke with the instrumented shim.

#### p10-stability-163 CEF shim unsafe-buffer queue to 0
- Files: Packages/macOS/CmuxNext/CEFShim/src/**, scripts/cmux-next/build-cef-shim.sh
- Change: Fix each warning with std::span, checked accessors, or `UNSAFE_BUFFERS(...)` + `// SAFETY:`; then make
  -Werror=unsafe-buffer-usage the default.
- Acceptance: Warning file 0; every UNSAFE_BUFFERS has a SAFETY line. Test: CEFShim/tests + CmuxNextBrowserTests +
  child-crash-e2e.

#### p10-stability-164 GPU crash loop must not FATAL cmux
- Files: scripts/cmux-next/process-chaos-e2e.py, Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift,
  plans/cmux-next/cef-helper-app-DESIGN.md
- Change: Chaos case `gpu-crash-loop`: SIGKILL the GPU helper 12 times in 60 s. Until F2: a CEF fork patch (or switch) that
  turns the final FallBackToNextGpuMode step into GPU-off (crash page) instead of
  IntentionallyCrashBrowserForUnusableGpuProcess; comment cites gpu_data_manager_impl_private.cc. Coordinate with PL-cefhost.
- Acceptance: Chaos case reports app pid unchanged/changed; the patch reference or switch exists with the citation.
- Test phase: `process-chaos-e2e.py --only gpu-crash-loop` on bare metal.

#### p10-stability-165 GhosttyKit ReleaseSafe lab variant
- Files: scripts/ensure-ghosttykit.sh, scripts/reload.sh, Packages/Shared/CmuxGhosttyKit/Package.swift
- Change: `--variant safe` (-Doptimize=ReleaseSafe, separate cache key); reload.sh --config asan|tsan|ubsan selects it.
- Acceptance: Shipped configs refuse it; the variant is in the build identity. Test: fleet asan build + VM fuzz 15 min on 26.

#### p10-stability-166 objc_raises class + checked helpers
- Files: scripts/cmux-next/crash_ratchet.py, scripts/cmux-next/crash-safety-report-baseline.json,
  scripts/cmux-next/tests/crash-ratchet-v2.test.sh, Packages/macOS/CmuxNext/Sources/CmuxNextCompat/CheckedFoundation.swift
- Change: Report-only class objc_raises: `JSONSerialization.data(withJSONObject` without isValidJSONObject on the line or
  above; legacy FileHandle availableData/seekToEndOfFile()/write(Data)/readData(ofLength:); NSRange APIs (substring(with:,
  attributedSubstring(from:, attribute(..at:, replaceCharacters(in:, addAttribute(..range:, character(at:). Helpers
  CheckedJSON.data(_:) throws, NSString.checkedSubstring(_:), range clamps that return nil (never silently clamp).
- Acceptance: `--report objc_raises` emits Q19; CI-read baseline unchanged; tests per pattern and guard exemption.
- Test phase: crash-ratchet-v2.test.sh; CmuxNextCompatTests.

#### p10-stability-167 objc_raises: JSONSerialization (160)
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextAgentPane,CmuxNextApp,CmuxNextMobile,CmuxNextHomeEngine,CmuxNextBrowser,
  CmuxNextCloud,CmuxNextDaemon,CmuxNextPages}/**, Packages/iOS/CmuxMobileRPC/Sources/**
- Change: CheckedJSON.data or Codable JSONEncoder; failure goes to the caller's typed error path.
- Acceptance: JSON subrow 0 in these modules. Test: module suites.

#### p10-stability-168 objc_raises: legacy FileHandle (23)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/{AgentPaneLineReader,AgentPaneShell,
  AgentPaneShellCompletionProcess}.swift, CmuxNextCloud/Process/ChildProcess.swift, CmuxNextDiff/DiffSidecarProcess.swift,
  CmuxNextMobile/MobileHost/MobileHostProcess.swift, CmuxNextNowPlaying/MediaRemoteAdapter.swift,
  CmuxNextPhone/{PhoneProcess,Android/AndroidScreenStream}.swift, CmuxNextRemote/{AddMachine/HostCLI,SSH/SSHRunner}.swift,
  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Compose.swift (re-derive at the task's SHA)
- Change: `try handle.read(upToCount:)` in readabilityHandler (an error ends that reader with a typed error);
  `try seekToEnd()`, `try write(contentsOf:)`.
- Acceptance: `git grep -n -E 'availableData|seekToEndOfFile\(\)|readData\(ofLength' -- 'Packages/**/Sources'` = 0.
- Test phase: suites; chaos kill of each child during output.

#### p10-stability-169 objc_raises: NSRange in MessagesLabHome (104)
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/**
- Change: Route each range-taking call through the checked helpers or prove the range on the same line (from the same
  string's length).
- Acceptance: range subrow 0 in the module. Test: Home render fuzz (028) + suites.

#### p10-stability-170 objc_raises: NSRange in App, Design, AgentPane, ErrorJournal, rest
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextApp,CmuxNextDesign,CmuxNextAgentPane,CmuxNextErrorJournal,CmuxNextUpdater,
  CmuxNextHomeEngine,CmuxNextBrowser}/**
- Change: as 169 (App 40, Design 29, AgentPane 21, ErrorJournal 19, rest); split per module if over 400 lines.
- Acceptance: range subrow 0 in these modules. Test: suites.

#### p10-stability-171 Delete private resume-once helpers
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/AgentActivityLineConnection.swift,
  CmuxNextAgentPane/{AcpmuxVersionHandoff,AgentPaneResumeOnce}.swift, CmuxNextApp/BrowserProfiles/AgentBrowserProfile.swift,
  CmuxNextApp/Server/ServerHelperClient.swift, CmuxNextBrowserAutomation/CallDeadline.swift,
  CmuxNextBrowserHistory/BrowserHistoryWriter.swift, CmuxNextDaemon/Launch/DaemonVersionHandoff.swift,
  CmuxNextHomeEngine/PageCallDeadline.swift, CmuxNextMobile/DaemonLane/ResumeOnce.swift,
  Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateDriver.swift,
  Packages/Shared/CmuxVNC/Sources/CmuxVNCDemoServer/VNCDemoServer.swift
- Change: Replace the 12 copies with OnceContinuation (cancellation semantics kept per site) and delete them.
- Acceptance: `git grep -n -E '(class|struct) (ResumeOnce|Once|OnceBox|ResumeGuard|InstallOnce|AgentPaneResumeOnce)\b' --
  'Packages/**/Sources'` = 0. Test: module suites.

#### p10-stability-172 Portable Mutex in CmuxSafeConcurrency
- Files: Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/Mutex.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Mutex.swift,
  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/OSAllocatedUnfairLock+Portable.swift
- Change: os_unfair_lock Mutex with the Synchronization API in CmuxSafeConcurrency (macOS 14 / iOS 17); CmuxNextCompat.Mutex
  wraps the same storage and keeps its main-thread lock-wait detector as an injected observer; CMUXMobileCore's lock
  forwards to it. Creates the package skeleton that 083 extends.
- Acceptance: `git grep -l 'os_unfair_lock_lock' -- Packages` lists only CmuxSafeConcurrency; CmuxNext call sites unchanged.
- Test phase: CmuxSafeConcurrency tests + CmuxNextCompatTests under TSan.

#### p10-stability-173 write_important (ImportantFileWriter)
- Files: cmux-tui/crates/cmux-tui-util/src/important_file.rs, cmux-tui/crates/acpmux/src/{catalog/mod.rs,hand/fsops.rs},
  cmux-tui/crates/cmux-host/src/{linux/identity.rs,team_ssh/store.rs}, cmux-tui/crates/cmux-tasks/src/store/snapshot.rs,
  cmux-tui/crates/cmux-tui/src/link/machine_update/apply.rs
- Change: `write_important(path, bytes, mode)`: temp in the same dir, write, fsync, rename, fsync dir, typed error on full
  disk. Move the write_atomic copies onto it, then production state writes (Q25: acpmux 54, cmux-tui 23, core 15, remote 8);
  log/scratch writes stay with a reason. Split per crate if over 400 lines.
- Acceptance: 0 private write_atomic copies; each converted path in the diff. Test: nextest; chaos full-disk case (009).

#### p10-stability-174 State-corruption chaos lane
- Files: scripts/cmux-next/state-corruption-e2e.py, scripts/cmux-next/stability-lanes.json
- Change: From state-roots-baseline.tsv and the daemon data dir, for each file (settings JSON, journal/session SQLite,
  history SQLite, chat-index, run.json, output snapshots): truncate, flip random bytes, zero-length; relaunch the tagged
  build; check app and daemon start, the file is set aside as `*.corrupt`, a fault is counted, other state kept.
- Acceptance: One JSON row per (file, mutation); refuses non-tagged sockets; never touches the user's real state.
- Test phase: bare metal on a lab mini against the final tip.

#### p10-stability-175 SQLite error policy
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextHistory/HistorySQLite.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/ChiefAdoption+SQLite.swift, cmux-tui/crates/cmux-chat-index/src/**,
  cmux-tui/crates/cmux-tui-core/src/** (Connection::open sites)
- Change: Busy timeout on each open; on SQLITE_CORRUPT/NOTADB move the DB aside, recreate, report one fault; never trap or
  loop at startup.
- Acceptance: Each opener has the policy; a test opens a garbage file and gets a working store + one fault. Test: suites + 174.

#### p10-stability-176 Stateful daemon request fuzzer (MojoLPM analog)
- Files: cmux-tui/fuzz/fuzz_targets/mux_requests.rs, cmux-tui/crates/cmux-tui-core/src/server/test_harness.rs,
  cmux-tui/crates/cmux-tui-core/src/mux/fuzz_support.rs
- Change: `#[cfg(feature = "fuzzing")]` harness runs the request dispatcher on an in-memory store with no PTYs; `arbitrary`
  sequences of (method, params) from the cmux-api-compat schema with live, stale and bogus ids and wrong order; after each
  step, run layout invariants (layout_invariants_tests); each reply is a typed result or error.
- Acceptance: Covers every schema method (new methods picked up automatically); uses the real request types.
- Test phase: rust-fuzz.sh --target mux_requests --seconds 1800.

#### p10-stability-177 Stateful ControlRouter fuzz
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextControlTests/ControlRouterFuzzTests.swift
- Change: Commands from the registered action and socket schemas, random sequences with live/bogus ids, wrong types, huge
  strings, into ControlRouter with a fake daemon.
- Acceptance: Reply or typed error per command; no trap; no main-thread turn > 50 ms; replayable failing sequence.
- Test phase: CmuxNextControlTests on the fleet + long mode 10 min.

#### p10-stability-178 BadMessage API
- Files: cmux-tui/crates/cmux-panic-log/src/bad_message.rs, cmux-tui/crates/cmux-tui-core/src/server/,
  Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/BadMessage.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/LineTransport.swift
- Change: `report_bad_message(peer, reason)` / `BadMessage.report(peer:reason:)`: close only that peer, count the reason, one
  report per reason per launch. A bad daemon frame makes the app drop and reconnect the daemon connection; a bad socket
  client closes that client. Decode-failure branches route through it.
- Acceptance: Tests: a malformed frame closes only that connection; others keep working.
- Test phase: cargo nextest -p cmux-tui-core; CmuxNextDaemonTests.

#### p10-stability-179 Swift fuzz: AgentPane stream + page bridge
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentStreamFuzzTests.swift,
  Packages/macOS/CmuxNext/Tests/CmuxNextPagesTests/PageBridgeFuzzTests.swift
- Change: Event lines, partial JSON, wrong types, huge strings, out-of-order turns (AgentPane 79 decode sites; Pages 12
  WKScriptMessage sites).
- Acceptance: No trap; a bad message is dropped with a counted fault; the pane stays live. Test: suites + long mode 5 min.

#### p10-stability-180 Swift fuzz: CEF/CDP, appcast, cloud, auth
- Files: Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFMessageFuzzTests.swift,
  Packages/macOS/CmuxNext/Tests/CmuxNextUpdaterTests/AppcastFuzzTests.swift,
  Packages/macOS/CmuxNext/Tests/CmuxNextCloudTests/CloudReplyFuzzTests.swift, Packages/Shared/CmuxAuthRuntime/Tests/
- Change: Garbage, truncated, deeply nested input for Browser 67, Updater 17, Cloud 17, AuthRuntime 14 decode sites.
- Acceptance: No trap. Test: suites + long mode.

#### p10-stability-181 Rust fuzz batch 6
- Files: cmux-tui/fuzz/fuzz_targets/, cmux-next-ios/rust/fuzz/, Native/OptChat/fuzz/
- Change: cmux-browser-host cdp/evaluate and gate/fetch; cmux-app-host script/session; cmux-mobile-host frame decode;
  optchat-chief request and transcript parsing. Each separate workspace gets its own fuzz dir and lock.
- Acceptance: One target per decoder with a seed corpus. Test: rust-fuzz.sh 10 min per target.

#### p10-stability-182 Coverage-guided Swift libFuzzer (Linux)
- Files: Packages/Shared/CmuxFuzzSupport/LinuxFuzz/Package.swift, Packages/Shared/CmuxFuzzSupport/LinuxFuzz/Sources/*/main.swift,
  scripts/cmux-next/swift-libfuzzer.sh
- Change: `@_cdecl("LLVMFuzzerTestOneInput")` executables wrapping the 016 `oneInput` bodies for decoders that build without
  AppKit (CMUXMobileCore protocol, CmuxTerminalSizing, CmuxIrxTransport frames, CmuxVNC RFB messages, CmuxHomeCore wire,
  CmuxTerminalStream); built with the swift.org toolchain and `-sanitize=fuzzer,address` on Linux (macOS only after a check
  that the toolchain ships the runtime). A Darwin-only decoder is extracted into a Foundation-only target first or skipped
  with a reason. Reuses the 183 corpora.
- Acceptance: >= 6 coverage-guided targets; separate products, not shipped targets; refuses a person's Mac.
- Test phase: `swift-libfuzzer.sh --all --seconds 1800` on a Linux Testbox; edges > the random mode's run.

#### p10-stability-183 Fuzz corpus store, minimize, coverage
- Files: scripts/cmux-next/fuzz-corpus.py, scripts/cmux-next/rust-fuzz.sh, scripts/cmux-next/stability-lanes.json,
  Packages/Shared/CmuxFuzzSupport/Sources/CmuxFuzzSupport/Corpus.swift
- Change: One corpus per target in a fleet artifact path; each run pulls, fuzzes, merges (`-merge=1` / `cargo fuzz cmin`),
  pushes back; weekly `cargo fuzz coverage` / llvm-cov edges per target; flat coverage over 3 runs -> fuzzer-quality issue;
  each crash input becomes a small checked-in regression file next to its fix.
- Acceptance: A run starts from the stored corpus (log shows the count); no checked-in corpus file > 64 KiB.
- Test phase: two consecutive `rust-fuzz.sh --seconds 120` runs; the second loads the first's corpus.

#### p10-stability-184 Fork safety: pre_exec
- Files: cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime/unix/{adopted_child,adopt_launch}.rs,
  cmux-tui/crates/cmux-tui-core/src/{git_ops/user_run,apps/host}.rs, cmux-tui/crates/cmux-tui/src/{remote_host/service,
  local_owner/install_key,link/ensure,cli/chief/launch,bin/cmux-tui-hook}.rs, cmux-tui/crates/acpmux/src/{daemon/router_owner/fifo,
  daemon/lock,cli/cli_agent,agent_host/link}.rs, pre_exec sites in cmux-remote, cmux-host, cmux-pane-protocol,
  cmux-browser-host, cmux-app-host, cmux-mux2
- Change: Each closure uses only async-signal-safe libc calls (no allocation, format!, locks, logging), or moves to
  posix_spawn attributes (setsid, setpgid, signal defaults).
- Acceptance: `async-blocking-scan --kind pre_exec` = 0 in production. Test: nextest for touched crates; spawn bench unchanged.

#### p10-stability-185 Child reaping
- Files: cmux-tui/crates/*/src/** (scanner kind child hits)
- Change: Every spawned Child is awaited/waited, stored with its owner, or kill_on_drop; std Child gets a reaper.
- Acceptance: `--kind child` = 0 in production. Test: nextest; readiness-soak zombie count 0.

#### p10-stability-186 Bounded queues
- Files: cmux-tui/crates/{acpmux,cmux-tui,cmux-tui-core,cmux-host,cmux-wg,cmux-browser-host,cmux-app-host,cmux-mux2,
  cmux-config}/src/** (scanner kind unbounded hits)
- Change: Bounded with a stated overflow policy (drop-oldest + counter, coalesce, backpressure), or
  `// unbounded-allow: <bound by construction>`. Split per crate if over 400 lines.
- Acceptance: `--kind unbounded` = 0 unreasoned. Test: nextest; STRESS soak memory slope.

#### p10-stability-187 cmux-lock-rank shared crate
- Files: cmux-tui/crates/cmux-lock-rank/**, cmux-tui/crates/cmux-tui-core/src/lock_rank.rs
- Change: Move RankedMutex/rank checks into a small crate (added to the lock in 101's commit); cmux-tui-core re-exports;
  behavior unchanged.
- Acceptance: cmux-tui-core tests unchanged and green. Test: nextest -p cmux-tui-core -p cmux-lock-rank.

#### p10-stability-188 Lock ranks: acpmux
- Files: cmux-tui/crates/acpmux/src/** (Q23 hits for long-lived hub/session locks)
- Change: Rank the long-lived locks; a debug test detects an inversion.
- Acceptance: Long-lived hub/session locks ranked. Test: nextest -p acpmux.

#### p10-stability-189 Lock ranks: cmux-tui
- Files: cmux-tui/crates/cmux-tui/src/** (Q23 hits)
- Change/Acceptance: as 188. Test: nextest -p cmux-tui.

#### p10-stability-190 unsafe impl Send/Sync review (21)
- Files: cmux-tui/crates/*/src/** (`git grep 'unsafe impl (Send|Sync)'`)
- Change: SAFETY argument naming the synchronization, or a type that is Send/Sync by construction; Miri or loom test for
  pure-Rust sites.
- Acceptance: Each remaining site has SAFETY + a test reference. Test: Miri lane (014).

#### p10-stability-191 Regex input bounds (ReDoS)
- Files: Packages/macOS/CmuxNext/Sources/{CmuxNextApp,CmuxNextErrorJournal,CmuxNextHome,CmuxNextBrowserCore,
  CmuxNextAgentPane}/** (regex sites), Packages/Shared/CmuxSentryTelemetry/Sources/CmuxSentryScrubbing/**,
  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/**
- Change: Cap input length per site or replace the regex with a linear scanner (Chrome uses RE2); time-budget fuzz case.
- Acceptance: Each site has a bound or scanner; scrubber budget test (no match > 10 ms on 64 KiB adversarial input).
- Test phase: suites + fuzz long mode.

#### p10-stability-192 Geometry re-entrancy guard (Crash D class)
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Diagnostics/GeometryReentrancyGuard.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Diagnostics/LayoutPassGuard.swift
- Change: Per-thread depth guard (base::AutoReset + DCHECK(!in_x_) pattern) for viewDidChangeBackingProperties,
  setFrameSize, setBoundsSize, layout, resizeSubviews; in Debug and lab builds depth > 8 reports once with the view class and
  stops the recursion; compiled out of Release.
- Acceptance: Zero Release cost; a self-recursive view test reports once without overflow.
- Test phase: CmuxNextDesignTests; VM fuzz canvas zoom seeds.

#### p10-stability-193 Private API lookups probed per macOS
- Files: scripts/cmux-next/check-objc-selectors.py, scripts/cmux-next/objc-selector-table.json
- Change: Extend to NSClassFromString/NSSelectorFromString/dlsym (94 lines), value(forKey:)/setValue(forKey:) on framework
  objects, swizzles; each needs a nil or responds(to:) guard; `--probe` records presence on 14/15/26/27 in the VM smoke.
- Acceptance: Unguarded lookup refused in the local tier; probe table per major. Test: os-matrix smoke --probe on all 4.

#### p10-stability-194 Webview page error boundary
- Files: webviews/src/ui/PageErrorBoundary.tsx, webviews/src/pages/**/main.tsx (every createRoot)
- Change: Shared boundary: reload card, report through ConsoleErrorCapture, one automatic reload (sad tab).
- Acceptance: Every non-test createRoot under webviews/src/pages wraps PageErrorBoundary; `bun run check` passes.
- Test phase: gallery entry with a throwing fixture; bun test.

#### p10-stability-195 Lab signatures for non-crash failures
- Files: scripts/cmux-next/crash_signature.py, scripts/cmux-next/stability-lab.py
- Change: Kinds: page JS errors, ErrorJournal faults, Invariant events, Rust hang JSONL, slow polls, BadMessage reasons.
- Acceptance: Fixtures give stable hashes per kind. Test: pytest.

#### p10-stability-196 Lab lanes: update, skew, restore
- Files: scripts/cmux-next/stability-lanes.json, scripts/cmux-next/stability-lab.py
- Change: update-e2e.py (newest nightly-next -> tip with live terminals and an agent turn), skew-matrix.py (CLI N vs daemon
  N+-1), restore-journey.py as fast lanes on one lab mini.
- Acceptance: Lanes declared with host class and minutes; failures become signatures. Test: one live tick.

#### p10-stability-197 Checked arithmetic in wire decoders
- Files: cmux-tui/crates/{cmux-pane-protocol,cmux-remote-protocol,cmux-rd-proto,cmux-transport,cmux-link}/src/**,
  cmux-tui/crates/cmux-holder/src/wire.rs, cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime/shared/codec.rs
- Change: arithmetic_side_effects and cast_possible_truncation to 0 in these paths with checked_*/try_from returning the
  decode error (release has overflow checks off). Split per crate.
- Acceptance: Both report-only lints 0 in the listed paths. Test: nextest + fuzz 017/018.

#### p10-stability-198 Package.swift settings lander
- Files: scripts/cmux-next/stability-settings.json, scripts/cmux-next/apply-stability-settings.py,
  scripts/cmux-next/tests/test_apply_stability_settings.py, Packages/macOS/CmuxNext/Package.swift, closure Package.swift files
- Change: Implementers add {package, target, setting} rows; the lander applies them every few hours in one commit (also bumps
  a Shared manifest to tools 6.2 when a setting needs it) and compile-checks on the fleet.
- Acceptance: Idempotent (second run no diff); only lander commits change p10 settings.
- Test phase: pytest for the rewriter; fleet compile-check of each lander commit.

#### p10-stability-199 Local-only rule tier + report-only baselines
- Files: scripts/cmux-next/prepush-gate.py, scripts/cmux-next/guardrails.py, scripts/cmux-next/crash_ratchet.py,
  scripts/cmux-next/rust_panic_ratchet.py
- Change: Rules tagged local_only run in the hook and plain runs only (skipped under GITHUB_ACTIONS and `--commits`);
  crash_ratchet/rust_panic_ratchet read report-only baselines (`*-report-baseline.json`, `rust-panic-extra-baseline.json`)
  only with `--report`, never in the compare mode CI runs.
- Acceptance: A test runs prepush-gate with GITHUB_ACTIONS=true and `--commits` and shows no local_only rule ran;
  crash-safety-baseline.json and rust-panic-baseline.json gain no rows from p10.
- Test phase: `python3 -I -m pytest` for prepush-gate and guardrails self-tests.

#### p10-stability-200 Tart image replication + dedicated lab hosts
- Files: scripts/fuzz/macos-matrix/images.json, scripts/fuzz/macos-matrix/MATRIX.md, cmuxterm-hq: build-fleet controller Tart
  host list
- Change: Copy golden 14/15/26/27 images to the M6 minis cmux15-24 except cmux20 and one more aws-m4pro-5..9 host (check
  disk first); tag them `stability-lab`; 2 VMs per host; scheduling only through cmux-ci (never maclease).
- Acceptance: `os-matrix.sh --os 14,15,26,27` runs 4 VMs at once on different hosts; images.json lists cached majors.
- Test phase: os-matrix smoke on all 4 with parallel placement in the receipt.

#### p10-stability-201 MallocProbGuard sampling
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Launch/DaemonLaunchEnvironment.swift, scripts/fuzz/macos-matrix/vm.sh
- Change: Verify libmalloc honors MallocProbGuard=1 on 14/15/26/27; on a sampled 5 % of Nightly launches set it for the Rust
  daemons (system malloc); .ips forwarded by the existing path; `--diag probguard` for the Chromium-off app.
- Acceptance: Off in Release and RC; sample rate is a commented constant; env only on child launches.
- Test phase: VM `--diag probguard` 15 min; a debug daemon heap overflow test gets a ProbGuard report.

#### p10-stability-202 nightly-assert variant
- Files: Packages/Shared/CmuxSafeConcurrency/Sources/CmuxSafeConcurrency/Invariant.swift, scripts/reload.sh,
  cmuxterm-hq: nightly build config
- Change: INVARIANT_REPORT flag for an -O build: debug checks and converted assert() sites report once per site per launch;
  a sampled slice of Nightly gets it.
- Acceptance: Release and RC refuse the flag; one event per site per launch (test).
- Test phase: package tests; one nightly-assert build on the fleet.

#### p10-stability-203 Unclean-exit metric
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextApp/Crash/CrashRecoveryService.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/UncleanExitReport.swift, scripts/cmux-next/stability-health.py
- Change: At launch send the previous AppRunMarker outcome (clean, crash-caught, unclean-no-report, signal, exception) as one
  consented, scrubbed event; stability-health reports unclean exits per 1k sessions.
- Acceptance: No data without consent; a SIGKILLed run shows as unclean-no-report next launch.
- Test phase: bare metal kill -9 a tagged build, relaunch, one event; pytest.

#### p10-stability-204 ShutdownBehavior + quit-storm lane
- Files: cmux-tui/crates/cmux-panic-log/src/supervise.rs, scripts/fuzz/macos-matrix/chaos.py
- Change: ShutdownBehavior (Continue, Skip, Block with deadline) required on every supervise call; quit-storm faults: Cmd-Q
  during page load, typing, daemon restart, split animation, then relaunch; any cmux/daemon/acpmux .ips fails.
- Acceptance: Every supervise call names a policy; one result.json row per quit fault.
- Test phase: os-matrix chaos on 26 and 27; nextest -p cmux-panic-log.

#### p10-stability-205 Classify trap/panic sites
- Files: scripts/cmux-next/crash_ratchet.py, scripts/cmux-next/rust_panic_ratchet.py, scripts/cmux-next/trap-classes.json
- Change: `--classify`: input-reachable if in or called from a Q14 decode entry point (same file or callee, call-graph proxy)
  or reading peer/file bytes; else invariant. The ratchet refuses a lowered notFatalUntil build number (local tier).
- Acceptance: Every hit has exactly one class in `--report`; rules in the docstrings.
- Test phase: crash-ratchet-v2.test.sh with fixtures for both classes; Rust fixture test.

#### p10-stability-206 Lab clippy disallowed-methods config
- Files: cmux-tui/lab/clippy/clippy.toml, cmux-tui/crates/cmux-blocking/src/lib.rs
- Change: disallowed-methods for std::fs::*, std::thread::sleep, std::process::Command::{output,status},
  std::sync::mpsc::Receiver::recv, std::sync::Condvar::wait, each naming its cmux-blocking wrapper; allowed inside
  cmux-blocking. Used only with `CLIPPY_CONF_DIR=cmux-tui/lab/clippy` in the lab Q10 run.
- Acceptance: No workspace clippy.toml and no Cargo.toml change; CI clippy unchanged.
- Test phase: lab Q10 run prints disallowed_methods counts per crate.

#### p10-stability-207 Crash keys
- Files: Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/CrashKeys.swift,
  Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/CrashKeySlots.swift, cmux-tui/crates/cmux-panic-log/src/crash_keys.rs
- Change: Preallocated fixed-size slots written with atomics (action id, pane kind, CEF state, daemon epoch, hung thread ids),
  read by the crash handler and hang reporters with no allocation; wired into the action pipeline and hang scopes.
- Acceptance: No allocation or lock in the read path (test under a malloc-forbidden check); values scrubbed.
- Test phase: crash-ends-app-gate.py shows keys in a forced crash report; package tests.

#### p10-stability-208 Rule of 2: inventory + sandboxed browser import
- Files: plans/cmux-next/rule-of-2.md, Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImportService/**,
  Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/**, scripts/cmux-next/stability-settings.json
- Change: Inventory every untrusted parser (language, sandbox, trust); move foreign-profile parsing (SQLite, plist, JSON
  Preferences, cookie blobs) into a sandboxed XPC service (no network, read-only user-selected profile) returning Sendable
  values; the app keeps the merge. VNC decode is the next candidate (documented). Split: service skeleton, then parsers.
- Acceptance: The app target no longer links SQLite for import; service entitlements are sandbox + read-only selected file;
  import results unchanged.
- Test phase: browser import tests + fuzz 025 against the service.

#### p10-stability-209 macOS Q10 clippy run + merge
- Files: scripts/cmux-next/rust_panic_ratchet.py, scripts/cmux-next/rust-panic-macos.sh
- Change: A macOS fleet step runs the Q10 clippy (`cmux-ci run --class isolated`); `--clippy-json` accepts several files and
  dedupes by file:line, so cfg(target_os = "macos") code is counted.
- Acceptance: Merged report lists macOS-only hits; CI behavior unchanged. Test: one fleet run.

#### p10-stability-210 Rust panic queue generator
- Files: scripts/cmux-next/rust_panic_ratchet.py, scripts/cmux-next/tests/test_rust_panic_queue.py
- Change: `--queue` turns the merged Q10 JSON into tasks of one file or a file group <= 50 hits, with crate, module, owner
  (OWNERS.md), class (205) and the error type at the nearest boundary.
- Acceptance: Every hit is in exactly one task; no task > 50 hits. Test: pytest with a fixture JSON.

#### p10-stability-211 strictMemorySafety on everywhere + SAFETY-TODO fix-its
- Files: scripts/cmux-next/apply-unsafe-fixits.py, scripts/cmux-next/stability-settings.json, scripts/cmux-next/guardrails.py,
  Packages/**/Sources (machine edits only)
- Change: Per package, the lander turns on `.strictMemorySafety()` (warning), runs swift-diagnostics `--fixits-out` on the
  fleet and applies the compiler's `unsafe` fix-its by machine, adding `// SAFETY-TODO(p10)` above each. Local-only
  guardrail refuses an added SAFETY-TODO(p10). A conflict is resolved by rerunning the script on the new tip.
- Acceptance: Source edits are only `unsafe` insertions and TODO comments (`git diff -U0 | grep '^+' | grep -v -E
  'unsafe|SAFETY-TODO'` shows only manifest lines); every closure target has the setting; diagnostics StrictMemorySafety = 0
  after the pass.
- Test phase: fleet compile-check (`cmux-ci build cmux --ref SHA`); Q04 count recorded.

### Post-push (not in the 72 h task count)
- 080 concurrency diagnostic groups as errors on one pinned toolchain (Q05).
- 149 CmuxMobileLinkFFI seam module and NotificationService Swift 6.
- VNC decode into a sandboxed service (208 follow-up).
