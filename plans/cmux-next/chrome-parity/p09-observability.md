# p09-observability: Chrome-grade observability for cmux-next (final spec)

Status: final, after the fixer pass over 3 adversarial reviews. Base: `/Users/lawrence/fun/wt/chrome-parity`
at `772cdfc45ac` (branch `perf/chrome-parity`, at `origin/feat-cmux-next`). All counts below come from `rg`
in that checkout on 2026-10-25, unless a line says otherwise.

The program has six parts:

1. **Trace points that stay on in Release.** One catalog, one clock (`CLOCK_UPTIME_RAW` ns), one 32-byte
   record format shared by Swift, Rust and C. Writers use per-thread chunks with no lock and no allocation.
   Every process has a crash-safe "black box". Recording starts and stops at run time through a socket call
   and `cmux trace`, with no env var and no relaunch.
2. **One cross-process Perfetto trace per key press (item 7).** The trace follows the key through app
   dispatch, the daemon, the PTY host or holder, the echo, about 12 thread handoffs, the app parse, Ghostty
   render, GPU completion, the CA commit and the estimated present. Each hop carries the exact flow id.
   Chromium's own trace joins it in Release.
3. **UMA-like field histograms.** A typed catalog with owners and expiry. Atomic log-linear buckets.
   Crash-safe mmap persistence per launch, with a system profile per file and delta upload. Histograms also
   come from the daemon and from Chromium's own `StatisticsRecorder`. Stability counts have denominators.
4. **A HangWatcher in Release** for every process and every must-not-block thread. This includes Ghostty
   renderer threads, tokio workers and Chromium's IO and pool threads. It adds 0 wakeups at idle.
5. **A crash report for every process.** Every shipped binary has crash keys, the black-box tail and
   symbolicated frames. Fatal hangs are reported at the next launch. An e2e crash matrix and hang matrix
   prove it.
6. **Privacy by construction.** Records hold only catalog names and numbers. Per-key timing never leaves the
   Mac. A visible indicator shows while a recording runs.

---

## 1. Chrome reference

Header paths marked [read] were fetched from chromium.googlesource.com on 2026-10-25. The other paths are
from memory and are not checked. Where cmux differs from Chrome, the reason is written next to it.

### Tracing
- `base/trace_event/trace_event.h` [read]: the TRACE_EVENT macros (`common/trace_event_common.h`) are built
  on the Perfetto SDK track-event data source (`base::TrackEvent`, `perfetto/tracing/track.h`,
  `track_event_args.h`). Every call site reads a per-category enabled flag (`category_group_enabled`).
  When the category is off, a trace point costs one load and one branch. `base/trace_event/builtin_categories.h`
  registers the categories statically. Flows link slices across threads and processes
  (`perfetto::Flow::ProcessScoped`, `perfetto::TerminatingFlow`). Slices that cross threads or overlap use
  async tracks (`TRACE_EVENT_NESTABLE_ASYNC_BEGIN0` with an id, or `perfetto::Track(uuid)`).
- Perfetto buffers (perfetto.dev/docs/concepts/buffers): each thread has its own `TraceWriter`, which
  writes into its own chunk of the shared memory buffer. Threads do not contend on the hot path.
  **cmux copies this** (tasks 003, 009): a writer claims a 32-slot chunk (1 header + 31 records) with one
  `fetch_add`, then writes records with no atomics other than the per-slot publish.
- Clock: on macOS `base::TimeTicks` is `mach_absolute_time` (`base/time/time_mac.mm`), which is the same
  clock as `CLOCK_UPTIME_RAW`. Perfetto merges clock domains with `ClockSnapshot` packets.
- Field recording: `content/browser/tracing/background_tracing_manager_impl.h` [read]. Scenarios and named
  triggers run ring-buffer recordings and keep or upload them after a trigger. Metadata is filtered for
  privacy (`GenerateMetadataProto`).
- Task tracing: every `PostTask` carries `FROM_HERE`, and `TaskAnnotator` draws a flow from the post to
  the run. `docs/threading_and_tasks.md` [read]: the priorities are USER_BLOCKING > USER_VISIBLE >
  BEST_EFFORT. `base/threading/scoped_blocking_call.h` marks blocking regions.

### Input to frame
- `cc/metrics/event_metrics.h` [read]: each input event has a timestamp for each dispatch stage
  (kGenerated ... kRendererMainFinished) and a `ui::LatencyInfo` trace id.
  `cc/metrics/compositor_frame_reporter.cc` closes the event at `gfx::PresentationFeedback` and records
  how good the timestamp is (kVSync, kHWClock). It emits `EventLatency` slices and `EventLatency.*` UMA for
  every input type (KeyPressed, MousePressed, GestureScroll...), and keeps only events that caused a
  frame update.
- `cc/metrics/frame_sequence_tracker.h`: expected frames against produced frames, per sequence type
  (scroll, animation, ...). `Graphics.Smoothness.PercentDroppedFrames*`.
- `content/browser/scheduler/responsiveness/calculator.h` [read]: measures execution time and
  queue-plus-execution time apart, finds congested intervals, reports about every 30 s with startup-stage
  suffixes, emits `Browser.MainThreadsCongestion`, and marks the slices in Perfetto.
- `components/startup_metric_utils`: classifies each start as cold, warm or lukewarm from its hard-fault
  count. From memory (not checked): on macOS the source is `task_info(TASK_EVENTS_INFO).pageins`, it is
  sampled at message-loop start, and the thresholds are warm < 5 and cold >= 3500.

### UMA
- `base/metrics/histogram_macros.h`: static bucket layouts and lock-free recording.
- `tools/metrics/histograms/*.xml`: every histogram has owners, units, a summary and `expires_after`.
- `base/metrics/persistent_histogram_allocator.h` [read]: `GlobalHistogramAllocator::CreateWithFile`.
  Histograms survive the process. Child processes record into shared memory that the browser merges.
  `components/metrics/persistent_histograms.cc` (from memory): each file has an embedded system profile,
  and the browser renames a spare file (`BrowserMetrics-spare.pma`) that it made at low priority. The
  file is not created on the startup path.
- `components/metrics/metrics_service.h` uploads deltas (`HistogramSnapshotManager`), so each sample is
  sent once. `components/metrics/clean_exit_beacon.h` and `stability_metrics_helper.h` count unclean
  sessions, with launches as the denominator (`Stability.Counts2`).

### Hangs
- `base/threading/hang_watcher.h` [read]: one watcher per process, on its own thread.
  `RegisterThread(kMainThread | kIOThread | kThreadPoolThread | kCompositorThread)`. `WatchHangsInScope` is
  RAII, its default is 10 s, and scopes nest. The deadline and flags share one atomic uint64
  (`HangWatchDeadline`). `ThreadControllerWithMessagePumpImpl` opens a scope for each work item.
  `Monitor()` → `RecordHang()` → `base::debug::DumpWithoutCrashing`. `BlockIfCaptureInProgress`,
  `InvalidateActiveExpectations()`. The watcher wakes every 10 s and has a drift tolerance
  (`kWaitDriftTolerance` 100 ms) so that a late watcher does not blame a thread. **cmux differs:** its
  watcher parks while nothing runs (rule I3), because of the idle target of <= 1 wake/s.
- `gpu/ipc/service/gpu_watchdog_thread.h` watches the GPU main thread.

### Crashes
- Crashpad runs its handler outside the crashing process, with one handler for every process type
  (`components/crash/core/app/crashpad.h`).
- `components/crash/core/common/crash_key.h` [read]: static-storage name and value pairs that the handler
  reads from the dead process. Writing a key costs a store, not an allocation.
- `base/debug/dump_without_crashing.h`: soft invariants (`DUMP_WILL_BE_CHECK`) report in the field and do
  not crash.
- `content/public/browser/child_process_termination_info.h`: a renderer crash shows a sad tab, and the
  browser keeps running.

---

## 2. cmux today (counts at `772cdfc45ac`)

### Trace points
- Release trace points are signposts (`Sources/CmuxNextSignposts`, 15 files). `SignpostName` has 17
  cases. 9 of them are reserved and have no emitter: motion.frame, motion.run, switch.workspace,
  switch.tab, switch.pane_focus, create.tab, create.workspace, cef.pump and cef.create_browser. The
  `launch` category has no names.
- 6 files make their own `OSSignposter`: TerminalTimings, DaemonLaunchTimings, AgentPaneLaunchTimings,
  DebugTimings, DebugTabSwitch and DebugPaneFocus.
- 227 Logger sites. 11 of them use a subsystem other than `com.cmuxterm.app.next`.
- On every key, `KeyFrameSignpost.begin` builds a String with `String(format:)`.
- perf-hot: `scripts/cmux-next/perf-hot-benches.json` has **15** path ids (the design draft said 14; it
  missed workspace-switch and action-budget). Most ids have no Release trace point.
- Clocks are mixed: 63 CACurrentMediaTime, 117 `ContinuousClock.now` (369 lines name `ContinuousClock`),
  34 `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, and 44 Date()/CFAbsoluteTimeGetCurrent duration sites in 36
  files. **On Darwin, ContinuousClock counts system sleep. UPTIME_RAW does not.**
- `CmuxNextCompat/Atomic.swift` wraps `UnsafeAtomic<Value>.create` (heap storage) and has no `@inlinable`
  member. So "one relaxed load" is a cross-module call today, and the atomic cannot live in an mmap page.

### Cross-process trace
- `scripts/cmux-next/trace.py` merges xctrace, `log stream` signposts, watchdog stalls, daemon spans,
  Chromium CDP and key flows. Key flows need `CMUX_NEXT_TRACE_FLOWS` at launch
  (`TypingLatencyProbe.shared` is a static let, TypingLatencyProbe.swift:37). Echo hops are joined by time
  windows. There is no renderer hop and no present hop.
- `TypingFrameProbe` adds a `setContents:` override to the IOSurfaceLayer class (class_addMethod,
  TypingFrameProbe.swift:24-26), and it stays for the life of the process.
- The Chromium trace exists only in DEBUG. `CefBeginTracing` is stock CEF API, and the in-repo shim
  (`Packages/macOS/CmuxNext/CEFShim/src/*.mm`) already includes CEF C++ headers. **No fork change is
  needed for Chromium tracing.**
- Rust: `cmux-flow-trace` (Vyukov ring with a 50 ms drain thread, enabled by env var) has 12 call sites.
  `debug_spans.rs` uses `Instant` only. There is no per-request span.
- `Command` (server.rs:731-733) derives only `Deserialize` (`tag = "cmd"`, kebab-case). Nothing can
  serialize a fixture, and strum is not a dependency.
- acpmux has 0 tracing spans (no `span!`, `info_span!` or `#[instrument]`); its uses are events only. It
  runs a tokio multi-thread runtime (acpmux/src/cli/entry.rs:49). Shipped tokio multi-thread runtimes: 4
  (acpmux entry.rs:49, cmux-tui remote_runtime.rs:212, link/mod.rs:146,
  cloud_conversations_backend.rs:51).
- The echo path has about 12 thread handoffs (ghostty-integration-DESIGN.md, "Key to frame").
- 197 unnamed `thread::spawn(` sites in non-test code of the shipped crates.

### Field metrics
- Opt-in Nightly hang reports (`diagnostics.hangReports`, schema 2, 64 KiB cap on the server). The daemon
  has in-memory log-linear histograms (`diagnostics.rs`) that are lost on a crash. Chromium records
  EventLatency, Smoothness and memory UMA in its own process, and nothing reads them.
- There is no catalog with owners or expiry, no crash-safe persistence, no stability denominators, and no
  field numbers for echo frames, dropped frames, congestion, idle wakeups, launch temperature, daemon
  latency, memory per process kind or webviews.

### Hangs
- `MainThreadWatchdog` (kqueue one-shot alarm, 0 idle wakeups) watches only the main thread. No Rust
  process has a hang watcher. Sentry's `appHangTimeoutInterval` is 8 s (CrashReporter.swift:52), and app
  hang tracking stays on. Chromium's own HangWatcher probably runs in the browser process with no dump
  handler (not measured).

### Crashes
- Sentry is in the app. Panic logs come only from the owner (owner_panic.rs:58) and the acpmux daemon
  (daemon.rs:63). These have no panic hook: holder, cmux-tui-host's own path, cmux-app-host,
  cmux-browser-host, acpmux `__agent-host`, `cmux mcp serve`, cmux-cloud
  (`first-party-apps/cloud/server`), optchat-chief (`Native/OptChat/optchat-chief`) and cmux-diff-sidecar
  (`Native/DiffSidecar`).
- The holder's Cargo.toml says it is std and libc only. `cmux-panic-log` depends on `serde_json`.
- Holder wire: `VERSION = 5`, `MIN_VERSION = 1`. HELLO and WELCOME carry capability bits (pty-holder.md
  rows 141-142). A new daemon adopts older holders (the `cmux-holder-v3` fixture crate).
- `SystemCrashReport.isHelper(ofBundle:)` (SystemCrashReport.swift:98) accepts only paths in the bundle.
  The holder and terminal hosts run from `~/Library/Application Support/cmux-tui/host-exe/<sha256>/`
  (cmux-tui-platform/src/host_exe.rs), so **their .ips files are dropped today**.
- Nightly uploads dSYMs for cmux-tui, cmux-tui-host and cmux-holder only (nightly.yml:2442-2444). It
  uploads none for cmux-app-host, cmux-browser-host, the cmux-built CEF helper, Chromium host and shim, or
  the CEF framework.
- 8 `assertionFailure(` sites are silent in Release.

---

## 3. Target design

### A. One clock, one record, per-thread chunks
- **Clock.** Every process stamps `CLOCK_UPTIME_RAW` ns. In Swift, `TraceClock` converts from
  NSEvent.timestamp, systemUptime and CACurrentMediaTime. A `ContinuousClock` instant converts only when
  both clocks were sampled at capture time, because ContinuousClock counts sleep. Rust uses
  `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` on macOS, `CLOCK_MONOTONIC` on Linux and QPC on Windows.
  Each remote machine has its own domain, joined by a `ClockSnapshot` and a measured offset (task 116).
- **Ring v1.** The spec is in trace.md; tasks 000 and 002 write it.
  - Header: magic `CMXTRACE`, version, pid, role, build id, `kern.bootsessionuuid`, start uptime, chunk
    count, offsets of the name table and the thread table. The header holds the **full** name table
    (fixed and interned names), so a newer build decodes an older ring correctly.
  - Record (32 B): `t_ns u64` (0), `seq u32` (8; seqlock: odd while writing, `2*lap+2` when published),
    `name u16` (12), `phase u8` (14; B/E/I/AB/AE/flow-out/flow-in/counter), `flags u8` (15; bit 0: arg1
    is an async or track id; bit 1: estimated), `arg0 u64` (16), `arg1 u64` (24).
  - Chunk (1 KiB): slot 0 is a 32-byte chunk header (thread index u32 into the chunked thread table,
    thread generation u32, chunk lap u64, published-count u32, reserved), and slots 1-31 are records. The
    thread lives in the chunk header, so the record stays 32 bytes.
  - Writers: a thread claims a chunk with one `fetch_add` on the chunk cursor, then writes
    records into it with a per-slot seqlock publish. It overwrites the oldest chunk when it wraps (black-box
    semantics). The decoder accepts only even sequences that match the lap, and merges by `t_ns`. This is
    **not** a Vyukov queue: a Vyukov producer waits for a consumer, and the black box has no consumer.
  - One write path. While `trace.start` is on, new chunks come from the large recording file, and the
    black-box tail is the last N records of whichever file is active. A trace point never writes twice.
  - Sizes by role. App and daemon: black box 4096 records, recording 1M. Holder and acpmux: 4096 and 256K.
    Terminal host: 512 and 16K. The Chromium host: 4096 and 256K. `trace.start` caps the total bytes and
    reports them in `trace.status`.
  - Lifetime. The process writes into a heap ring from its first instruction. A BackgroundWork `.files`
    job (Rust: a one-shot thread at start) renames a spare file or creates the ring file, maps it
    `MAP_SHARED`, and copies the heap records into it. Nothing opens or truncates a file on main before the
    first frame. A recording mapping is mapped once and **never unmapped** while the process lives, so a
    late writer cannot fault (it is reset on the next start). Cleanup deletes a ring whose pid is dead
    (kill(pid,0) plus the header's start time) and that is older than 3 days. The directory is capped at
    16 MiB. The holder writes into a holder-lifetime directory.
  - Idle disk: an idle process writes no records, so it has no dirty pages. The done checks measure
    `ri_diskio_byteswritten`.
- **Categories.** One `Atomic<UInt64>` bitset per process, read with one inlined relaxed load (task 093
  makes the Compat atomics inlinable). Black-box default: action, key, switch, create, cef, launch,
  daemon, hang, crash. Recording adds motion, frame, stall, task, burst, input, webview, remote.
- **Async slices.** Intervals that cross turns or threads, or that overlap (create.tab, switch.tab,
  motion.run, launch.*, the app's daemon.request, cef.create_browser, acpmux requests), use AB/AE with the
  OSSignpostID or the intent id as the async id. The exporter maps (name, async id) to a Perfetto Track.
- **One process-wide `TraceRuntime`** owns the rings, category flags, name and thread tables, crash-key
  page, HangWatch table and MetricsStore. It is the single reviewed exception in arch-ratchet.json
  (`stateful_singletons`, `global_mutable_statics`), like Chrome's `TraceLog` and
  `GlobalHistogramAllocator`.
- **C writer.** The same protocol as a header-only C11 file (`CEFShim/src/cmux_trace.h`), for the
  Chromium host and the shim. It is also the reference for the Ghostty Zig hook.

### B. Catalog and emitters
- `SignpostName` is the single catalog. **Task 000 freezes it in hour 0**: it adds every new name,
  category, histogram id, crash-key slot and API signature as stubs. After that, emitter tasks edit only
  leaf files. This prevents merge conflicts between agents and full-graph rebuilds.
- New categories: daemon, frame, task, hang, input, webview, remote. New names: daemon.request,
  control.request, task.post, task.run, frame.tick, frame.commit, frame.gpu_done, frame.present_estimate,
  frame.sequence, ghostty.render, launch.{process_to_main, first_window, first_frame, daemon_ready,
  first_terminal_output}, stall.{create_surface, palette_open, icon_picker_open}, cef.geometry,
  cef.host_input, motion.drag_frame, switch.app_activation, key.omnibar_suggest, key.palette_search,
  input.frame, resize.frame, remote.{input, frame_decoded, present}, webview.{inp, loaf}, hang.*, crash.*,
  and the 12 echo hop names (task 102).
- Each perf-hot path id maps to catalog names in perf-hot-benches.json (a `trace` field).
- The DEBUG-only timers write the same marks into the ring in Release.
- Dynamic names are `StaticString` only (enforced by type). Custom action ids map to `custom` or
  `extension`.

### C. Item 7: key to Ghostty frame, one trace
- **Start.** `trace.start` (control socket, Release, same user, no path or command parameters) sets the
  flags, opens the recording rings and forwards daemon `trace-start`. The daemon forwards to holders that
  were granted `TRACE_CONTROL`, to terminal hosts and to acpmux. It also starts Chromium tracing in the
  process that runs CefInitialize: the app, or the Chromium host after F2. Key flows start only with
  `keys:true`. While recording runs, a visible indicator shows. Secure input drops per-key records.
- **Exact flows.** The app mints a flow id for each key (pid in the high 32 bits). The `send` request
  carries it. The host or holder (`WRITE_FLOW` capability) stamps it on the next PTY read. Each of the about
  12 thread handoffs carries the id in its queue item (u64, 0 when off) and writes a hop. The daemon's
  output event carries `flow`: today an optional JSON field, and a fixed u64 header field when the G5
  binary frame lands (agreed with PL-daemon). The app marks decode, main hop, parse and contents.
  `ghostty.render` comes from the Ghostty hook on the renderer thread. `frame.gpu_done` comes from the
  Metal completion handler. The contents mark comes from the hook's IOSurface handoff (the Release
  build has no swizzle).
- **Present.** `frame.present_estimate` is the first vsync at or after max(frame.commit,
  frame.gpu_done), with the "estimated" flag set. It is measured only on a host with a lit display, and
  it is calibrated once against a high-speed capture (task 092).
- **Every daemon request** is linked by `hash(app pid, request id)` on both sides, with no wire change
  (task 103). CLI and MCP requests carry their own flow (task 115).
- **Export.** `cmux trace record --seconds N` collects every ring and the Chromium JSON. The Rust
  exporter writes native Perfetto protobuf (descriptors, interned names, async tracks, flows, one
  ClockSnapshot per machine). `trace.py` prints per-target key→present_estimate p50/p95/p99/max, a
  per-hop table, clock-order violations and QoS inversions. It joins Chromium's EventLatency on the
  NSEvent timestamp.

### D. Field histograms (UMA)
- **CmuxNextMetrics** (core layer, depends only on Compat and Trace). `HistogramID` gives name, unit,
  layout (log-linear, 4 sub-buckets per octave, shared golden with Rust), owner and expiry. An expired id
  records nothing. `record()` is 3 relaxed atomic adds into a per-launch `MAP_SHARED` file. The file
  header holds the system profile (version, build, channel, OS, hardware class, boot session). Each bucket
  has a "logged" shadow, so an upload sends deltas only.
- **Child processes.** The daemon, holder and acpmux write the same layout into
  `metrics-<role>-<pid>.bin`. The app maps these files read-only. A crashed daemon's numbers survive.
- **Chromium.** A shim export reads `base::StatisticsRecorder` for an allowlist of names (EventLatency,
  Smoothness, renderer and GPU memory, Stability, FCP). They are folded in as `chromium.*`.
- **Recorded:** key.frame (view, terminal); key.echo_frame (1 in 16, contents mark from the hook);
  input.frame.<kind> (mouse_down, mouse_up, drag, scroll, ime_commit, paste); resize.frame; main.turn;
  main.queue_delay; main.congestion.{exec,queue}.{launch,steady}; hang.over250.per_hour;
  hang.thread_hung.<lane>; action.commit.<entrypoint>; action.cmd_t/n/w and missed frames;
  smoothness.dropped_pct.<motion|scroll|resize|drag|remote_stream>; frame.interval;
  launch.first_frame.<temperature>; launch.pageins; idle.wakeups.{app_main, app_total, daemon};
  cef.pump; cef.helper_exit; renderer.unresponsive_ms; memory.<kind>_kib, memory.total_kib,
  memory.hidden_workspace_kib; cpu.<kind>_pct; disk.idle_write_kib_per_min; daemon.request.<class>;
  daemon.dispatch.queue_us; automation.request.<class>, automation.main_queue_us,
  automation.blocked_person; webview.inp.<page>, webview.loaf_ms.<page>, webview.js_errors.<page>;
  remote.input_to_present; key.echo_frame.<local|bridge|cloud>; runtime.busy_ms; stability.* counts;
  blocking.violations (Nightly).
- **Upload.** Hang reports schema 3 add `histograms[]` (buckets as `[index,count]` pairs, at most 32
  histograms × 24 non-empty buckets), `stability{}`, `blackbox[]` (the tails of the app, daemon and
  involved host rings, at most 512 events, catalog names and numbers only, **never** key or per-key PTY
  records), and one section per source launch with that launch's profile. The body is at most 48 KiB.
  The server drops unknown names and does not reject the report. Release builds send aggregates
  (`histograms[]` and `stability{}` only, no `blackbox[]`) when the person turns on the new setting
  `diagnostics.performanceData` (default off).
- **Local view.** `metrics.snapshot`, `cmux metrics` and a View Metrics action (chrome://histograms).

### E. HangWatcher in Release, in every process
- **Swift (`CmuxNextTrace/HangWatch.swift`).** `HangWatchScope` is `~Copyable`. Slots live in a growable
  chunked table, with a packed atomic deadline and flags (Chrome's HangWatchDeadline). Scopes nest. A GCD
  lane's slot is keyed by lane, and each job stores `mach_thread_self()`, so the sampler samples the
  thread that really runs. `invalidateActive()` covers nested run loops, modal waits and network or
  process waits.
- **Monitor (CmuxNextControl, on the existing watchdog thread kqueue).** Opening or closing a scope costs
  two atomic stores and no syscall. Watcher rule:
  - While scopes open and close, the watcher arms one one-shot timer per minimum deadline. That is at most
    1 wake/s at a 1 s deadline.
  - After one full minimum-deadline period with no scope opened (the open generation did not change),
    it parks.
  - The first open after it parks posts one `EVFILT_USER`.
  - Detection latency is at most deadline + minimum deadline.
  - Idle: 0 wakes.
  - Drift tolerance: if the watcher itself wakes more than 100 ms late, it skips blame and moves an ignore
    threshold forward (Chrome's kWaitDriftTolerance).
  - Rejected alternative: a kqueue timer per slot costs 2 syscalls per batch on the terminal output lane.
- **Rust (`cmux-hang-watch`).** The same rule with a Condvar. tokio workers are watched through
  `on_thread_unpark` and `on_thread_park` (a worker that does not park within 2 s is hung). The sampler
  (macOS only) does nothing between `thread_suspend` and `thread_resume` except read registers and memory
  into a preallocated buffer. It maps images after resume. Linux and Windows record the thread name and
  the deadline only.
- **Watched:** main; daemon reader and writer; terminal output lane; local PTY; BackgroundWork; control
  handlers; diagnostics queues; remote view, mobile, acpmux pane and status, agent activity, browser host
  provider and CEF child monitor; Ghostty renderer threads (through the hook); mux-control-dispatch (with a
  deadline per MethodClass); mux-conn, journal writer, terminal-work, line-out; holder poll; host pty,
  parser and client-input; acpmux sync threads and tokio workers; cmux's tokio runtimes; Chromium's IO and
  pool threads (Chromium's own HangWatcher, routed through the shim); the Chromium host's main thread.
- **On a hang:** a stack of the hung thread, a Sentry event that names the thread and carries a
  stacktrace and debug_meta, a hang-report entry, a ring instant and a `last-hang/<n>` bundle of every
  process tail.
- **Fatal hangs:** at 2 s the watchdog writes `hang_in_progress` (start time, up to 64 frames) into the
  crash-key page and writes the Sentry envelope to the disk cache. The next launch reports it. Only after
  that is Sentry's own app-hang tracker turned off.

### F. A crash report for every process
- **Crash keys.** A fixed-slot mmap page per process (Swift, Rust, C), written with relaxed stores.
- **Panic logs** in every shipped Rust binary (the queue is generated from a built bundle). The holder
  uses a std-only writer.
- **Native crashes** of Rust processes: SystemCrashForwarder accepts the host-exe root, and attaches that
  pid's black box and crash keys.
- **Chromium.** Helper exits become rate-limited Sentry events. Crashpad minidumps (local database, no
  ServerURL) are forwarded through an annotation allowlist (Nightly with opt-in only). The Chromium host
  is a first-class process kind. Chromium's own HangWatcher dumps go to cmux.
- **WebKit** content-process ends and "Page unresponsive" are stability events.
- **dSYMs** for every shipped binary.
- `dumpWithoutCrashing` for the Release invariant sites.
- **E2E:** crash-matrix.py (16 kinds; 17 with the host flag on) and hang-matrix.py (every lane plus a fatal
  hang).

---

## 4. Rules for every task in this program

1. **No new CI gates, jobs, steps, perf-gate rows or CI tests** (CLAUDE.md, Lawrence 2026-10-23).
   observability-audit.py, crash-matrix.py, hang-matrix.py and field-histograms.py are run by hand. Task
   041 changes only message text in guardrails.py. Task 085 extends only the path list of an existing
   continue-on-error upload loop.
2. **After task 000 lands,** no task edits SignpostName.swift, SignpostCategory.swift, HistogramID.swift,
   HistogramID+Dimensions.swift (a dimension value is the last part of a histogram name) or Package.swift. A
   missing name is added in a short follow-up to 000 that the lead merges, never inside an emitter task. The
   category bits, ring roles and phases are the tables of trace.md; the Swift and Rust tests pin each number.
3. **Hot path.** A disabled trace point is one inlined relaxed load and one branch. A write has no lock, no
   malloc, no syscall and no Foundation call. Prove it with a bench (task 090) before rolling out to
   per-frame sites (037, 057, 113).
4. **Main thread.** No file open, truncate, mmap, prune or `fsync` on main. Use BackgroundWork `.files`.
5. **Privacy.**
   - Records hold catalog names (StaticString) and numbers only.
   - Key-category and per-key PTY records never leave the Mac, in Sentry attachments or in hang reports.
   - No per-key records while secure input or a password prompt is active.
   - PrivacyLeakScanner runs on every report and attachment.
   - Chromium JSON is URL-filtered before export.
6. **Socket policy.** trace.start, trace.stop, trace.status, metrics.snapshot and trace-fetch take no path
   and no command-bearing parameter, and are refused for remote relay callers. trace.start and trace-fetch
   are risk:high and need an independent review receipt and the relay analysis. debug.hang_inject and
   debug-panic are compiled out of Release (`#if DEBUG || CMUX_BENCH_HOOKS`, `cfg(debug_assertions)` or the
   bench feature).
7. **Holder.** Std and libc only (cmux-trace and cmux-hang-watch are std+libc). Every new feature is a
   capability bit granted in WELCOME. The v3 adoption test must keep passing.
8. **Layers.** CmuxNextTrace and CmuxNextMetrics are core and depend only on CmuxNextCompat. HangWatch
   slots and scopes are in CmuxNextTrace. The monitor and reporting are in CmuxNextControl. BlockingDetector
   (Compat) registers through a callback that the composition root sets.
9. **Threads.** Each thread or queue a task adds has its threading-model.md row in the same push (task 000
   adds the known ones up front).
10. **Owners.** Notify the OWNERS.md owner of each owned file: PL-arch (signposts), PL-telemetry (hang
    reports, crash reporting), PL-trace (flows), the Performance Lead (Wakeups), PL-motion-core,
    PL-switch, PL-cef-tab, PL-cefhost, PL-ghostty, PL-daemon and PL-typing.
11. **Cross-platform Rust.** cmux-trace, cmux-hang-watch and every instrumented cmux-tui-core file must pass
    `cargo check --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`, run by hand on
    the fleet.
12. **Verification.** Agents never build or test on the person's Mac. Use
    `cmux-ci run --class isolated --script ... --ref SHA` or `nx-remote`. Each fix gets a regression test
    that fails without it, and the commit says the red and green results.

---

## 5. Done checks

The audit script prints every base count. Fixed numbers below are the base values at `772cdfc45ac`.

1. **Catalog.** `python3 scripts/cmux-next/observability-audit.py catalog --json` exits 0 with
   reserved_without_emitter = 0 (base 9), raw_ossignposter_outside_catalog = 0 (base 6),
   noncanonical_log_subsystem = 0 (base 11), perf_hot_ids_without_trace = 0 of 15 (the ids are read from
   perf-hot-benches.json), debug_only_timers_without_release_mark = 0 (base 6), and launch_names >= 5 (base
   0).
2. **Clocks.** `observability-audit.py clocks --json` reports wallclock_duration_sites = 0 (base 44 in 36
   files) and continuous_clock_trace_sites = 0. A remaining use carries `// wall-clock: <why>` or
   `// continuous-clock: <why>`.
3. **Overhead on the fleet, Release.**
   - TraceEventBench: a disabled point <= 2 ns. A ring write <= 60 ns p99 single-thread. With 8 threads
     contended, p99 is within 20% of single-thread. 0 mallocs.
   - MetricsRecordBench: <= 10 ns per record.
   - `cargo bench -p cmux-trace`: a write <= 40 ns p99.
   - bench-typing.py key->frame p50 with the black box on is no more than 0.05 ms above the base.
   - The cost of the hook contents mark per frame is printed.
4. **Idle and disk on the fleet.** `bench-idle.sh`, 60 s, Release build, Chromium tabs open, black box on
   and recording off:
   - App main wakeups <= 0.5/s. App+daemon <= 1/s.
   - The hang-watch threads (app, daemon, holder, acpmux) make 0 wakeups.
   - No `HangWatcher` thread in a Chromium child (`sample <pid>`).
   - `ri_diskio_byteswritten` from tracing and metrics = 0 bytes/min.
   - During bench-typing light, each watcher makes <= 1 wake/s.
   - The Sentry app-hang off/on A/B delta is written in perf-lead.md.
5. **Item 7.** Run on a fleet Release build with no env var, on a lit-display host named in the result
   (cmux20-bench or a capture mini). Run `cmux trace record --seconds 20 --chromium --keys` during
   `trace.py record --scenario stress-storm --release`. The result:
   - trace.perfetto-trace loads in trace_processor with 0 import errors.
   - >= 95% of presses have complete flows with all 12 handoff hops, ghostty.render, frame.gpu_done,
     frame.commit and frame.present_estimate.
   - clock_order_violations = 0. qos_violations is printed.
   - A Chromium track is present.
   - daemon.request covers 100% of requests, and request_flow_linked = 100%.
   - summary.json has key_to_present_estimate_ms{p50,p95,p99,max} per target.
   - The present estimate error, measured against a high-speed capture, is written in perf-lead.md.
6. **Field metrics.** On a Nightly-config build with hang reports on, after `trace.py record --scenario
   light-storm` with 3 Chromium tabs:
   - `cmux metrics --json` lists >= 40 catalog histograms with count > 0, including
     `chromium.EventLatency.KeyPressed.TotalLatency`, `webview.inp.home` and `daemon.request.*`.
   - The View Hang Report preview is schema 3 and the body is <= 48 KiB.
   - A planted key record is absent from blackbox[], and PrivacyLeakScanner refuses 0 reports.
   - The web route on main answers 204 for schema 3, 204 with the name dropped for an unknown histogram
     name, 400 for a bad shape and 413 for an oversize body.
   - Two reports in one launch send each sample once.
   - After `kill -9` of the daemon during the storm, the next report still has daemon.request.*.
7. **HangWatcher.**
   - On the fleet, `swift test --filter 'HangWatch|MainThreadWatchdog'`,
     `cargo test -p cmux-hang-watch` and `cargo check` on Linux and Windows targets pass.
   - `hang-matrix.py --app $NX_APP` blocks each registered lane for 3 s: the app lanes, the daemon lanes,
     the holder, the host, acpmux sync and runtime, ghostty-renderer, chromium-io, remote-view and
     acpmux-pane. Each block yields exactly 1 hang record that names the thread, with >= 5 frames (>= 3 on
     x86_64), within deadline + minimum deadline + 1 s.
   - The fatal case (main blocked 5 s, then SIGKILL) yields 1 fatal-hang envelope at relaunch.
   - A 10-minute STRESS soak yields 0 hang records. Sleep is tested with an injected clock. A real sleep
     runs only on an exclusive host with `pmset schedule wake`.
8. **Crashes.** `crash-matrix.py --app $NX_APP --recorder DIR` starts a fresh holder and checks its build
   id, then triggers these kinds: app signal, app NSException, daemon panic, daemon SIGSEGV, holder abort,
   terminal-host panic, terminal-host SIGSEGV, acpmux panic, agent-host panic, app-host panic,
   browser-host panic, renderer crash, GPU crash, utility kill, webkit-content kill and `cmux mcp serve`
   panic; plus chromium-host abort while the host flag is on.
   - Each kind yields exactly 1 recorded envelope with the tags process and crash_source and its crash
     keys.
   - Its top cmux frame has an image UUID that matches a dSYM of the build.
   - It increments exactly its stability counter.
   - For Chromium, WebKit and chromium-host kinds, the app pid does not change.
   - For the app crash, the relaunch event has a blackbox attachment with >= 256 events and 0 key
     records.
9. **Rust coverage.**
   - `observability-audit.py rust --bundle <fleet build>` reports panic_log_missing = 0 and
     blackbox_init_missing = 0 for every Mach-O in `Contents/Resources/{bin,libexec}`.
   - `rg -n 'hang_watch::'` has >= 1 hit in connection_frame.rs and holder.rs.
   - `cargo test -p cmux-tui-core command_names` covers every Command variant through an exhaustive match.
   - MQ13 = 0 unnamed threads.

---

## 6. Machine queues

`observability-audit.py` runs each query, prints JSON `{queue, hits:[{file,line,symbol}], count}`, and with
`--tasks` prints one task line per hit or batch. Run each query from the repo root.

- **MQ1. Reserved catalog names with no emitter** (1 task per hit; 9 today). `cd Packages/macOS/CmuxNext &&
  for c in $(rg -o 'case \.(\w+): "' Sources/CmuxNextSignposts/SignpostName.swift -r '$1'); do rg -q
  "\.(begin|end|event|interval|endSpanningNestedLoop|asyncBegin|asyncEnd)\(\.$c\b|SignpostName\.$c\b" -g
  '!**/SignpostName.swift' -g '!**/SignpostMetricKitMirror.swift' Sources || echo $c; done`. After task
  000, this queue lists every name that 000 adds until its emitter task lands.
- **MQ2. Raw OSSignposter outside the catalog** (6 files; 2 tasks of 3).
  `rg -l 'OSSignposter\(' -g '!**/CmuxNextSignposts/**' Packages/macOS/CmuxNext/Sources`
- **MQ3. Non-canonical log subsystems** (11 sites; 1 task).
  `rg -n --pcre2 'subsystem: "(?!com\.cmuxterm\.app\.next")' Packages/macOS/CmuxNext/Sources`
- **MQ4. DEBUG-only timing traces to promote** (1 task per 3 files).
  `rg -l '^#if DEBUG \|\| CMUX_BENCH_HOOKS|^#if DEBUG$' Packages/macOS/CmuxNext/Sources | rg
  '(Trace|Timings?|Timer)(\+\w+)?\.swift$' | rg -v 'Debug[A-Z]|CEFEventTrace|BurstTrace\+Control'`, plus
  `Sources/CmuxNextControl/Diagnostics/BurstTrace.swift`.
- **MQ5. perf-hot ids with no trace point.** The ids come from `perf-hot-benches.json` `paths` (15). Cross
  them with `rg -n '// perf-hot: \S+ (\S+)' -r '$1' -o Packages --glob '*.swift'`. A hit is an id whose
  marked files have no `Signposter\.|KeyFrameSignpost|InputFrameSignpost|ScrollFrameSignpost|SignpostActionRunTiming|Trace\.scope`,
  or that has no `trace` field.
- **MQ6. Wall-clock duration sites** (44 in 36 files; batches of <= 15 files per package group).
  `rg -n 'CFAbsoluteTimeGetCurrent\(\)|Date\(\)\.timeIntervalSince' Packages/macOS/CmuxNext/Sources`
- **MQ7. Swift lanes to register with HangWatch** (48 sites before filtering).
  `rg -n 'DispatchQueue\(label:|Thread\.detachNewThread|= Thread\(' Packages/macOS/CmuxNext/Sources`. Keep
  only the threading-model.md rows whose "May block on" is Nothing, or a bounded socket, PTY or frame
  operation. Batches: tasks 069, 070 and 119.
- **MQ8. Rust long-lived loop threads to register with cmux-hang-watch and cmux-trace.** `rg -n
  'thread::Builder::new\(\)\s*\.name\(\s*(format!\()?"(mux-control-dispatch|mux-conn|mux-line-out|mux-session-journal|mux-terminal-work|terminal-host-(pty|parser|client-input)|holder-link|surface-)'
  cmux-tui/crates/{cmux-tui-core,cmux-tui,cmux-holder}/src`, plus `rg -n 'new_multi_thread\(\)'
  cmux-tui/crates/{cmux-tui,acpmux}/src` (4 runtimes).
- **MQ9. Shipped binaries without a panic log or a black box** (regenerated from a bundle). Run
  `observability-audit.py rust --bundle <fleet .app>`. It lists each Mach-O in
  `Contents/Resources/{bin,libexec}` and `Contents/Frameworks/*.app/Contents/MacOS`, maps it to its crate
  through Cargo.toml `[[bin]]` names, and reports the crates without `cmux_panic_log::install` or
  `init_blackbox`. Today's static fallback: the holder, cmux-tui-host, cmux-app-host, cmux-browser-host,
  acpmux agent-host, `cmux mcp serve`, cmux-cloud, optchat-chief and cmux-diff-sidecar.
- **MQ10. Sentry options that add wakeups or swizzles** (1 task). `rg -n 'options\.(enable\w+|appHangTimeoutInterval)'
  Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/CrashReporter.swift` diffed against
  `Packages/Shared/CmuxSentryTelemetry/Sources/CmuxSentryReporting/CLISentryRuntimePolicy.swift`.
- **MQ11. Command variants without a wire name.** After task 013, the compiler enforces it: `wire_name`
  is an exhaustive match with no wildcard. Base count: `awk 'NR>=733' cmux-tui/crates/cmux-tui-core/src/server.rs
  | awk '/^}/{exit}{print}' | rg -c '^\s{4}[A-Z][A-Za-z0-9]*\s*(\{|\(|,)'`.
- **MQ12. Histogram catalog ids with no record site** (1 task per id group; runs after task 000).
  `for id in $(rg -o 'case (\w+)' -r '$1' Packages/macOS/CmuxNext/Sources/CmuxNextMetrics/HistogramID.swift);
  do rg -q "record\(\.$id\b" Packages/macOS/CmuxNext/Sources cmux-tui/crates || echo $id; done`
- **MQ13. Unnamed Rust threads** (197 today; 1 task per <= 40 hits). `rg -n 'std::thread::spawn\(|thread::spawn\('
  --glob '!**/tests/**' --glob '!**/*tests*.rs'
  cmux-tui/crates/{cmux-tui-core,cmux-tui,cmux-holder,acpmux,cmux-app-host,cmux-browser-host}/src`
- **MQ14. Untraced detached tasks** (204 today; 1 task per <= 30 hits).
  `rg -n 'Task\.detached' Packages/macOS/CmuxNext/Sources`
- **MQ15. ContinuousClock sites on trace, histogram or deadline paths** (369 lines name ContinuousClock,
  117 `.now`; batches of <= 15 files). `rg -n 'ContinuousClock' Packages/macOS/CmuxNext/Sources`. A hit is
  done when it uses TraceClock or SuspendingClock, or carries `// continuous-clock: <why>`.
- **MQ16. Silent Release invariants** (8 today; 1 task).
  `rg -n 'assertionFailure\(' Packages/macOS/CmuxNext/Sources`

---

## 7. Review dispositions

Every review item was checked against the code. Each one was applied, merged or dropped as follows.

**Applied (problems):**
- Vyukov ring cannot overwrite; one contended tail. Applied: per-thread chunks plus a seqlock and overwrite
  (002, 003, 009).
- No async ids. Applied: AB/AE phases (002, 006, 022).
- Double write with two rings. Applied: one write path (002, 005).
- Use-after-unmap at stop. Applied: map once, never unmap (003, 009).
- File creation on main at launch. Applied: heap first, then a `.files` swap and a spare file (003, 005,
  052).
- 172 hosts × 32 MiB. Applied: sizes by role and a total cap (002, 020).
- Thread table and slot overflow, tid reuse. Applied: chunked tables, generations and a TLS destructor
  (004, 066).
- Rust crates are macOS-only. Applied: rule 11, platform modules in 009, and task 132.
- Holder wire without negotiation. Applied: capability bits (096). The VERSION 6 proposal was dropped
  because pty-holder.md HELLO and WELCOME already carry capability bits.
- Holder and serde_json. Applied: a std-only writer feature in cmux-panic-log (080).
- Watcher wakes at every 0→1 transition. Applied: the watcher rule in section E (067, 071).
- Rust hang events not symbolicated. Applied: stacktrace and debug_meta (075).
- acpmux async handlers and 0 spans. Applied: tokio hooks (118) and async slices (017).
- Chromium in-process assumption (F2). Applied: role-aware CEF tasks and tasks 094 and 104.
- 050 needs no fork. Applied: in-repo shim (050).
- 016, 018 and 081 versus F6 and G5. Applied: the flow is a header field when G5 lands; the host path stays
  primary while the holder is default-off.
- HangWatch layer cycle. Applied: slots in core Trace (066), rule 8.
- Metrics layer. Applied: core (000).
- arch-ratchet singletons. Applied: one TraceRuntime exception (000).
- Schema 3 is too large. Applied: index pairs and 48 KiB (063).
- Server 400 on unknown names. Applied: drop and count (064).
- ContinuousClock counts sleep. Applied: 002 and MQ15/129.
- frame.present is an estimate and minis have no lit display. Applied: `frame.present_estimate`, a lit
  host and calibration (037, 092).
- Runtime swizzle in Release. Applied: the hook's contents mark; the swizzle stays DEBUG-only (019, 054).
- 013 cannot serialize. Applied: an exhaustive match (013).
- 012 handoffs missing. Applied: 102.
- Memory subtraction is wrong with shared renderers. Applied: per-browser renderer pids (061).
- Report-trigger bias. Applied: sampling at transitions (061, 121).
- The black box holds only the app ring. Applied: merged tails (063).
- Keystroke-timing side channel. Applied: 128 and rule 5.
- trace.start reachable by agents. Applied: `keys:true`, an indicator, a URL filter (020, 133).
- Fatal hangs after 076. Applied: 110, and 076 depends on 110.
- The sampler can deadlock. Applied: 072.
- 2 s dispatch deadline. Applied: MethodClass deadlines and invalidate (073).
- Interning a runtime String. Applied: StaticString (025).
- SignpostName conflicts and rebuilds. Applied: 000 and rule 2.
- Thread-doc guardrail ordering. Applied: rule 9 and 000.
- Ids decoded by a newer build. Applied: the header name table (004).
- Sleep on a shared fleet host. Applied: 088.
- Delta upload and per-launch profile. Applied: 052, 053, 063.
- Startup temperature source. Applied: pageins (034).
- Drift tolerance. Applied: 067, 071.
- The GPU completes after vsync. Applied: frame.gpu_done (048, 037).
- Join Chromium EventLatency. Applied: 023.
- Chromium's own HangWatcher wakes for nothing. Applied: 106.
- Boot session versus crash. Applied: 053, 109.
- MQ5 has 15 ids, not 14. Applied.
- 085 is risk:high. Applied.
- 021 `cli/mod.rs` does not exist. Applied: `cli.rs`.

**Merged (missing tasks that more than one reviewer proposed):**
- Chromium host: r1-099, r2-094/096 and r3-093 became 094 and 104.
- Crashpad: r2-095 and r3-095 became 105.
- Chromium HangWatcher: r1-107 and r3-094 became 106.
- Chromium UMA: r1-106 and r3-096 became 107.
- Stability counts: r1-101 and r3-103 became 109.
- Fatal hang: r1-102 and r2's 076 fix became 110.
- EventLatency: r1-103 and r2-101 became 111.
- Responsiveness: r1-104, r2-100 and r3-102 became 112.
- QoS inversion: r1-116 and r2-102 became 122.
- Daemon histogram persistence: r2-099 and r3-097 became 131, which also replaces the server-stats call in
  062.
- Panic logs: r1-095 and r3-099 became 099 and 100.
- dSYMs: r1-096 was merged into 085.
- Rust crash keys: r3-098 became 097 (forwarding) and 098 (the page).

**Dropped, with reasons:**
- r1's shm_open black box. macOS cannot list POSIX shm names, so the segments of crashed hosts would leak
  until reboot, and the 31-character name limit is tight. The fix used instead: an idle process writes no
  records, so it has no dirty pages. Hosts get a 512-record ring. Done check 4 measures disk bytes. If
  check 4 fails, a later task moves to shm with daemon-owned names.
- r2's per-slot EVFILT_TIMER. It costs 2 syscalls per batch on hot lanes. The section E rule meets the idle
  target with atomics only.
- r2's "ghostty.render optional in item 7". It was not taken, because the user asked for more ambition.
  048 is on the critical path. If the fork slips, done check 5 is red and names 048.
- r1's "decision for the lead: Release field data". It was decided (memory: decide yourself): aggregates
  only, behind a new setting that is off by default (task 134).

---

## 8. Risks

1. **Owner coordination at scale.** Many tasks edit owned files. Task 000 and rule 2 remove most
   SignpostName conflicts. The lead merges follow-ups to 000 in order.
2. **Forks.** Tasks 048 (ghostty-next renderer hook, land with PL-ghostty's G1), 106 and 107 (CEF fork:
   SetDumpWithoutCrashingFunction and StatisticsRecorder are not in the public CEF API) need fork releases.
   The CEF pin is blocked on R2 upload rights (perf-lead F2). 050, 105's config and 061's renderer pids use
   the in-repo shim and stock CEF API, and do not need the fork. If the CEF fork slips, 106 and 107 slip.
   Item 7 is not blocked by them.
3. **F2 and F6 land during the 72 h.** CEF tasks are role-aware. Host tasks stay required while the holder
   is default-off (`CMUX_TUI_TERMINAL_HOST_MODEL`). If the holder becomes default before hour 36, the lead
   may drop host-only instrumentation, and the drop must be written here.
4. **Socket policy (risk:high).** trace.start, trace-fetch (116) and Release metrics.snapshot need review
   receipts. Making trace.start DEBUG-only would defeat "trace a Release build". Do not take that shortcut.
5. **Web on main deploys automatically.** 064 must deploy before 063's flag turns on. No DB migration
   (jsonb). Typed columns later would need PlanetScale staging and then main, before merge.
6. **Privacy.**
   - Crashpad minidumps hold stack memory that can contain page content. 105 sends only from Nightly with
     the opt-in, and with stack memory left out until Lawrence decides.
   - The privacy policy text is still owed (perf-lead).
   - The Release aggregates setting (134) is user-visible and needs localization.
7. **Idle budget.**
   - The watcher rule allows <= 1 wake/s while lanes are active.
   - frame.present_estimate asks for one display-link tick while recording when the link is idle.
   - Sentry ANR off (076) is expected to save about 0.6 main wakes/s. This is not measured yet; 076
     measures it.
8. **Hot-path overhead.**
   - Per-thread chunks remove contention, but threads that write rarely waste chunk space. Chunks are 32
     records (1 KiB).
   - On x86_64 Rust frames need `-C force-frame-pointers=yes`. Otherwise the check accepts >= 3 frames.
9. **Toolchain.** `~Copyable` scopes and Atomic need Swift 6.2 and macOS 14. Use Compat's Atomic and
   `AtomicPointerSlot` (093), not Synchronization.Atomic (macOS 15+).
10. **swift_task_enqueueGlobal_hook (123)** is a runtime hook with no stability promise. Phase 1 only
    measures, and it falls back to the original enqueue.
11. **Remote daemons (116).** The clock offset has an error bound. trace-fetch is a new remote-reachable
    method and goes through the relay-policy analysis.
12. **Decisions I made without input. Flag them to Lawrence:**
    - (a) A hand-written Perfetto protobuf encoder, not the C++ SDK.
    - (b) The black box is on by default in Release, sized by role.
    - (c) key.echo_frame samples 1 in 16 keys.
    - (d) Sentry's app-hang tracker goes off after 110 lands.
    - (e) Chrome's temperature thresholds (5 and 3500 pageins) are not calibrated on the fleet.
    - (f) Release aggregates go behind a new setting that is off by default (134).
    - (g) There is no shm black box (dropped above).
    - (h) Crashpad stack memory is left out.
13. **Lazy shortcuts avoided:**
    - Thread naming (MQ13), detached-task tracing (MQ14) and the ContinuousClock audit (MQ15) are real
      machine queues, not risk notes.
    - Chromium's own UMA and HangWatcher are read through the shim, not modelled again.

---

## 9. Task table

Size: S <= 150 lines, M <= 400 lines, L > 400 lines (split if needed). "Q" is the machine queue.

| ID | Title | Size | Depends on | Q |
|---|---|---|---|---|
| 000 | Freeze catalog, API stubs, layers, ratchet exception, thread rows | M | - | |
| 001 | observability-audit.py: queues MQ1-MQ16 and done-check counts | M | - | MQ1-16 |
| 002 | TraceClock and ring v1 spec (chunks, seqlock, async phases) | S | 000 | |
| 003 | Swift ring: per-thread chunks, overwrite, heap-then-file, never unmap | M | 002, 093 | |
| 004 | Header name table, chunked thread table with generations | M | 003 | |
| 005 | Category flags, black-box open off main, role sizes, cleanup | S | 003 | |
| 006 | Signposter writes every interval and event to the ring (async ids) | M | 004, 005 | |
| 007 | No allocation on the key and stall trace path | S | 006 | |
| 008 | One unified-log subsystem | S | - | MQ3 |
| 009 | Rust cmux-trace: ring v1, per-thread chunks, platform modules | M | 002 | |
| 010 | cmux-trace macros: scopes, async, instants, flows, scope stack | M | 009 | |
| 011 | cmux-flow-trace becomes a shim over cmux-trace | S | 010 | |
| 012 | debug_spans writes ring scopes on the uptime clock | M | 010 | |
| 013 | Command::wire_name() exhaustive match and MethodClass | M | - | MQ11 |
| 014 | Daemon request spans, arrival stamps, per-class histograms | M | 010, 013 | |
| 015 | Daemon trace-start/stop/status, forwarded to holder, hosts, acpmux | M | 010, 096 | MQ8 |
| 016 | Holder and terminal-host spans | M | 010, 096 | MQ8 |
| 017 | acpmux: event instants and async request slices | M | 010 | MQ8 |
| 018 | Exact echo flows through PTY, holder and daemon output (Rust) | M | 011, 096 | |
| 019 | App: exact output flows, runtime flow start, no Release swizzle | M | 006, 018 | |
| 020 | trace.start/stop/status control methods in Release (risk:high) | M | 006, 015, 019, 128 | |
| 021 | `cmux trace` CLI: record, start, stop, status, export | M | 020, 022 | |
| 022 | Native Perfetto protobuf exporter with async tracks | L | 009 | |
| 023 | trace.py: v1 rings, Release mode, exact flows, Chromium join | M | 009, 020 | |
| 024 | trace.py: percentiles and the clock-order check | M | 023 | |
| 025 | App-side daemon.request async interval (StaticString names) | S | 006, 013 | |
| 026 | Emit motion.frame and motion.run | S | 006 | MQ1 |
| 027 | Emit switch.workspace | S | 006 | MQ1 |
| 028 | Emit switch.tab | S | 006 | MQ1 |
| 029 | Emit switch.pane_focus | S | 006 | MQ1 |
| 030 | Emit create.tab | M | 006 | MQ1 |
| 031 | Emit create.workspace | S | 006 | MQ1 |
| 032 | Emit cef.pump (role-aware), remove wall-clock pump log | S | 006 | MQ1 |
| 033 | Emit cef.create_browser (role-aware) | S | 006 | MQ1 |
| 034 | launch.* names, process-start clock, pageins temperature | M | 006 | MQ1 |
| 035 | Raw OSSignposters to catalog, batch 1 | S | 034 | MQ2 |
| 036 | Raw OSSignposters to catalog, batch 2 | S | 028, 029 | MQ2 |
| 037 | frame.tick, frame.commit, frame.present_estimate | M | 006, 019 | MQ5 |
| 038 | perf-hot: cef.geometry and cef.host_input | S | 006 | MQ5 |
| 039 | perf-hot: motion.drag_frame and switch.app_activation | S | 006 | MQ5 |
| 040 | perf-hot: key.omnibar_suggest and key.palette_search | S | 006 | MQ5 |
| 041 | perf-hot-benches.json: `trace` field for all 15 ids | S | 037-040 | MQ5 |
| 042 | Task tracing for BackgroundWork, LaneScheduler, MainActorWorkQueue | M | 006 | |
| 043 | Release marks from the DEBUG terminal-creation traces | S | 030 | MQ4 |
| 044 | Release marks from ChatOpenTrace, MotionFrameTrace, BurstTrace | S | 026, 030 | MQ4 |
| 045 | Wall clock to TraceClock, batch 1 | M | 002 | MQ6 |
| 046 | Wall clock to TraceClock, batch 2 | S | 002 | MQ6 |
| 047 | Wall clock to TraceClock, batch 3 | M | 002 | MQ6 |
| 048 | ghostty-next trace hook: render, IOSurface handoff, gpu_done, destroy | M | - | |
| 049 | cmux registers the Ghostty hook: ghostty.render and contents mark | S | 048, 019 | |
| 050 | In-repo CEF shim: tracing exports (no fork) | S | - | |
| 051 | Chromium tracing in Release driven by trace.start (role-aware) | M | 050, 020 | |
| 052 | CmuxNextMetrics: catalog, buckets, mmap, profile, delta shadow | L | 000, 093 | MQ12 |
| 053 | Previous-launch fold per source launch, boot-session beacon | M | 052 | MQ12 |
| 054 | Record key.frame and sampled key.echo_frame (hook contents mark) | M | 052, 019, 049 | MQ12 |
| 055 | Record main.turn and hang.over250.per_hour | S | 052 | MQ12 |
| 056 | Record action.commit per entrypoint and Cmd-T/N/W | S | 052, 057 | MQ12 |
| 057 | FrameSequenceTracker for motion and action windows | M | 052, 026 | MQ12 |
| 058 | Record launch first frame per temperature | S | 034, 052 | MQ12 |
| 059 | Record idle wakeups for app and daemon with no added wakeups | M | 052 | MQ12 |
| 060 | Record the CEF pump and Chromium helper exits (role-aware) | S | 052, 032 | MQ12 |
| 061 | Memory per hidden workspace via per-browser renderer pids | M | 052 | MQ12 |
| 062 | Fold daemon request latency from the daemon metrics file | S | 131, 052 | MQ12 |
| 063 | Hang reports schema 3: histograms, stability, merged black box | M | 052, 003, 128 | |
| 064 | Web (main): accept schema 3, drop unknown names, aggregate | M | - | |
| 065 | metrics.snapshot, `cmux metrics`, View Metrics action | M | 052 | |
| 066 | HangWatch slots and scope in CmuxNextTrace (core) | M | 000, 093 | |
| 067 | Hang monitor on the watchdog thread (watcher rule, drift) | M | 066 | |
| 068 | Stack sample of the hung thread and the hang report | M | 067 | |
| 069 | Register Swift lanes, batch 1 | M | 066 | MQ7 |
| 070 | Register Swift lanes, batch 2 | M | 066 | MQ7 |
| 071 | Rust cmux-hang-watch: slots, scope, watcher rule, platforms | M | - | MQ8 |
| 072 | Mach stack sampler with no lock between suspend and resume | M | 071 | |
| 073 | Daemon hang-watch registrations with MethodClass deadlines | M | 071, 013 | MQ8 |
| 074 | Holder, terminal-host and acpmux sync-thread registrations | M | 071, 096 | MQ8 |
| 075 | RustDiagnosticsForwarder with stacktrace and debug_meta | M | 071 | MQ9 |
| 076 | Sentry ANR thread off, auto-instrumentation trimmed, measured | S | 110 | MQ10 |
| 077 | Attribute hangs inside the CEF pump (role-aware) | S | 078, 032 | |
| 078 | Crash keys page (Swift) | M | 003 | |
| 079 | Black box and crash keys on the next-launch crash event | M | 078, 004, 128 | |
| 080 | Holder panic log with a std-only writer | S | - | MQ9 |
| 081 | Terminal-host crash sidecars to Sentry | S | - | MQ9 |
| 082 | Rust panic lines carry the trace scope stack | S | 010 | |
| 083 | Chromium helper exits as Sentry events | S | - | |
| 084 | CEF FATAL line on browser-process aborts (role-aware) | S | 079 | |
| 085 | dSYMs for every shipped binary (risk:high) | S | - | |
| 086 | Sentry recorder transport (DEBUG and bench only) | S | - | |
| 087 | crash-matrix.py: one report per process kind (16+1 kinds) | M | 086, 079, 083, 080, 081, 097, 099, 101, 108 | |
| 088 | hang-matrix.py and hang injection | M | 068, 069, 070, 073, 074, 075, 110 | |
| 089 | Nightly sink for blocking violations | M | 063 | |
| 090 | Overhead benches: trace, metrics, Rust ring, hook mark, watcher | S | 006, 052, 009 | |
| 091 | Docs and owners | S | 020, 063, 067, 071 | |
| 092 | Test phase: full verification with numbers recorded | M | 024, 051, 065, 087, 088, 090 | |
| 093 | Inlinable atomics and AtomicPointerSlot in CmuxNextCompat | S | - | |
| 094 | C ring writer header for the Chromium host, shim and Ghostty | M | 002 | |
| 095 | Black box in every shipped Rust process, roles, cleanup | M | 009 | MQ9 |
| 096 | Holder capability bits TRACE_CONTROL and WRITE_FLOW | M | 009 | |
| 097 | SystemCrashForwarder: host-exe copies, attach black box and keys | S | 095, 098 | |
| 098 | Rust crash-key page | M | 010 | |
| 099 | Panic logs: app-host, browser-host, agent-host, mcp serve | M | - | MQ9 |
| 100 | Panic logs: cmux-cloud, optchat-chief, diff-sidecar, server-helper | S | 001 | MQ9 |
| 101 | Debug crash injectors for the daemon and acpmux | S | - | |
| 102 | Item 7: flow hops at all 12 thread handoffs | M | 018, 019 | |
| 103 | Exact flows for every daemon request from the request id | S | 014, 025 | |
| 104 | Chromium Host process observability (F2) | L | 094, 020, 083, 066 | |
| 105 | Crashpad minidumps from Chromium processes (Nightly opt-in) | M | 083, 086, 085 | |
| 106 | Chromium HangWatcher: forward dumps, off in children | M | 068 | |
| 107 | Chromium UMA snapshot and BrowserMetrics cleanup | M | 052 | |
| 108 | WebKit content-process ends and Page unresponsive | M | 052, 006 | |
| 109 | Stability counts with denominators and exit enums | M | 052, 053 | MQ12 |
| 110 | Fatal-hang report at next launch | S | 078 | |
| 111 | EventLatency for all input types and live resize | M | 007, 052, 037 | MQ12 |
| 112 | Responsiveness calculator: congestion, queue vs run | M | 055, 014 | MQ12 |
| 113 | FrameSequenceTracker for scroll, resize and drag | S | 057 | MQ12 |
| 114 | Webview INP, long animation frames and JS errors | M | 052 | MQ12 |
| 115 | Automation latency: CLI, MCP and agent flows | M | 006, 052, 042 | |
| 116 | Remote daemons: clock offset, trace-fetch, remote echo | L | 015, 022, 054 | |
| 117 | Name every Rust thread | M | - | MQ13 |
| 118 | Hang watch for tokio runtimes through park and unpark | S | 071, 072 | MQ8 |
| 119 | Register Swift lanes, batch 3 | M | 066 | MQ7 |
| 120 | Ghostty renderer-thread hang watch through the hook | S | 049, 067 | |
| 121 | Memory, CPU, disk and pressure per process kind | M | 052, 059 | MQ12 |
| 122 | trace.py: QoS inversion and off-priority hop check | S | 024, 042 | |
| 123 | Swift concurrency global-enqueue hook (measure phase) | M | 006, 066 | |
| 124 | TracedTask.detached with FROM_HERE | M | 042 | MQ14 |
| 125 | `cmux trace blackbox` and the local last-hang bundle | M | 022, 095, 068 | |
| 126 | field-histograms.py: Nightly-to-Nightly regression | S | 064 | |
| 127 | Remote desktop view: input to present and drops | S | 006, 052 | MQ1 |
| 128 | Keystroke-timing privacy gate | S | 005 | |
| 129 | ContinuousClock on trace paths to TraceClock | M | 002 | MQ15 |
| 130 | dumpWithoutCrashing for Release invariant sites | S | 078 | MQ16 |
| 131 | Daemon histograms in a crash-safe mmap file | M | 014, 052 | |
| 132 | cmux-trace and cmux-hang-watch Linux and Windows backends | M | 009, 071 | |
| 133 | Recording indicator and Chromium JSON URL filter | S | 020, 051 | |
| 134 | Release opt-in for aggregate performance data | M | 063, 064 | |

---

## 10. Task details

Paths are relative to the repo root. `S/` = `Packages/macOS/CmuxNext/Sources/`, `T/` =
`Packages/macOS/CmuxNext/Tests/`, `R/` = `cmux-tui/crates/`.

### 000 Freeze catalog, API stubs, layers, ratchet exception, thread rows
- Files: S/CmuxNextSignposts/SignpostName.swift, S/CmuxNextSignposts/SignpostCategory.swift,
  S/CmuxNextTrace/TraceRuntime.swift, S/CmuxNextTrace/HangWatch.swift, S/CmuxNextTrace/CrashKeySlot.swift,
  S/CmuxNextMetrics/HistogramID.swift, Packages/macOS/CmuxNext/Package.swift,
  plans/cmux-next/architecture-layers.json, plans/cmux-next/arch-ratchet.json,
  plans/cmux-next/threading-model.md.
- Change: In one push:
  - Add the core targets CmuxNextTrace and CmuxNextMetrics (dependencies: CmuxNextCompat, and Trace for
    Metrics).
  - Add every new SignpostName case and category in section 3B, every HistogramID in section 3D, and every
    crash-key slot.
  - Add stub signatures for TraceRuntime, the typed Signposter overloads, HangWatch, HangWatchScope and
    `Metrics.record`. The stubs do nothing.
  - Add one dated `TraceRuntime` exception to arch-ratchet.json.
  - Add the threading-model.md rows for the watcher threads: app hang monitor, the Rust hang-watch thread
    per process and the ring-open one-shot threads.
- Acceptance:
  - arch-ratchet.py and the guardrails.py thread-doc check pass.
  - Every new name has a doc comment and an owner.
  - The diffs of the later tasks 025-047, 052-062 and 102-127 do not touch SignpostName.swift,
    SignpostCategory.swift, HistogramID.swift or Package.swift.
- Test phase: `python3 scripts/cmux-next/arch-ratchet.py`; `python3 scripts/cmux-next/guardrails.py`; a
  fleet compile of the package (`cmux-ci build cmux --ref SHA`).

### 001 observability-audit.py
- Files: scripts/cmux-next/observability-audit.py.
- Change: A new stdlib-only script with these subcommands: catalog, clocks, lanes, rust (`--bundle PATH`),
  sentry, histograms, threads, tasks and asserts. Each runs the exact MQ1-MQ16 queries through `rg`. It
  prints JSON, and `--tasks` prints one task line per hit or batch. MQ5 reads perf-hot-benches.json. It is
  not wired to CI or pre-push.
- Acceptance:
  - Stdlib plus `rg` only. No network. No writes.
  - `catalog` returns 9 reserved names on the base.
  - `--self-test` checks each query against fixture strings.
  - No .github or guardrails.py change in the diff.
- Test phase: run `catalog --json` at the base (9/6/11/…) and at the tip (0s).

### 002 TraceClock and ring v1 spec
- Files: S/CmuxNextTrace/TraceClock.swift, plans/cmux-next/trace.md, T/CmuxNextTraceTests/TraceClockTests.swift.
- Change: Write TraceClock: `nowNanos()` = `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, plus converters from
  NSEvent and systemUptime seconds, CACurrentMediaTime, and `ContinuousClock.Instant` (only with a paired
  UPTIME sample taken at capture). Add a "Release trace ring v1" section to trace.md. It gives the byte
  offsets of the header and the 32-byte record, the per-thread chunk claim, the seqlock publish
  (odd while writing, `2*lap+2` when published), the phase codes including AB/AE, the flags, the name and
  thread tables, the build id, and the one-write-path rule. Swift, Rust and C share this spec.
- Acceptance:
  - The converters agree within 1 us.
  - The ContinuousClock converter is correct with an injected 10 s sleep offset.
  - Every field in trace.md has a byte offset.
- Test phase: `cmux-ci run --class isolated`: `swift test --filter TraceClockTests`.

### 003 Swift ring
- Files: S/CmuxNextTrace/TraceRing.swift, S/CmuxNextTrace/TraceRingFile.swift, T/CmuxNextTraceTests/TraceRingTests.swift.
- Change: A ring of 32-byte records in 1 KiB chunks (a chunk header with the thread index, then 31
  records). A thread's TLS pointer names its current chunk.
  When the chunk is full, one `fetch_add` on the chunk cursor claims the next (lap = cursor / chunks). Each
  record is published with a seqlock (store the odd sequence, write the payload, store-release the even
  sequence). When the ring wraps, it overwrites the oldest chunk and counts the overwrite. The ring starts
  on the heap. `TraceRingFile.adopt(directory:role:)` runs on BackgroundWork `.files`: it renames a spare
  file or creates the file, maps it `MAP_SHARED`, copies the heap records into it, and swaps the pointer.
  The recording mapping is created once and never unmapped. If mmap fails, the heap ring stays and the
  failure is counted. Uses AtomicPointerSlot (093).
- Acceptance:
  - Diff review: no lock, malloc, syscall or Foundation call on write.
  - 8 threads × 100k records into a large ring decode exactly once, in per-thread order.
  - A torn-write test passes.
  - Black box: after writing 10× capacity, the decoder finds only whole records.
  - A child process that aborts leaves a file that decodes.
  - The 8-thread contended p99 is within 20% of single-thread (bench in 090).
- Test phase: fleet: `swift test --filter TraceRingTests` in Debug and `-c release`.

### 004 Header name table and chunked thread table
- Files: S/CmuxNextTrace/TraceNames.swift, S/CmuxNextTrace/TraceThreads.swift.
- Change: SignpostName cases take fixed ids, append-only. `TraceSite` is a StaticString holder with an
  atomic UInt16 id, registered once into the header name table. The header stores the full table and the
  build id. Thread table: 256-entry chunks linked by an atomic pointer and allocated at registration (off
  the hot path). Each entry has a generation (a reused tid gets a new entry), the tid,
  pthread_getname_np and pthread_get_qos_class_np. A TLS destructor frees the entry. Overflow counters are
  in the header.
- Acceptance:
  - A test pins the ids of the existing cases.
  - A file written by an older build decodes with the header alone (a test with a different case order).
  - 2,000 threads register with 0 overflow.
  - After first use, the hot path is one atomic load.
- Test phase: fleet: `swift test --filter 'TraceNames|TraceThreads'`.

### 005 Category flags, black-box open, role sizes, cleanup
- Files: S/CmuxNextTrace/TraceCategories.swift, S/CmuxNextApp/AppServices.swift, T/CmuxNextTraceTests/TraceCategoriesTests.swift.
- Change: An `Atomic<UInt64>` bitset with an inlined `isEnabled`. Default set as in section 3A. AppServices
  starts the heap ring at once. It schedules the file adoption (003) and the cleanup (dead pid and older
  than 3 days, 16 MiB cap) on `.files`. It makes the next launch's spare file about 90 s after launch.
- Acceptance:
  - The default set matches the list (test).
  - No open(O_CREAT), ftruncate or mmap on main before the first frame (BlockingDetector Debug test).
  - The cleanup test keeps live-pid files.
- Test phase: fleet: `swift test --filter TraceCategoriesTests`; bench-startup.py shows no warm-launch
  regression.

### 006 Signposter writes to the ring
- Files: S/CmuxNextSignposts/Signposter.swift, S/CmuxNextSignposts/SignpostInterval.swift.
- Change: Every begin, end, event and flowHop also writes a ring record when its category flag is on.
  Intervals that can cross turns write AB/AE, with the OSSignpostID as the async id. Typed overloads pass
  numbers: the action index and entrypoint, scroll phase, class and owner ids, and the flow id.
  SignpostInterval keeps the begin time.
- Acceptance:
  - Every public emit method writes under the flag (diff).
  - An action interval decodes as AB/AE with the same name and id and an increasing t.
  - With the flag off, 0 records.
- Test phase: fleet: `swift test --filter SignpostsTests`.

### 007 No allocation on the key and stall path
- Files: S/CmuxNextSignposts/KeyFrameSignpost.swift, S/CmuxNextSignposts/Signposter.swift, S/CmuxNextWakeups/MainFrameBudget.swift, S/CmuxNextWakeups/TypingLatencyProbe.swift.
- Change: Typed `begin(.keyToFrame, target:ageMicros:)` with OSLogMessage and no `String(format:)`. A typed
  stall event. flowHop takes StaticString names.
- Acceptance:
  - `rg -n 'String\(format:' S/CmuxNextSignposts` = 0.
  - No interpolation passed to an emit in MainFrameBudget.swift.
  - 1000 key.frame pairs make 0 mallocs (malloc_zone statistics).
- Test phase: fleet: `swift test -c release --filter KeyFrameSignpostAllocationTests`.

### 008 One unified-log subsystem
- Files: the 11 MQ3 hits (AppServices, AgentCursorInputBridge, FreeTierAttestStarter, HostPressureService,
  PageRelayChannel, LayoutPassGuard, DaemonVersionHandoff, DaemonLauncher+Capabilities, DaemonLauncher+Build,
  CmuxNextBrowserHost/ProviderConnection, BrowserHostProvider).
- Change: subsystem `com.cmuxterm.app.next`. The categories stay.
- Acceptance: MQ3 = 0.
- Test phase: `observability-audit.py catalog`.

### 009 Rust cmux-trace crate
- Files: R/cmux-trace/{Cargo.toml, src/lib.rs, src/ring.rs, src/clock.rs, src/map.rs, tests/ring.rs}, cmux-tui/Cargo.toml.
- Change: A std+libc crate. Ring v1 is byte-identical to 003: per-thread chunks, a seqlock and overwrite.
  `init_blackbox(dir, role, slots)` starts on the heap and adopts the file on a one-shot thread.
  `start_recording` maps the recording file once and never unmaps it; `stop` clears the category bits.
  The thread index, name and QoS are captured on the first write. clock.rs: UPTIME_RAW on macOS,
  CLOCK_MONOTONIC on Linux, QPC on Windows. map.rs: mmap on unix and a heap fallback elsewhere (132
  completes Windows). No writer thread.
- Acceptance:
  - 8 threads × 100k records decode exactly once.
  - A child abort leaves a file that decodes.
  - The off path makes 0 allocations.
  - A golden file is shared byte for byte with T/CmuxNextTraceTests/Fixtures.
  - `cargo check -p cmux-trace` passes for the Linux and Windows targets.
- Test phase: fleet: `cargo test -p cmux-trace`; the cross-target `cargo check`.

### 010 cmux-trace macros
- Files: R/cmux-trace/src/{macros.rs, names.rs, lib.rs}, R/cmux-trace/tests/macros.rs.
- Change:
  - `trace_scope!` is a guard that writes E on drop.
  - `trace_async_begin!` and `trace_async_end!(id)`.
  - `trace_instant!`, `trace_flow_out!`, `trace_flow_in!` and `trace_counter!`.
  - A static AtomicU16 per call site.
  - An AtomicU64 category bitset.
  - A thread-local scope stack (depth 16, ids only) for 082 and 098.
- Acceptance:
  - Off: one relaxed load and a branch (expand snapshot).
  - Nested scopes decode as nested B/E pairs.
  - Async pairs decode by id.
- Test phase: fleet: `cargo test -p cmux-trace`.

### 011 cmux-flow-trace becomes a shim
- Files: R/cmux-flow-trace/src/lib.rs, R/cmux-flow-trace/Cargo.toml.
- Change: Keep the public API that the 12 call sites use. Hops become cmux-trace flow instants (category
  key). Drop the 50 ms writer thread. `CMUX_TRACE_FLOWS` still starts recording at init. The crate stays
  std+libc (the holder uses it).
- Acceptance:
  - No diff outside the crate.
  - The existing tests are adapted to read v1 and pass.
  - No `thread::spawn` in the crate.
- Test phase: fleet: `cargo test -p cmux-flow-trace -p cmux-trace`.

### 012 debug_spans writes ring scopes
- Files: R/cmux-tui-util/src/debug_spans.rs, R/cmux-tui-util/Cargo.toml.
- Change: `Trace::start` also records `start_uptime_ns`. `mark()` writes ring instants (daemon). `finish()`
  writes an async pair. The JSONL output gains `start_uptime_ns` and `tid`.
- Acceptance:
  - The 94 call sites are untouched.
  - new_tab_spans and new_terminal_first_text pass.
- Test phase: fleet: `cargo test -p cmux-tui-util -p cmux-tui --test new_tab_spans --test new_terminal_first_text`.

### 013 Command::wire_name() and MethodClass
- Files: R/cmux-tui-core/src/server.rs, R/cmux-tui-core/src/server/command_names.rs, R/cmux-tui-core/src/server/command_names_tests.rs.
- Change: `fn wire_name(&self) -> &'static str` as an exhaustive match with no wildcard, generated once by
  a script from the enum and its serde renames and aliases. `MethodClass` (topology, terminal_io, create,
  query, browser, agent, cloud, other) has a per-class hang deadline and a "may wait" flag.
- Acceptance:
  - The compiler enforces every variant.
  - A test deserializes `{"cmd": name}` for every name, and every error is about a missing field, never
    "unknown variant".
  - Aliases are listed.
- Test phase: fleet: `cargo test -p cmux-tui-core command_names`.

### 014 Daemon request spans and per-class histograms
- Files: R/cmux-tui-core/src/server/{connection_frame.rs, connection_scheduler.rs, responses.rs}, R/cmux-tui-core/src/diagnostics.rs.
- Change:
  - The reader stamps the arrival time.
  - `handle_request_with_cancellation` opens `trace_scope!(daemon, "daemon.request", method id, request id
    hash)` with instants for parsed, dispatched, reply.queued and reply.sent.
  - The async starters (url_open, chief_inspect, cloud) get async slices.
  - diagnostics gains histograms per MethodClass (arrival to sent) and daemon.dispatch.queue_us.
- Acceptance:
  - A guard closes the scope on every return path.
  - server-stats has `request_latency_us.<class>`.
  - 3 requests decode as 3 pairs with 4 instants each.
- Test phase: fleet: `cargo test -p cmux-tui-core request_spans`.

### 015 Daemon trace-start/stop/status
- Files: R/cmux-tui-core/src/server.rs, R/cmux-tui-core/src/server/trace_control.rs, R/cmux-tui-core/src/holder_runtime/sink.rs, R/cmux-tui-core/src/terminal_host_runtime/shared/host_serve.rs, R/acpmux/src/daemon.rs.
- Change: Commands `TraceStart{categories, keys}`, `TraceStop` and `TraceStatus`, with no path parameter.
  The daemon picks the directories under its state root. Remote clients are refused. The daemon starts
  its own recording and forwards it to holders that were granted TRACE_CONTROL (096), to live terminal
  hosts and to acpmux. The reply lists the ring paths and the bytes per role, under the total cap.
- Acceptance:
  - A remote client is refused.
  - A v3 or v5 holder without the capability gets no frame, and its status says untraced.
  - A local test sees daemon, host and holder rings.
- Test phase: fleet: `cargo test -p cmux-tui-core trace_control`; `cargo test -p cmux-holder`.

### 016 Holder and terminal-host spans
- Files: R/cmux-holder/src/holder.rs, R/cmux-tui-core/src/terminal_host_runtime/shared/{host_shared.rs, host_parser.rs, host_start.rs}.
- Change:
  - Holder: a poll-iteration scope (recording only), and pty.read and pty.write instants with a terminal
    hash and a byte count.
  - Host: scopes for the pty read, the parser and the client-input write.
  - The host path is the primary acceptance (the holder is default-off).
- Acceptance:
  - One scope per iteration, under the flag.
  - A stress test gives host and holder records.
  - The holder dependencies are still std+libc.
- Test phase: fleet: `cargo test -p cmux-holder -p cmux-tui-core host_spans`.

### 017 acpmux: event instants and async request slices
- Files: R/acpmux/src/cli/entry.rs, R/acpmux/src/trace_layer.rs, R/acpmux/src/daemon.rs, R/acpmux/Cargo.toml.
- Change:
  - A `tracing_subscriber` Layer maps events to instants while recording runs. Names are interned per
    callsite metadata, and fields are dropped.
  - Request dispatch writes async slices keyed by request id.
  - acpmux has 0 spans, so the layer does not map spans.
- Acceptance:
  - 0 allocations per event when off.
  - With recording on, an acpmux run decodes async request slices.
- Test phase: fleet: `cargo test -p acpmux trace_layer`.

### 018 Exact echo flows (Rust)
- Files: R/cmux-tui-core/src/surface/{input.rs, pty_surface.rs, hosted_reader/output.rs}, R/cmux-tui-core/src/terminal_host_runtime/shared/host_shared.rs, R/cmux-holder/src/holder.rs, R/cmux-tui-core/src/server/cmd_terminal_io.rs.
- Change:
  - Each terminal has an AtomicU64 `last_input_flow`. It is set when a `send` with a flow is written. The
    next PTY read swaps it out and stamps it.
  - The holder takes the flow only through WRITE_FLOW (096).
  - The output event gets an optional `flow`: a JSON field now, or the fixed u64 header field when G5's
    binary frame is in the tree (agree the layout with PL-daemon).
- Acceptance:
  - `flow` is present only when set.
  - send flow 42 gives pty.read 42 and output 42.
  - Old fixtures deserialize.
  - A v3 holder never gets the trailer.
- Test phase: fleet: `cargo test -p cmux-tui-core echo_flow`; `cargo test -p cmux-holder`.

### 019 App: exact output flows, runtime start, no Release swizzle
- Files: S/CmuxNextDaemon/Terminal/TerminalAttachment.swift, S/CmuxNextWakeups/TypingLatencyProbe.swift, S/CmuxNextTerminal/TypingFrameProbe.swift, S/CmuxNextTerminal/TerminalSurfaceView.swift, S/CmuxNextTerminal/TerminalOutputLane.swift.
- Change:
  - Flows are a runtime atomic with start and stop. The env var is the launch default.
  - A flow id is minted for each key-down while flows are on. A fixed table holds the open flows per
    surface (more than one in flight).
  - TerminalAttachment decodes `flow` for the decoded, main-hop and parsed marks.
  - In Release, the contents mark comes from 049. The setContents swizzle is installed only in DEBUG and
    bench builds.
- Acceptance:
  - `static let shared` no longer reads the env var for flows.
  - With flows started at run time, 3 keys sent before any echo give 3 chains.
  - The swizzle is inside `#if DEBUG || CMUX_BENCH_HOOKS` (rg).
- Test phase: fleet: `swift test --filter 'TypingLatencyProbe|TerminalAttachment'`.

### 020 trace.start/stop/status control methods (risk:high)
- Files: S/CmuxNextControl/Diagnostics/ControlRouter+Trace.swift, S/CmuxNextControl/Routing/ControlRouter+Builtins.swift, S/CmuxNextApp/Control/AppControl.swift, T/CmuxNextControlTests/TraceControlTests.swift.
- Change: `trace.start {categories?, seconds_cap <= 600, chromium?, keys?}`:
  - It opens the app recording ring and sets the flags.
  - It starts flows only when `keys` is true and secure input is off (128).
  - It sends daemon trace-start and starts Chromium tracing (051), in-process or through the host.
  - It shows the indicator (133).
  - A cap timer stops a recording that someone forgot.
  - `stop` returns the paths.
  - Parameters: no path and no command.
  - Access: refused over remote relays; allowed in cmuxOnly and automation modes.
- Acceptance:
  - Tests cover the relay refusal, status, the cap and `keys` false by default.
  - The PR body has the policy section and a review receipt.
- Test phase: fleet: `swift test --filter TraceControlTests`.

### 021 `cmux trace` CLI
- Files: R/cmux-tui/src/cli.rs, R/cmux-tui/src/cli/trace.rs.
- Change: `cmux trace record --seconds N --out DIR [--chromium] [--keys] [--categories ...]` calls
  trace.start, waits, stops, copies the rings and the Chromium JSON, and runs the exporter (022).
  `cmux trace start|stop|status` are the raw calls.
- Acceptance:
  - `--help` lists the options.
  - A fake-socket test checks the call order and the output files.
- Test phase: fleet: `cargo test -p cmux-tui cli_trace`.

### 022 Native Perfetto protobuf exporter
- Files: R/cmux-trace/src/{export.rs, proto.rs}, R/cmux-trace/tests/export.rs.
- Change: A hand-written varint and length-delimited encoder. It reads N rings and writes Process and
  ThreadDescriptors (role, name, QoS); TrackEvent slices and instants with interned names; AB/AE as async
  Tracks (uuid from the name and id); flows; counters; and one ClockSnapshot per machine (UPTIME_RAW to
  BUILTIN_CLOCK_MONOTONIC_RAW, plus the remote offsets from 116). It merges the Chromium JSON with its
  measured offset.
- Acceptance:
  - A golden test decodes the output with an in-test parser.
  - Two overlapping create.tab intervals on main import with 0 errors.
- Test phase: fleet: `cargo test -p cmux-trace export`; trace_processor_shell on the STRESS recording:
  0 import errors, and `select count(*) from flow` > 0.

### 023 trace.py: v1 rings, Release mode, exact flows, Chromium join
- Files: scripts/cmux-next/trace.py.
- Change:
  - A v1 reader for every role.
  - `record --release` uses `cmux trace`.
  - Flows use exact ids and fall back to windows only for old recordings.
  - New hops: the 12 handoffs, ghostty.render, frame.gpu_done and frame.present_estimate.
  - A cmux key flow joins Chromium's EventLatency where kGenerated equals the key's NSEvent timestamp.
- Acceptance: the self-test gains ring-parse, exact-flow, mixed and Chromium-join cases, and the old
  self-tests pass.
- Test phase: `python3 scripts/cmux-next/trace.py --self-test`; a fleet STRESS recording.

### 024 trace.py: percentiles and the clock-order check
- Files: scripts/cmux-next/trace.py.
- Change: summary.json gains key_to_present_estimate_ms and key_to_commit_ms {p50,p95,p99,max,n} per
  target, per-hop percentiles, clock_order_violations and request_flow_linked. A new command
  `check-clock DIR` exits 1 on a violation.
- Acceptance:
  - A planted out-of-order hop gives 1 violation.
  - The percentiles match a reference computation.
- Test phase: `trace.py --self-test`.

### 025 App-side daemon.request
- Files: S/CmuxNextDaemon/Connection/LineTransport.swift, S/CmuxNextDaemon/Connection/DaemonCommandName.swift.
- Change: `request(cmd:)` callers pass a typed `DaemonCommandName` (StaticString). It is generated from 013's
  `wire_name` list, and an unknown name maps to `other`. An AB is written at send and an AE on reply or
  timeout, with the outcome. The flow id goes into the arguments.
- Acceptance:
  - A `defer` ends the interval on every exit.
  - A fake-transport test gives matched pairs.
  - No dictionary or lock on the path.
  - trace.md closes this open request.
- Test phase: fleet: `swift test --filter LineTransportTests`.

### 026 Emit motion.frame and motion.run
- Files: S/CmuxNextLayout/Views/ScreenContentView+Motion.swift.
- Change: One motion.frame per window per tick (arguments: moved panes, frame dt). motion.run is an async
  pair from the structural change to rest (arguments: frames, max frame). Notify PL-motion-core.
- Acceptance: MQ1 no longer lists them. A spring test decodes N frames and 1 run.
- Test phase: fleet: `swift test --filter ScreenContentViewMotionTests`.

### 027 Emit switch.workspace
- Files: S/CmuxNextDesign/Diagnostics/SwitchFrameTimer.swift, S/CmuxNextApp/Control/DebugWorkspaceSwitch.swift.
- Change: The intent begins the async pair (input age), and CommitBoundary ends it. SwitchFrameTimer reads
  the same timestamps. Notify PL-switch.
- Acceptance: MQ1 clear. DEBUG and signpost durations agree within 0.1 ms.
- Test phase: fleet: `swift test --filter SwitchFrameTimerTests`.

### 028 Emit switch.tab
- Files: S/CmuxNextApp/Control/DebugTabSwitch.swift, S/CmuxNextBrowser/CEF/CEFLayerHosting.swift, S/CmuxNextDesign/Diagnostics/SwitchFrameTimer.swift.
- Change: An async pair with the kind (cold, warm, page), ended at the content commit. For Chromium, that
  is pageShown's first frame.
- Acceptance: MQ1 clear. 1 pair per switch.
- Test phase: fleet: `swift test --filter TabSwitchTimingTests`.

### 029 Emit switch.pane_focus
- Files: S/CmuxNextApp/Control/DebugPaneFocus.swift, S/CmuxNextApp/Focus/KeyRouter.swift.
- Change: From the focus intent to the settled focus commit, in every build.
- Acceptance: MQ1 clear.
- Test phase: fleet: `swift test --filter PaneFocusTimingTests`.

### 030 Emit create.tab
- Files: S/CmuxNextApp/PaneBrowserTabOpener.swift, S/CmuxNextApp/PaneController+Intents.swift, S/CmuxNextBrowser/CEF/CEFFirstPaintBridge.swift, S/CmuxNextTerminal/TypingFrameProbe.swift.
- Change: An async pair keyed by the intent id, from the key's turn to the first themed content frame for
  each kind (terminal, Chromium, WebKit, chat, page). A stand-in instant marks the stand-in commit. A tab
  that closes before its first frame ends with outcome=closed. Notify PL-cef-tab.
- Acceptance: MQ1 clear. Each kind ends exactly once, including the close case.
- Test phase: fleet: `swift test --filter CreateTabTimingTests`.

### 031 Emit create.workspace
- Files: S/CmuxNextSidebar/Logic/SidebarNewRowTimer.swift, S/CmuxNextApp/AgentTabs+OptimisticWorkspace.swift.
- Change: An async pair from the intent to the commit that draws the row.
- Acceptance: MQ1 clear.
- Test phase: fleet: `swift test --filter SidebarNewRowTimerTests`.

### 032 Emit cef.pump (role-aware)
- Files: S/CmuxNextBrowser/CEF/CEFMessagePump.swift, S/CmuxNextBrowser/CEF/CEFPumpStats.swift.
- Change: `fire()` wraps `work()` in cef.pump (arguments: armed reason, long-run flag, elapsed). Remove the
  Date() Logger.debug lines. This runs while the pump is in the app. With the Chromium host on, 104 emits
  the same name from the host.
- Acceptance: MQ1 clear. No Date() in CEFMessagePump.swift. The MetricKit mirror is unchanged.
- Test phase: fleet: `swift test --filter CEFPumpTests`.

### 033 Emit cef.create_browser (role-aware)
- Files: S/CmuxNextBrowser/CEF/CEFPaneHost.swift, S/CmuxNextBrowser/CEF/CEFSpareWindow.swift.
- Change: An async pair around each shim create (arguments: spare, profile index). In host mode, the pair
  closes on the host's created reply.
- Acceptance: MQ1 clear. Each `shim\.create` hit is inside a pair.
- Test phase: fleet: `swift test --filter CEFPaneHostTests`.

### 034 launch.* names, process-start clock, pageins temperature
- Files: S/CmuxNextApp/Control/DebugTimings.swift, S/CmuxNextApp/FirstFrameGate.swift, S/CmuxNextTrace/LaunchClock.swift.
- Change:
  - Emit the 5 launch names.
  - The process start comes from PROC_PIDTBSDINFO, converted to uptime.
  - The temperature comes from `task_info(TASK_EVENTS_INFO).pageins`, sampled at the first main run-loop
    turn, with Chrome's thresholds (warm < 5, cold >= 3500; cited from memory) as named constants.
  - Record launch.pageins.
- Acceptance:
  - The launch category has >= 5 names with emitters.
  - The process start is within 5 ms.
  - The pure temperature function is tested at each threshold.
- Test phase: fleet: `swift test --filter LaunchClockTests`; bench-startup.py per temperature.

### 035 Raw OSSignposters, batch 1
- Files: S/CmuxNextTerminal/TerminalTimings.swift, S/CmuxNextDaemon/Launch/DaemonLaunchTimings.swift, S/CmuxNextAgentPane/AgentPaneLaunchTimings.swift.
- Change: Use stall.create_surface and launch.* through Signposter.
- Acceptance: MQ2 <= 3.
- Test phase: audit catalog.

### 036 Raw OSSignposters, batch 2
- Files: S/CmuxNextApp/Control/{DebugTimings.swift, DebugTabSwitch.swift, DebugPaneFocus.swift}, scripts/cmux-next/trace.py.
- Change: Use stall.palette_open, stall.icon_picker_open, switch.tab and switch.pane_focus. Remove the
  local statics. Update the trace.py stalls mapping.
- Acceptance: MQ2 = 0.
- Test phase: audit catalog; trace.py `--self-test`.

### 037 frame.tick, frame.commit, frame.present_estimate
- Files: S/CmuxNextWakeups/FrameScheduler.swift, S/CmuxNextSignposts/CommitBoundary.swift.
- Change:
  - `deliver` writes frame.tick (timestamp, targetTimestamp) under the frame category.
  - CommitBoundary writes frame.commit.
  - For a flow-marked commit, the first tick whose target >= max(commit, gpu_done when 048 is present)
    writes frame.present_estimate (flow, target, flag "estimated").
  - With the link idle, it asks for one tick while recording only.
  - As built: `FramePresentEstimate` writes frame.commit once per main run-loop turn end, from one observer
    after Core Animation's (arg0 the first flow it carries, arg1 how many). frame.tick names its display
    (arg1: display id in the high 32 bits, nanoseconds to the target in the low 32). Presents are per
    display: a flow is presented by its window's display, and the one tick is asked of that display. The
    typing probe's echo commit (019, the contents mark) marks the flow.
  - Covers perf-hot frame-tick.
- Acceptance:
  - Off: one load in `deliver`.
  - Fake-link tests: commit then tick; and a gpu_done that comes after the vsync moves the present one
    frame later.
- Test phase: fleet: `swift test --filter FrameSchedulerTests`.

### 038 perf-hot: cef.geometry and cef.host_input
- Files: S/CmuxNextApp/Windows/WindowOverlayLayer.swift, S/CmuxNextBrowser/CEF/CEFHostView.swift, S/CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostConnection.swift.
- Change: cef.geometry is an interval around parentGeometryDidChange and syncCatchers, with an instant per
  post. cef.host_input is an instant per send. Notify PL-motion-cef.
- Acceptance: MQ5 clear for these ids.
- Test phase: audit catalog.

### 039 perf-hot: motion.drag_frame and switch.app_activation
- Files: S/CmuxNextApp/Drag/TabDragSession+Ghost.swift, S/CmuxNextDesign/WindowKeyFamily.swift.
- Change: An interval per drag tick, and one per keyDidMove.
- Acceptance: MQ5 clear for drag-frame and cmd-tab.
- Test phase: audit catalog.

### 040 perf-hot: key.omnibar_suggest and key.palette_search
- Files: S/CmuxNextBrowser/Omnibox/OmnibarReducer.swift, S/CmuxNextPalette/PaletteModel+Search.swift.
- Change: Intervals with the result count. home-key maps to key.frame target=view in 041.
- Acceptance: MQ5 clear for these ids.
- Test phase: audit catalog.

### 041 perf-hot-benches.json `trace` field
- Files: scripts/cmux-next/perf-hot-benches.json, scripts/cmux-next/guardrails.py.
- Change: All 15 ids get `trace: [names]`. The guardrails warning text prints them (message only).
- Acceptance: Every id has existing names. The guardrails diff changes only the message format.
- Test phase: `guardrails.py --list`; audit catalog.

### 042 Task tracing for BackgroundWork, LaneScheduler, MainActorWorkQueue
- Files: S/CmuxNextWakeups/{BackgroundWork.swift, LaneScheduler.swift, LaneJob.swift}, S/CmuxNextControl/Concurrency/MainActorWorkQueue.swift.
- Change: Default arguments `file: StaticString = #fileID, line: UInt = #line` are interned. A post writes
  a task.post flow-out. A run writes a task.run scope with the flow-in, the lane, the priority and the
  queue wait. Control requests get control.request scopes.
- Acceptance: No call-site changes. 3 jobs decode as 3 flow pairs with the correct sites.
- Test phase: fleet: `swift test --filter 'BackgroundWorkTests|MainActorWorkQueueTests'`.

### 043 Release marks from the DEBUG terminal-creation traces
- Files: S/CmuxNextWakeups/NewTerminalTrace.swift, S/CmuxNextTerminal/TerminalSession+NewTerminalTrace.swift, S/CmuxNextTerminal/TerminalFinalGridTrace.swift.
- Change: The mark points write create.tab instants in every build. The aggregation stays in `#if`.
- Acceptance: MQ4 clear for these files.
- Test phase: fleet: Release compile check.

### 044 Release marks from ChatOpenTrace, MotionFrameTrace, BurstTrace
- Files: S/CmuxNextWakeupsDisplay/ChatOpenTrace.swift, S/CmuxNextDesign/Motion/MotionFrameTrace.swift, S/CmuxNextControl/Diagnostics/BurstTrace.swift.
- Change: As 043.
- Acceptance: MQ4 = 0.
- Test phase: Release compile check; audit.

### 045 / 046 / 047 Wall clock to TraceClock (batches)
- Files: 045: S/CmuxNextControl, S/CmuxNextWakeups, S/CmuxNextDesign. 046: S/CmuxNextBrowser,
  S/CmuxNextBrowserCore. 047: S/CmuxNextApp, S/CmuxNextTerminal, S/CmuxNextDaemon and the rest.
- Change: Each MQ6 hit that computes a duration or a trace time uses TraceClock. A user-visible date keeps
  Date() with `// wall-clock: <why>`.
- Acceptance: MQ6 is clear in the batch paths. After 047, wallclock_duration_sites = 0.
- Test phase: audit clocks; fleet tests of the touched targets.

### 048 ghostty-next trace hook
- Files: ghostty-next/include/ghostty.h, ghostty-next/src/renderer/Thread.zig, ghostty-next/src/renderer/Metal.zig, ghostty-next/src/apprt/embedded.zig (submodule; fork owned by PL-ghostty), plus the cmux gitlink.
- Change: `ghostty_set_trace_hook(fn(ctx, event u32, surface u64, seq u64))` is a process-wide atomic
  function pointer. Events: frame begin and end (drawFrame), IOSurface handoff, gpu_done (Metal
  addCompletedHandler), IO write, surface destroy. Off, it costs one load. Land it with PL-ghostty's G1
  change, so the renderer path changes once.
- Acceptance: The off path is one load (review). Fork CI passes. The gitlink bump is in the same push as
  049.
- Test phase: fleet: GhosttyNextKit build and the cmux compile.
- As built (ghostty-next branch `cp/p09-observability-048`; 049 writes against this interface):
  - `ghostty_set_trace_hook(const ghostty_trace_hook_s*)`. The record `{callback, ctx}` is owned by the
    embedder and never changes or is freed while the process runs. The fork keeps one atomic pointer to it,
    so a callback and its ctx can never be paired wrongly. NULL, or a NULL callback, turns the hook off.
  - `ghostty_trace_hook_cb(void* ctx, ghostty_trace_event_e event, uint64_t surface, uint64_t seq)`.
    `surface` is `ghostty_surface_trace_id(surface)`: nonzero and never reused. The surface pointer is not
    used, because a present queued to main can arrive after `ghostty_surface_free`, when a new surface can
    have the same address.
  - Events: `FRAME_BEGIN` (seq = the number the frame gets if the draw commits) and `FRAME_END` (seq = the
    committed frame, or 0 when nothing was drawn). They come from Metal `drawFrameStart`/`drawFrameEnd`,
    not from Thread.zig, so the main-thread display-pass draws are included. `GPU_DONE` comes from the
    completed handler. `CONTENTS_SET` comes when the frame's IOSurface becomes the layer contents (one
    frame can be reported twice in a host-size change: count the first). `IO_WRITE` (seq = byte count)
    comes before a MANUAL surface's `io_write_cb`. `SURFACE_DESTROY` comes after `ghostty_surface_free`.
  - The gitlink and the CmuxGhosttyKit pin stay where they are: the bump is made with 049, after the fork
    PR is merged and its GhosttyNextKit release is out.

### 049 cmux registers the Ghostty hook
- Files: S/CmuxNextTerminal/GhosttyTraceHook.swift, S/CmuxNextTerminal/TerminalSurfaceView.swift.
- Change: A `@convention(c)` hook writes ghostty.render begin and end, frame.gpu_done and the contents mark
  (IOSurface handoff) for the surface's open flow (019's table). It also gives 054 its sample end. It is
  installed at start. When nothing uses it, the pointer is null. At the IOSurface handoff it also calls
  the surface's `TerminalEchoStage.contentsSet()` (p04-input-006), and `TerminalEchoStages.makeStage()`
  then makes echo stages in Release too (today only DEBUG and bench builds, which have the swizzle).
  The contents mark goes through `TypingLatencyProbe.mark(.contents, surface:)`, so 037's
  `FramePresentEstimate` dates the echo's present with no extra call. Only a frame handed to its layer
  before its GPU work ends marks its commit with `awaitsGPU: true` and calls
  `FramePresentEstimate.gpuDidFinish(flow:atNanos:)` from the Metal completion handler (on main).
- Acceptance:
  - 0 allocations (synthetic call test).
  - In a STRESS trace, ghostty.render falls between app.output.parsed and frame.commit.
- Test phase: fleet: `swift test --filter GhosttyTraceHookTests`; a STRESS recording.

### 050 In-repo CEF shim: tracing exports (no fork)
- Files: Packages/macOS/CmuxNext/CEFShim/src/shim_tracing.mm, S/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h.
- Change: `cmux_cef_begin_tracing(categories, started_fn, ctx)`, `cmux_cef_end_tracing(path, written_fn, ctx)`
  and `cmux_cef_now_trace_us()` wrap the stock CEF API (`include/cef_trace.h`). They post to the browser UI
  thread, and each callback runs once (the failure value when CEF refuses or drops the request). The output
  is legacy JSON; CEF's public API has no proto end, and this reason is written in the code.
  - No buffer size: `CefBeginTracing` builds `TraceConfig(categories, "")`, so Chromium's default
    record-until-full buffer applies. A set size needs the CEF fork (TraceConfig JSON
    `trace_buffer_size_in_kb`).
  - The written path means Chromium finished the recording, not that the file exists or is complete
    (Chromium ignores open and write errors). The caller stats and parses it off the main thread.
- Acceptance: The header declares the 3 functions. A Release-build embedder case writes JSON.
  - Open: the embedder case is not written yet. 051's fleet Release run `cmux trace record --chromium` is
    the first real run of these exports.
- Test phase: fleet: `cmux-ci build cmux`; `scripts/cmux-next/test-shim-tracing-cpp.sh`.

### 051 Chromium tracing in Release (role-aware)
- Files: S/CmuxNextBrowser/CEF/CEFShimLibrary.swift, S/CmuxNextBrowser/CEF/CEFTracing.swift, S/CmuxNextControl/Diagnostics/ControlRouter+Trace.swift.
- Change: `trace.start chromium:true` begins tracing (toplevel, cc, viz, gpu, input, latencyInfo,
  benchmark; Chromium's default buffer, because 050 has no buffer size on stock CEF) in-process, or
  through the host wire TRACE_START (104) when the Chromium host is on. It records the clock offset in
  meta.json and ends into the recording directory.
- Acceptance: Host mode off and on both produce JSON. The offset is in meta.json. A missing host symbol
  reports unsupported.
- Test phase: fleet Release: `cmux trace record --chromium`; trace.py shows the GPU and renderer tracks.

### 052 CmuxNextMetrics
- Files: S/CmuxNextMetrics/{HistogramID.swift (filled from 000), Histogram.swift, MetricsStore.swift, MetricsProfile.swift}, T/CmuxNextMetricsTests/HistogramTests.swift.
- Change:
  - Log-linear buckets, 4 sub-buckets per octave, with a golden shared with Rust (131).
  - `record()` is 3 relaxed adds into a per-launch `MAP_SHARED` file, adopted from a spare file off main.
  - The header has the system profile.
  - Each bucket has a "logged" shadow, so a report sends current minus logged.
  - An expired id records nothing.
- Acceptance:
  - No lock or allocation (test).
  - The edges match Rust for 1000 random values.
  - Expiry test.
  - Delta test: 2 snapshots send each sample once.
- Test phase: fleet: `swift test -c release --filter CmuxNextMetricsTests`.

### 053 Previous-launch fold and boot-session beacon
- Files: S/CmuxNextMetrics/MetricsLaunchFold.swift, S/CmuxNextApp/Crash/AppRunMarker.swift.
- Change: At launch, read each earlier launch's file as its own report section with its own profile, and
  delete it after the upload succeeds. The run marker stores `kern.bootsessionuuid`. An unclean exit with a
  different boot session counts as system_shutdown, not as a crash.
- Done in 053: `MetricsLaunchFold` and `MetricsLaunchFileReader` (S/CmuxNextMetrics/MetricsLaunchFileReader.swift),
  which maps a 052 file read-only and gives its profile, delta and a section id from the header (role, pid,
  start time, boot session; never the file name, because pids are reused). 063 owns the launch-time call:
  it runs the fold with `MetricsLaunchFileReader(role: .app)` off main and sends each section with its
  report upload.
- Acceptance: A crashed launch's file is folded once and kept under its own version. The fold is
  idempotent. A boot-change test passes.
- Test phase: fleet: `swift test --filter MetricsLaunchFoldTests`.

### 054 Record key.frame and the sampled key.echo_frame
- Files: S/CmuxNextSignposts/KeyFrameSignpost.swift, S/CmuxNextWakeups/TypingLatencyProbe.swift, S/CmuxNextTerminal/GhosttyTraceHook.swift.
- Change: key.frame per target. key.echo_frame samples 1 key in 16 while no sample is open, from key-down
  to the hook's contents mark for that surface. There is no swizzle and no CSV. Add a `remote` dimension
  (local, bridge, cloud).
- Acceptance: MQ12 clear for these ids. With sampling off, one load per key. A synthetic-marks test.
- Test phase: fleet: `swift test --filter 'KeyFrame|TypingLatencyProbe'`.

### 055 Record main.turn and hang.over250.per_hour
- Files: S/CmuxNextControl/Diagnostics/MainThreadWatchdog.swift.
- Change: The heartbeat observer records each turn's busy time. Stalls of 250 ms or more count per active
  hour.
- Acceptance: MQ12 clear for these ids. No new observer or timer.
- Test phase: fleet: `swift test --filter MainThreadWatchdogTests`.

### 056 Record action.commit and Cmd-T/N/W
- Files: S/CmuxNextControl/ActionBudget/ActionBudgetLedger.swift.
- Change: The fold off main records per entrypoint, plus tab.new, window.new and tab.close with missed
  frames (057).
- Acceptance: MQ12 clear for these ids. Nothing new on the action path.
- Test phase: fleet: `swift test --filter ActionBudgetLedgerTests`.

### 057 FrameSequenceTracker for motion and action windows
- Files: S/CmuxNextWakeups/FrameSequenceTracker.swift, S/CmuxNextWakeups/FrameScheduler.swift.
- Change: A tracker is open during motion.run and for 3 frames after each commit. It counts expected
  vsyncs against frames that committed changes, and records smoothness.dropped_pct.motion,
  frame.interval and a frame.sequence ring summary.
- Acceptance: Synthetic tick tests with 0, 1 and 5 drops at 60 Hz and 120 Hz pass. While closed, it costs
  one branch per tick.
- Test phase: fleet: `swift test --filter FrameSequenceTrackerTests`; anim-perf-terminal.py.

### 058 Record launch first frame per temperature
- Files: S/CmuxNextApp/FirstFrameGate.swift.
- Change: Record launch.first_frame.<temperature> from 034.
- Acceptance: MQ12 clear for the launch ids.
- Test phase: bench-startup.py cold and warm.

### 059 Record idle wakeups
- Files: S/CmuxNextMetrics/IdleWakeupSampler.swift, S/CmuxNextApp/AppServices.swift.
- Change: At the existing resign-active and become-active transitions and at report triggers, read
  `proc_pid_rusage` V4 (interrupt and package-idle wakeups) for the app and the daemon, plus the watchdog's
  main wake count. A period with no input while inactive counts as idle.
- Acceptance: No timer and no new observer. Fake-provider tests.
- Test phase: bench-idle.sh: within 10% of the bench's own count.

### 060 Record the CEF pump and helper exits (role-aware)
- Files: S/CmuxNextBrowser/CEF/CEFPumpStats.swift, S/CmuxNextBrowser/CEF/CEFRuntime+Crashes.swift.
- Change: cef.pump per pass, and cef.helper_exit (process type × reason). In host mode the pump numbers
  come from the host's metrics file (104).
- Acceptance: MQ12 clear for the cef ids.
- Test phase: fleet: `swift test --filter CEFPumpTests`.

### 061 Memory per hidden workspace via renderer pids
- Files: S/CmuxNextMetrics/MemorySampler.swift, S/CmuxNextApp/HangReports/HangReportsController.swift, Packages/macOS/CmuxNext/CEFShim/src/shim_browser.mm, S/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h.
- Change:
  - A shim export gives the render process id for each browser.
  - At workspace hide and show, at resign-active and at report triggers, sum `ri_phys_footprint` per
    workspace.
  - A renderer shared between visible and hidden tabs counts by the share of its hidden frames.
  - Record memory.hidden_workspace_kib only when the attribution is clear. Count the unclear samples.
    Each sample is tagged with its trigger kind.
- Acceptance: MQ12 clear for the memory ids. Fake-provider tests, including a shared renderer.
- Test phase: STRESS report preview.

### 062 Fold daemon request latency
- Files: S/CmuxNextApp/HangReports/HangReportsController.swift, S/CmuxNextMetrics/ChildMetricsReader.swift.
- Change: At a report, map the daemon's metrics file (131) read-only and fold daemon.request.<class>. No
  socket request.
- Acceptance: MQ12 clear for the daemon ids. A missing file is counted.
- Test phase: STRESS report preview.

### 063 Hang reports schema 3
- Files: S/CmuxNextHangReports/{HangReport.swift, HangReportBuilder.swift, HangReportCollector.swift, PrivacyLeakScanner.swift}, T/CmuxNextHangReportsTests/HangReportWireFormatTests.swift.
- Change:
  - `histograms[]`: name (catalog only), unit, buckets as `[index,count]`, count, sum, max. At most 32
    histograms × 24 buckets, deltas only.
  - `stability{}` from 109.
  - Per-launch sections with profiles: at launch, run 053's `MetricsLaunchFold` with
    `MetricsLaunchFileReader(role: .app)` off main, send each section under its id, and delete its file
    only after the upload succeeded.
  - `blackbox[]`: up to 512 events taken at a hang >= 1 s or a key.frame > 50 ms, merged from the app,
    daemon and involved host rings with a process field. Key and per-key PTY records are filtered out
    (128).
  - The body is at most 48 KiB, and blackbox is dropped first when the body is too large.
  - Sent only after the server-version flag (default off until 064 deploys).
- Acceptance:
  - Round trip.
  - A non-catalog name is refused.
  - A full-cap body is <= 48 KiB.
  - 0 key records.
- Test phase: fleet: `swift test --filter CmuxNextHangReportsTests`.

### 064 Web (main): schema 3
- Files: web/services/hangReports/, web/app/api/hang-reports/route.ts, web/scripts/hang-reports-histograms.ts.
- Change:
  - Decode schema 2 and 3.
  - Unknown histogram names that match `^[a-z0-9_.]{1,64}$` are dropped and counted. Only a bad shape gets
    400, and an oversize body gets 413.
  - Add `catalog_version`. The data is stored as jsonb, with no migration.
  - A read-only merge script prints p50, p95 and p99 per name, version and day.
- Acceptance:
  - bun tests: 204, 204 with the name dropped, 400 and 413.
  - The lints in CLAUDE.md pass.
  - It deploys before 063's flag turns on.
- Test phase: `bun test` in web/; a PR on main.

### 065 metrics.snapshot, `cmux metrics`, View Metrics
- Files: S/CmuxNextControl/Diagnostics/ControlRouter+Metrics.swift, R/cmux-tui/src/cli/metrics.rs, R/cmux-tui/src/cli.rs, S/CmuxNextActions/Catalog, S/CmuxNextActions/HangReportsActions.xcstrings.
- Change:
  - A read-only method, whose only parameter is `names`.
  - A CLI table, or `--json`.
  - The palette action diagnostics.viewMetrics opens the JSON in a file tab. It is bound with
    `bindEffect`, and its strings are in all locales.
- Acceptance: The policy note is in the PR. The localization audit is reported.
- Test phase: fleet: `swift test --filter MetricsControlTests`; `cargo test -p cmux-tui cli_metrics`.

### 066 HangWatch slots and scope (core)
- Files: S/CmuxNextTrace/HangWatch.swift, T/CmuxNextTraceTests/HangWatchTests.swift.
- Change:
  - `registerThread(kind, name)` and `registerLane(name)` return a token.
  - Slots are in a growable chunked table. Each holds the thread port, the name id and a packed atomic
    deadline with flags.
  - `HangWatchScope` is `~Copyable` and nests.
  - A lane scope stores `mach_thread_self()`.
  - `invalidateActive()`.
- Acceptance:
  - Open and close are two stores and no syscall.
  - Nesting test.
  - 2,000 registrations.
- Test phase: fleet: `swift test --filter HangWatchTests`.

### 067 Hang monitor (watcher rule, drift)
- Files: S/CmuxNextControl/Diagnostics/{MainThreadWatchdog.swift, MainThreadWatchdogAlarm.swift, HangMonitor.swift}.
- Change:
  - The section E rule: armed while scopes open, parked after a quiet minimum-deadline period, one
    EVFILT_USER on the first open after it parks.
  - Drift tolerance of 100 ms.
  - Records hang.thread_hung.<lane> per active hour.
  - Overdue slots are marked block-on-capture, then captured (068).
- Acceptance:
  - 0 wakes over 10 s idle.
  - <= 1 wake/s under a synthetic burst pattern at a 1 s minimum deadline (section E), plus the first
    open's wake. The app's slot table keeps a 100 ms minimum deadline (p02-threads RUN-8 must see a 150 ms
    stall on a 100 ms budget), so there a burst makes about 10 wakes/s.
  - Detection within deadline + minimum deadline + 50 ms.
  - A late watcher blames nobody.
- Test phase: fleet: `swift test --filter 'HangWatch|MainThreadWatchdog'`; bench-idle.sh.

### 068 Stack sample and hang report
- Files: S/CmuxNextControl/Diagnostics/ThreadStackSampler.swift, S/CmuxNextApp/HangReports/WatchdogReporting.swift, S/CmuxNextCrashReporting/MainThreadHangEvent.swift, S/CmuxNextHangReports/HangSample.swift.
- Change: Sample the registered thread by its port. Send a Sentry hang event tagged `hang.thread`, add a
  `thread-hang` report entry and a ring instant, and trigger the last-hang bundle (125).
- Acceptance: A blocked thread gives 1 event with its name and frames, and no duplicate within the
  interval.
- Test phase: fleet: `swift test --filter ThreadHangReportTests`.

### 069 Register Swift lanes, batch 1
- Files: S/CmuxNextDaemon/Connection/{LineTransport.swift, SocketWriter.swift}, S/CmuxNextTerminal/{TerminalOutputLane.swift, LocalPTYTerminalIO.swift}.
- Change: One scope per unit of work (a line parse, an outbox drain, an output chunk, a PTY write). The
  read(2) wait stays outside the scope. Deadlines: 1 s, and 2 s for a write.
- Acceptance: One scope per item. The threading-model rows say hang-watched.
- Test phase: hang-matrix lanes daemon-reader, terminal-output and localpty.

### 070 Register Swift lanes, batch 2
- Files: S/CmuxNextWakeups/{BackgroundWork.swift, LaneScheduler.swift}, S/CmuxNextControl/ControlService.swift, S/CmuxNextCompat/Threading/BlockingDetector.swift.
- Change: Lane jobs run in a lane scope (.files 5 s, .system and .cpu 10 s). Control accept and
  per-connection handlers are registered. BlockingDetector registers through a Compat callback that the
  composition root sets.
- Acceptance: One scope per job. No upward import (layer ratchet).
- Test phase: hang-matrix lane backgroundwork.

### 071 Rust cmux-hang-watch
- Files: R/cmux-hang-watch/{Cargo.toml, src/lib.rs, tests/watch.rs}, cmux-tui/Cargo.toml.
- Change:
  - `register_thread(name)` returns a Guard; `watch(deadline)` returns a Scope; `invalidate_active()`.
  - A chunked slot table.
  - One watcher thread with the section E rule (Condvar), and drift tolerance.
  - A hang appends one line to hangs-<pid>.jsonl.
  - std+libc only. It builds on Linux and Windows; the sampler is macOS-only.
- Acceptance:
  - 0 wakes in 5 s idle.
  - Detection within the bound.
  - No allocation on scope open or close.
  - The cross-target check passes.
- Test phase: fleet: `cargo test -p cmux-hang-watch`.

### 072 Mach stack sampler
- Files: R/cmux-hang-watch/src/sample_macos.rs, cmux-tui/.cargo/config.toml (x86_64 force-frame-pointers for the shipped binaries).
- Change:
  - Between `thread_suspend` and `thread_resume`, the sampler only reads registers and walks frame
    pointers into a preallocated `[u64; 128]` within the stack bounds.
  - After resume, it maps the frames to image UUID and offset from a table that
    `_dyld_register_func_for_add_image` caches.
  - A scope guard makes sure resume always runs.
- Acceptance:
  - A thread parked in a known function resolves to that function.
  - A thread blocked inside malloc does not deadlock the sampler.
- Test phase: fleet: `cargo test -p cmux-hang-watch sample`.

### 073 Daemon hang-watch registrations
- Files: R/cmux-tui-core/src/server/{connection_frame.rs, connection_scheduler.rs}, R/cmux-tui-core/src/mux/terminal_work.rs, R/cmux-tui-core/src/journal_ingress.rs, R/cmux-tui-core/src/journal_ingress/.
- Change:
  - mux-control-dispatch: one scope per request, with the MethodClass deadline. Methods that may wait call
    `invalidate_active` around the network or process wait, and the trace marks the wait.
  - mux-conn: one scope per frame.
  - Journal writer: one scope per batch (5 s).
  - terminal-work: one scope per job.
  - line-out: one scope per write (2 s).
- Acceptance: `rg 'hang_watch::'` hits each file. The suite is green.
- Test phase: fleet: `cargo test -p cmux-tui-core`; hang-matrix daemon lanes.

### 074 Holder, host and acpmux sync-thread registrations
- Files: R/cmux-holder/src/holder.rs, R/cmux-tui-core/src/terminal_host_runtime/shared/host_shared.rs, R/acpmux/src/daemon.rs.
- Change: Holder: one scope per poll iteration's work. Host: one per pty, parser and client-input item.
  acpmux: one per `spawn_blocking` and sync-thread item. Async workers are covered by 118.
- Acceptance: Each loop thread calls `register_thread`. The suites are green.
- Test phase: fleet: `cargo test -p cmux-holder -p acpmux`; hang-matrix.

### 075 RustDiagnosticsForwarder
- Files: S/CmuxNextCrashReporting/{OwnerPanicForwarder.swift, RustPanicSource.swift}, S/CmuxNextApp/Crash/CrashReporter+Launch.swift, S/CmuxNextHangReports/HangReportCollector.swift.
- Change:
  - A list of (log pattern, source, kind) for every role in 095, 099 and 100.
  - Hang lines become Sentry events with `threads[].stacktrace.frames` (instruction_addr = image address +
    offset) and `debug_meta.images` (uuid, address, size, code_file).
  - The fingerprint is the top 3 in-app frames and the thread name.
  - Each hang line is also a hang-report entry.
- Acceptance:
  - A fixture line gives frames and debug_meta that list every UUID.
  - Lines are forwarded once, across restarts.
  - Nothing is forwarded while telemetry is off.
- Test phase: fleet: `swift test --filter OwnerPanicForwarderTests`.

### 076 Sentry: app-hang tracking off, trimmed, measured
- Files: S/CmuxNextCrashReporting/CrashReporter.swift, T/CmuxNextCrashReportingTests/CrashReporterOptionsTests.swift.
- Change: `enableAppHangTracking = false` (only after 110). `enableMetricKit = false` (hang reports own
  MetricKit). Review swizzling and breadcrumbs against CLISentryRuntimePolicy. Record before and after main
  wakes/s in the commit.
- Acceptance: The options test passes. The commit has the numbers.
- Test phase: bench-idle.sh A/B.

### 077 Attribute hangs inside the CEF pump (role-aware)
- Files: S/CmuxNextBrowser/CEF/CEFMessagePump.swift, S/CmuxNextControl/Diagnostics/MainThreadWatchdog.swift.
- Change: The in_cef_pump key is set around `work()` in whichever process runs the pump. Stall and hang
  records carry `cef=true`, with the tag hang.cef.
- Acceptance: A stall during a fake pump is tagged.
- Test phase: fleet: `swift test --filter MainThreadWatchdogTests`.

### 078 Crash keys page (Swift)
- Files: S/CmuxNextTrace/CrashKeys.swift, S/CmuxNextActions/SignpostActionRunTiming.swift, S/CmuxNextWakeups/MainTaskBoard.swift.
- Change:
  - A fixed-slot mmap page per launch (adopted off main), with slots from 000.
  - Keys: action and entrypoint, main_task owner, in_cef_pump, last_input_uptime, count buckets, daemon pid
    and state, cef_api, ghostty_commit, and `hang_in_progress` (for 110).
  - `ScopedCrashKey` restores the old value.
- Acceptance: Relaxed stores only. A child abort leaves a page that decodes.
- Test phase: fleet: `swift test --filter CrashKeysTests`.

### 079 Black box and crash keys on the next-launch crash event
- Files: S/CmuxNextCrashReporting/CrashReporter.swift, S/CmuxNextApp/Crash/{CrashReporter+Launch.swift, RunMarkerFile.swift}.
- Change: Before Sentry sends cached events, read the previous run's ring and keys. `beforeSend` for
  crash-level events adds the keys as tags. When the hang-reports opt-in is on, it also adds `blackbox.txt`
  (the last 512 events, catalog names and numbers, no key records), passed through the scrubber.
- Acceptance: The attachment is added once. Privacy test: only catalog strings and 0 key records.
- Test phase: crash-matrix app kinds.

### 080 Holder panic log with a std-only writer
- Files: R/cmux-holder/src/main.rs, R/cmux-holder/Cargo.toml, R/cmux-panic-log/{Cargo.toml, src/lib.rs, src/minimal.rs}, S/CmuxNextCrashReporting/RustPanicSource.swift.
- Change: cmux-panic-log gains a `minimal` feature with no serde_json and a hand-escaped JSON line. The
  holder installs it (holder-panics.jsonl). Add `RustPanicSource.holder`.
- Acceptance:
  - The holder dependencies are std, libc, cmux-flow-trace, cmux-trace, cmux-hang-watch and
    cmux-panic-log/minimal (all std+libc).
  - A panic test writes one line.
- Test phase: fleet: `cargo test -p cmux-holder panic -p cmux-panic-log`.

### 081 Terminal-host crash sidecars to Sentry
- Files: R/cmux-tui-core/src/terminal_host_runtime/shared/host_crash.rs, R/cmux-tui/src/owner_start/owner_panic.rs, S/CmuxNextCrashReporting/RustPanicSource.swift.
- Change: When the owner reads a .crash sidecar, it appends a panic-log line (source cmux-tui-host) before
  it deletes the sidecar.
- Acceptance: A sidecar becomes one line.
- Test phase: fleet: `cargo test -p cmux-tui-core host_crash`.

### 082 Rust panic lines carry the scope stack
- Files: R/cmux-panic-log/src/lib.rs, R/cmux-trace/src/lib.rs.
- Change: The panic hook adds the thread's scope stack (innermost first), the uptime and the role.
- Acceptance: A panic inside a scope prints its name (tests/hook.rs).
- Test phase: fleet: `cargo test -p cmux-panic-log`.

### 083 Chromium helper exits as Sentry events
- Files: S/CmuxNextBrowser/CEF/CEFRuntime+Crashes.swift, S/CmuxNextApp/Crash/CrashRecoveryService.swift, S/CmuxNextCrashReporting/SystemCrashEvent.swift.
- Change: Each abnormal helper exit sends one event (type, subtype, reason, code, pump state; no URL or
  title). The limit is 1 per type per hour. The pid is kept, to match the .ips file and the minidump.
- Acceptance: 3 crashes give 1 event. The scrubber test passes.
- Test phase: crash-matrix renderer, GPU and utility.

### 084 CEF FATAL line (role-aware)
- Files: S/CmuxNextApp/Crash/{CrashReporter+Launch.swift, AppRunMarker+Chromium.swift}.
- Change: After an unclean exit of the process that ran CefInitialize (the app or the Chromium host),
  read the tail of cef.log (<= 64 KiB). Keep only `FATAL:<path>:<line>]` plus 120 characters with URLs
  removed, and put it in the tag cef.fatal.
- Acceptance: Planted URL lines are redacted.
- Test phase: fleet: `swift test --filter CEFFatalLineTests`.

### 085 dSYMs for every shipped binary (risk:high)
- Files: .github/workflows/nightly.yml, scripts/upload-sentry-dsyms.sh, scripts/cmux-next/embed-cef.sh, scripts/cmux-next/build-cmux-tui-client.sh, scripts/cmux-next/bundle-server-helper.sh, scripts/build-diff-sidecar.sh.
- Change:
  - Run `dsymutil` next to the lipo step for cmux-cef-helper, cmux-chromium-host and the shim.
  - Keep split debuginfo for cmux-app-host, cmux-browser-host, cmux-cloud, optchat-chief,
    cmux-diff-sidecar and server-helper.
  - Add the CEF framework dSYM when the pinned archive has one (symbol_level=1).
  - Extend only the existing `for dsym in` list (nightly.yml:2442).
- Acceptance: Only the path list changes in nightly.yml. Missing paths are skipped. Review receipt.
- Test phase: next nightly: `sentry-cli debug-files check` for each UUID.

### 086 Sentry recorder transport (DEBUG and bench)
- Files: S/CmuxNextCrashReporting/SentryRecorderTransport.swift, S/CmuxNextCrashReporting/CrashReporter.swift.
- Change: With `CMUX_NEXT_SENTRY_RECORDER=<dir>`, envelopes are written to files. The type is compiled out
  of Release.
- Acceptance: The type is only inside `#if` (rg). An event lands as a file.
- Test phase: fleet: `swift test --filter SentryRecorderTransportTests`.

### 087 crash-matrix.py
- Files: scripts/cmux-next/crash-matrix.py.
- Change: For each kind in done check 8:
  - Launch a tagged bench app with the recorder and start a fresh holder (check its build id).
  - Trigger the crash with 101's injectors, kill or chrome:// URLs, then relaunch or wait.
  - Check that exactly 1 envelope arrived, with its tags, keys, black box (app kinds, 0 key records), dSYM
    UUIDs and stability counter.
  - Check that the app pid survives for Chromium, WebKit and host kinds.
  - The chromium-host kind runs only when the host flag is on.
- Acceptance: `--self-test` checks the parsers. It signals only processes it started.
- Test phase: nx-remote `--needs gui`.

### 088 hang-matrix.py and hang injection
- Files: scripts/cmux-next/hang-matrix.py, S/CmuxNextControl/Diagnostics/HangInjectControl.swift, R/cmux-tui-core/src/server/debug_hang_inject.rs.
- Change:
  - `debug.hang_inject {lane, ms}`, and daemon `debug-hang-inject` for the daemon, holder, host and
    acpmux lanes (compiled out of Release).
  - The script runs each lane in done check 7 and the fatal case.
  - The soak uses an injected clock for sleep. A real sleep runs only with `--exclusive-host` and
    `pmset schedule wake`.
- Acceptance: The injectors are inside cfgs. `--self-test` passes.
- Test phase: nx-remote `--needs gui`.

### 089 Nightly sink for blocking violations
- Files: S/CmuxNextCompat/Threading/BlockingDetector.swift, S/CmuxNextHangReports/{HangReportCollector.swift, HangReport.swift}.
- Change: With the Nightly `CMUX_BLOCKING_CHECKS` flag (owned by the blocking program), blocking drains
  hand {kind, image UUID + offset frames} to the collector. Schema 3 gets `blocking[]` (at most 32).
- Acceptance: Nothing is compiled with the flag off. Privacy test.
- Test phase: fleet: `swift test --filter HangReportCollectorTests`.

### 090 Overhead benches
- Files: T/CmuxNextTraceTests/TraceEventBench.swift, T/CmuxNextMetricsTests/MetricsRecordBench.swift, R/cmux-trace/benches/ring.rs.
- Change: Release benches measure a disabled point, a single-thread write, an 8-thread write, a metrics
  record, the hook contents mark and a scope open and close, with malloc counts. Not wired to CI.
- Acceptance: They print ns p50 and p99 and assert 0 mallocs.
- Test phase: fleet: `swift test -c release --filter 'TraceEventBench|MetricsRecordBench'`;
  `cargo bench -p cmux-trace`.

### 091 Docs and owners
- Files: plans/cmux-next/{trace.md, hang-reports-DESIGN.md, threading-model.md, OWNERS.md, perf-lead.md}.
- Change:
  - trace.md: Release tracing and `cmux trace`.
  - hang-reports-DESIGN.md: schema 3.
  - threading-model.md: the hang-watch column.
  - OWNERS.md: rows for CmuxNextTrace, CmuxNextMetrics, cmux-trace and cmux-hang-watch (PL-telemetry
    and PL-trace).
  - STE style.
- Acceptance: The thread-doc guardrail passes.
- Test phase: `guardrails.py`.

### 092 Test phase
- Files: plans/cmux-next/perf-lead.md.
- Change: On fleet Release and Nightly-config builds, macOS 26 and 27, light and STRESS, run every done
  check. Calibrate frame.present_estimate against a high-speed capture on a lit-display host. Record the
  numbers with job ids and SHAs.
- Acceptance: perf-lead.md has the values. Each red check names its owner task.
- Test phase: this task.

### 093 Inlinable atomics and AtomicPointerSlot
- Files: S/CmuxNextCompat/Atomic.swift, S/CmuxNextCompat/AtomicPointerSlot.swift, T/CmuxNextCompatTests/AtomicPointerSlotTests.swift.
- Change: Add `@inlinable` relaxed load and store for UInt64 and UInt32. Add `AtomicPointerSlot` over
  `UnsafeMutablePointer<UInt64>` (`UnsafeAtomic(at:)`) for chunk cursors, sequences, buckets and keys in
  mmap memory. Notify the Compat owner.
- Acceptance: The disassembly in -O shows an inlined load (test notes). 8-thread tests pass.
- Test phase: fleet: `swift test -c release --filter AtomicPointerSlotTests`.

### 094 C ring writer header
- Files: Packages/macOS/CmuxNext/CEFShim/src/cmux_trace.h, Packages/macOS/CmuxNext/CEFShim/src/cmux_trace_test.c.
- Change: The ring v1 writer and crash-key page as header-only C11 with stdatomic: per-thread chunks, the
  seqlock and the role byte. It is the reference for the Ghostty Zig hook.
- Acceptance: The 009 golden file decodes byte for byte from C. No allocation on write.
- Test phase: fleet: `cmux-ci build cmux`; the C test.

### 095 Black box in every shipped Rust process
- Files: R/cmux-tui/src/owner_start.rs, R/cmux-tui/src/bin/cmux-tui-host.rs, R/cmux-holder/src/main.rs, R/acpmux/src/daemon.rs, R/acpmux/src/agent_host/host.rs, R/cmux-app-host/src/main.rs, R/cmux-browser-host/src/bin/cmux-browser-host.rs, R/cmux-trace/src/cleanup.rs.
- Change: `init_blackbox` is the first call in each main, with a role and size (daemon, host, holder,
  acpmux, agent_host, app_host, browser_host). cmux-app-host opens its ring before it enters the sandbox.
  Cleanup removes dead-pid rings older than 3 days and keeps the directory under 16 MiB, once at daemon
  start (no timer). The holder uses a holder-lifetime directory.
- Folders (agreed with 063, whose hang reports merge these rings; `HangReportFieldSources.RingFolders`): every
  process but the holder writes into the app's trace folder, `~/Library/Logs/<bundle id>/trace`, which the app
  hands the daemon at launch and the daemon hands its hosts. The holder keeps `<socket>.trace` beside its socket
  in `/tmp/cmux-hd-<uid>`. 063 already reads both, and the daemon's `CMUX_TRACE_FLOWS` folder.
- Acceptance:
  - `rg init_blackbox` hits all 7 mains.
  - The app-host call comes before the sandbox call.
  - Cleanup tests: live pids are kept, and the cap holds.
- Test phase: fleet: `cargo test -p cmux-trace cleanup`; after STRESS, one ring per live process.

### 096 Holder capability bits TRACE_CONTROL and WRITE_FLOW
- Files: R/cmux-holder/src/{wire.rs, holder.rs}, R/cmux-tui-core/src/holder_runtime/{service.rs, sink.rs}, plans/cmux-next/pty-holder.md.
- Change:
  - Two capability bits are granted in WELCOME.
  - TRACE_CONTROL adds the kinds TRACE_START and TRACE_STOP, with a fixed payload (category mask, record
    count) and no path.
  - WRITE_FLOW adds an optional u64 trailer on WRITE.
  - The daemon sends them only when they were granted. A holder without them is marked `holder_untraced`
    (no window heuristic).
  - VERSION stays 5.
  - The conformance corpus gains these exchanges.
- Acceptance:
  - `a_new_daemon_adopts_an_older_holder_by_its_wire_version` passes against cmux-holder-v3.
  - A v3 holder never gets the new frames.
  - The dependencies stay std+libc.
- Test phase: fleet: `cargo test -p cmux-holder -p cmux-tui-core holder_runtime`;
  `CMUX_REQUIRE_HOLDER_FIXTURES=1 cargo test --workspace holder_terminals`.

### 097 SystemCrashForwarder: host-exe copies and the attached black box
- Files: S/CmuxNextCrashReporting/{SystemCrashReport.swift, SystemCrashForwarder.swift, SystemCrashEvent.swift}, T/CmuxNextCrashReportingTests/SystemCrashReportTests.swift.
- Change:
  - An allowlist of roots: the bundle, and the host-exe root (the `CMUX_TUI_HOST_EXE_DIR` override,
    compared in anonymized form), limited to cmux-tui, cmux-tui-host and cmux-holder.
  - For a forwarded Rust crash, attach that pid's black box (512 events, no key records) and the crash
    keys (098) as tags.
  - Set the process tag.
- Acceptance:
  - A report under host-exe/<sha>/cmux-holder is forwarded.
  - An unknown name or another app's folder is not forwarded.
  - A planted ring gives one attachment that passes PrivacyLeakScanner.
- Test phase: fleet: `swift test --filter SystemCrashReportTests`; crash-matrix holder abort and host
  SIGSEGV.

### 098 Rust crash-key page
- Files: R/cmux-trace/src/crash_keys.rs, R/cmux-tui-core/src/server/connection_frame.rs.
- Change: A fixed page per process (request method id, terminal count, holder link state, build), written
  with relaxed stores.
- Acceptance: abort() inside a scope leaves a page that decodes.
- Test phase: fleet: `cargo test -p cmux-trace crash_keys`.

### 099 Panic logs: app-host, browser-host, agent-host, mcp serve
- Files: R/cmux-app-host/src/main.rs, R/cmux-browser-host/src/bin/cmux-browser-host.rs, R/acpmux/src/agent_host/host.rs, R/cmux-tui/src/cli/mcp.rs, S/CmuxNextCrashReporting/RustPanicSource.swift, S/CmuxNextApp/Crash/CrashReporter+Launch.swift.
- Change: Install cmux_panic_log in each binary, with a log file per process in the owner's state root.
  cmux-app-host opens the fd before the sandbox. Add the RustPanicSource cases appHost, browserHost,
  agentHost and mcp.
- Acceptance: 4 install hits. A panic test per crate writes one line.
- Test phase: fleet: `cargo test -p cmux-app-host -p cmux-browser-host -p acpmux panic_log`.

### 100 Panic logs: cmux-cloud, optchat-chief, diff-sidecar, server-helper
- Files: first-party-apps/cloud/server/src/main.rs, Native/OptChat/optchat-chief/src/main.rs, Native/DiffSidecar/src/main.rs, scripts/cmux-next/bundle-server-helper.sh (the source it bundles), S/CmuxNextCrashReporting/RustPanicSource.swift.
- Change: Install the panic log in each binary. Add the RustPanicSource cases. Run the regenerated MQ9.
  Note: first-party-apps/cloud/server is under BSL-licensed directories only if LICENSE lists it; check
  LICENSE before editing, and skip it if it is listed and the edit needs an outside CLA.
- Acceptance: `observability-audit.py rust --bundle` reports panic_log_missing = 0.
- Test phase: fleet: cargo tests of each crate; audit rust.

### 101 Debug crash injectors for the daemon and acpmux
- Files: R/cmux-tui-core/src/server/debug_crash_inject.rs, R/acpmux/src/debug_crash_inject.rs.
- Change: `debug-panic {kind: panic|abort|segv}` behind `cfg(debug_assertions)` or the bench feature.
  Refused for remote clients.
- Acceptance: Inside the cfg (rg). A Release build does not have the symbols.
- Test phase: fleet: `cargo test -p cmux-tui-core debug_crash_inject`.

### 102 Item 7: flow hops at all 12 thread handoffs
- Files: R/cmux-tui-core/src/surface/{attach_tap.rs, pty_surface.rs}, R/cmux-tui-core/src/server/line_connection.rs, R/cmux-tui-core/src/terminal_host_runtime/shared/host_shared.rs, S/CmuxNextDaemon/Connection/LineTransport.swift, S/CmuxNextTerminal/TerminalOutputLane.swift.
- Change: Each handoff in ghostty-integration-DESIGN.md "Key to frame" writes an enqueue and dequeue hop:
  host PTY thread, host client writer, daemon frames thread, surface parse, attach-out encode, line-out,
  app transport reader, main actor, output lane, renderer, Metal completion, main setContents. The queue
  items carry a u64 flow (0 when off).
- Acceptance: One echo gives >= 12 distinct hop names for one flow. Off: one load per site.
- Test phase: fleet STRESS: summary.json per-hop table for all 12.

### 103 Exact flows for every daemon request
- Files: S/CmuxNextDaemon/Connection/LineTransport.swift, R/cmux-tui-core/src/server/connection_frame.rs, scripts/cmux-next/trace.py.
- Change: Both sides derive the flow as hash(app pid from LOCAL_PEERPID, request id), and write flow-out
  and flow-in on send, receive, reply and reply-receive. No wire change.
- Acceptance: No wire diff. 3 requests decode as 3 chains.
- Test phase: STRESS: request_flow_linked = 100%.

### 104 Chromium Host process observability (F2)
- Files: Packages/macOS/CmuxNext/CEFShim/src/{browser_host_main.mm, chromium_host_wire.h}, S/CmuxNextBrowser/CEF/ChromiumHost/{ChromiumHostSession.swift, ChromiumHostLauncher.swift, ChromiumHostRestartPolicy.swift, ChromiumHostConnection.swift}.
- Change: With the host flag on:
  - (a) The host opens a black box (role chromium_host) and a crash-key page with 094, and writes
    cef.pump, cef.create_browser and wire-frame marks with the flow ids.
  - (b) A hang scope runs around each CefDoMessageLoopWork item, through a CFRunLoop observer.
  - (c) The wire frames TRACE_START and TRACE_STOP call 050 in the host.
  - (d) The supervisor turns a host exit (signal or status) into a rate-limited Sentry event with the host
    black-box tail, a restart count and a stability counter.
  - (e) The host writes a metrics file for the cef.pump numbers.
  - Notify PL-cefhost.
- Acceptance:
  - With the flag on, a SIGSEGV of the host gives 1 event and the app pid does not change.
  - `cmux trace record --chromium` produces host JSON and wire hops with the app's flow ids.
  - With the flag off, nothing changes.
- Test phase: nx-remote `--needs gui`: crash-matrix chromium-host; a STRESS trace with the host on.

### 105 Crashpad minidumps from Chromium processes (Nightly opt-in)
- Files: S/CmuxNextBrowser/CEF/CEFCrashReporterConfig.swift, scripts/cmux-next/embed-cef.sh, S/CmuxNextCrashReporting/SystemCrashForwarder.swift.
- Change:
  - Write crash_reporter.cfg with no ServerURL (local database only) and crash keys (process type, cmux
    version, CEF API). It is written only on Nightly with hang reports on.
  - The next launch forwards new minidumps to Sentry's minidump endpoint. It keeps only allowlisted
    annotations, leaves stack memory out (pending Lawrence's decision), and drops the matching .ips by pid.
- Acceptance:
  - No ServerURL.
  - A planted URL annotation is removed.
  - 1 event per minidump.
- Test phase: crash-matrix renderer, GPU and host on a Nightly-config build.

### 106 Chromium HangWatcher: forward dumps, off in children
- Files: manaflow-ai/cef fork shim sources (SetDumpWithoutCrashingFunction), S/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h, S/CmuxNextBrowser/CEF/CEFSwitches.swift, S/CmuxNextBrowser/CEF/CEFRuntime+Crashes.swift.
- Change:
  - `cmux_cef_set_dump_handler(cb)` installs `base::debug::SetDumpWithoutCrashingFunction` in the browser
    process. The callback receives the hung thread list and the frames.
  - cmux records a thread-hang with source chromium. It watches the IO and pool threads; UI-thread
    watching stays off, because the cmux watchdog covers it.
  - Children get `disable-features=EnableHangWatcher` until Crashpad (105) forwards them.
- Acceptance:
  - The export is behind an API version check.
  - The switch-list unit test passes.
  - A synthetic callback gives 1 record.
  - A fork case that blocks IO for 12 s calls the callback once.
- Test phase: hang-matrix lane chromium-io; `sample <pid>` of the children.

### 107 Chromium UMA snapshot and BrowserMetrics cleanup
- Files: manaflow-ai/cef fork shim sources (StatisticsRecorder bridge), S/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h, S/CmuxNextBrowser/CEF/CEFHistogramHarvest.swift.
- Change:
  - `cmux_cef_histogram_snapshot(names, n, cb)` returns deltas for an allowlist: EventLatency.KeyPressed and
    MousePressed TotalLatency, Graphics.Smoothness.PercentDroppedFrames3.AllSequences,
    Memory.Renderer and Memory.Gpu PrivateMemoryFootprint, Stability.Counts2, and
    PageLoad.PaintTiming.NavigationToFirstContentfulPaint.
  - It is folded as `chromium.*` at report triggers.
  - Check `<cef cache>/BrowserMetrics/*.pma`, then delete the old files or turn the feature off, and say
    which in the commit.
- Acceptance:
  - A name outside the allowlist is refused.
  - The harvest runs at triggers only.
  - An old fork reports unsupported.
  - The directory does not grow.
- Test phase: `cmux metrics --json` lists chromium.EventLatency.KeyPressed.TotalLatency with count > 0.

### 108 WebKit content-process ends and Page unresponsive
- Files: S/CmuxNextBrowser/WebKit/WebKitTab+Delegates.swift, S/CmuxNextPages/PageWebView+Lifecycle.swift, S/CmuxNextAgentPane/AgentPaneNavigation.swift, S/CmuxNextBrowser/CEF/CEFTab+Events.swift, S/CmuxNextBrowser/Core/BrowserTabStateMachine.swift.
- Change:
  - Each of the 3 `webViewWebContentProcessDidTerminate` sites and the CEF unresponsive transition records
    a ring instant, a stability counter (engine × surface kind) and a rate-limited Sentry event (no URL).
  - renderer.unresponsive_ms records the time from shown to ended.
- Acceptance: 4 call sites. 3 ends give 1 event and a counter of 3. Scrubber test.
- Test phase: fleet tests; crash-matrix webkit-content.

### 109 Stability counts with denominators
- Files: S/CmuxNextMetrics/StabilityCounters.swift, S/CmuxNextMetrics/MetricsLaunchFold.swift, S/CmuxNextApp/Crash/{AppRunMarker.swift, CrashRecoveryService.swift}, S/CmuxNextDaemon/Connection/{DaemonConnection.swift, ConnectionHeartbeat.swift}, S/CmuxNextAgentPane/AcpmuxDaemonLauncher.swift.
- Change: Record these counts:
  - stability.launch and stability.active_seconds.
  - stability.unclean_exit{crash, system_shutdown, killed, fatal_hang}.
  - stability.child_exit{daemon, holder, host, acpmux, agent_host, app_host, browser_host, chromium_host,
    renderer, gpu, utility, webkit} × {clean, signal, panic, oom}.
  - daemon.unresponsive with the last method class.
  The counts persist in the metrics file. Schema 3 sends them as `stability{}`.
- Acceptance: Each source has one record call. A different boot session never counts as a crash. The
  fold test shows the counts survive an app crash.
- Test phase: fleet: `swift test --filter StabilityCountersTests`; crash-matrix counter check.

### 110 Fatal-hang report at the next launch
- Files: S/CmuxNextControl/Diagnostics/MainThreadWatchdog.swift, S/CmuxNextApp/Crash/{RunMarkerFile.swift, CrashReporter+Launch.swift}, S/CmuxNextTrace/CrashKeys.swift.
- Change:
  - At 2 s, the watchdog thread writes `hang_in_progress` (start time and up to 64 frames as UUID and
    offset) and writes the Sentry envelope to the disk cache synchronously on its own thread.
  - When the stall ends, it clears them.
  - At the next launch, an unclean marker with the flag set gives one "fatal app hang" event, with the
    stack, debug_meta and the black box.
- Acceptance: A planted page gives 1 event. A clean exit gives none. No timer. A SIGKILL test passes.
- Test phase: hang-matrix fatal case.

### 111 EventLatency for every input type and live resize
- Files: S/CmuxNextSignposts/InputFrameSignpost.swift, S/CmuxNextSignposts/KeyFrameSignpost.swift, S/CmuxNextApp/CmuxApplication.swift, S/CmuxNextTerminal/TerminalSurfaceView+TextInput.swift.
- Change:
  - Generalize KeyFrameSignpost to InputFrameSignpost, with these kinds: key, mouse_down, mouse_up, drag
    (coalesced, 1 per frame), scroll, ime_commit, paste.
  - `sendEvent` stamps the NSEvent timestamp. The stamp closes at the next content-changing frame.commit,
    and events that cause no frame are dropped.
  - resize.frame covers each live-resize tick.
  - Histograms input.frame.<kind> and resize.frame.
  - Zero allocation.
- Acceptance: One load per event when off. Synthetic-event tests. MQ12 clear for input.*.
- Test phase: fleet: `swift test --filter InputFrameSignpostTests`; a mouse and scroll bench.

### 112 Responsiveness calculator
- Files: S/CmuxNextControl/Diagnostics/ResponsivenessCalculator.swift, S/CmuxNextControl/Diagnostics/MainThreadWatchdog.swift, S/CmuxNextControl/Concurrency/MainActorWorkQueue.swift, R/cmux-tui-core/src/server/connection_scheduler.rs.
- Change:
  - Record main.queue_delay (post to run, and input age per event).
  - Record congested-ms per 30 s interval, execution-only and queue-plus-execution, with launch and steady
    suffixes. The fold runs lazily at the next turn (no timer). Each congested interval gets a ring slice.
  - Daemon: the same for dispatch, from 014's arrival stamps.
- Acceptance: No timer or observer. Synthetic sequences match a reference that follows Chrome's merge
  rules.
- Test phase: fleet: `swift test --filter ResponsivenessCalculatorTests`;
  `cargo test -p cmux-tui-core dispatch_queue`.

### 113 FrameSequenceTracker for scroll, resize and drag
- Files: S/CmuxNextWakeups/FrameSequenceTracker.swift, S/CmuxNextApp/AppServices.swift, S/CmuxNextApp/Drag/TabDragSession+Ghost.swift.
- Change: Open sequences for terminal and page scroll (with momentum), live resize and tab drag. Record
  smoothness.dropped_pct.<type>.
- Acceptance: One open and one close site per type. The 057 tests run for each type.
- Test phase: anim-perf-terminal.py and a scroll bench.

### 114 Webview INP, long animation frames and JS errors
- Files: S/CmuxNextDesign/Windows/WebTheme.swift, S/CmuxNextPages/PageWebView.swift, webviews/src/protocol/perfReport.ts.
- Change:
  - The shared WebTheme bootstrap adds PerformanceObserver for 'event' (durationThreshold 16),
    'long-animation-frame' and 'longtask' (the WebKit fallback), plus error and unhandledrejection
    counters.
  - It flushes on visibilitychange, on pagehide and after an event of 200 ms or more. No timers.
  - The page id comes from a static list.
- Acceptance:
  - No setInterval or setTimeout in the added JS.
  - `bun run check` in webviews/ and scripts/web-lint.sh pass.
  - A fake bridge message gives histograms.
  - A planted URL is refused.
- Test phase: `cmux metrics --json` lists webview.inp.home.

### 115 Automation latency
- Files: S/CmuxNextControl/{ControlSocketServer.swift, ControlConnection.swift}, R/cmux-tui/src/cli/app/call.rs, S/CmuxNextActions/SignpostActionRunTiming.swift.
- Change:
  - The CLI mints a flow and sends an optional numeric `flow`.
  - control.request marks accepted, parsed off main, queued, dispatched and replied, with a method id and
    a source (cli, mcp, agent, app).
  - The flow is carried to action.commit.
  - Histograms automation.request.<class>, automation.main_queue_us and automation.blocked_person.
- Acceptance:
  - A guard closes the scope.
  - 3 CLI calls decode as 3 flows.
  - Old apps ignore the field.
  - The policy note is in the PR.
- Test phase: fleet: `swift test --filter ControlSocketServerTests`; `cargo test -p cmux-tui cli_flow`.

### 116 Remote daemons: clock offset, trace-fetch, remote echo
- Files: S/CmuxNextDaemon/Connection/{DaemonConnection.swift, DaemonEndpoint.swift}, R/cmux-tui-core/src/server/trace_control.rs, R/cmux-trace/src/export.rs.
- Change:
  - A min-RTT offset is estimated on the existing identify heartbeat. The offset and its error bound go in
    the meta.
  - `trace-fetch` returns only the remote daemon's own recording bytes, with no path parameter, over the
    authenticated connection. Relay clients that do not own the session are refused.
  - One ClockSnapshot per machine.
  - key.echo_frame gets the remote dimension.
- Acceptance:
  - Policy test.
  - With a fake offset of 37 ms and an RTT of 4 ms, the hops align within the bound.
  - The clock-order check passes on a bridge recording.
- Test phase: a bridge session to a Linux lane: remote tracks and complete flows.

### 117 Name every Rust thread
- Files: per batch of <= 40 MQ13 hits in R/{cmux-tui-core, cmux-tui, acpmux, cmux-browser-host, cmux-app-host}/src, plans/cmux-next/threading-model.md.
- Change: Use `thread::Builder::new().name("<prefix>-<role>")` with <= 15 bytes, and add a
  threading-model row for each.
- Acceptance: MQ13 = 0 for the batch. A list test in cmux-trace checks that the names are unique and short.
  The thread-doc guardrail passes.
- Test phase: cargo tests; a STRESS decode shows 0 unnamed daemon threads.

### 118 Hang watch for tokio runtimes
- Files: R/acpmux/src/cli/entry.rs, R/cmux-tui/src/{remote_runtime.rs, link/mod.rs, cloud_conversations_backend.rs}, R/cmux-hang-watch/src/tokio.rs.
- Change: `on_thread_start` registers the worker. `on_thread_unpark` opens a 2 s scope and
  `on_thread_park` closes it. runtime.busy_ms is recorded at report triggers.
- Acceptance: All 4 runtimes chain the 3 hooks. A `std::thread::sleep(3 s)` inside a task gives 1 hang
  record.
- Test phase: fleet: `cargo test -p cmux-hang-watch tokio`; hang-matrix acpmux-runtime.

### 119 Register Swift lanes, batch 3
- Files: S/CmuxNextRemoteView/Transport/RemoteRdStreamTransport.swift, S/CmuxNextRemoteView/Present/MetalYUVRenderer.swift, S/CmuxNextMobile/DaemonLane/UnixSocketLane.swift, S/CmuxNextAgentPane/{AcpmuxPaneSocket.swift, AcpmuxStatusClient.swift}, S/CmuxNextAgentActivity/AgentActivityLineConnection.swift, S/CmuxNextBrowserHost/ProviderConnection.swift, S/CmuxNextBrowser/CEF/CEFChildProcessMonitor.swift.
- Change: Register each lane, with one scope per item (1 s; the renderer 250 ms). The blocking wait stays
  outside the scope.
- Acceptance: MQ7's filtered list has no lane left unregistered.
- Test phase: hang-matrix remote-view and acpmux-pane.

### 120 Ghostty renderer-thread hang watch
- Files: S/CmuxNextTerminal/GhosttyTraceHook.swift.
- Change: The hook's frame begin and end open and close a 500 ms scope. The thread registers on the first
  call and unregisters on the destroy event. Uses the growable table (066).
- Acceptance: 2 stores and no allocation. A synthetic blocked renderer gives 1 record that names
  ghostty-renderer and the surface hash.
- Test phase: hang-matrix ghostty-renderer.

### 121 Memory, CPU, disk and pressure per process kind
- Files: S/CmuxNextMetrics/ProcessResourceSampler.swift, S/CmuxNextHostPressure/HostPressureMonitor.swift, S/CmuxNextApp/HangReports/HangReportsController.swift.
- Change:
  - At report triggers and at active and inactive transitions, read `proc_pid_rusage` for the known pids:
    the app, the daemon, hosts or the holder (from daemon status), acpmux and agent hosts, app-host,
    browser-host and the Chromium helpers by type.
  - Record memory.<kind>_kib, memory.total_kib, cpu.<kind>_pct and disk.idle_write_kib_per_min.
  - Each pressure transition records a counter and an instant.
- Acceptance: No timer. Pids come from known sources, not a name scan. Fake-provider tests.
- Test phase: STRESS preview lists >= 8 kinds; bench-idle compares with fs_usage within 10%.

### 122 trace.py: QoS inversion check
- Files: scripts/cmux-next/trace.py.
- Change: For each flow and task.run, list hops on threads below userInitiated, and waits where a higher
  QoS thread waits on lower-QoS work. Add `qos_violations[]` and the command `check-qos DIR`.
- Acceptance: Planted fixtures give 1 and 1. Not wired to CI.
- Test phase: `trace.py --self-test`; a STRESS recording.

### 123 Swift concurrency global-enqueue hook (measure phase)
- Files: S/CmuxNextTrace/ConcurrencyHook.swift, S/CmuxNextApp/AppServices.swift, plans/cmux-next/threading-model.md.
- Change:
  - Phase 1: install `swift_task_enqueueGlobal_hook`. It calls the original enqueue and writes a task.post
    record with the priority, and counts the jobs.
  - Phase 2 (the lead decides after the 090 bench): a cmux-owned executor runs each job inside
    HangWatchScope and task.run, like Chrome's ThreadPool. If phase 2 is not done, write the reason in
    threading-model.md.
- Acceptance: Off: one load and a tail call. On: task.post records appear.
- Test phase: fleet: `swift test --filter ConcurrencyHookTests`; a bench-typing A/B within 0.05 ms.

### 124 TracedTask.detached with FROM_HERE
- Files: S/CmuxNextWakeups/TracedTask.swift, plus one MQ14 batch (<= 30 hits) per follow-up task. Task 000
  gave every target that calls `Task.detached` a CmuxNextWakeups dependency, so no batch edits Package.swift.
  CmuxNextCompat's sites are out of scope: Wakeups depends on Compat, so Compat cannot call TracedTask.
- Change: `TracedTask.detached(priority:file:line:operation:)` writes a flow-out at the post and a task.run
  scope with the queue wait. Convert one batch per task. Each site names a priority.
- Acceptance: MQ14 = 0 for the batch. 3 tasks decode as 3 flows with the correct sites.
- Test phase: fleet: `swift test --filter TracedTaskTests`; Release compile check.

### 125 `cmux trace blackbox` and the last-hang bundle
- Files: R/cmux-tui/src/cli/trace.rs, R/cmux-trace/src/export.rs, S/CmuxNextControl/Diagnostics/ControlRouter+Trace.swift.
- Change: On a hang >= 1 s or a key.frame > 50 ms, copy every process tail into `last-hang/<n>` (at most
  5, on `.files`). `cmux trace blackbox [--last-hang N | --now]` exports them to Perfetto.
- Acceptance: The copy runs on `.files`. A hard limit (test). The fixture export loads.
- Test phase: hang-matrix: `--last-hang 1` loads with 0 errors and shows the hung lane.

### 126 field-histograms.py
- Files: scripts/cmux-next/field-histograms.py, web/scripts/hang-reports-histograms.ts.
- Change: Compare Nightly N with N-1..N-3, with a bootstrap 95% interval. Name regressions over 10% that
  fall outside the interval. Run by hand.
- Acceptance: The self-test finds a planted 20% p95 regression and ignores noise. No .github change.
- Test phase: `--self-test`; the first 3 schema-3 Nightlies.

### 127 Remote desktop view: input to present
- Files: S/CmuxNextRemoteView/Present/MetalFramePresenter.swift, S/CmuxNextRemoteView/Input/.
- Change: remote.input (with a sequence number), remote.frame_decoded and remote.present (with the echoed
  sequence when present). Histograms remote.input_to_present and
  smoothness.dropped_pct.remote_stream.
- Acceptance: The 3 names have emitters (MQ1 = 0). MockRemoteStreamSource tests.
- Test phase: a cmux-rd bench against a Linux lane.

### 128 Keystroke-timing privacy gate
- Files: S/CmuxNextTrace/TraceCategories.swift, S/CmuxNextHangReports/HangReportBuilder.swift, S/CmuxNextCrashReporting/CrashReporter.swift, T/CmuxNextTraceTests/BlackboxPrivacyTests.swift.
- Change:
  - The black-box decoder used for uploads drops the key category and per-key PTY and flow records.
  - While secure keyboard entry is on or Ghostty reports a password prompt, the key category is off,
    also for local recordings.
  - The Sentry attachment is sent only with the hang-reports opt-in.
- Acceptance: 100 planted key records give 0 in the attachment and in blackbox[]. A secure-input test
  writes 0 key records.
- Test phase: fleet: `swift test --filter BlackboxPrivacyTests`.

### 129 ContinuousClock on trace paths
- Files: per MQ15 batch (<= 15 files) in S/.
- Change: Sites that feed a trace mark, a histogram or a hang deadline use TraceClock or SuspendingClock.
  Sites that must count sleep say `// continuous-clock: <why>`.
- Acceptance: audit clocks continuous_clock_trace_sites = 0 for the batch.
- Test phase: audit clocks; fleet tests of the touched targets.

### 130 dumpWithoutCrashing
- Files: S/CmuxNextCrashReporting/DumpWithoutCrashing.swift, S/CmuxNextCrashReporting/CrashReporter.swift, plus the 8 MQ16 sites.
- Change: `Diagnostics.dumpWithoutCrashing(site: StaticString)` sends a non-fatal event with the stack and
  the crash keys, at most once per site per launch. The 8 sites become assert plus dump.
- Acceptance: Each MQ16 hit is next to a dump call. A rate-limit test.
- Test phase: fleet: `swift test --filter DumpWithoutCrashingTests`.

### 131 Daemon histograms in a crash-safe mmap file
- Files: R/cmux-trace/src/metrics.rs, R/cmux-tui-core/src/diagnostics.rs.
- Change: The daemon (and the holder and acpmux) record request latency per class, the dispatch queue,
  locks and the journal into `metrics-<role>-<pid>.bin`, with 052's layout and profile header (a golden
  shared with Swift). server-stats reads the same memory.
- Acceptance: A golden byte test. A SIGKILLed child's file folds once.
- Test phase: fleet: `cargo test -p cmux-tui-core diagnostics_persist`; `cargo test -p cmux-trace metrics`.

### 132 Linux and Windows backends for cmux-trace and cmux-hang-watch
- Files: R/cmux-trace/src/{map.rs, clock.rs}, R/cmux-hang-watch/src/lib.rs.
- Change: Linux: mmap MAP_SHARED and CLOCK_MONOTONIC. Windows: CreateFileMapping and QPC. The hang watcher
  works on both and records the thread name and the deadline (no sampler).
- Acceptance: `cargo check` and `cargo test` pass on a Linux lane. `cargo check` passes for the Windows
  target.
- Test phase: fleet Linux lane: `cargo test -p cmux-trace -p cmux-hang-watch`.

### 133 Recording indicator and Chromium JSON URL filter
- Files: S/CmuxNextControl/Diagnostics/ControlRouter+Trace.swift, S/CmuxNextApp/Diagnostics/TraceRecordingIndicator.swift, R/cmux-trace/src/export.rs.
- Change:
  - While a recording runs, a titlebar indicator shows "Recording trace" with a Stop action. It uses a
    `Motion.indicators` gate, TypeScale fonts and localized strings.
  - Before export, the exporter strips URL-like args (`url`, `src`, `href`, data URIs and any `scheme://`
    string) from the Chromium JSON.
- Acceptance:
  - The indicator shows and hides with start and stop (test).
  - A planted URL is absent from the export.
  - The localization audit is reported.
  - A native capture or `No capture: <why>` is in the PR.
- Test phase: fleet: `swift test --filter TraceRecordingIndicatorTests`; `cargo test -p cmux-trace export_filter`.

### 134 Release opt-in for aggregate performance data
- Files: S/CmuxNextHangReports/HangReportService.swift, S/CmuxNextHangReports/HangReportAskPolicy.swift, the settings source for `diagnostics.performanceData` (the schema is regenerated, never hand-edited), S/CmuxNextActions/HangReportsActions.xcstrings.
- Change: A new setting, `diagnostics.performanceData` (default off, all channels). When it is on, Release
  sends schema 3 with `histograms[]` and `stability{}` only (no blackbox, no samples), through the same
  scanner.
- Acceptance:
  - Default off (test).
  - A Release body has no blackbox or samples (test).
  - The localization audit is reported.
- Test phase: fleet: `swift test --filter HangReportServiceTests`.
