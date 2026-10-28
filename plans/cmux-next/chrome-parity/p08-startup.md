# p08-startup: start up like Chrome, then go past it

Program spec, final (fixer pass over the design and 3 reviews).
Checkout: `/Users/lawrence/fun/wt/chrome-parity` at `772cdfc45ac` (origin/feat-cmux-next).
Earlier, not landed launch work: `origin/pl-threading-slicec-g1`, 6 commits `HEAD..ba1d1a4a239`
(`1ef99263bd5` red test, `28616a404d0`, `b407fffc3b2`, `4d83ef255d0`, `e4812e90436`, `ba1d1a4a239`).

Goal: the first frame shows only the window and a saved picture of that window. Everything else runs
later, ordered by priority. Chromium (CEF) starts after the first frame for a visible Chromium page, and at
idle for everything else; after F2 it runs out of process. Startup tracing is always available and covers
the app, the daemon and Chromium. The Release build uses PGO and an order file.

## 0. What this fixer pass changed (review outcome)

Applied from the reviews (each was checked in the code at `772cdfc45ac`):

- Chromium deadlock fixed (reviews 2 and 3). A focused restored Chromium page (Home, New Tab, agent page
  in Chromium mode, or a browser tab) could not start CEF before `startup_complete`, while
  `startup_complete` waited for that page's first paint. Now a restored page that shows in a visible window
  starts CEF in an `afterFirstFrame` post (Chrome's first visible WebContents is the startup goal). Only
  restored pages that do not show wait for `afterStartup`. Tasks 040, 041 and done check 7 are rewritten.
- Chrome reference corrected (review 3, then checked against `after_startup_task_utils.cc` on
  chromium main). The ref count and the failsafe are always on (not Android). The feature
  `kImprovedStartupBestEffortDelay` only changes the failsafe length (`kStartupDelayFailsafeTimeout`, else
  3 min) and the StartupObserver details (`kStartupDelayVisibleTabTimeout`,
  `kStartupDelayStopOnLoadingTimedOut`, tabs only). Review 3 said the refs exist only in the experiment;
  that part was wrong.
- Completion semantics like Chrome's StartupObserver (review 3): loaded-idle, not first paint; a first-idle
  ref; a 5 s visible-pane bound that restarts when all visible panes hide; completion is posted and never
  fires during quit (task 105).
- Startup posts name a destination, main or a BackgroundWork lane, with no default (review 3). Folded
  into task 010.
- New package target `CmuxNextLaunch` (review 2). `check-app-size.sh` caps CmuxNextApp, and the cap only
  goes down. All new launch types go there; CmuxNextApp gets only wiring (task 073). `StartupTrace` moves
  there too, because CmuxNextSignposts has no state (architecture-refactor-DESIGN section 7).
- Task 014 (the per-domain split) has no dependency now and runs at hour 0. It lands on
  `feat-cmux-next` as a small `risk:low` PR, so that every program edits the per-domain files from the start.
- Measurement first (review 2): hour-0 seed profile with the tools that exist today (task 072). The
  `startup-queue.py` `gaps` and `blocking` modes depend only on 002 and 006.
- Q4 (comment audit, 167 files) and its template 035 are dropped. Reason: a comment proves nothing about
  run time, and 167 small diffs in files that other programs edit give conflicts for little gain. Runtime
  queues replace it: Q11 (main-actor jobs and untagged main turns before `startup_complete`), Q12
  (off-main jobs that bypass the fence), Q13 (timers, watchers, observers armed in the launch window).
  Review 1's Q4b is dropped for the same reason.
- Done check 8(3) cannot be checked with awk. A pinned ast-grep tool `startup-lint.py` does it (task 104,
  an agent tool, not CI).
- Input during the picture phase changes only the model in its turn. It never builds the whole window
  in one turn (task 061 rewritten).
- Picture safety (reviews 1 and 2): no backdrop blur in the picture (a live `WindowMaterialView` sits
  under it); no picture for full-screen windows or windows on another Space; a layout hash compared with
  the prefetched daemon launch snapshot; Secure Input panes, `sharingType == .none` windows and protected
  media are filled with the theme background; pictures are deleted with browsing data, a profile, a close
  for good, or the setting off (tasks 063, 100, 102).
- Managed policy (MDM, URL filter) stays critical and applies before any page engine starts. Only
  `writeManagedStatus` and the watchers are deferred (task 101, `risk:high`).
- Settings migrations run as pure transforms inside the settings launch read, before the first snapshot
  (task 106). Before, the first window could show legacy keys.
- Control socket (reviews 1 and 3): bind off main after the existing owner check (`unlinkIfOwn`), accept,
  peer policy and parse off main, a bounded in-process startup queue that replays after registration
  (Chrome's ProcessSingletonStartupLock). `listen(descriptor, 64)` at
  `CmuxNextControl/ControlSocketServer.swift:170`, not 128. `risk:high` (tasks 019, 107).
- `LaunchRead.take()` returning nil had no correct path. Rule added: the critical steps that need a read
  run in a continuation on the read's completion event (a main hop at `MainWorkClass.input`); there is no
  wait and no default value drawn for one frame.
- Sentry static is already decided: `Packages/Shared/CmuxSentryTelemetry/Package.swift:54-56` links
  Sentry-Dynamic because a static Sentry adds a fourth personality routine. Removed from 032. Task 067
  (Sparkle via dlopen) is measure-only unless Sparkle costs >= 3 ms.
- PGO and order file rebuilt (reviews 2 and 3): Swift `-profile-generate` is frontend instrumentation, so
  `-pgo-temporal-instrumentation` most likely does nothing for Swift. The launch set comes from a profile
  flush at `startup_complete` (`__llvm_profile_write_file` then `__llvm_profile_reset_counters`, task
  103). The final order is made against the `-profile-use` binary: launch-profile functions mapped through
  its link map, then the cold-launch `__TEXT` page-fault symbols of that same binary, which also covers
  Rust, Zig and C code (task 109, merges review 1's 094). Coverage is checked with the link map, not `nm`
  (Release is stripped). `-order_file_statistics` is optional.
- PGO in the Nightly: no new CI step. The fetch runs inside an existing build script, `-profile-use` only
  when the sha256 matches, behind a repository variable that is off by default, `risk:high` (task 052).
- ThinLTO and cross-module optimization A/B before PGO (task 110). 0 hits today for `-lto`,
  `-cross-module-optimization`, `-order_file`, `-profile-use` in `cmux.xcodeproj`, `Package.swift`
  and `scripts/reload.sh`.
- Rust PGO uses `llvm-profdata` from the pinned rustc's `llvm-tools`, and covers `cmux-app-ffi` too (056).
- Official CEF: no new day-long build. Use the bundle-size owner's job `70436914a38e` output; the PGO
  profile must be the one for the fork's exact Chromium revision; mismatch rate < 10 %; the shim's crash
  recovery test must pass (047).
- Dependency fixes: 057 depends on 001 and 073 (not 043); 020-022 depend on 014; 006 has no dependency
  (only its `--temperature` flag waits for 007); 071 depends on 063 (its CEF-host case runs only when F2 is
  on). 034 now picks one priority (afterStartup, `.utility` lane) instead of a fenced job at afterFirstFrame.
- Temperature is classified at `run_loop_start` from page-ins, with Chrome's constants as the start.
  Page-ins at first frame are a separate value (007).
- Interrupted launches are flagged and kept out of the statistics (task 108). Chrome:
  `WasMainWindowStartupInterrupted`.
- Visibility of non-front windows is by occlusion, not z-order (062).
- Path and count fixes: `CmuxNextDesign/Launch/LaunchRead.swift`; `CmuxNextApp/Handlers/HandlerCoverage.swift`;
  `BrowserTabConfiguration` in `CmuxNextBrowser/Engine/BrowserEngine.swift:14`;
  `CmuxNextApp/Pages/Chromium/ChromiumPageHost.swift`; `CmuxNextSidebar/Model/SidebarModel+VisibleRows.swift`;
  `CmuxNextUpdater/WebUpdates/WebUpdater.swift`; `CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostLauncher.swift`;
  Q3 = 11 hits; `CEFRuntime.shared.start(` = 11 sites; `UserDefaults.standard` = 23 sites in Sources
  (review 1 said 71); `BrowserTabConfiguration(` = 9 sites in 9 files in Sources, 44 in 35 files with tests;
  `makeTab(` = 30 in Sources.
- Added from review 1 (all confirmed): launch snapshot decode off main (`DaemonService+LaunchSnapshot.swift:24`
  calls `LaunchSnapshot.load` on main), sidebar snapshot and run marker reads, Home caches and device ID,
  WebUpdates OTA, crash forwarders, the Q2 remainder, census tools Q11/Q12/Q13, probe XPC/mach/spawn/dlopen
  (`probe.c:32` lists `mach_msg` as a known gap), AppKit restoration (`isRestorable = false` only in
  `BrowserPopupWindow.swift:82`; 0 `applicationSupportsSecureRestorableState`), watchdog from main()
  (today `AppDelegate.swift:80`), crash streak safe launch, RestoredPageLoader on the existing
  `TabContentCache+Deferred.swift` path, first terminal surface cost, the ActionCatalog `swift_once` wait,
  daemon startup timeline and deferral (`run_server` at `cmux-tui/crates/cmux-tui/src/main.rs:2222`; 0 QoS
  calls in cmux-tui), no-window launch, external open, ChatsFeed split, Q1b stored-property initializers
  (43 today), multi-process startup trace.
- Added from review 3: field slow-launch trace ring (Chrome background tracing analog), interrupted launches,
  control socket startup lock, settings migrations at load, order from the final binary, LTO/CMO A/B.

Dropped, with reason: Q4/Q4b and template 035 (above). Review 1's 094 is merged into 109. Review 3's 075
is merged into 010. Review 2's 074 and review 3's 073 are merged into 040.

## 1. Chrome reference

1. Startup is a phase with its own queues. `content/browser/scheduler/browser_task_queues.h`: all queues
   start disabled; `EnableAllExceptBestEffortQueues()` runs early; `OnStartupComplete()` enables the
   best-effort queues. A `kStartup` queue holds tasks critical for startup; `kUserInput` ranks above
   `kUserBlocking`. During startup, best-effort work does not run.
2. The same fence on the thread pool. `base/task/thread_pool/thread_pool_instance.h`:
   `BeginBestEffortFence()` / `EndBestEffortFence()` (`ScopedBestEffortExecutionFence`). Running tasks complete.
   The fence covers the whole ThreadPool, so no BEST_EFFORT task escapes it.
3. After-startup tasks. `chrome/browser/after_startup_task_utils.cc`: `AfterStartupTaskUtils::PostTask`
   takes a `destination_runner` and queues the task on the UI thread until `SetBrowserStartupIsComplete()`;
   then each task is posted to its own runner (most are ThreadPool BEST_EFFORT). The hop from another
   thread to the UI thread is USER_VISIBLE, so the hop is not itself an after-startup task. Completion uses
   a ref count (not Android): the implicit startup ref, `StartupInProgressRef`s, and a performance_manager
   StartupObserver that holds a ref until the visible page is `kLoadedIdle` (or loading timed out, or a
   visible-tab timeout that restarts when all visible pages hide). A failsafe task always runs:
   `kStartupDelayFailsafeTimeout` when `kImprovedStartupBestEffortDelay` is on, else 3 min.
   `MaybeSignalStartupComplete` posts the completion, so it does not fire during shutdown. Chrome records
   `Startup.BrowserStartupCompleteReason`, `Startup.AfterStartupTaskCount`,
   `Startup.AfterStartupTaskDelayedUntilTime` and the trace event `Startup.StartupComplete`.
4. Milestones and temperature. `components/startup_metric_utils/browser/startup_metric_utils.h`:
   `RecordBrowserMainMessageLoopStart`, `RecordBrowserMainLoopFirstIdle`, `RecordBrowserWindowDisplay`,
   `RecordBrowserWindowFirstPaint`, `RecordFirstWebContentsNonEmptyPaint`, FCP/LCP, each a delta from
   `RecordApplicationStartTime`. `StartupTemperature` (COLD/WARM/LUKEWARM/UNDETERMINED) is decided at the
   message-loop start from the hard-fault count (on Mac, `task_info(TASK_EVENTS_INFO).pageins`). The fault
   count at first paint is a separate histogram. Every `Startup.*` histogram is split by temperature, and
   interrupted startups (`WasMainWindowStartupInterrupted`: hidden window, a dialog first, first run) are
   left out.
5. Startup tracing. `components/tracing/common/tracing_switches.cc`: `--trace-startup[=categories]`,
   `--trace-startup-duration` (5 s), `--trace-startup-file`, `--trace-startup-format` (proto, written in
   chunks, so it survives a crash), `--trace-startup-owner`. It reaches child processes through the trace
   config and buffer handles. In the field, background tracing scenarios keep a small trace and upload it
   when a scenario such as a slow startup fires.
6. Session restore creates windows and tabs but does not load them all. `chrome/browser/sessions/session_restore.h`:
   background tabs are created lazily without a renderer (`skip_renderer_creation`); `TabLoader` loads tabs
   progressively, with a concurrency limit, under memory pressure one at a time. The active visible tab
   loads at once. Android's StartupPaintPreview shows a picture only for the first restored tab and removes
   it at first meaningful paint; it does not redefine first paint.
7. PGO and order files. `chrome/build/mac-arm.pgo.txt` and `mac.pgo.txt` name per-revision profiles
   fetched only with `checkout_pgo_profiles=True`; Mac ships PGO only with official ThinLTO builds
   (`docs/pgo.md`: `chrome_pgo_phase` 0/1/2, `pgo_data_path`, `tools/pgo/generate_profile.py`). Order files
   exist for Android only; the orderfile builder runs after the PGO builder at the same commit, from a
   build that uses that profile, and `check_orderfile.py` checks it (`docs/orderfile.md`). cmux goes past
   Chrome on Mac with an order file.
8. Hang watching from the first instruction: `base/threading/hang_watcher.h` starts on the main thread
   early, before startup work. The UI thread never blocks (`ScopedBlockingCall`, `ThreadRestrictions`,
   `docs/threading_and_tasks.md`). Chrome itself reads Local State on the UI thread at startup; cmux beats
   that by reading on a launch thread from the top of `main()`.
9. Safe startup after crashes: `VariationsSafeModeTracker` counts crashes before a clean start and falls
   back to a safe seed. `ProcessSingletonStartupLock` accepts and queues command-line invocations during
   startup and replays them at `Unlock()`.

## 2. cmux today (`772cdfc45ac`)

Measured:
- perf-lead.md issue 18 (#17587): first frame 217-263 ms; live tree 351-936 ms at 24 workspaces.
- `ba1d1a4a239` on cmux20-bench, macOS 27, warm, 2 runs: first window frame 499 ms (max 556); agent pages
  decoded at 48 ms and terminal frames at 51 ms. The pictures wait about 450 ms for the frame. There is no
  breakdown of those 450 ms yet (task 072 makes it).
- `scripts/cmux-next/perf-cron.py:179` budgets: `did_finish_launching_end` 800 ms,
  `first_window_frame_committed` 1000 ms, `sidebar_rows_shown` 1000 ms (3-6x looser than the targets).
- `bench-startup.py` "cold" means only "daemon stopped": no purge, no page-in count, median and max only.
- `CefInitialize` 100-160 ms on main (0.8 s in a macOS 26 VM).

Launch path (`Packages/macOS/CmuxNext/Sources`):
- `CmuxNextApp/CmuxNextApp.swift` `main()`: malloc zone, signal policy, open-file limit, CloudAuth env
  capture, env freeze, LaunchWarmup thread (ActionCatalog 950 descriptors, palette strings, SF Symbols,
  display UUIDs, `DaemonLauncher.prewarmLoginEnvironment` = `$SHELL -l -i`, 1-17 s, every launch),
  AppEnvironment, 2 singletons (`AgentPaneScrollAnchors.shared`, `AgentPaneDraftAttachments.shared`),
  `DaemonService.prestart`, CrashOnExceptions, NSApp. The main-thread watchdog starts only at
  `AppDelegate.swift:80`.
- `CmuxNextApp/AppDelegate.swift` (500 lines): `applicationDidFinishLaunching` plus `startSettingsAndControl`
  hold 81 distinct start/follow/wire/load/install/register calls (Q2), all before the first frame. Among
  them: synchronous settings read and config file create; `ThemeBridge.start` (first `GhosttyRuntime.shared`:
  `ghostty_init` and config file load on main); `services.daemon.start` -> `showLaunchSnapshot` ->
  `LaunchSnapshot.load(path:)` on main (`DaemonService+LaunchSnapshot.swift:24`, up to 8 MiB JSON); Sentry
  start; `AppActions.bind`, `HandlerCoverage.verify`, a Release walk of `unboundActionIDs()`; `MainMenu.make`;
  `settings.writeManagedStatus`; `WebUpdates.shared.prepare`; `home.start`, `chatsFeed.keepCurrent` (which
  builds `ChatsFeed.started`: 5 feeds, a sweep, an acpmux connect, a device-ID file read), browser profiles,
  bookmarks, history, apps, device hub, mobile, keep-awake, Computer Use helper, `newTabSpares.prewarm`.
- `CmuxNextApp/AppServices.swift` (666 lines) `init`: 18 `_ = x` eager builds (Q1), 43 stored-property
  initializers that run before the body (Q1b; for example `ChromiumRuntimeService.make()`,
  `BrowserSharedStores.application()`, MemoryPressureEvents, AppCrashReporting which starts
  SystemCrashForwarder and 2 OwnerPanicForwarders), `SidebarSnapshotStore.init` (synchronous read),
  `CrashRecoveryService` -> `AppRunMarker` (read and write on main), and `browserHost.start`,
  `notifications.start`, `input.start`, `updater.attach`, `serverUpdates.start`.
- `restoreWhenLoaded` / `LaunchSnapshotWindow` build the full window controller before the first commit.
- Deferral: 4 ad hoc mechanisms (FirstFrameGate 43 lines, LaunchSettle 91, IdleOnce, LaunchImageHold 45)
  with 11 Q3 sites plus 6 launch DemandTimers. No priority, no per-turn budget, no fence, no record.
  `FirstFrameGate.open()` runs every waiter in one main turn, including `AgentPaneView.startWarmup` (first
  WKProcessPool, about 150 ms of main).
- The control socket starts after settings migrations and `launchSettle.settled(within: 4 s)`
  (`AppDelegate.swift:340-347` migrations). `listen(descriptor, 64)`.
- 204 `Task.detached` and 8 `DispatchQueue.global` sites in Sources bypass BackgroundWork. 188
  `DemandTimer(` sites. 23 `UserDefaults.standard`, 13 `SecItemCopyMatching` sites.
- No cmux window sets `isRestorable = false` except `BrowserPopupWindow`; AppKit state restoration runs.

Chromium:
- ChromiumWarmup (p06-scheduler-050, task 018): the launch check, `CefInitialize` and the spare window are
  idle tasks of the main-thread scheduler, posted once startup settled (`ChromiumWarmupIdle`); the
  preload's framework read waits behind the startup fence (p08-startup-045). inputQuiet 750 ms, counted from
  the app's last input, with one deadline (`ChromiumWarmup.quiet`) only after input while a step waits;
  maxDelay 5 s (500 ms for a spare), then background work. No launch timer. `CefInitialize` runs in its idle
  task's own turn (`CEFEngine.initializeLoaded` after `libraryLoadEnded`, `CEFLoadedStart`), not in a later
  continuation; the Chromium Host's launch start (`startWithoutIdleWait`) awaits it. Chromium is the default engine,
  and cmux pages (Home, New Tab, agent pages) are hosted in Chromium (`PageWebView.chromiumHosting`,
  perf-lead F3). `CEFEngine.makeTab` -> `CEFRuntime.shared.start` runs at once for a restored visible
  Chromium tab. 11 `CEFRuntime.shared.start(` sites (9 are user features: passwords, passkeys).
- Restored pages after crash recovery already defer through `TabContentCache+Deferred.swift`
  (`defersRestoredPages`, `startedDeferred`). There is no loader queue (0 hits for TabLoader-like caps).
- F2 (CEF browser process out of process) about 10 % done (cef-helper-app-DESIGN slice 3).

Pictures: terminal frames and agent images are saved at quit. Browser pages have in-memory pictures only.
No whole-window picture.

Tracing: 45 `DebugTimings.markLaunch` sites in 14 files to the LaunchMarkSink pipe, not os_signposts. No
startup trace. `trace.py` has no launch scenario. The daemon records no startup times (only
`server_lifecycle_ready: AtomicBool`, `cmux-tui-core/src/mux.rs:725`). Field: MetricKit
`MXAppLaunchMetric` only (`CmuxNextHangReports/HangReport.swift`).

Build: target cmux-next Release is whole-module `-O` with dead-code stripping. No order file, no PGO,
no LTO, no CMO. CEF dist is not official. Non-system dylibs at launch: Sentry-Dynamic and Sparkle.
Nightly: `xcodebuild -scheme cmux -configuration Release` (`.github/workflows/nightly.yml:1146`, `2184`),
universal.

## 3. Target design

### A. Phases (process start = kinfo `p_starttime`; Release/bench build; 120 Hz fleet mini)

- P0 pre-main (dyld, initializers): <= 25 ms warm.
- P1 `main()` to `NSApp.run`: <= 10 ms on main. The watchdog starts first. `main()` only starts work: the
  LaunchPrefetch thread (QoS userInitiated) reads and decodes settings JSON (with the migrations as pure
  transforms), the Ghostty config bytes, the managed-preferences bytes, the daemon launch snapshot, the
  front window's saved picture and meta, the sidebar snapshot, the run marker, the Home caches, the device
  ID, the WebUpdates pointer, terminal frames and agent images. The daemon prestart connects; the control
  socket binds and accepts into the startup queue after the owner check. All off main.
- P2 critical (`applicationDidFinishLaunching`): <= 40 ms of main. Only the critical allowlist (<= 15
  names): settings snapshot take, managed policy apply, theme, registry plus KeyRouter (keys work),
  WindowManager, AppKit event handlers (Apple events, WebAuth), and the window for the front saved window
  with a live `WindowMaterialView` and one picture layer. A step that needs a read that is not done runs in
  a continuation on the read's completion event, at `MainWorkClass.input`; it never waits and never draws a
  default for one frame. On a meta mismatch, P2 builds today's live window.
- P3 `first_window_frame_committed`: <= 150 ms warm, <= 300 ms cold (purge + daemon stopped). If the picture
  is not decoded, the window is ordered in on the decode completion or at a 40 ms deadline (a DemandTimer).
- P4 afterFirstFrame (`MainWorkClass.visible`, budgeted per frame, yields to input): the live
  `WindowRootView` under the picture, slice by slice (sidebar visible rows, tab strips, focused pane, other
  visible panes). The picture leaves region by region at first meaningful content (terminal: first frame
  after the daemon snapshot is applied; page: first contentful paint), 2 s bound. Terminals attach
  focused-first. A visible restored Chromium page starts CEF here (before F2 this is one named main turn
  of 100-160 ms; after F2 the host spawns off main). The control socket registers its methods (one post
  per group) and replays the startup queue. Other visible (not occluded) windows show their pictures, one
  per frame.
- P5 `startup_complete`: refs reach 0 (implicit registration, firstFrame, firstIdle, restore, one
  visiblePaneLoadedIdle per visible pane with a 5 s bound that restarts on hide) or a 10 s failsafe fires.
  Reason recorded. Never during quit. Then the BackgroundWork best-effort fence ends and the afterStartup
  queues release in post order.
- P6 afterStartup: `.main` posts run one per idle turn, <= 4 ms per turn, input first. Lane posts run on
  their BackgroundWork lane at their WorkPriority. Contents: CefInitialize for hidden Chromium needs, spare
  Chromium window, WKProcessPool warm-up (unless a WebKit agent pane is visible), spares, palette steps,
  icon picker, open panel, Sparkle, ssh, server reach, free-tier attest, classic imports, managed status
  write, launch cleanup, crash forwarders, OTA network check, hang-report upload, CEF framework prefetch
  (`.idle`), login shell env (`.utility` lane, unless a cold daemon needs it now).
- onDemand: services nobody shows are never built at launch (lazy vars, no `_ = x`).

Why 10 s and not Chrome's 3 min failsafe: cmux panes are local (terminals hydrate from a local daemon), so a
startup that is not complete in 10 s is a stuck daemon or a bug, and its reason histogram makes it visible.
Why 5 s for a visible pane: Chrome's `kStartupDelayVisibleTabTimeout` experiment value; terminals rarely
need it.

### B. One mechanism: StartupScheduler (CmuxNextWakeups)

- `post(_ priority: StartupPriority, _ name: StaticString, on destination: .main | .lane(Lane, WorkPriority), _ work:)`.
  No default destination. Priorities: `.critical` (inline, name checked against `criticalAllowlist`),
  `.afterFirstFrame` (FrameBatchQueue at `MainWorkClass.visible`), `.afterStartup` (main: background class,
  one per idle turn; lane: behind the fence), `.onDemand` (documentation only).
- `hold(_ reason:) -> StartupInProgressRef`, `firstFrameCommitted()`, `finishRegistration()`, `beginQuit()`.
- A post from another thread before completion hops to main at userVisible and is queued once.
- Every task is a launch signpost interval and a record for `debug.startup`, the StartupTrace ring and the
  hang watchdog's current-task pointer.
- FirstFrameGate, `LaunchSettle.whenSettled`, IdleOnce, `LaunchImageHold.whenClear` and ChromiumWarmup's
  launch timers are deleted. Launch calls live in `CmuxNextApp/Startup/Startup+<Domain>.swift`.

### C. Saved window picture (types in CmuxNextLaunch)

- At quit, per open non-incognito window that is not full screen and is on the active Space:
  `cacheDisplay` of the root view without the backdrop, with each visible pane's live picture composited at
  its frame. Secure Input panes, `sharingType == .none` windows and protected-media pages are filled with
  the theme background. HEIC on the `.files` lane, mode 0600, per profile directory under
  `state/window-pictures`, with meta: frame, screen, scale, appearance, theme generation, sidebar width,
  build, and a layout hash (workspace IDs in sidebar order, shown workspace, pane tree).
- Used only when every meta field matches; the layout hash is compared with the prefetched daemon launch
  snapshot per region; a mismatched region takes today's path. Never after crash recovery, after a crash
  streak, or for incognito leftovers. Deleted with Clear Browsing Data, profile delete, a close for good, or
  `launch.savedPicture` off. Setting default on.
- Browser page pictures are persisted per tab the same way.

### D. Chromium

- `BrowserTabConfiguration.origin`: `.user | .automation | .restoreVisible | .restoreHidden`, no default
  in the new init.
- `.user` and `.automation` start CEF at once (input first). `.restoreVisible` (a page in a visible,
  not occluded window: browser tab, Home, New Tab, Chromium agent page) starts CEF as an afterFirstFrame
  post, right after the picture frame. `.restoreHidden` waits for afterStartup, shows its picture, and
  then loads through RestoredPageLoader (focus then visibility order, concurrency cap from cores, 1 under
  memory pressure, hidden pages never load until shown). Built on `TabContentCache+Deferred.swift`, not a
  second deferral path.
- After F2 the host process is spawned off main (afterFirstFrame when a visible pane is Chromium, else
  afterStartup). A Chromium crash or CHECK during launch never ends cmux.

### E. Tracing like Chrome, and past it

- Milestones: `process_start`, `main_start`, `run_loop_start`, `first_idle`, `window_display`,
  `launch_picture_shown`, `first_window_frame_committed`, `first_live_content_frame`, `startup_complete`,
  plus the values (not times) `launch.temperature` and `launch.pageins_run_loop_start` (at the run loop's start,
  `did_finish_launching_end`), `launch.pageins_first_frame`, `launch.main_cpu_ms` and `launch.interrupted`.
- Always-on launch os_signposts (Release too).
- `CMUX_TRACE_STARTUP=<s>[,file]`: Chrome Trace Event JSON from a preallocated ring, flushed in 64 KiB
  chunks on the `.files` lane (survives a crash), plus the daemon's track (`startup_marks`) and CEF's own
  `--trace-startup` file, merged by `trace.py` on one clock.
- `trace.py --scenario launch-warm|launch-cold`; `bench-startup.py` percentiles and true cold.
- Nightly opt-in: launch histograms by temperature (interrupted launches left out), and a 32 KiB slow-launch
  ring attached only when a launch is slow.
- The watchdog runs from the first statement of `main()` and tags a stall with the current startup task.

### F. Release binary

- Spike first (048): which Swift instrumentation works in the pinned Xcode.
- Profile build (`reload.sh --config profile`): `-profile-generate`, CMUX_BENCH_HOOKS, a flush at
  `startup_complete` (launch.profraw) and at `debug.pgo_flush` before quit (rest.profraw).
- Stage 1 gives `cmux-next.profdata`. Stage 2 builds `-profile-use`, maps the launch profile's functions
  through that build's link map, and adds the cold-launch `__TEXT` page-fault symbols of that build; the
  result is `Resources/build/cmux-next.order`, bound to the profdata sha256.
- `-profile-use` reaches CmuxNext Swift targets only (mechanism from 048: Package.swift unsafeFlags under
  `.when(configuration: .release)` when an env var names the file, or the command line). Rust daemon and
  `cmux-app-ffi` get `-Cprofile-use`. ThinLTO/CMO chosen by A/B (110). Official CEF with its revision's
  PGO profile when the A/B wins.
- Refresh is a manual fleet script; no new CI job or step. Nightly use is behind a repository variable,
  off by default.

## 4. Rules for every task

1. Root cause. Nothing throttled for visible work. Patterns in PATTERNS.md, REVIEW-STANDARD.md.
2. No main-thread blocking: no `.wait()`, `sync`, semaphore or `allowBlocking`. A launch read is consumed by
   event, never by waiting; a not-ready read never draws a default for one frame.
3. Every startup task declares a StartupPriority, a destination, and (for lanes) a WorkPriority with QoS.
   A `.main` post body does no file, network or process work.
4. New types go in `CmuxNextLaunch` (or their owning package), not CmuxNextApp. Every task that touches
   CmuxNextApp runs `scripts/cmux-next/check-app-size.sh --base origin/feat-cmux-next` and must not grow
   source lines. Raising the cap needs the chief's go; the implementer stops and reports instead.
5. No new singletons; injection by init.
6. Each fix has a regression test that fails without it. The agent runs it on the fleet (`cmux-ci run
   --class isolated ...`) red before and green after, and writes both results in the commit. No CI gates,
   perf rows, budgets, jobs or steps are added.
7. Never compile or test on the person's Mac.
8. `risk:high` with an independent review receipt: 019, 107 (socket policy), 101 (managed policy), 052
   and 056 (release build inputs), 067 if it goes ahead (updater). 014 and 073 are `risk:low`. Others are
   `risk:normal`.
9. Animation only through the Motion gate; with animations off the picture swap is one frame.
10. Before pushing: `python3 scripts/cmux-next/prepush-gate.py`; for scripts, the Python unit tests.
11. Tasks edit only their listed files. A file outside the list needs a note in the commit.
12. Take the critical allowlist from `plans/cmux-next/startup-DESIGN.md` (015); a new critical name needs a
    measured cost row there.

## 5. Done checks

All on one fleet GUI mini, bench config build (`reload.sh --config bench`; check 6 needs a `--config bench-checks`
build of the same SHA), 120 Hz, named host, macOS, display kind and SHA.

1. Warm. `python3 scripts/cmux-next/bench-startup.py --app "$NX_APP" --mode warm --profile realistic --runs 20 --require-optimized --json warm.json`.
   Pass: `first_window_frame_committed` p50 <= 150 ms, p95 <= 180 ms; `window_display` p50 <= 140 ms;
   `first_live_content_frame` p50 <= 300 ms (terminal focus) and <= 450 ms (Chromium page focus, before F2);
   `startup_complete` p50 <= 800 ms. Interrupted runs are listed and left out.
2. Cold. Same with `--mode cold --temperature cold --runs 10` (sudo -n purge, daemon stopped). Pass:
   `first_window_frame_committed` p50 <= 300 ms, p95 <= 360 ms; `first_live_content_frame` p50 <= 600 ms;
   `startup_complete` p50 <= 1500 ms; `launch.temperature == cold` in >= 8 of 10 runs.
3. First frame is the picture (structure, not pixels). From `debug.startup` after each warm run:
   `first_commit_layer_tree == [WindowMaterialView, LaunchPictureView]` and `views_built == 0` at
   `first_window_frame_committed`, in 20 of 20 runs with a matching picture. Order holds in 20 of 20:
   `launch_picture_shown < first_window_frame_committed < launch.non_paint_services`. Pixel diff < 2 % is
   optional, on cmux20-bench only.
4. Main thread at launch, from `debug.startup`: `main_cpu_ms_to_first_frame <= 60`; `critical_violations == 0`;
   allowlist length <= 15; no afterStartup task starts before `startup_complete`; reason is never `failsafe`
   in 20 of 20 runs; `python3 scripts/cmux-next/startup-lint.py` prints 0 hits.
5. No hangs at launch. `debug.hangs` from process start (watchdog from `main()`) to `startup_complete + 5 s`,
   20 warm + 10 cold: 0 stalls > 250 ms; 0 main turns > 16 ms except the named CefInitialize turn (until F2)
   and, only if 017 finds no off-main path, the named WKProcessPool turn; main turn p99 <= 4 ms from first
   frame to `startup_complete + 5 s`, excluding those named turns.
6. No blocking at launch. `python3 scripts/cmux-next/startup-queue.py blocking --app "$NX_APP" --runs 5` on a
   `reload.sh --config bench-checks` app gives 0 sites first hit on main before `startup_complete`. A `--config bench`
   app has no detector (`debug.blocking` `compiled_in: false`), and the tool refuses it (task 147).
   `scripts/measure/blocking-probe.sh --until-mark first_window_frame_committed` shows 0 raw calls on main,
   including the xpc-reply, mach-receive, spawn and dlopen kinds (084).
7. Chromium, STRESS session, 20 runs. With no visible Chromium pane: `cef.initialize_started > startup_complete`.
   With a visible restored Chromium page: `cef.initialize_started <= first_window_frame_committed + 20 ms`,
   reason `visiblePaneLoadedIdle` (never timed out), and hidden restored tabs start no renderer before
   `startup_complete`. RestoredPageLoader never exceeds its cap. After F2: CefInitialize on cmux main is
   0 ms and `kill -9` of the host during launch leaves cmux alive and answering `debug.key`.
8. Static counts. (1) Q1 command <= 3 hits (cache, windows, keyRouter). (2) Q1b: every one of the 43
   stored initializers is marked value-only, lazy or posted in startup-DESIGN.md. (3) Q3 command 0 hits.
   (4) `startup-lint.py` 0 hits.
9. Order file. `python3 scripts/cmux-next/pgo/check.py --app "$NX_APP" --order Resources/build/cmux-next.order --link-map <map>`:
   >= 90 % of order symbols resolved in the final Release binary; profdata sha in the order header matches.
   Cold A/B (purge, 10 runs each, same host): `launch.pageins_first_frame` -30 % or better and
   `first_window_frame_committed` p50 -10 % or better.
10. PGO. Release log shows `-profile-use` on every CmuxNext Swift target and `-Cprofile-use` on cmux-tui and
    cmux-app-ffi. A/B (20 warm runs plus bench-typing.py and pane-perf-terminal.py): first frame p50 -5 % or
    better, no typing or motion p95 regression > 2 %. Nightly uses it only with the repository variable on.
11. Startup tracing. `CMUX_TRACE_STARTUP=5` writes `~/Library/Logs/cmux/startup-<pid>.json` that loads in
    Perfetto with app, daemon and (when a Chromium page restores) CEF tracks and one slice per milestone and
    startup task; `kill -9` at 1 s leaves a parseable file. Unset: `trace_ring_bytes == 0`, no CEF switch.
    `trace.py record --scenario launch-cold` prints the critical path and the top 10 main frames.
12. Field. A NIGHTLY opt-in hang report holds `launchFirstFrame` and `launchStartupComplete` histograms by
    temperature, no interrupted launches, and the slow-launch ring only after a forced slow launch.
    PrivacyLeakScanner passes. Reports off: nothing allocated.
13. Launch correctness matrix (071) on fleet macOS 26 and 27, and Tart 14 and 15 (correctness only): first
    launch, scale change, appearance flip, theme change, crash recovery, crash streak, incognito leftovers,
    3 windows on 2 displays, full-screen window, translucent window, workspace closed by the CLI while
    closed, daemon cold, daemon unavailable, no-window launch, launch by URL open, quit during launch.
    Pass: the first frame is never blank and never layout-wrong (no closed workspace, no wrong pane tree);
    content may be stale until live, at most 2 s.
14. Idle after launch. From `startup_complete + 5 s` for 30 s with 3 restored Chromium tabs open:
    app + daemon wakeups <= 1/s, main <= 0.5/s (bench-idle). No launch-only timer is still armed (Q13 list).
15. Edge launches: `CMUX_NEXT_NO_ACTIVATE=1` completes with reason `noWindow`, p50 < 1 s; a quit 100 ms after
    launch runs 0 afterStartup tasks.

## 6. Machine queues

Every hit of a queue is one task with the named template. Each queue is regenerated after its tasks land.

- Q1 eager builds. `awk '/^    init\(environment: AppEnvironment/,/^    }$/' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift | grep -n -E '^\s*_ = [a-z][A-Za-z]*'`.
  18 today. Tasks 020-024. Target <= 3.
- Q1b stored initializers. `grep -n -E '^    (let|var|private\(set\) (var|let)) [a-zA-Z]+(: [^=]+)? = [A-Z][A-Za-z.]*[(.]' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift`.
  43 today. Task 098 (and 078 for AppCrashReporting).
- Q2 launch calls. `awk '/func applicationDidFinishLaunching/,/^    func applicationShouldTerminate/' .../AppDelegate.swift | grep -o -E '[A-Za-z.?]+\.(start|follow|wire|load|install|prewarm|register[A-Za-z]*|activate|attach|keepCurrent|startCloud|startChromiumRuntime|observe[A-Za-z]*|warmWhenIdle|bindRegistryActions|startDaemonSync|watchScope|writeManagedStatus|applyManagedFeaturesNow)\(' | sort -u`
  = 81 today. After 014: `python3 scripts/cmux-next/startup-lint.py` (104) over `CmuxNextApp/Startup/*.swift`
  and `AppServices.init`. Tasks 025-031, 077, 079, 095, 097, 101.
- Q3 ad hoc deferral. `git grep -n -E 'firstFrame\.whenOpen|launchSettle\.whenSettled|IdleOnce(\(\))?\.schedule|(LaunchImageHold\.shared|imageHold)\.whenClear|firstFrame\.armBackstop|launchSettle\.settled\(within|warmWhenIdle\(after:' -- Packages/macOS/CmuxNext/Sources`
  = 11 today; `git grep -n -E 'DemandTimer\(owner: "(ChromiumWarmup|LaunchSettle|FirstFrameGate|LaunchImageHold)'` = 6 timers. Tasks 016, 018. Target 0.
- Q5 runtime blocking (a `--config bench-checks` app). `startup-queue.py blocking --runs 5 --temperature warm|cold` and
  `blocking-probe.sh --until-mark startup_complete` (with the 084 kinds). Template 038.
- Q6 main-thread profile. `startup-queue.py profile`: symbols >= 2 ms inclusive on main before first frame,
  turns >= 4 ms before `startup_complete`, `swift_once` / static init >= 1 ms. Seeded by 072. Template 039.
- Q7 mark gaps. `startup-queue.py gaps warm.json --min-ms 5`. Template 039.
- Q8 Chromium origin. After 040: the deprecated `BrowserTabConfiguration.init` without `origin` gives one
  compiler warning per site (`swift build 2>&1 | grep 'without origin'` in the fleet build log); 9 Sources
  sites are done in 040; each test file with warnings is one task (113). Then 114 removes the overload.
- Q9 pre-main. `xcrun xctrace record --template 'App Launch'` export, `otool -L "$NX_APP/Contents/MacOS/cmux" | grep -v -E '/System/|/usr/lib/'`.
  Each dylib or initializer >= 1 ms is one task (template 055).
- Q10 order coverage. `pgo/check.py ... --launch-profile fresh.profraw`. A refresh trigger, not per hit.
- Q11 main jobs. `startup-queue.py mainjobs` (080): each enqueuer of main-actor jobs, main-queue blocks,
  run-loop sources or timers with >= 1 ms total or >= 5 jobs before `first_window_frame_committed`, and
  each main turn before `startup_complete` that runs outside a StartupScheduler task or the allowlist.
  Template 081.
- Q12 off-main jobs. `startup-queue.py globaljobs` (082): each caller of `.utility`, `.background` or
  unprioritized jobs before `startup_complete` that is not a BackgroundWork lane job (204 `Task.detached`,
  8 `DispatchQueue.global` today). Template 083.
- Q13 arms. `startup-queue.py arms` (085): each DemandTimer (188 sites), FSEvents/DispatchSource watcher
  and NSWorkspace/distributed observer armed before `startup_complete`, with first fire time. Template 086.
- Dropped: Q4 and Q4b (comment audits). Reason in section 0.

## 7. Risks and decisions taken

Decisions taken (memory: decide, most ambitious). Each can be reversed with the reply shown:
- PGO and order refresh is a manual fleet script (054), because CLAUDE.md forbids new CI jobs. To change,
  reply "allow a weekly fleet cron for PGO refresh" or "keep the manual refresh script".
- The saved window picture is on by default behind `launch.savedPicture`. It stores terminal and page
  content on disk (mode 0600; never incognito, Secure Input, protected media). Reply "saved window picture
  on by default" or "saved window picture off by default".
- The launch target (<= 150 ms warm) is met by the picture frame. The live content target is
  `first_live_content_frame` <= 300 ms warm and <= 600 ms cold, reported as a second headline number.
  Reply "launch target means the picture frame" or "launch target means live content".
- Before F2, a visible restored Chromium page costs one CefInitialize main turn (100-160 ms) right after
  the picture frame. It is a named exception in done check 5. The root fix is F2 (046).

Risks:
- A picture can show content that changed while cmux was closed, for up to 2 s. The layout hash refuses a
  layout-wrong picture; content is replaced region by region at first meaningful content.
- Swift instrumentation in the pinned Xcode may not support what F needs. 048 checks first; the fallback is
  `-sanitize-coverage=func,trace-pc-guard` (needs ASan in the profile build only).
- `-profile-use` scope: the command line reaches remote packages too (Sentry, Sparkle) and gives warnings.
  048 picks the scoped mechanism; the reviewer checks the Release log.
- A Swift PGO miscompile shows only in Release. Nightly use waits for the A/B and a STRESS soak and is
  behind a repository variable, off by default.
- Lazy builds can break order-dependent code (observers registered in init, "first read in init (no IUO)").
  Each Q1/Q1b/Q2 task opens each init body.
- The control socket accepts into a 256-entry startup queue; overflow gets a typed `starting` error that the
  CLI retries. It reverses the cx-z9kz0 order (`d08d8d7d3c5`); 019 writes why that is now safe.
- True cold needs `sudo -n purge` on fleet hosts; without it cold means only "daemon stopped" and the 300 ms
  cold target cannot be proven.
- Virtual displays can time commits differently; numbers name the display kind.
- Deferring Sentry integrations and crash forwarders shortens hang and session data for the first seconds;
  crash capture stays first.
- An official CEF build changes CHECK and symbol behavior that the shim's crash handling depends on; 047
  runs the shim crash-recovery test before any pin.
- Daemon deferral (094) delays the update check and crash forwarding by up to 5 s on a cold daemon.
- 065 (hidden workspaces) overlaps the hidden-workspace and PL-daemon D7 owners (OWNERS.md); it keeps only
  the launch acceptance here and is coordinated with them.

## 8. Task table

Size: S <= 150 lines, M <= 400, L = 400 split into commits. "Q" = machine queue. Tasks 001, 014, 047, 048,
072, 073, 084, 087 have no dependency and start at hour 0.

| id | title | size | depends on | queue |
| --- | --- | --- | --- | --- |
| 001 | Land the launch-read slice (6 commits) | M | - | |
| 002 | Chrome-parity milestones | S | - | |
| 003 | Launch os_signposts, always on | S | 002 | |
| 004 | StartupTrace (CMUX_TRACE_STARTUP), chunked | M | 003, 073 | |
| 005 | trace.py launch-warm / launch-cold | M | 004 | |
| 006 | bench-startup percentiles, true cold, optimized-only | M | - (flag: 007) | |
| 007 | Startup temperature from page-ins | S | 073, 002 | |
| 008 | debug.startup command | S | 010, 007 | |
| 009 | Field launch histograms by temperature | M | 007 | |
| 010 | StartupScheduler with destinations | L | - | |
| 011 | BackgroundWork best-effort fence | M | - | |
| 012 | Wire scheduler and fence at the root | M | 010, 011, 001, 014 | |
| 013 | Startup refs and reasons | M | 012 | |
| 014 | Split AppDelegate into Startup files (hour 0, lands on feat-cmux-next) | M | - | Q2 |
| 015 | Critical allowlist and startup-DESIGN.md | S | 014 | |
| 016 | Q3: ad hoc deferral to posts | M | 013 | Q3 |
| 017 | Spread the first-frame burst; WKProcessPool measured | S | 016 | |
| 018 | ChromiumWarmup on the scheduler | M | 016 | Q3 |
| 019 | Control socket: bind off main after owner check | M | 014 | |
| 020 | Q1: cloud and feed lazy | M | 014 | Q1 |
| 021 | Q1: remote services lazy | M | 014 | Q1 |
| 022 | Q1: UI helpers lazy | M | 014 | Q1 |
| 023 | Q1: palette lazy | M | 016 | Q1 |
| 024 | Q1: CEFEngine factory, chromiumWarmup lazy | L | 018 | Q1 |
| 025 | Q2 settings: launch read, writes later | M | 014, 001 | Q2 |
| 026 | Q2 Ghostty config bytes prefetched | M | 014, 001 | Q2 |
| 027 | Q2 Home and New Tab feeds | M | 014 | Q2 |
| 028 | Q2 browser data before first page engine | M | 014 | Q2 |
| 029 | Q2 platform services | M | 015 | Q2 |
| 030 | Q2 menu, bindings, coverage | M | 014 | Q2 |
| 031 | Q2 starts out of AppServices.init | M | 015 | Q2 |
| 032 | Sentry: handlers first, integrations later | M | 003 | Q9 |
| 033 | main() <= 10 ms, no file I/O | M | 001, 003 | |
| 034 | Login shell env and palette strings later | S | 012 | |
| 036 | startup-queue.py generators | M | 002, 006 (profile: 005; mainjobs: 008) | |
| 037 | blocking-probe launch window | S | 002 | |
| 038 | Q5 template | S | 036 | Q5 |
| 039 | Q6/Q7 template | S | 036 or 072 | Q6 |
| 040 | Tab origin and Chrome's visible-first CEF rule | M | 012, 013 | Q8 |
| 041 | cmux pages in Chromium follow the origin rule | M | 040 | Q8 |
| 042 | WebKit views after first frame | M | 016, 001 | Q8 |
| 043 | Persist browser page pictures | M | 001, 073 | |
| 044 | CEF start marks | S | 002 | |
| 045 | CEF framework prefetch at .idle behind fence | S | 011 | |
| 046 | After F2: host spawn off main | M | 040 | |
| 047 | Official CEF + revision PGO profile A/B | L | - | |
| 048 | Spike: Swift PGO/order toolchain | S | - | |
| 049 | Profile build config | M | 048 | |
| 050 | Scenario runner stage 1 (profdata) | M | 049, 103 | Q10 |
| 051 | Order file in the Release link | S | 109 | |
| 052 | PGO in Release builds (no new CI step) | M | 050, 110 | |
| 053 | pgo/check.py with link map | S | 051 | Q10 |
| 054 | Refresh script | S | 052, 053 | |
| 055 | Q9 template | S | 003 | Q9 |
| 056 | Rust PGO for cmux-tui and cmux-app-ffi | M | 048 | |
| 057 | WindowPictureStore at quit | L | 001, 073 | |
| 058 | Decode front picture in main | S | 057, 001 | |
| 059 | First frame = window + picture | L | 058, 012 | |
| 060 | Live window behind the picture | L | 059 | |
| 061 | Input in the picture phase | M | 060 | |
| 062 | Other visible windows (by occlusion) | M | 060 | |
| 063 | Picture setting, invalidation, privacy | M | 059 | |
| 064 | Sidebar visible rows: measure first | S | 060 | |
| 065 | Hidden workspaces: launch acceptance only | M | 060 | |
| 066 | Daemon connect marks (app side) | S | 002 | |
| 067 | Sparkle: measure; dlopen only if >= 3 ms | M | 055 | Q9 |
| 068 | Rust FFI and libghostty before first frame | S | 003 | |
| 069 | Test phase: baseline | S | 036, 006 | |
| 070 | Test phase: after numbers | M | 069, 062, 052, 051 | |
| 071 | Test phase: correctness matrix (extend relaunch-e2e) | M | 063 | |
| 072 | Hour-0 launch profile seed | S | - | Q6 |
| 073 | CmuxNextLaunch package (hour 0) | S | - | |
| 074 | Launch snapshot decode off main | M | 001 | Q5 |
| 075 | Sidebar snapshot and run marker reads | M | 001 | Q5 |
| 076 | Home caches and device ID off main | M | 001 | Q5 |
| 077 | WebUpdates OTA: pointer read early, network later | M | 001, 012 | Q2 |
| 078 | Crash forwarders after startup | S | 011, 012 | Q1b |
| 079 | Q2 remainder | M | 014, 015 | Q2 |
| 080 | Q11 main-job census | M | 008, 036 | Q11 |
| 081 | Q11 template | S | 080 | Q11 |
| 082 | Q12 off-main job census | M | 011, 036 | Q12 |
| 083 | Q12 template: job to BackgroundWork | S | 082 | Q12 |
| 084 | blocking-probe XPC/mach/spawn/dlopen | M | - | Q5 |
| 085 | Q13 arm census | M | 008 | Q13 |
| 086 | Q13 template | S | 085 | Q13 |
| 087 | AppKit state restoration off | S | - | |
| 088 | Watchdog from main(), phase tags | M | 010 | |
| 089 | Crash-streak safe launch | M | 010, 063 | |
| 090 | RestoredPageLoader (TabLoader) | M | 040 | Q8 |
| 091 | First terminal surface cost | M | 026 | |
| 092 | ActionCatalog swift_once wait | S | 001, 008 | Q6 |
| 093 | Daemon startup timeline | M | 004, 066 | |
| 094 | Daemon: defer background work, declare QoS | M | 093 | |
| 095 | No-window launch | S | 013 | |
| 096 | Launch by external open | M | 040, 060 | |
| 097 | ChatsFeed.started split | S | 027, 076 | Q2 |
| 098 | Q1b stored initializers | M | 014 | Q1b |
| 099 | Multi-process startup trace (CEF + daemon) | M | 004, 093 | |
| 100 | Delete pictures with browsing data, profiles, closes | M | 043, 057 | |
| 101 | Managed policy before any page engine | S | 025 | |
| 102 | Picture rules: backdrop, full screen, Spaces, layout hash | M | 059, 074 | |
| 103 | Profile flush hooks | S | 049, 010 | Q10 |
| 104 | startup-lint.py | S | 014 | Q2 |
| 105 | Completion semantics like StartupObserver | M | 013 | |
| 106 | Settings migrations at load | M | 025 | |
| 107 | Control socket startup lock | M | 019 | |
| 108 | Interrupted launches | S | 007, 009 | |
| 109 | Scenario runner stage 2: order from final binary | M | 050, 052 | Q10 |
| 110 | ThinLTO / CMO A/B | S | 048 | |
| 111 | Nightly slow-launch trace ring | M | 009, 004 | |
| 112 | Spike: ghostty_init off main | S | 026 | |
| 113 | Q8 template: test file passes origin | S | 040 | Q8 |
| 114 | Remove the origin-less init | S | 113 (queue empty) | Q8 |
| 115 | Launch histograms wired, sent at schema 3 | S | 009, 007, 013, 108, p09-063, p09-064 | |

### Task details

Each task: files, change, acceptance (diff-only reviewer), test phase (fleet).

**001 Land the launch-read slice.** Files: `CmuxNextDesign/Launch/LaunchRead.swift`, `CmuxNextDesign/Launch/LaunchFileReader.swift`,
`CmuxNextApp/CmuxNextApp.swift`, `CmuxNextAgentPane/AgentPaneLaunchImages.swift` (moved from CmuxNextApp),
`CmuxNextAgentPane/AgentPaneRelaunchWake.swift`, `CmuxNextTerminal/TerminalLaunchFrames.swift` and the g1 tests.
Change: cherry-pick `HEAD..ba1d1a4a239` (6 commits, red test `1ef99263bd5` first) onto the program branch; resolve
conflicts with no new behavior. Acceptance: `git cherry` shows 6 patches; the red test commit comes first;
`CmuxNextApp.swift` starts the 3 reads before `CmuxApplication.shared`; no `take()` waits. Test: `swift test --filter
'LaunchRead|AgentPaneLaunchImages|TerminalLaunchFrames|RelaunchWake'`; bench warm realistic: images read < 60 ms,
0 `launch_image_missed` in 10 runs.

**002 Milestones.** Files: `CmuxNextApp/Control/DebugTimings.swift`, `CmuxNextApp.swift`, `AppDelegate.swift`,
`Windows/WindowManager.swift`, `scripts/cmux-next/bench-startup.py`. Change: marks `run_loop_start` (one-shot
CFRunLoop entry observer), `first_idle` (first beforeWaiting after DFL), `window_display`, `first_live_content_frame`,
`startup_complete` (fired by 010); add to MARKS in order. Acceptance: 5 new names, each once; observers removed after
firing. Test: bench warm 5 runs, all present in order.

**003 Launch signposts.** Files: `CmuxNextSignposts/LaunchSignposts.swift`, `DebugTimings.swift`, `LaunchMarkSink.swift`.
Change: each markLaunch also emits an os_signpost (subsystem `com.cmuxterm.app.next`, category `launch`); StaticString
intervals for main, DFL, AppServices.init, window build, first commit. Acceptance: one begin and one end per interval;
no allocation beyond the mark string; not `#if DEBUG`. Test: `log stream --signpost` lists all milestones.

**004 StartupTrace.** Files: `CmuxNextLaunch/StartupTrace.swift`, `CmuxNextApp.swift`, `DebugTimings.swift`,
`Tests/CmuxNextLaunchTests/StartupTraceTests.swift`. Change: `CMUX_TRACE_STARTUP=<s>` (default 5) and
`CMUX_TRACE_STARTUP_FILE`; ring preallocated in main; records marks, startup task begin/end, main turns > 1 ms (from the
watchdog through an injected sink), lane job begin/end, daemon prestart steps, in CLOCK_UPTIME_RAW µs; flushed in 64 KiB
chunks on `.files` as Chrome Trace Event JSON, and closed at the deadline; `debug.startup_trace` dumps early.
Acceptance: unset = one getenv, no ring; a test parses a full and a truncated chunked file; no write on main.
Test: unit test; one launch loads in ui.perfetto.dev.

**005 trace.py launch scenarios.** Files: `scripts/cmux-next/trace.py`, `trace_fixtures.py`,
`scripts/cmux-next/tests/test_trace_launch.py`. Change: `--scenario launch-warm|launch-cold` (xctrace all processes and
log stream first; cold = stop daemon + `sudo -n purge`); window process start to `startup_complete + 2 s`; merges
StartupTrace, daemon and CEF files (099); summary prints milestones, top 10 main frames before first frame, main turns
> 4 ms. Acceptance: existing scenarios unchanged; fixture test; existing clock rule. Test: one recording each.

**006 bench-startup.** Files: `bench-startup.py`, `scripts/cmux-next/tests/test_bench_startup.py`. Change: p50/p95/p99/max;
`--temperature cold` (purge each run, daemon stopped, refusal named and run stopped); print `launch.pageins_first_frame`,
`launch.temperature`, `launch.interrupted`; `--require-optimized` reads `CMUXBuildConfiguration` or `debug.timings`;
`--order A<B` checks. Acceptance: fixture tests; no flag changes meaning. Test: unit tests on Linux; one cold run.

**007 Startup temperature.** Files: `CmuxNextLaunch/StartupTemperature.swift`, `DebugTimings.swift`,
`Tests/CmuxNextLaunchTests/StartupTemperatureTests.swift`. Change: at `run_loop_start` read `ri_pageins`
(`proc_pid_rusage` V4) through a seam and classify with Chrome's constants from `startup_metric_utils` at the pinned
revision as the first thresholds (tuned later on the fleet); at first frame read page-ins and main thread CPU as separate
values. Values, never time marks (a `launch.value` signpost, not `launch.mark`, and a `<name> <value>` pipe line that
VALUE_MARKS in startup-queue.py and bench-startup.py lists): `launch.pageins_first_frame`, `launch.main_cpu_ms`
(`CmuxNextLaunch/StartupCounterReader.swift`, `LaunchCounterLog.swift`; `debug.timings` `launch_counters`). Acceptance: pure classifier
tested; syscalls through the seam; nothing after the reads. Test: warm reads warm, purge reads cold.
Since p09-observability-034 the classifier exists: `LaunchClock.Temperature` (CmuxNextTrace), decided once at
`did_finish_launching_end` and sent as `launch.temperature.<name>` and `launch.pageins_run_loop_start`. 007 adds no
second classifier or enum; it reuses that one (the hang report and metrics enums map from it with `init(_:)`) and adds
only the first-frame values.

**008 debug.startup.** Files: `CmuxNextApp/Control/DebugStartup.swift` (wiring), payload builder in `CmuxNextLaunch`,
`Control/AppControl.swift`. Change: DEBUG or CMUX_BENCH_HOOKS only: milestones, temperature, page-ins,
`main_cpu_ms_to_first_frame`, tasks (name, priority, destination, posted/start/duration), `critical_violations`, reason,
`views_built`, `first_commit_layer_tree`, thread list at first frame, `trace_ring_bytes`, `action_catalog_main_wait_ms`.
Acceptance: read-only; absent in Release. Test: fields present in 5 of 5 runs.

**009 Field histograms.** Files: `CmuxNextHangReports/HangReport.swift`, `HangReportBuilder.swift`,
`HangReportCollector.swift`, `IntervalHistogram.swift`, `Tests/CmuxNextHangReportsTests/LaunchHistogramTests.swift`.
Change: `launchFirstFrame`, `launchStartupComplete`, `launchLiveContent` keyed by temperature, plus a completion reason
count; schema version up; allow-listed fields only. Acceptance: PrivacyLeakScanner passes; off cost one atomic load.
Test: unit tests; a report JSON holds them.

**010 StartupScheduler.** Files: `CmuxNextWakeups/StartupScheduler.swift`, `StartupPriority.swift`,
`StartupInProgressRef.swift`, `StartupDestination.swift`, `Tests/CmuxNextControlTests/StartupSchedulerTests.swift`.
Change: API in section 3B (destination with no default; userVisible hop from other threads; `beginQuit()`); failsafe
DemandTimer 10 s; completion is posted, marks `startup_complete` with reason, releases in post order; post after
completion goes straight to its class; each task is a signpost interval and a record; a current-task StaticString
pointer for the watchdog. Acceptance: tests with ManualClock and `MainWorkScheduler.testing`: afterStartup never
before refs reach 0; pending input defers `.main` afterStartup; failsafe reason; order kept; unknown critical name
recorded; lane posts run off main; a background-thread post is queued once; after `beginQuit()` nothing runs and the
timer is cancelled; no timer after completion. Test: red before, green after.

**011 Best-effort fence.** Files: `CmuxNextWakeups/BackgroundWork.swift`, `LaneScheduler.swift`,
`Tests/CmuxNextControlTests/BackgroundWorkTests.swift`. Change: `beginBestEffortFence()` / `endBestEffortFence()`;
`.idle` and `.bestEffort` jobs queue; awaited fenced jobs are promoted. Acceptance: tests for both; QoS unchanged.

**012 Wire at the root.** Files: `CmuxNextApp.swift`, `Startup/Startup+Core.swift`, `AppServices.swift`,
`FirstFrameGate.swift`, `LaunchSettle.swift`. Change: main() makes the scheduler and begins the fence; injected by init;
first window CATransaction completion calls `firstFrameCommitted()`; refs firstFrame, restore; FirstFrameGate becomes a
private adapter. Acceptance: same work, only the order owner changes; FirstFrameGateTests ported; app-size not grown.
Test: `startup_complete` present, reason not failsafe in 10 of 10.

**013 Refs and reasons.** Files: `LaunchSettle.swift`, `Windows/WindowManager.swift`, `PaneContentView+LaunchImage.swift`.
Change: per visible pane a ref released by its content signal (loaded-idle in 105), the pane bound, or
daemon-unavailable; restore ref at the end of `WindowManager.restore`; reasons `visiblePaneLoadedIdle`,
`visiblePaneTimedOut`, `noVisiblePane`, `noWindow`, `daemonUnavailable`, `failsafe`. Acceptance: each path releases
exactly once (fake panes). Test: reasons over 10 runs.

**014 Split AppDelegate (hour 0, PR to feat-cmux-next).** Files: `AppDelegate.swift`, `Startup/Startup+{Settings,Browser,
Home,Platform,Control,Terminal}.swift`, plus moves of `AppServices+AfterFirstFrame.swift` content into
`Startup+Core.swift`. Change: move the bodies of DFL and `startSettingsAndControl` into one `registerX(services:settings:)`
per domain, called in the same order; no scheduler yet. Offset wrapper lines in the same diff by moving launch-only types
with no AppServices dependency (LaunchImageHold, LaunchWarmup) into CmuxNextLaunch (073). Acceptance: move only; the Q2
output over the new files is the same 81 names in the same order; `check-app-size.sh --base origin/feat-cmux-next` passes
(else stop and report). `risk:low`. Test: fleet compile and CmuxNextAppTests.

**015 Allowlist and design doc.** Files: `plans/cmux-next/startup-DESIGN.md`, `StartupScheduler.swift`,
`plans/cmux-next/perf-lead.md`. Change: table of the 81 Q2 calls, 18 Q1 builds, 43 Q1b initializers and the main() steps
with priority, destination and reason; `criticalAllowlist` (<= 15) from it; perf-lead row 18 links it. Acceptance: every
name once; code allowlist equals the critical rows.

**016 Q3 to posts.** Files: `AppDelegate.swift`/Startup files, `LaunchWarmup.swift`, `LaunchCleanup.swift`,
`LaunchImageHold.swift`, `CmuxNextDesign/MadeAheadOpenPanel.swift`, `FirstFrameGate.swift`. Change: each Q3 hit is a post;
palette prepare is one afterStartup post per step; icon picker, open panel warm, temp cleanup afterStartup (lane where it
does I/O); LaunchImageHold becomes a ref; IdleOnce and FirstFrameGate deleted. Acceptance: Q3 = 0; palette first-open
test unchanged; app-size lower. Test: bench-stalls palette rows unchanged.

**017 First-frame burst.** Files: `AppServices+AfterFirstFrame.swift` (or its Startup file),
`CmuxNextAgentPane/AgentPaneView+Warmup.swift`. Change: FreeTierAttest, ssh, serverReach, updater each one afterStartup
post; spares, page host pool, AgentTabImport afterStartup; AgentPaneView.startWarmup: measure first; if a WebKit agent
pane is visible, the first afterFirstFrame slot, else afterStartup; try an off-main path and record the result.
Acceptance: one service per post; a58bace0947 tests pass. Test: 0 main turns > 16 ms in 1 s after first frame except the
named WKProcessPool turn (20 runs).

**018 ChromiumWarmup on the scheduler.** Files: `CmuxNextChromiumWarmup/ChromiumWarmup.swift`, `AppServices+Chromium.swift`,
`Tests/CmuxNextChromiumWarmupTests/ChromiumWarmupTests.swift`. Change: remove the launch timer and the launch paths of the
idle and give-up timers; CefInitialize and the spare window are afterStartup posts with an idle predicate: one DemandTimer
re-armed only on input while the post is pending, cancelled at the post (counted in Q13); menu-tracking rule kept.
Acceptance: 0 launch DemandTimers owned by ChromiumWarmup; CefInitialize never before `startup_complete` for hidden needs
and never with input pending. Test: bench-idle shows no ChromiumWarmup wakeups after the warm start.

**019 Control socket bind (risk:high).** Files: `Startup/Startup+Control.swift`, `CmuxNextControl/ControlService.swift`,
`CmuxNextControl/ControlSocketServer.swift`, `ControlSocketServer+File.swift`, `Control/AppControl.swift`. Change: from
main(), off main: owner check (`unlinkIfOwn`), bind in the same private directory with the same mode rules, `listen(fd,
SOMAXCONN)`; method registration as one afterFirstFrame post per group; requests served at `MainWorkClass.automation`;
`launchSettle.settled(within: 4 s)` removed; migrations handled by 106 and classic imports afterStartup on a lane.
Acceptance: no request served before its group registers; a live instance's socket is never unlinked (test); policy
unchanged; the commit says why the cx-z9kz0 order (`d08d8d7d3c5`) is now safe. Test: first answered request p50 <=
first frame + 50 ms.

**020-022 Q1 lazy.** 020 cloud and feed (`AppServices.swift`, `Cloud/AppServices+Cloud.swift`); 021 ssh, remoteLocalhost,
remoteTerminals (+start) (`AppServices.swift`, `Startup/Startup+Platform.swift`); 022 rightSidebarSections (icon build to
an afterStartup lane post), previews, dragSession, emptyWorkspaces, configActions, resources. Change: remove the `_ = x`;
readers that relied on init order move to posts; a visible need posts afterFirstFrame. Acceptance: Q1 drops by 2/3/6;
no IUO; each init body checked for observers (moved to posts). Test: owning suites; sign-in callback at launch reaches
auth (020); restored remote workspace reconnects (021); drag, right sidebar, config action work (022).

**023 Q1 palette.** Files: `AppServices.swift`, `Startup/Startup+Core.swift`. Change: remove `_ = palette`; bindings and
hooks afterFirstFrame; prepare steps at idle (016); a palette key before that builds it in the key's turn as input class.
Acceptance: Q1 -1; a palette key 50 ms after first frame opens it (fake time).

**024 Q1 CEFEngine factory.** Files: `AppServices.swift`, `TabContentCache.swift`. Change: factory in place of an instance;
CEF wiring moves to an `engineDidCreate` hook; `_ = chromiumWarmup` goes. Acceptance: Q1 <= 3 overall;
`AppRunMarker.keepSignalHandlers` runs before CefInitialize (test). Test: CmuxNextBrowserTests, CEF crash recovery.

**025 Q2 settings.** Files: `Startup/Startup+Settings.swift`, `CmuxNextSettings/SettingsController.swift`,
`CmuxNextApp.swift`. Change: `prepareDefaultURL` and `readAtLaunch` become a LaunchRead from main(); DFL's settings-
dependent critical steps run in a continuation on its completion (no wait, no default frame); `writeManagedStatus` an
afterStartup lane post; `UserOnlySettingConfirmation.install` and the didBecomeActive MDM task afterFirstFrame; policy
apply stays critical (101). Acceptance: 0 file calls on main from this path; a cold-disk test shows no window commit
before the theme is applied and no main wait.

**026 Q2 Ghostty config.** Files: `CmuxNextTerminal/GhosttyRuntime.swift`, `GhosttyRuntime+ConfigFiles.swift`,
`Startup/Startup+Terminal.swift`, `CmuxNextApp.swift`. Change: the launch thread reads every config file (default and
recursive) into memory; `loadConfig` uses `ghostty_config_load_string`; `GhosttyConfigLiveReload.start` and
`GhosttyKeybindSync.start` afterFirstFrame. (Off-main `ghostty_init` is spike 112.) Acceptance: 0 file reads on main in
the runtime phase marks; diagnostics identical on both paths (test). Test: `dfl.theme - dfl.settings_read` <= 5 ms.

**027 Q2 Home feeds.** Files: `Startup/Startup+Home.swift`, `Home/HomeService.swift`. Change: home.start, projectsImport,
AgentPageChats wire, NewTab feeds and ChatSettingsPush afterFirstFrame when Home or an agent page shows, else
afterStartup; Home first frame from the cache (076). Acceptance: 5ae7be88773 tests pass; no Chief or cloud connect before
first frame.

**028 Q2 browser data.** Files: `Startup/Startup+Browser.swift`. Change: profiles, bookmarks, history, locationTrail,
FirstPartyPageSchemes, `PageWebView.chromiumHosting`, 3 preference follows afterFirstFrame; reads on `.files`; an engine
start awaits `profiles.loaded` by event. Acceptance: no engine starts before profiles load (test). Test: right profile in
10 of 10 relaunches.
As landed (deviation from the spec above): the gate is `TabContentCache.enginesAwait`, a `LaunchReadEvent` that
`BrowserProfileService.load` wires and signals; the read's step makes the waiting tab's page itself, so a tab no pane
shows gets one too. It gates every page whose profile the book chooses (a daemon tab's record); a session-local tab
(incognito or default store), a machine-store page and a copy of a live page choose no profile from the book and are not
held. A deferred restored page makes no engine and is not held. Only history's daemon sync and the location trail's scope
moved to afterFirstFrame posts: FirstPartyPageSchemes, `PageWebView.chromiumHosting` and the engine, link-click and
bookmark preference follows are read by the first page or the first frame, so they stay before it. The profile, bookmark
and history reads were already off main (their file actors); they did not move to the `.files` lane.
Startup/Startup+Browser.swift waits for 014's split. Test: a relaunch with a tab in a deleted profile opens it in the
default store, and the profile's data is removed (`BrowserPagesAwaitProfilesTests`).

**029 Q2 platform.** Files: `Startup/Startup+Platform.swift`. Change: KeepAwake, ComputerUseHelperDaemon, mobile,
deviceHub, macScreenPages, remoteLocalhost, apps, updater.follow, hibernation, notifications.follow,
followMacScreenSettings, UpdateFeedPosting afterStartup; borders and glass afterFirstFrame; globalHotKeys afterFirstFrame;
WebAuth handler and Apple-event URL handler stay critical. FeaturePolicyEnforcer is not moved (101). Acceptance: each name
has its design-doc priority. Test: global hot key works within 1 s.

**030 Q2 menu and coverage.** Files: `MainMenu.swift`, `Handlers/HandlerCoverage.swift`, `AppDelegate.swift`/Startup file,
`AppActions.swift`. Change: coverage verify and the unbound walk DEBUG only; measure MainMenu.make and AppActions.bind; if
the menu > 2 ms, top-level items critical and submenus afterFirstFrame, with a test that every key equivalent fires before
the fill. Acceptance: no Release walk; menu measured < 2 ms or deferred with the key test green.

**031 Q2 starts out of AppServices.init.** Files: `AppServices.swift`, `Startup/Startup+Core.swift`. Change: browserHost,
notifications.start, input.start, surfaceInvariant occlusion, updater.attach + serverUpdates.start become posts; NSApp
input hooks stay in init. Acceptance: init holds no start() calls; banner and update-sheet tests pass.

**032 Sentry.** Files: `CmuxNextCrashReporting/CrashReporter.swift`, `Crash/CrashReporter+Launch.swift`. Change: measure
SentrySDK.start; keep crash and signal handlers at launch; app-hang tracking, session file I/O and swizzled breadcrumbs
start afterStartup. Static Sentry is out of scope (personality limit, CmuxSentryTelemetry/Package.swift:54).
Acceptance: early-crash test (0.1 s) still reports; SentrySDK.start main time <= 3 ms warm.
As built (cp/p08-startup-032): sentry-cocoa 9.28 installs every integration inside `SentrySDK.start` and has no
public API to install one later, so only app-hang reports move (paused at start, resumed in one afterStartup post,
feature `sentryHandlersFirst`). Session I/O stays at start: `SessionTracker` already reads and writes its files on
the SDK's own queue (`endCachedSession`, `startSession` dispatch async), and manual sessions would lose the
cached-session close of a run that ended abnormally. Network breadcrumbs stay on: turning them off removes the
URLSession swizzle from the start but loses them for the whole run. The forwarder starts stay for 078. The
`launch.sentry_start` interval (`crash.sentry_start` to `crash.sentry_started`) measures the call; the 3 ms
target and the early-crash test are open until the fleet measures them. If the start is still over 3 ms, the
cost is in SentryCrash install and the binary image cache, which only a lead decision on the spec can move.

**033 main().** Files: `CmuxNextApp.swift`, `AppEnvironment.swift`, `CmuxNextApp+LaunchEnvironment.swift`. Change:
signpost each step; directory creation for scroll anchors and draft attachments, SidebarSnapshotFile paths and
AppEnvironment reads become LaunchReads; the 2 `.shared` assignments become init injection. Acceptance: main_start to
main.run <= 10 ms warm; 0 file calls on main before main.run.

**034 Launch thread diet.** Files: `LaunchWarmup.swift` (or its CmuxNextLaunch home), `CmuxNextDaemon/Launch/DaemonLauncher.swift`.
Change: `prewarmLoginEnvironment` becomes an afterStartup `.utility` lane post; with no remembered env and a daemon to spawn
now, `.userInitiated` at once. `prewarmStrings` afterStartup. Acceptance: no child process before first frame when a
remembered env exists; cold-daemon behavior unchanged.

**036 startup-queue.py.** Files: `scripts/cmux-next/startup-queue.py`, `scripts/cmux-next/tests/test_startup_queue.py`.
Change: modes `blocking`, `gaps` (depend on 002, 006), `profile` (on 005), `mainjobs`, `globaljobs`, `arms` (on 080, 082,
085), all with `--json`; fleet guard. Acceptance: fixture tests per mode; never runs on the person's Mac.

**037 blocking-probe launch window.** Files: `scripts/measure/blocking-probe.sh`, `blocking-probe-report.py`. Change:
`--until-mark NAME` keeps main-thread calls before the mark. Acceptance: launch section; old modes unchanged.

**038 Q5 template.** Files: the site from the queue. Change: move the read or write to a LaunchRead or a lane job; prefetch
when first paint needs it; never `allowBlocking`. Acceptance: absent in the next Q5 run; no new main wait.

**039 Q6/Q7 template.** Files: the owner of the symbol or gap. Change: lazy, lower priority, off main or O(visible); a
`swift_once` >= 1 ms becomes a lazy instance or launch-thread precompute. Acceptance: under threshold in the next run (5,
median); numbers in the commit.

**040 Tab origin, visible-first.** Files: `CmuxNextBrowser/Engine/BrowserEngine.swift`, `CmuxNextBrowser/CEF/CEFEngine.swift`,
`TabContentCache.swift`, `TabContentCache+Deferred.swift`, the 9 Sources sites of `BrowserTabConfiguration(`,
`Tests/CmuxNextBrowserTests/CEFLaunchDeferralTests.swift`. Change: `origin` per section 3D in a new init with no default; the
old init stays, deprecated, and means `.user` (Q8); `.restoreVisible` starts CEF in an afterFirstFrame post; `.restoreHidden`
uses the existing deferred path until afterStartup and 090. Acceptance: tests: visible restored starts after
`firstFrameCommitted()` and before completion; hidden waits; user starts at once; completion with a focused Chromium page
has reason `visiblePaneLoadedIdle`; no cycle (fake engine + ManualClock); no second deferral mechanism. Test: STRESS
relaunch 20 runs per done check 7.

**041 cmux pages in Chromium.** Files: `CmuxNextApp/Pages/Chromium/ChromiumPageHost.swift`, `CmuxNextPages/PageWebView.swift`,
`Startup/Startup+Browser.swift`. Change: a page view made during launch gets `.restoreVisible` or `.restoreHidden` from its
pane's visibility; a hidden one shows its picture or the theme background until loaded. Acceptance: Home in front starts CEF
in the first afterFirstFrame slot; Home hidden never before completion (fake engine). Test: Home in front 10 runs: picture,
then live page; `first_live_content_frame` not worse than base.

**042 WebKit views.** Files: `AgentPaneView+Warmup.swift`, `AgentTabStore+Launch.swift`, `NewTab/NewTabSparePool.swift`.
Change: `newTabSpares.prewarm` afterStartup; every WKWebView/WKProcessPool before completion is the visible agent pane's
(afterFirstFrame, after its picture) or an afterStartup post; `deferAtLaunch` waits on the scheduler. Acceptance: test for
the limit. Test: agent focus `first_live_content_frame` p50 <= 300 ms warm.

**043 Browser page pictures.** Files: `CmuxNextLaunch/BrowserLaunchPictures.swift`, `Quit/QuitCoordinator.swift`,
`TabContentCache+Previews.swift`, `CmuxNextApp.swift`. Change: at quit, JPEG per visible non-incognito tab (privacy fills as
3C), mode 0600, per profile; LaunchRead decodes; shown until first contentful paint; unasked images dropped 30 s after
launch. Acceptance: incognito never written; stale size shows nothing.

**044 CEF marks.** Files: `CEF/CEFRuntime.swift`, `DebugTimings.swift`. Change: `cef.preload_started`, `library_loaded`,
`initialize_started`, `initialize_ended`, `spare_window_ready`, `first_page_paint` with trigger, by hook injection.
Acceptance: once each; no new dependency on the app.

**045 CEF prefetch.** Files: `CEF/CEFFrameworkPrefetch.swift`, `CEF/CEFRuntime.swift`. Change: the 367 MiB read is a `.idle`
job behind the fence; promoted to userBlocking when a user or visible tab asks. Acceptance: no CEF file reads before
completion on a cold launch without a visible Chromium page; promotion test.

**046 After F2.** Files: `AppServices+Chromium.swift`, `CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostLauncher.swift`.
Change: with the host on, the CefInitialize post becomes a posix_spawn off main (afterFirstFrame when a visible pane is
Chromium, else afterStartup); host death shows crash state. Acceptance: 0 ms CefInitialize on main; kill test.

**047 Official CEF A/B.** Files: `scripts/cmux-next/cef-manifest.json`, `scripts/cmux-next/tests/cef-build-flags.test.sh`.
Change: coordinate with the bundle-size owner; A/B job `70436914a38e`'s official dist against the pin; for the next pin,
rebase the official flags onto the cmux.33 fork with `checkout_pgo_profiles=True` and the profile for that exact
revision. Acceptance: pin only if CefInitialize and new-tab first paint are each >= 10 % faster, no STRESS soak crash, the
profile mismatch rate < 10 %, and the shim crash-recovery test passes; flags test checks `is_official_build=true`.
Status: gate only; the A/B was not run, and the pin and the cmux.33 rebase are still open. `cef_build_flags.py`
refuses `require_official_pgo: true` unless the manifest records `pgo_profile` per arch (the exact name in
`chrome/build/mac-arm.pgo.txt` / `mac.pgo.txt` at the fork's revision) and an `official_pgo_ab` record that meets
the acceptance; the framework's `archive.json` must record that profile and the `pgo_mismatch` counts that
`--count-pgo-mismatch` reads from the build log.

**048 Toolchain spike.** Files: `plans/cmux-next/startup-DESIGN.md`, `scripts/cmux-next/pgo/probe-toolchain.sh`. Change: on
the pinned Xcode, test `-profile-generate` + `__llvm_profile_write_file`/`reset_counters`, `llvm-profdata merge`, the
trace-pc-guard fallback, and how `-profile-use` reaches only CmuxNext targets (Package.swift unsafeFlags from an env var vs
command line). Acceptance: the doc names working commands and the Xcode version; exit 0/1 per path.

**049 Profile config.** Files: `scripts/reload.sh`, `scripts/cmux-next/pgo/build-profile.sh`. Change: `--config profile`:
Release optimization, `-profile-generate`, `-fprofile-instr-generate` in OTHER_LDFLAGS, CMUX_BENCH_HOOKS, `CMUX_PGO_PROFILE`;
CEFShim and Rust FFI not instrumented here. Acceptance: other configs unchanged; a launch writes a non-empty profraw.

**050 Runner stage 1.** Files: `scripts/cmux-next/pgo/run-scenarios.py`, `scripts/cmux-next/tests/test_pgo_scenarios.py`.
Change: `--stage profile`: 3 cold, 3 warm launches, STRESS restore, 2000 keys, Cmd-T/W/N/D x50, switch x100, palette x20,
first Chromium tab, quit; collects launch.profraw and rest.profraw (103); merges `cmux-next.profdata` and keeps the launch
function list. Acceptance: deterministic list; fixture test for merge.

**051 Order file in link.** Files: `cmux.xcodeproj/project.pbxproj`, `Resources/build/cmux-next.order`. Change: Release block of
target cmux-next only: `-Xlinker -order_file -Xlinker $(SRCROOT)/Resources/build/cmux-next.order`, `LD_GENERATE_MAP_FILE=YES`;
`-order_file_statistics` only if ld-prime accepts it. Acceptance: only the Release block changes; a missing symbol is a
warning.

**052 PGO in Release (risk:high).** Files: `scripts/cmux-next/check-release-compile.sh`, the existing build script that the
nightly step calls, `scripts/cmux-next/pgo/fetch-profdata.sh`, `Resources/build/cmux-next.profdata.sha256`,
`Packages/macOS/CmuxNext/Package.swift` (if 048 picks it). Change: fetch by sha256 inside the existing script; `-profile-use`
for CmuxNext targets only when the sha matches and the repository variable is on; otherwise no flag with a warning; the
flag set from 110. Acceptance: no workflow step added (reviewer diffs `.github/`); both paths build.

**053 check.py.** Files: `scripts/cmux-next/pgo/check.py`, `scripts/cmux-next/tests/test_pgo_check.py`. Change: order
coverage from the link map; percent of a fresh launch profile in the first 64 `__TEXT` pages; profdata hash mismatch rate;
order header profdata sha. Acceptance: fixture tests; exit 1 under 90 % or mismatch > 20 %; not wired to CI.

**054 Refresh script.** Files: `scripts/cmux-next/pgo/refresh.sh`, `startup-DESIGN.md`. Change: one command: profile build
at a SHA, stage 1, upload, stage 2 (109), update order and sha, open a PR. Acceptance: idempotent; refuses a dirty tree.

**055 Q9 template.** Files: the image or initializer. Change: static or lazy dlopen off main, remove +load or mod_init,
lazy Swift global. Acceptance: under 1 ms or absent in the next App Launch export.

**056 Rust PGO.** Files: `scripts/cmux-next/pgo/rust-pgo.sh`, `cmux.xcodeproj/project.pbxproj` (Release "Bundle cmux-tui"
phase), the cmux-app-ffi build script. Change: `-Cprofile-generate` for cmux-tui and cmux-app-ffi; scenarios bench-startup
daemon, bench_cli_storm.py, new-tab-daemon-bench.py; merge with `$(rustc --print sysroot)/lib/rustlib/<host>/bin/llvm-profdata`
after an LLVM version check; `-Cprofile-use` in Release when present. Acceptance: Debug unchanged; no profdata = as before.
Test: daemon op p50/p95 -5 %.

**057 WindowPictureStore.** Files: `CmuxNextLaunch/WindowPictureStore.swift`, `WindowPictureMeta.swift`,
`Quit/QuitCoordinator.swift` (wiring), `Tests/CmuxNextLaunchTests/WindowPictureStoreTests.swift`. Change: section 3C save
path; composites terminal and agent pictures, and page pictures when 043 lands; HEIC on `.files`. Acceptance: incognito never
written; encode off main; quit +<= 30 ms per window.

**058 Decode front picture.** Files: `CmuxNextApp.swift`, `WindowPictureStore.swift`. Change: LaunchRead from the snapshot's
window recency; `kCGImageSourceShouldCacheImmediately`; mark `launch_picture_decoded`. Acceptance: off main; no picture, no
read. Test: p50 <= 60 ms.

**059 First frame = picture.** Files: `Windows/LaunchSnapshotWindow.swift`, `Windows/WindowManager.swift`,
`CmuxNextLaunch/LaunchPictureView.swift`. Change: on a meta match, the NSWindow at the saved frame with a live
`WindowMaterialView` and one picture layer (`contentsGravity` topLeft); ordered in on decode completion or a 40 ms
DemandTimer; mark `launch_picture_shown`. Acceptance: first commit has no WindowRootView; mismatch takes today's path; no
main wait. Test: done check 3.

**060 Live window behind the picture.** Files: `Windows/WindowManager.swift`, `WindowRootView.swift`,
`CmuxNextDesign/Launch/LaunchReveal.swift`. Change: afterFirstFrame slices; picture leaves per region at first meaningful
content, 2 s bound; Motion gate (one frame with animations off). Acceptance: no blank region (fake regions); each step in
budget; `check-motion.sh` clean. Test: 0 turns > 16 ms first frame to completion (except named).

**061 Input in the picture phase.** Files: `LaunchPictureView.swift`, `Focus/KeyRouter.swift`,
`Tests/CmuxNextAppTests/LaunchPictureInputTests.swift`. Change: a key changes only the model in its turn (registry action, or
the terminal stand-in buffer) and raises the focused-pane slice to the next frame; a click on a picture region is held and
re-sent to the live view at the same point when the region is live (2 s), or dropped if its model changed; a live resize or
full-screen toggle removes the picture at once. Acceptance: test: a key between `launch_picture_shown` and live reaches its
target exactly once; no main turn builds the whole window. Test: typed burst 10 ms after first frame, 10 relaunches, no lost
keys (InputJournal).

**062 Other windows.** Files: `Windows/WindowManager.swift`. Change: visible = not occluded and on an active display; each
visible window's picture one per afterFirstFrame post and its focused pane afterFirstFrame; occluded or off-screen windows
build at afterStartup or when they become key. Acceptance: with 3 windows (1 occluded) only visible windows build before
completion (`views_built`).

**063 Picture setting and safety.** Files: `WindowPictureStore.swift`, `CmuxNextSettings/Schema/SettingsSchema+Launch.swift`,
`CmuxNextApp/Resources/Localizable.xcstrings`. Change: `launch.savedPicture` (default on), localized; not used after crash
recovery, incognito leftovers, screen/scale/appearance/theme/build change; Secure Input, `sharingType .none`, protected media
filled. Acceptance: a test per rule; strings in every locale file the localization skill names.

**064 Sidebar rows.** Files: `CmuxNextSidebar/Model/SidebarModel+VisibleRows.swift` and the list `+OnScreen`/`+Reuse` files.
Change: measure rows built before completion with 60 workspaces; close with the number if <= visible + 2, else build
off-screen rows at afterStartup. Test: `sidebar_rows_shown` p50 <= 250 ms warm STRESS.

**065 Hidden workspaces (coordinated).** Files: `Windows/WindowManager.swift`, `TabContentCache.swift`, `PaneController.swift`.
Change: with the hidden-workspace and D7 owners: no controller, view or engine for a hidden workspace at launch; attach
focused then visible. Acceptance: `views_built` == visible panes; 60-workspace test builds 1 workspace.

**066 Daemon connect marks.** Files: `CmuxNextDaemon/Connection/DaemonPrestart.swift`,
`CmuxNextDaemonService/DaemonService+LaunchSnapshot.swift`. Change: `daemon.connect_started`, `spawned`, `identified`,
`snapshot_received`; cold spawn through ProcessLauncher off main. Acceptance: once each; no main spawn.

**067 Sparkle.** Files: `Packages/macOS/CmuxNext/Package.swift`, `CmuxNextUpdater/UpdaterService.swift`. Change: measure the
Sparkle image and initializers; close with the number unless >= 3 ms; if so (risk:high), a protocol whose implementation
dlopens Sparkle off main at afterStartup. Acceptance: number recorded, or otool no longer lists Sparkle and updater tests pass.
Measure: `scripts/measure/sparkle-image-cost.sh` (fleet entry) runs `scripts/cmux-next/sparkle-image-cost.py`: per
fresh process, `dlopen(Sparkle, RTLD_NOW)` after its system dependencies, minus a control dlopen; p50/p95/p99/max and
the verdict (`keep-linked` under 3 ms p50, else `dlopen-off-main`); `--app` also lists the executable's non-system
dylibs. Number: not yet run (the entry needs the hq measureScripts allowlist); Package.swift and UpdaterService.swift
stay unchanged until the number says `dlopen-off-main`.

**068 FFI and libghostty.** Files: `AppServices.swift`, `CmuxNextTerminal/GhosttyRuntime.swift`. Change: signpost first FFI
calls and `ghostty_init`; tokio or relay starts reachable before completion move to afterStartup owners; check GhosttyNextKit
is ReleaseFast. Acceptance: no FFI runtime thread at first frame (thread list).

**069 Baseline.** Files: `plans/cmux-next/perf-lead.md`. Change: at the base SHA, bench warm/cold x20, STRESS x10, trace.py
x5, startup-queue modes, App Launch x5; p50/p95/p99/max rows. Acceptance: rows name host, macOS, refresh, display, SHA, config.

**070 After numbers.** Files: `perf-lead.md`, `startup-DESIGN.md`. Change: rerun 069 at the tip, plus PGO/order A/B and the
field check; pass or fail per done check. Acceptance: each of the 15 done checks has a row.

**071 Correctness matrix.** Files: `scripts/cmux-next/relaunch-e2e.py`, `scripts/cmux-next/restore-trace.py`. Change: add the
done-check-13 cases to the existing drivers; the CEF-host kill case runs only when F2 is on. Acceptance: PASS/FAIL per case
with screenshot path. Test: macOS 26/27 fleet; `scripts/cmux-next/os-matrix.sh --os 14,15` for correctness.

**072 Hour-0 seed.** Files: `plans/cmux-next/startup-DESIGN.md`. Change: at `772cdfc45ac` and `ba1d1a4a239`: bench-startup warm
realistic x10 `--hangs 16 --json`, App Launch and Time Profiler x3, blocking-probe over launch; write the breakdown of the
450 ms gap, main symbols >= 2 ms before first frame, and main turns >= 16 ms as the first Q6/Q5 rows. Acceptance: rows with
file:line, p50 ms, run IDs; >= 80 % of main CPU before first frame explained.

**073 CmuxNextLaunch package (hour 0).** Files: `Packages/macOS/CmuxNext/Package.swift`, `plans/cmux-next/architecture-layers.json`,
`Sources/CmuxNextLaunch/` (first type: LaunchImageHold or LaunchWarmup moved from CmuxNextApp), `Tests/CmuxNextLaunchTests/`.
Change: target depends on CmuxNextCompat, CmuxNextSignposts, CmuxNextWakeups, CmuxNextDesign; core/feature layer.
Acceptance: no dependency on CmuxNextApp; `check-app-size.sh --base` passes; layer test passes.

**074 Launch snapshot off main.** Files: `CmuxNextDaemonService/DaemonService+LaunchSnapshot.swift`, `DaemonService.swift`,
`CmuxNextDaemon/Launch/LaunchSnapshot.swift`, `CmuxNextApp.swift`. Change: LaunchRead from main() decodes the snapshot at
userInitiated on `.files`; `DaemonService.start` applies it on completion by event; `applyProvisional` stays on main.
Acceptance: no `LaunchSnapshot.load` reachable on main from start; tests for both orders; `launch_snapshot_applied` kept.
Test: p50 <= 60 ms STRESS warm.

**075 Sidebar snapshot and run marker.** Files: `SidebarSnapshot/SidebarSnapshotStore.swift`, `SidebarSnapshotFile.swift`,
`Crash/AppRunMarker.swift`, `Crash/CrashRecoveryService.swift`, `AppServices.swift`, `CmuxNextApp.swift`. Change: both reads
are LaunchReads; the marker write on `.files`; recovery decisions take the read. Acceptance: no file I/O on main from both
inits; recovery unchanged for clean, one crash, two quick crashes.

**076 Home caches and device ID.** Files: `Home/HomeService+LaunchList.swift`,
`Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeStore+Cache.swift`, `CmuxNextHomeEngine/HomeSidebarLaunchCache.swift`,
`Cloud/CloudService.swift`, `CmuxNextCloud/Tunnel/CloudPaths.swift`. Change: LaunchReads; primeHomeList seeds from them or by
event (theme background until then). Acceptance: 5ae7be88773 tests pass; slow-read test shows no wait; no `Data(contentsOf:)`
on the prime path.

**077 WebUpdates OTA.** Files: `CmuxNextWebUpdates/WebUpdates.swift`, `CmuxNextUpdater/WebUpdates/WebUpdater.swift`,
`Startup/Startup+Pages.swift`. Change: pointer read and verification as a LaunchRead; channel follow and network check one
afterStartup lane post; activation observers stay. Acceptance: no network before completion (fake transport); bundled vs kept
consistency test.

**078 Crash forwarders.** Files: `Crash/CrashReporter+Launch.swift`, `CmuxNextCrashReporting/SystemCrashForwarder.swift`,
`OwnerPanicForwarder.swift`, `Startup/Startup+Platform.swift`. Change: forwarder starts and the DiagnosticReports listing
become `.bestEffort` lane posts behind the fence; handlers and LayoutPassGuard stay. Acceptance: no forwarder file calls
before completion; previous-run report still sent in the same launch.
As built (cp/p08-startup-078): feature `crashForwardersAfterStartup` (default off). `CmuxNextCrashReporting/CrashForwarders`
holds the three forwarders; `CrashForwarders.post(on:)` posts their first pass and watches as one
`.afterStartup` post `CrashReporting.forwarders` on `.lane(.files, .bestEffort)`, so it waits for completion and the fence.
Finding acpmux (`AcpmuxEnvironment.resolve`: executable checks and the signature check) moves into that post too.
`Startup/Startup+Platform.swift` does not exist on this branch; the wiring is the one `AppServices.init` line.
Off, the forwarders start at once as before. Sentry's handlers, the invariant sink and LayoutPassGuard install at launch.

**079 Q2 remainder.** Files: `Startup/Startup+{Control,Terminal,Settings,Platform,Core}.swift`. Change: priorities for
hangReports.start, settings.start, keybindingsFile.start, mouseSideButtons, DaemonPrompts, TerminalHooks, themes.start and
followChromeTheme, terminalTheme.follow, configActions.start, WorkspaceAutoNameWiring, BrowserOmnibarPreference,
startChromiumRuntime, debugSettings.start, PageDescriptor registers, the feedGitHub Task, LastAppCLIPointer.publish, the
BrowserDesignMode temp cleanup, palette settings source and shortcut editor, WindowActivation.activateApp,
WatchdogReporting.install (moves to 088). Theme and terminal look stay critical; detached cleanups become `.bestEffort` lane
posts. Acceptance: startup-lint 0 hits; each name in the doc. Test: key sweep 100 ms after first frame; theme and keybinding
edits after launch apply.

**080 Q11 main-job census.** Files: `CmuxNextLaunch/MainJobCensus.swift`, `CmuxNextApp.swift`, `Control/DebugStartup.swift`,
`startup-queue.py`. Change: DEBUG/bench only: `swift_task_enqueueMainExecutor_hook`, run-loop source/timer observers, the
MainDelivery seam; per job: caller (dladdr), priority, run time; plus main turns outside scheduler tasks. Acceptance: not in
Release; bounded preallocated ring; unit test.

**081 Q11 template.** Files: the enqueuer. Change: the unstructured Task or main async becomes a post or lazy; observer loops
start at their post. Acceptance: absent before first frame in the next run.

**082 Q12 off-main census.** Files: `CmuxNextLaunch/GlobalJobCensus.swift`, `CmuxNextWakeups/BackgroundWork.swift`,
`startup-queue.py`. Change: bench-only `swift_task_enqueueGlobal_hook`; report non-lane `.utility`/`.background`/unprioritized
callers before completion. Acceptance: DEBUG/bench only; fixture tests.

**083 Q12 template.** Files: the caller. Change: the job becomes a BackgroundWork job with a WorkPriority; QoS kept or
lowered, never raised. Acceptance: absent in the next globaljobs run.

**084 blocking-probe kinds.** Files: `scripts/measure/blocking-probe/probe.c`, `blocking-probe-report.py`,
`CmuxNextCompat/Threading/BlockingKind.swift`. Change: interpose `xpc_connection_send_message_with_reply_sync`,
`mach_msg`/`mach_msg2` with receive, `posix_spawn`/`posix_spawnp`/`fork`, `dlopen`, `getpwuid_r`, `SecItemCopyMatching`/`SecItemAdd`;
`BlockingKind.xpcReply`. Acceptance: old fields unchanged; fixture test.

**085 Q13 arm census.** Files: `CmuxNextWakeups/DemandTimer.swift`, `CmuxNextWakeups/FolderWatch.swift`,
`Control/DebugStartup.swift`, `startup-queue.py`. Change: bench-only record of each timer, watcher and observer armed before
completion with owner and first fire. Acceptance: 0 Release cost; fixture test.

**086 Q13 template.** Files: the arm site. Change: move a non-critical arm to an afterStartup post. Acceptance: absent in the
next arms run; bench-idle wakeups in the first 10 s recorded before and after.

**087 AppKit restoration off.** Files: `Windows/WindowManager.swift`, `AppDelegate.swift`, `Windows/LaunchSnapshotWindow.swift`.
Change: `isRestorable = false` at each NSWindow creation; `applicationSupportsSecureRestorableState` true; check CEF windows.
Acceptance: git grep shows each site; restore tests pass. Test: fs_usage shows no Saved Application State writes.

**088 Watchdog from main().** Files: `CmuxNextApp.swift`, `AppDelegate.swift`, `Control/AppControl.swift`,
`CmuxNextControl/Diagnostics/MainThreadWatchdog.swift`, `CmuxNextHangReports/HangReport.swift`. Change: the watchdog is made and
started as the first statement of main(); AppControl takes it by init; a stall before completion carries the scheduler's
current task name and phase. Acceptance: `MainThreadWatchdog()` only in CmuxNextApp.swift, before LaunchWarmup; tag test with a
fake scheduler; Release cost one pointer store per task. Test: a bench-only 300 ms stall before NSApp is listed (red before).

**089 Crash-streak safe launch.** Files: `Crash/LaunchRecovery.swift`, `Crash/AppRunMarker.swift`, `StartupScheduler.swift`
(reached-complete hook), `Tests/CmuxNextAppTests/LaunchSafeModeTests.swift`. Change: the marker records reached
`startup_complete` and the last task; 2 runs in a row that did not reach it skip every launch cache (pictures, snapshot,
Home/sidebar caches, frames, agent images, Debug overrides, Chromium restore order), reason `crashStreak`; one clean completion
resets. Acceptance: tests for 0/1/2 and reset; a trapping decoder is skipped next launch.

**090 RestoredPageLoader.** Files: `CmuxNextApp/RestoredPageLoader.swift` (or CmuxNextLaunch if no app types), `TabContentCache+Deferred.swift`,
`TabContentCache.swift`, `Tests/CmuxNextAppTests/RestoredPageLoaderTests.swift`. Change: section 3D loader on the deferred path.
Acceptance: order, cap, pressure fallback 1, hidden never, click promotes; crash-recovery deferral unchanged. Test: 12 visible
pages over 3 windows: <= N concurrent, 0 turns > 16 ms to +5 s.

**091 First terminal surface.** Files: `GhosttyRuntime.swift`, `TerminalSurfaceView.swift`, `TerminalTimings.swift`,
`LaunchWarmup.swift`. Change: split the first `ghostty_surface_new` cost with signposts; prefetch MTLDevice and the font
descriptor and fallback cascade on the launch thread; a runtime Metal compile becomes a fork change per cmux-ghostty.
Acceptance: numbers before/after (5 runs); the commit says why each launch-thread object is thread-safe.

**092 ActionCatalog wait.** Files: `LaunchWarmup.swift`, `CmuxNextActions/ActionCatalog.swift`. Change: signpost the first main
access; a LaunchRead the registry takes, which main builds itself when the read has not started; or the build at
userInteractive. Acceptance: `action_catalog_main_wait_ms == 0` in 20 of 20.

**093 Daemon startup timeline.** Files: `cmux-tui/crates/cmux-tui/src/main.rs` (`run_server`, line 2222),
`cmux-tui/crates/cmux-tui-core/src/mux/lifecycle.rs`, `cmux-tui/crates/cmux-tui-core/src/server/cmd_server.rs`,
`CmuxNextDaemon/Launch/DaemonLaunchTimings.swift`. Change: fixed-size write-once marks (config_loaded, owner_prepared,
socket_bound, mux_restored, owner_event_loop, websocket_ready, launch_snapshot_writer_started, lifecycle_ready,
first_identify_served) in identify/status `startup_marks`; the app maps them to `daemon.*` marks. Acceptance: Rust order test;
old daemon tolerated. Test: cargo test on Testbox; cold bench names the slowest daemon step.

**094 Daemon deferral and QoS.** Files: `cmux-tui/crates/cmux-tui/src/main.rs`, `owner_start.rs`,
`owner_start/background_checks.rs`, `owner_start/crash_forward.rs`, `owner_start/memory_guard.rs`, `headless.rs`. Change: one
"after first client" hook (first identify plus snapshot served, or 5 s) starts background checks, crash forward, memory guard,
coderouter poller, journal plugin, apps, chief brains, reapers; their threads set `pthread_set_qos_class_self_np` utility or
background. Acceptance: fake-clock test; each spawned thread names a QoS; shutdown order unchanged.

**095 No-window launch.** Files: `Startup/Startup+Platform.swift`, `Windows/WindowManager.swift`, `StartupScheduler.swift`.
Change: when restore shows no window, release firstFrame and pane refs with reason `noWindow`; no picture read. Acceptance:
test. Test: done check 15.

**096 External open.** Files: `AppDelegate.swift`/Startup file, `Onboarding/ExternalOpenController.swift`,
`Windows/WindowManager.swift`. Change: flush at `launch_picture_shown`; the target pane builds first and its picture region
drops; an auth callback reaches CloudAuth before completion. Acceptance: an open-URL event before first frame creates the tab
once with trigger `user`.

**097 ChatsFeed split.** Files: `AgentRecents/ChatsFeed+Start.swift`, `Startup/Startup+Home.swift`. Change: indicator feeds
afterFirstFrame when a sidebar or agent tab shows them; upload sweep a `.bestEffort` lane post; Chief turn states afterStartup
unless a Chief tab is visible; device ID from 076. Acceptance: no acpmux connect before first frame (fake factory); indicator
tests pass.

**098 Q1b initializers.** Files: `AppServices.swift`, `ChromiumRuntimeService.swift`, `CmuxNextBrowser/Core/BrowserSharedStores.swift`.
Change: each of the 43 whose init does I/O, starts a source or registers an observer becomes lazy or a post. Acceptance: the
diff and the doc mark each one; no IUO. Test: `dfl.services - dfl.theme` before/after.

**099 Multi-process startup trace.** Files: `CEF/CEFRuntime.swift`, `CmuxNextLaunch/StartupTrace.swift`, `scripts/cmux-next/trace.py`,
`CmuxNextDaemon/Launch/DaemonLauncher.swift`. Change: with the variable set, pass CEF `--trace-startup`, `-file`, `-duration`;
pass the variable to a cold daemon spawn; trace.py merges app, daemon (093) and CEF on one clock. Acceptance: unset adds no
switch (command-line builder test). Test: one launch with a restored Chromium tab shows 3 tracks.

**100 Picture deletion.** Files: `CmuxNextLaunch/LaunchPictureStore.swift`, `CmuxNextBrowser/CEF/CEFEngine+BrowsingData.swift`,
`BrowserProfiles/BrowsingDataClear.swift`, `BrowserProfiles/BrowserProfileService+Lifecycle.swift`,
`Tests/CmuxNextLaunchTests/LaunchPictureDeletionTests.swift`. Change: clear data, profile delete, setting off, close for good
delete matching pictures on `.files`. Acceptance: a test per path; no delete on main.

**101 Managed policy first (risk:high).** Files: `Startup/Startup+Settings.swift`, `ManagedPolicyBridge.swift`,
`FeaturePolicyEnforcer.swift`, `Tests/CmuxNextAppTests/ManagedPolicyLaunchOrderTests.swift`. Change: apply prefetched managed
preferences critically before any page engine or feature; only writes and watchers deferred. Acceptance: a blocked URL
restored in the front tab never loads, also on WebKit.

**102 Picture rules.** Files: `CmuxNextLaunch/WindowPictureMeta.swift`, `LaunchPictureView.swift`,
`Tests/CmuxNextLaunchTests/WindowPictureMetaTests.swift`. Change: backdrop excluded; no picture for full screen or another
Space; layout hash per region against the prefetched launch snapshot (074). Acceptance: a test per rule; never stretched.

**103 Profile flush hooks.** Files: `CmuxNextLaunch/ProfileFlush.swift`, `Control/DebugStartup.swift`. Change: `#if CMUX_PGO_PROFILE`:
`__llvm_profile_write_file` then `__llvm_profile_reset_counters` at completion (launch.profraw); `debug.pgo_flush` before quit
(rest.profraw). Acceptance: absent in Release and bench; 2 non-empty files per launch.

**104 startup-lint.py.** Files: `scripts/cmux-next/startup-lint.py`, `scripts/cmux-next/tests/test_startup_lint.py`. Change:
pinned ast-grep; lists Q2-regex calls in `Startup/*.swift` and `AppServices.init` whose closest enclosing call is not
`startup.post(...)` and whose name is not allowlisted. Acceptance: fixtures for inside, outside, allowlisted; not in CI or the
gate.

**105 Completion semantics.** Files: `StartupScheduler.swift`, `LaunchSettle.swift`, `Quit/QuitCoordinator.swift`,
`Tests/CmuxNextControlTests/StartupSchedulerTests.swift`. Change: pane ref at loaded-idle (terminal: first frame after the
snapshot plus 100 ms with no output; page: load finished); firstIdle ref; 5 s pane bound restarting when all visible panes
hide; quit calls `beginQuit()`. Acceptance: tests for each rule. Test: reason histogram; quit 100 ms after launch runs 0
afterStartup tasks.

**106 Settings migrations at load.** Files: `CmuxNextSettings/SettingsController.swift`, `Startup/Startup+Settings.swift`,
`Tests/CmuxNextSettingsTests/LaunchMigrationTests.swift`. Change: the 4 migrations (`migrateLegacyQuitBehavior`,
`migrateLegacyWorkspaceRowKeys`, `migrateLegacyPaneToolbarButtons`, `migrateClassicSettings`) become pure JSON transforms in
the settings LaunchRead; write-back an afterStartup lane post; 2 classic imports afterStartup. Acceptance: first snapshot has
migrated keys; same result as today on the existing fixtures.

**107 Socket startup lock (risk:high).** Files: `CmuxNextControl/ControlSocketServer.swift`, `ControlService.swift`,
`CmuxNextControl/ControlStartupLock.swift`, `Tests/CmuxNextControlTests/ControlStartupLockTests.swift`. Change: accept, peer
policy and parse off main; a bounded queue (256) replayed in order at unlock; overflow gets a typed `starting` error.
Acceptance: policy before enqueue; 300 early clients: 256 answered in order, 44 `starting`, 0 ECONNREFUSED.

**108 Interrupted launches.** Files: `CmuxNextLaunch/StartupTemperature.swift`, `DebugTimings.swift`,
`CmuxNextHangReports/HangReportCollector.swift`, `bench-startup.py`. Change: `launch.interrupted` for noActivate/hidden, occluded
or minimized window, daemon prompt, MDM confirmation, crash-recovery dialog, first launch; left out of histograms and
percentiles. Acceptance: classifier tests; filler skips them.

**109 Runner stage 2.** Files: `scripts/cmux-next/pgo/run-scenarios.py`, `scripts/cmux-next/pgo/page-fault-order.py`,
`scripts/cmux-next/pgo/check.py`, `scripts/cmux-next/tests/test_pgo_page_fault_order.py`. Change: `--stage order` on the
`-profile-use` build: map the launch function list through its link map, add its cold-launch `__TEXT` page-fault symbols
(Virtual Memory trace), header with profdata sha. Acceptance: fixture tests (no duplicates, launch symbols first); check.py
refuses a sha mismatch.

**110 ThinLTO / CMO A/B.** Files: `scripts/cmux-next/pgo/lto-ab.sh`, `startup-DESIGN.md`. Change: Release 3 ways (as today,
`-cross-module-optimization`, `-lto=llvm-thin`): size, link time, cold/warm first frame, typing p95, Debug leaf-edit build time.
Acceptance: table; Debug unchanged.

**111 Slow-launch ring.** Files: `CmuxNextLaunch/StartupTrace.swift`, `CmuxNextHangReports/HangReportBuilder.swift`,
`Tests/CmuxNextHangReportsTests/LaunchTraceAttachTests.swift`. Change: with Nightly reports on, a 32 KiB names-only ring until
completion, attached when a launch exceeds its p95 budget, else freed. Acceptance: off = nothing allocated; PrivacyLeakScanner
passes; freed by completion + 1 s.

**112 Spike: ghostty_init off main.** Files: `startup-DESIGN.md`. Change: time-boxed (4 h) read of libghostty thread safety for
`ghostty_init` and config parse; write the answer and, if yes, the follow-up task. Acceptance: answer with source citations.

**113 Q8 template.** Files: one test file with deprecated-init warnings. Change: pass an explicit origin. Acceptance: no
warning from that file.

**114 Remove the origin-less init.** Files: `CmuxNextBrowser/Engine/BrowserEngine.swift`. Change: delete the deprecated init.
Acceptance: compiles; 0 warnings of that kind.

**115 Launch histograms wired.** Files: `CmuxNextApp/HangReports/WatchdogReporting.swift`, `HangReportsController.swift`,
`LaunchSettle.swift`, `hang-reports-DESIGN.md`. Change: at `startup_complete`, one `HangReportCollector.noteLaunch` per launch
from the milestones, 007's temperature, 013's reason and 108's interrupted flag. 009 records launches but keeps the wire at
schema 2 (the server refuses unknown keys and drops the report); this task turns on `HangReportBuilder(wireSchema: .v3)` behind
p09-063's server-version flag, after p09-064 accepts a strict `launches` struct with a byte-identical fixture, and agrees the
schema number with 063. Acceptance: flag off sends schema 2 with no `launches`; flag on meets done check 12.
