# p14-energy: idle wakeup budget near zero for app and daemon, timer coalescing, CEF pump idle cost, Energy Saver

Program spec, final (fixer pass over the design and 3 reviews). Base: perf/chrome-parity at 772cdfc45ac
(= origin/feat-cmux-next). Counts come from `rg` in `/Users/lawrence/fun/wt/chrome-parity` at that commit unless a line
names another source. Fixer re-checks (2026-10-25) are marked "(checked)".

Scope in one sentence: at idle, no cmux process wakes unless an event from outside arrives; every deadline that must
stay is flexible and shares a wake with the others; hidden work costs nothing; on battery or in Low Power Mode, cmux
does what Chrome's Energy Saver does, and does not touch what the person types or moves.

Item 6 of perf-lead.md (idle wakeups app+daemon <= 1/s, main <= 0.5/s with Chromium tabs open) is the headline
target. Faults touched: F2 (out-of-process Chromium host, energy side only), F13 (idle/hidden cost).

No new CI gate, CI job, CI step, perf-gate row or CI test (Lawrence 2026-10-23). New static rules go only into the
pre-push guardrails (added lines). Full-tree checks and all budgets run in this program's own test phase on the fleet
(task 090), and every task runs its own regression test on the fleet before and after.

## 1. Chrome reference

Paths are in chromium/src at main, read 2026-10-25.

1. One timer per thread. `base/message_loop/message_pump_apple.mm`: `MessagePumpCFRunLoopBase` keeps one
   `CFRunLoopTimer` (`delayed_work_timer_`), created once as "a repeating timer with a preposterous firing time" in
   `kCFRunLoopCommonModes`. `ScheduleDelayedWork` re-arms it with `CFRunLoopTimerSetNextFireDate` and skips the call
   when `delayed_run_time` did not change (`delayed_work_scheduled_at_`). Under `kTimerSlackMac` it first calls
   `CFRunLoopTimerSetTolerance(timer, next_work_info.leeway)` ("The tolerance needs to be set before the fire date or
   it may be ignored"). Idle work runs from a `kCFRunLoopBeforeWaiting` observer.
2. Yield to input. `MessagePumpCFRunLoopBase::RunWork` runs one `DoWork`, signals its run loop source again and
   returns, so native events run between Chromium tasks. Chrome never runs an unbounded batch in one callout.
3. One wake for all delayed work of a thread. `base/task/sequence_manager/wake_up_queue.h` "aggregates wake-ups from
   multiple TaskQueueImpl into a single wake-up": an `IntrusiveHeap` ordered by `WakeUp::latest_time()`.
   `NonWakingWakeUpQueue` queues never wake the thread.
4. Delay policy and leeway. `base/task/delay_policy.h`: `kFlexibleNoSooner` (default of `PostDelayedTask`),
   `kFlexiblePreferEarly`, `kPrecise`; `MaybeOverrideDelayPolicy` makes `kPrecise` flexible at or above
   `max_precise_delay`. `base/task/task_features.{h,cc}`: `kAddTaskLeewayFeature` on by default, `kDefaultLeeway`
   8 ms (16 ms on Windows), `kDefaultMaxPreciseDelay` 36 ms ("slightly above 30Hz timer"). `kAlignWakeUps` aligns
   "wake ups ... at a 8ms boundary" of `TimeTicks()` (mach absolute time origin, `message_pump.cc`
   `AdjustDelayedRunTime`, clamped by `std::min(aligned, latest_time)`). `kTimerSlackMac` adds "slack ... on mac message
   pumps"; with it on, `MessagePumpCFRunLoopBase::AdjustDelayedRunTime` returns `earliest_time` and does not snap.
   `kAlignWakeUps` and `kTimerSlackMac` are `DISABLED_BY_DEFAULT` in code and come on only through field trials. cmux
   passes `--disable-field-trial-config` (CEFSwitches.swift), so both are off in cmux today.
5. Kernel slack on the IO thread. `base/message_loop/message_pump_kqueue.cc` arms `EVFILT_TIMER` with `NOTE_LEEWAY`
   = leeway under `kTimerSlackMac`: the kernel sees the slack.
6. Background pages. `third_party/blink/renderer/platform/scheduler/common/features.h`: 1 wake per second in a
   background page or hidden cross-origin frame; 1% CPU in a page backgrounded for 10 s; intensive throttling to 1 wake
   per minute after `kIntensiveWakeUpThrottling_GracePeriodSeconds_Default` = 5 min.
   `throttling/wake_up_budget_pool.h`: queues "which run for a limited time at regular intervals" aligned to the
   interval (`SetWakeUpInterval`, `AllowLowerAlignmentIfNoRecentWakeUp`). `WebContentsOcclusionCheckerMac` marks the
   visible tab of a covered or minimized window `OCCLUDED`, so it gets the same throttling.
7. Energy Saver as shipped. `chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc`: modes
   `kEnabled`, `kEnabledOnBattery`, `kEnabledBelowThreshold`; `kLowBatteryThresholdPercent` = 20 and the test is
   `battery_percentage_ < 20` (strictly below). Inputs: `on_battery_power_` from `base::PowerMonitor` and the battery
   level. No Low Power Mode trigger, no thermal trigger. Session off switch
   `SetTemporaryBatterySaverDisabledForSession`, cleared when the Mac is plugged in and when the pref changes
   (`OnBatterySaverModePrefChanged`). When active: `content::StartThrottlingAllFrameSinks(base::Hertz(30))` (every
   frame sink, also a page the person scrolls) and `FreezingPolicy::ToggleFreezingOnBatterySaverMode`.
   `MessagePump::OverrideAlignWakeUpsState(true, 32 ms)` and `ChildThreadImpl::SetBatterySaverMode` act only under
   `kBatterySaverModeAlignWakeUps`, which is `FEATURE_DISABLED_BY_DEFAULT` (`content/public/common/content_features.cc`,
   `child_thread_impl.cc`). So the 32 ms alignment is a Chrome experiment, not Chrome's default.
8. Freezing on battery saver. `components/performance_manager/freezing/freezing_policy.cc`: in battery saver a
   background browsing instance becomes freezable only when its background CPU proportion is at or above
   `kFreezingHighCPUProportion`; every `CannotFreezeReason` (audio, capture, WebRTC, form input) still applies. Chrome
   does not shorten the grace for every tab.
9. Power signals on Mac. `base/power_monitor/power_monitor.h` (`IsOnBatteryPower`, `AddPowerThermalObserver`,
   `AddPowerSuspendObserverAndReturnSuspendedState`). `components/power_monitor/battery_state_sampler_mac.cc` uses
   `IOPMPowerSourceSamplingEventSource`: `IOServiceAddInterestNotification(kIOGeneralInterest)` on `IOPMPowerSource`,
   no timer (only other platforms sample each minute). A desktop Mac has no `IOPMPowerSource`, so nothing registers
   and the battery modes are hidden. Percent is current/full capacity (`battery_level_provider_mac.mm`). Chrome
   handles the notification on its UI thread.
10. Process priority. `base/process/process_mac.cc` `Process::SetPriority`: `kBestEffort` =
    `TASK_BACKGROUND_APPLICATION` + `TASK_SUPPRESSION_POLICY` (lowpri CPU, `LATENCY_QOS_TIER_5` timer throttle, disk
    throttle, background sockets); `kUserVisible` = background role without suppression; `kUserBlocking` =
    `TASK_FOREGROUND_APPLICATION`. `RenderProcessHostImpl::UpdateProcessPriority` puts hidden and spare renderers at
    `kBestEffort`.
11. Task priority. `docs/threading_and_tasks.md`: "A task that has a 1-hour delay probably doesn't have to run right
    away when its delay expires"; use `TaskPriority::BEST_EFFORT`.
12. Counters. `base/process/process_metrics_apple.mm`: `task_platform_idle_wakeups` is a subset of
    `task_interrupt_wakeups`; `GetIdleWakeupsPerSecond` reports interrupt wakeups and
    `GetPackageIdleWakeupsPerSecond` the package-idle ones. `components/power_metrics/resource_coalition_mac.mm` reads
    coalition energy, `energy_billed_to_me` and `gpu_time`.
13. One hang watcher per process: `base/threading/hang_watcher.h` (10 s monitoring period in `hang_watcher.cc`).
14. Chrome measured on our fleet (xbench, `scripts/perf-bench/baseline/BENCH-apple-m4-pro-macos27.md`, 2026-10-20, M4
    Pro, macOS 27.0.1, Chrome 155): idle wakeups 63.5/s (20 tabs) and 44.8/s (1 tab); idle power in view 51.2 mW (20
    tabs) and 10.8 mW (1 tab); hidden 0.9 mW. These used the `buf[4] + buf[5]` counter (see 2.4); task 047 measures
    both browsers again with the corrected counters, and the D6 ratios use the new numbers.

Where cmux goes past Chrome on purpose (each is written in its task):
- Power inputs arrive on a utility queue; the main actor hears only an input edge (058). Chrome handles them on UI.
- The saver frame-sink throttle skips frame sinks with input in the last 1 s and cmux's own pages (029). Chrome
  throttles every sink.
- Auto mode also triggers on macOS Low Power Mode, and on thermal serious/critical while on battery (022). Chrome has
  neither.
- 32 ms wake alignment in saver (Chrome's `kBatterySaverModeAlignWakeUps` experiment) is on in cmux (040).
- Flexible deadlines of 1 s or more align to whole uptime seconds with up to 10% leeway (Apple Energy Efficiency
  Guide; Blink's 1 s wake-up budget pool), where Chrome uses a flat 8 ms (011).
- The Chromium Host (F2) may App Nap while every hosted page is hidden (128): a role Chrome's browser process can not
  get.
- Idle agent harnesses of hidden sessions freeze (117), like `FreezingPolicy` for tabs.

## 2. cmux today

### 2.1 Measured (fleet; machines were often heavily loaded)

- xbench 2026-10-20, cmux NEXT with a Chromium tab: idle wakeups 56.5/s (20 tabs) and 73.0/s (1 tab; Chrome 44.8);
  idle power in view 122 mW (Chrome 51.2); hidden 2.2 mW (Chrome 0.9). cmux on Home: 8.6 wakeups/s, 1.7 mW.
- speed-of-sound-DESIGN.md sec. 5/7 (cmux20, Release): main thread wakes 27-107/s at idle, 107/s when the app is
  hidden (more than in view); Home 3.40% CPU and 358 KB/s disk writes (the Home cache part is fixed); each hidden
  WebKit tab 11 wakeups/s; WebKit GPU 198 Mach messages/s.
- idle-wakeups.md sec. 7 (after 2026-09-30): terminals-only app 0.28-0.45/s, daemon 0.03/s, hosts 0. With one static
  Chromium tab the app is at 2.95/s: CEF pump requests of 1.1-2.2/s plus `BusyWatchdog.window` at 0.1/s. sec. 8 lists
  "app hidden" and "window covered" as UNVERIFIED.
- All measurements so far ran a configuration that does not ship (2.4).

### 2.2 Swift app (rg counts at 772cdfc45ac, checked)

- `CmuxNextWakeups` (46 files, 4202 lines): FrameScheduler, DemandTimer, Backoff, WakeupLedger, ProcessUsage,
  BackgroundWork, WorkPriority. `check-concurrency.sh` WAKEUP_RULES cover CmuxNext Sources only.
- 154 `// wakeup-allow:` escapes (checked) in 113 files; 7 periodic (ErrorJournalService 300 s, GitHubFeedSource,
  HostPressureMonitor 15 s Debug toggle, DeviceHubSocket ping, ModelRouterLease renewal, CloudAccessAsks triage,
  events.stream heartbeat).
- 188 `DemandTimer(` sites (checked). `DemandTimer.schedule(after:_:)` takes
  `@escaping @isolated(any) @Sendable () async -> Void` (DemandTimer.swift:35, checked) and runs
  `Task { clock.sleep(for: delay) }` with no tolerance, so a main-actor fire wakes a pool thread and then main.
- 71 `Task.sleep(`/`.sleep(for:|until:)` sites without `tolerance` (checked).
- CEF pump: `CEFPumpTimer.swift` owns one CFRunLoopTimer with an 8 ms leeway. Delayed requests arrive as integer ms
  (`CEFPumpSchedule.request(milliseconds:now:)`, CEFPumpSchedule.swift:117, checked); cross-thread requests hop with
  `CFRunLoopPerformBlock` (CEFMessagePump.swift:166, checked). The pre-API-7 follow-up chain
  (`SafetyNet`, `followUps`, `sliceMayHaveCutWork` at CEFPumpSchedule.swift:163) is still present. `timeSlice` is
  10 ms (CEFPumpSchedule.swift:38). The browser UI thread runs CEF's `MessagePumpExternal`
  (`settings.external_message_pump = true`, shim_process.mm:447); the Chromium Host runs `CefRunMessageLoop()`
  (browser_host_main.mm:542, checked).
- CEF's `MessagePumpExternal::ScheduleDelayedWork` sends `(delayed_run_time - recent_now).InMilliseconds()`: truncated,
  relative to a stale `recent_now`, without `next_work_info.leeway`. A 7.9 ms task arrives as 7 ms, cmux fires early,
  Chromium finds nothing due and asks again with a delay that truncates to 0, which cmux treats as "now". One Chromium
  delayed task can cost 2 or more main wakes.
- `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser (CEFTab+Freeze.swift:22, checked). No
  check proves that hidden or occluded Chromium pages report `hidden` before the freeze grace.
- FrameScheduler asks for `CAFrameRateRange(80...120)` always (FrameScheduler.swift:232, checked). 15 files have an
  `isAnimation: false` client (checked), and they include key->frame clients (TerminalFrameHold, FrameBatchQueue,
  ResizeCoordinator), probes (DebugFrameProbe, MotionFrameTrace, SwitchFrameTimer, DebugMainCPUProbe) and a per-frame
  GlassBackdropFeed.
- Energy: `LowPowerMode` (CmuxNextDesignTokens) is read by WebKitEngine render rate, BrowserHibernation neighbor radius,
  GlassModeWatch and BackdropVideoView. `PowerSourceMonitor` (the one `IOPSNotificationCreateRunLoopSource`, checked)
  is used only by KeepAwake. `KeepAwakePolicy.swift:22` holds an assertion while `phoneServing` and the phone setting
  allow it (checked). No unified energy mode, no battery threshold, no thermal policy beyond the backdrop video, no
  Chromium frame-rate or wake-alignment throttle. `CmuxNextKeepAwake` depends on Bridge, Compat, Daemon, Settings
  (Package.swift:788, checked).
- Sentry 9.28: `CrashReporter.swift:52` sets `appHangTimeoutInterval = 8.0` and keeps app-hang tracking on. On macOS
  that is the V1 ANR tracker thread, which wakes every 1.6 s and posts to main (about 0.6/s each). Dev builds do not
  start Sentry, so this was never measured.
- Other sources: 3 `NSWindow.didUpdateNotification` observers; 39 `.activeAlways` tracking areas; 10 infinite
  CAAnimations in CmuxNext (Motion+AppKit 6, NightSky 2, Wiggle, SidebarNowPlayingControls) plus 7 in app-linked
  Shared packages (checked: CmuxHomeRender Animate.swift:145,161; MessagesLab SidebarDrawing.swift:720,
  Transcript.swift:1625,1728,1770, Compose.swift:236); `symbolEffect` loops (UpdateSheetView:105/108) and an
  indeterminate ProgressView (ScreenSessionView:188); 2 TimelineView (SleepySceneView ticks at 1 s for HH:MM); 18
  CFRunLoopObservers.
- cmux's own WKWebViews: AgentPaneView.swift:192, PageWebView.swift:273 (also made when the page shows in Chromium),
  AgentActivityHostView.swift:41 (checked). Hidden ones keep WebKit's visible timers.
- `TerminalAttachment.sendHidden` (TerminalAttachment.swift:359, checked) keeps the full stream of a hidden view, so a
  terminal that prints in a hidden workspace wakes the app at the output rate.
- Phone Access binds an iroh endpoint whenever it is on and the person is signed in.
- File watchers (`FileTreeWatchStream`, `FolderWatchStream` with `kFSEventStreamCreateFlagNoDefer`,
  `ImportHistorySync`) wake on every write by other apps.
- `ConnectionHeartbeat.swift` (CmuxNextDaemon/Connection, checked; the design's `DaemonConnection+Heartbeat.swift` does
  not exist) sends identify every 15 s (`DaemonConnectionConfiguration.swift:17`, 2 misses close).

### 2.3 Outside the Swift rule's scope

- App-linked Shared packages + CmuxUpdater: 104 wakeup hits (CmuxIrxTransport 28, CmuxHomeCore 18, CmuxAuthRuntime 17,
  CmuxUpdater 11, CmuxMessagesLab 10, CMUXMobileCore 10, CmuxVNC/ScreenKit/InstallAuthCore 10), including 3 raw display
  links in MessagesLab (FrameTick.swift:25, Materials.swift:303, FlightRecorder.swift:130) and 3
  `Timer.scheduledTimer` in NativeScroll.swift.
- webviews/src: 15 product `setInterval` sites, 25 CSS `infinite` animations, self-rescheduling `setTimeout` polls
  (backgroundTaskOutput.ts:148 polls every 1.2 s, also hidden; checked) and requestAnimationFrame self-loops (35 files
  call rAF).
- cmux-tui (Rust, non-test src): 547 timed waits in 300 files (recv_timeout 132, tokio sleep 132, wait_timeout 114,
  thread::sleep 99, set_read_timeout 78, try_wait 29, tokio interval 16). Not matched today: `park_timeout` 6
  (checked; mux_ingress.rs:219 parks 1 ms in a loop until `worker_start`), `libc::poll(` 45 (about 30 with a finite
  timeout), `libc::kevent(` with a timespec 8, `epoll_wait` 2, tokio `sleep_until(` 24 (checked), `interval_at(` 1,
  acpmux `clock.sleep`, `tokio::time::timeout(` around recv in a loop. 0 `wakeup-allow`, 0 thread QoS.
- acpmux idle polls on HEAD: hub/watch.rs POLL 400 ms, server/wait.rs 1 s re-evaluate, hub/pool/reaper.rs `ps -A`,
  agent.rs LEADER_CHECK 500 ms. origin/pl-acpmux-audit (34 files, +2301/-288, checked; owner PL-acpmux) replaces the
  watch POLL with the notify crate but keeps the 1 s wait poll (wait.rs:174 on the branch) and LEADER_CHECK (agent.rs:178).
- CEFShim C++/ObjC (app and Chromium Host) and ghostty-next Zig (renderer, termio, search threads in the app) are in no
  queue.
- Unlanded from origin/pl-idle-s: ae57277e31b, b3a70bf5db6, 1e28b135bc7, 12beb941430, 069bc0c6c9d (`git cherry`,
  checked; 3cfee72f3f5 is superseded by d6fb6bf85ee).

### 2.4 Measurement today

- `scripts/cmux-next/idle-budget.py` + `idle-budget.json` (checked): kinds app (main 0, 1/s), daemon 1/s, holder 0,
  terminal-host 0, acpmux 1.0, cef-* null. Sessions light (Home's pages run in Chromium by default), light-webkit,
  light-hidden, stress, stress-static. No Chromium-tabs session, no energy, no cef-host kind, no sum rule.
- `procs.py:52` returns `buf[4] + buf[5]` (ri_pkg_idle_wkups + ri_interrupt_wkups, checked): package-idle wakes count
  twice. `ri_energy_nj` is CPU-only; work moved to the render server is not counted.
- `bench_launch.py:79-80` sets `CMUX_NEXT_NO_ACTIVATE=1` and `CMUX_NEXT_SOCKET_MODE=automation` (checked). In DEBUG that
  makes `WindowDrawPolicy.isAutomationLaunch` true (occluded windows draw, PageWebView renders when covered), and the
  app is never active. Sentry and hang reports are off without `CMUX_NEXT_DEV_SENTRY=1` and
  `CMUX_NEXT_DEV_HANG_REPORTS=1`.
- Other tools: cef-idle-probe.py, bench_power.py, xbench.py (has Chrome), bench-idle.sh / bench_idle.py (hidden and
  minimized scenarios), browser-idle-cost-live.py (N static Chromium tabs from a local server, per process class).
  `debug.wakeups` exists in Debug and bench builds. Fleet minis have no battery.

## 3. Target design

### A. The budget file is the contract

`scripts/cmux-next/idle-budget.json` v2 sets limits per session and per process kind: interrupt wakeups/s, main wakes/s,
CPU and billed energy (mW), GPU ms/s, disk bytes/s, network bytes, log lines, threads, process role, plus sum rules
("app+daemon", "tree"), ratio rules against Chrome, and an `allowed_periodic` list (period >= 15 s, named owner, why).

Kinds cover every process in the tree: app, daemon, holder, terminal-host, acpmux, agent-harness, cef-host,
cef-renderer, cef-extension, cef-gpu, cef-network, cef-storage, cef-audio, cef-utility, webkit-app-page,
webkit-browser-tab, webkit-gpu, crash-watcher, cua-helper, crashpad. An `other:*` process fails `--gate`.

Sessions: light-webkit (strict D2 numbers), light (Home pages in Chromium), light-hidden, minimized, occluded, home,
tabs-static, stress-static, energy-saver, energy-saver-auto (simulated battery 15%), signed-in, app-quit,
external-churn, agent-idle, agent-working-visible, busy-hidden, and chrome-static (Google Chrome with the same pages,
and with uBlock Origin installed, for fair ratios).

Measurement runs the shipping configuration: Release + `CMUX_BENCH_HOOKS`, shipping occlusion draw, activated app,
Sentry and hang reports on. `--gate` refuses a Debug build and refuses a run whose saver state or thermal state was
not what the session asked for.

`idle-budget.py --gate` and `energy-test-phase.py` are the test-phase checks, not CI gates.
`scripts/cmux-next/wakeup-audit.py` is the full-tree static audit; its `--queue` output is the work list.

### B. Chrome's timer model on the main thread

- `DelayPolicy` (precise / flexibleNoSooner / flexiblePreferEarly) and `WakeLeeway` in CmuxNextWakeups: 8 ms
  (kDefaultLeeway); precise only below 36 ms (kMaxPreciseDelay); flexible delays >= 1 s snap to whole uptime seconds
  with leeway min(10%, 1 s) (Apple's guide, Blink's 1 s pool); 32 ms alignment under the saver.
- `MainWakeUpQueue`: one `CFRunLoopTimer` in common modes, created once and re-armed (like message_pump_apple.mm). A
  `Mutex`-held heap of deadlines (like WakeUpQueue) that accepts inserts from any thread: an insert re-arms only when
  the new fire date is earlier than the armed one (`CFRunLoopTimerSetNextFireDate` is safe from any thread), and
  otherwise costs no wake. The alignment grid is `CLOCK_UPTIME_RAW` ns (the same origin as Chromium's `TimeTicks`),
  converted to `CFAbsoluteTime` only at arm. fireDate = min(alignUp(earliest flexible), min(latest)); precise entries
  are never aligned. A re-arm to the same date is skipped. A fire runs due entries until a 2 ms budget, then re-arms
  for now so input runs between (Chrome RunWork).
- `DemandTimer` reads the action's `@isolated(any)` `.isolation`. A main-actor action goes to MainWakeUpQueue: no pool
  thread. A new sync method `scheduleOnMain(after:tolerance:_ action: @MainActor () -> Void)` runs inline in the
  callout; the async path creates one `Task { @MainActor in }` inside the callout (the main thread is already awake,
  no extra kernel wake). Other actions use `clock.sleep(for:tolerance:)`. Async call sites do not change (a
  contingency queue exists if `.isolation` is unusable at macOS 14); sync sites move to `scheduleOnMain` in 133.
  Queue deadlines are uptime (no system sleep, like `TimeTicks`), and the injected clock times only the sleep path.
- CEF pump: the queue owns the fire date of CEF's delayed requests, so Chromium's delayed tasks and cmux deadlines
  share wakes. CEF work runs as its own `CFRunLoopPerformBlock` after the cmux entries of the same fire, never inside
  the heap loop (nested run loops in a CEF pass can not delay cmux deadlines). Immediate and cross-thread "now"
  requests keep today's PerformBlock/CEFPumpCrossThreadGate path. A new fork API reports the absolute run time, leeway
  and precise flag (no int-ms truncation, no early fire). The dead pre-API-7 follow-up chain goes away.
- Backoff waits and every remaining sleep pass tolerance.

### C. Nothing periodic

- The wakeup rule moves into pre-push guardrails for app-linked Shared packages, CmuxUpdater, cmux-tui crates,
  webviews/src (setInterval, CSS infinite, setTimeout/rAF self-loops), CEFShim C++/ObjC, TimelineView(.periodic),
  NSWindow.didUpdateNotification, `.activeAlways`, `symbolEffect` repeating.
- Escapes take a closed vocabulary: `wakeup-allow: deadline|backoff|bounded|cli-only|fixture|debug|periodic <owner>`.
  `--strict` refuses any other word and any `periodic` escape not in `allowed_periodic`. wakeup-audit sorts Rust hits
  into "loop with no blocking event" (must become an event, a deadline or MaintenanceClock) and "one-shot deadline"
  (escape allowed); reviewers check that each escape matches its code shape.
- What stays periodic becomes an event (kqueue vnode, NOTE_EXIT/pidfd, FSEvents, NWPathMonitor, notify crate),
  `NSBackgroundActivityScheduler` for maintenance (its block posts one coalesced main-actor intent; pause by invalidate
  and recreate), or in Rust one `MaintenanceClock` per process.
- `MaintenanceClock` (cmux_tui_core::wake): 5-minute wall-aligned grid, 30 s leeway that the kernel sees (macOS kqueue
  `EVFILT_TIMER` `NOTE_ABSOLUTE|NOTE_LEEWAY` + `EVFILT_USER` for register/notify; Linux `PR_SET_TIMERSLACK`), next
  instant from `SystemTime` so sleep does not shift it, overdue jobs after wake spread over one leeway window, and a
  `skippable_in_saver` flag (false for leases and renewals). Jobs that bound data loss after a crash (output_store
  FULL_FLUSH 3 s, SNAPSHOT 30 s, journal_retention CHECKPOINT 30 s, journal_maintenance 30 s) stay dirty-triggered
  one-shot `wake::deadline`s with 10% leeway and no saver stretch.
- Keepalives run only after a silence budget with no traffic, on both sides of a socket. The DaemonConnection
  heartbeat is silence-based (identify only after `interval` with no inbound frame), 15 s while a window is visible
  or a request waits, 60 s flexible while hidden for connections that carry a notification stream, none otherwise;
  visibility is injected from the App. BusyWatchdog's window end is flexible with 10 s leeway.
- One hang watcher: Sentry's ANR thread goes off; MainThreadWatchdog episodes go to Sentry.

### D. Energy Saver (Chrome's battery_saver_mode_manager on macOS signals)

- New service target `CmuxNextEnergy`: `PowerSourceMonitor` (moved from KeepAwake), `LowPowerMode` (moved from
  DesignTokens), `BatteryLevel` (IOPS notify on a utility dispatch queue; percent = current/full capacity; subscribe to
  percent only while on battery; `hasBattery` false and nothing registered on desktop Macs), `ThermalStateWatch`,
  `SuspendWatch` (willSleep, didWake, screensDidSleep, screensDidWake), and `EnergyMonitor`. Inputs hop to the main
  actor only on a policy-input edge.
- Only `CmuxNextApp` (composition root) imports `CmuxNextEnergy`. Every consumer reads `EnergyPolicySource` from
  `CmuxNextWakeups` (core) or gets a closure injected by AppServices. No new layer edge in arch-ratchet.json.
- Setting `energy.saver`: `auto` (default), `onBattery`, `always`, `off`. Pure `EnergyPolicyResolver`:
  auto = Low Power Mode, or (on battery and percent < 20), or (on battery and thermal >= serious). Thermal never turns
  the saver on while plugged in (a desktop under build load must not throttle visible pages or change benches).
  Reasons: `lowPowerMode`, `battery`, `thermal`, `setting`. Session override "Turn off Energy Saver for now" is cleared
  on the battery -> AC edge and on any change of the setting.
- `EnergyPolicy` (core value): `isSaver`, `wakeAlignment` (8/32 ms), `ambientMaxFPS` (nil/30), `webFrameRate`
  (nil/30), `pollStretch` (1/4), `suspended`, `screensAsleep`, plus the raw inputs for consumers like KeepAwake.
- Consumers: wake alignment; FrameScheduler `.ambient` clients (opt-in, 30 Hz cap in saver only); Motion loops static
  in saver only (normal mode unchanged); CEF through the fork API (frame sinks 30 Hz except sinks with input in the
  last 1 s and cmux's own pages; `OverrideAlignWakeUpsState` 32 ms; `SetBatterySaverMode` on child processes with
  `BatterySaverModeAlignWakeUps` on); hibernation neighbor radius 0 and CPU-based freezing (Chrome FreezingPolicy);
  WebKit render rate; background polls x4 or paused when nothing shows them; file watchers stretched; ghostty-next
  animation wakes >= 33 ms; daemon and acpmux through `energy.set` (the daemon also reads the power source itself, so
  it follows AC/battery after the app quits); acpmux pool parked; webviews `data-cmux-energy` (static ambient CSS);
  suspend and screen sleep park keepalives and reconnect once on wake.
- The saver never changes key->frame of native UI, motion the person starts, or frames of a page the person is
  scrolling or typing in (input exemption). It changes only ambient loops, hidden and background work, timer slack
  and frame sinks with no recent input.
- UI: sidebar footer leaf indicator with a hover card (reason, "Turn off for now"), palette actions, settings row,
  release-notes highlight, `debug.energy`, `debug.energy.simulate` (Debug and bench builds only), `cmux energy`
  CLI/MCP parity, action-surfaces export.

### E. CEF pump idle cost

- `enable-features=AlignWakeUps,BatterySaverModeAlignWakeUps` now (child processes and the Chromium Host benefit; the
  in-process UI thread gets alignment from MainWakeUpQueue). `TimerSlackMac` is added only after the absolute-time fork
  API (046) lands, because with it on `AdjustDelayedRunTime` returns `earliest_time` and the int-ms external pump would
  lose the 8 ms snapping.
- cef-idle-probe produces Q8: posting locations at >= 0.02/s in an idle tabs-static session, on every browser-process
  thread (CrBrowserMain, ThreadPool workers, Chrome_IOThread, all in the cmux app) and in renderer, GPU, network,
  storage and audio processes. Candidates to check first: Media Router discovery, component updater, GCM, Optimization
  Guide, NetworkQualityEstimator, spare renderer. Safe Browsing and CRLSet stay. Each item is turned off by an existing
  switch, or by a fork patch. All Q8 items fan out in parallel.
- All fork work (029, 037 fork part, 046, 048 fork part, 107, 124, Q8 fork patches) goes into one fork API bump, one
  Chromium build and one pin commit (task 136). Switch-only fixes land in cmux at once.
- Hidden and occluded Chromium pages must report `document.visibilityState == 'hidden'` (048); hidden renderers and the
  extension process run at best-effort priority (106/107); the built-in uBlock Origin MV2 background page is measured
  as its own kind (108).
- With the Chromium Host (F2) on, its wakes count as cef-host, judged against Chrome's browser process in chrome-static;
  the app's main thread then has 0 Chromium wakes, and the host may App Nap while every page is hidden (128).

### F. Hidden and idle cost zero

- Home MessagesLab FrameTick, FlightRecorder and Materials links go through FrameScheduler or become CA animations.
- Hidden WKWebViews (browser tabs and cmux's own pages) are hidden to WebKit: `isHidden` first, detach from the window
  only if measurement shows it is needed; a Chromium-shown PageWebView makes no WKWebView.
- Infinite CA loops (CmuxNext and Shared) stop while their window is occluded, miniaturized or hidden (LoopVisibility).
- `.activeAlways` -> `.activeInActiveApp` where hover in an inactive app is not needed.
- didUpdate observers become targeted events; SleepyScene uses an everyMinute clock.
- webviews: one `pageClock` per page, aligned, stopped when hidden; elapsed labels past 60 s step per minute; ambient
  indicators step at <= 30 Hz when visible; polls are host pushes or visible-only.
- Ghostty cursor blink becomes a render-server opacity animation (068); fallback: blink stops after 15 s with no input,
  behind a setting (069). ghostty-next animation wakes follow the saver (114).
- Hidden terminal output reaches the app at most once per second (4 s in saver), with bells, OSC notifications, title
  and exit flushed at once (119).
- Idle agent harnesses of hidden sessions freeze (SIGSTOP) after 300 s (30 s in saver), thaw before any byte is
  forwarded (117/118).
- Phone Access binds iroh only while a phone is paired or the pairing page is open (122).

### G. Rust QoS and process priority (background classes only; the QoS program owns request threads)

- Journal maintenance, fanout tailer, hook workers, reapers, kitty budget worker and MaintenanceClock run at
  utility/background thread QoS.
- Pooled and prewarmed acpmux agents until assigned, and acpmux with no attached session, run at `PRIO_DARWIN_BG`
  (Chrome kBestEffort for spare renderers), reverted in the same turn on assignment or attach. Terminal hosts and
  holders stay normal: a hidden terminal can still run a person's build.

## 4. Rules for implementers

1. Read CLAUDE.md, PATTERNS.md, REVIEW-STANDARD.md, threading-model.md and idle-wakeups.md before starting. Read
   OWNERS.md and tell the owner of every area you touch (PL-acpmux for acpmux, PL-ghostty for ghostty-next, cef-layer
   and F2 owners for CEFShim/CEF, Performance Lead for Motion and the budget file).
2. Red first: commit the failing regression test before the fix; record the same focused command's red and green on
   the fleet (`cmux-ci run --class isolated ... --ref SHA`). Never build or test on the person's Mac.
3. No CI gate, job, step or test. Guardrails refuse only added lines. The test phase is `energy-test-phase.py`.
4. An escape uses the closed vocabulary in C. An escape added to pass a check without a code-shape match is a review
   defect. Adding `tolerance:` is accepted only where the code is a true one-shot deadline; a periodic loop must
   become an event, a DemandTimer or MaintenanceClock.
5. All Wakeups tests use `ManualClock`; ManualClock records tolerance and fires exactly at the deadline.
6. The saver never touches key->frame, person-started motion, or a page with input in the last 1 s. Any task that
   changes a frame rate shows bench-typing (native and Chromium composer) and split-spring before and after.
7. Only CmuxNextApp imports CmuxNextEnergy. Run `scripts/cmux-next/arch-ratchet.py` before push; a raised edge count
   is a defect. Before editing CmuxNextBrowser/CEF files, check the architecture-refactor move list
   (architecture-layers.json) and the F2 and cef-layer programs' in-flight files.
8. Handlers use `registry.bindEffect` and return `.done`; no await, no I/O. Power and process sampling happen off main.
9. Fork patches go to the fork integration branch for task 136; cmux code gates every call on the fork API version and
   is a no-op below it.
10. Measurement: wait for a quiet host (`--max-load 4`), median of 3 windows, Release + bench hooks, shipping draw,
    activated app, Sentry on. Wakeups/s is the judged metric; CPU and mW only on a quiet host.
11. Do not hand-edit generated files (settings-schema.json, docs/mdm/*). New strings follow cmux-localization.
12. Do not change a Ghostty-default shortcut. Add no new shortcut in this program.

## 5. Done checks

All checks run from `python3 scripts/cmux-next/energy-test-phase.py` (task 090) on a macOS 27 measure host with a
120 Hz virtual display (`--vdisplay=120`), Release + `CMUX_BENCH_HOOKS`, settle 60 s, median of 3 x 60 s windows.
Wakeups are interrupt wakeups (task 047). Task 091 records the numbers.

- D1 static: `python3 -I scripts/cmux-next/wakeup-audit.py --strict` exits 0 over Packages/macOS/CmuxNext/Sources, the
  18 app-linked Packages/Shared targets + Packages/macOS/CmuxUpdater, cmux-tui/crates/*/src (non-test, with the 111
  patterns), webviews/src (with the self-loop rule) and Packages/macOS/CmuxNext/CEFShim/src. Every escape uses the
  closed vocabulary; periodic escapes are at most `allowed_periodic` (<= 6 entries, period >= 15 s, named owner).
- D2 light-webkit session: app <= 0.5/s, app main 0 (the checked-in owner budget, PL-idle with the Performance Lead),
  daemon <= 0.2/s, holder and terminal-host wakeups_max 0, acpmux <= 0.1/s, tree CPU energy <= 1.0 mW. Light session
  (Home pages in Chromium): app <= 1.0/s and main <= 0.5/s (D4's Chromium limits). Both include one focused terminal
  with a blinking cursor, so they depend on 068 or 069.
- D3 light-hidden, minimized and occluded: app <= 0.3/s, main <= 0.1/s, and each no higher than light on the same run
  (today 107/s main when hidden).
- D4 tabs-static (1 visible static Chromium tab, 10 hidden Chromium, 5 hidden WebKit): app+daemon <= 1.0/s, app main
  <= 0.5/s; each hidden Chromium renderer <= 0.1/s after the freeze grace; cef-extension <= 0.1/s; cef-network
  <= 0.2/s; each hidden WebKit content process <= 0.5/s (today 11/s); cef-gpu <= Chrome's GPU process in chrome-static
  (absolute 1.0/s is a goal, not a check; the GPU watchdog stays); with the Chromium Host on, cef-host <= Chrome's
  browser process in chrome-static.
- D5 stress-static: app+daemon <= 1.0/s, app main <= 0.5/s, daemon threads <= the threads_max recorded in
  idle-budget.json by task 091.
- D6 Chrome ratio (`xbench.py run --browsers cmux-chromium,cmux-terminal,chrome --rounds 3 --max-load 4`, one host,
  047 counters, Chrome with uBlock Origin installed): cmux-chromium idle-wakeups-20 <= 0.5 x chrome; idle-wakeups-1
  <= 0.5 x chrome; power-idle-visible (billed energy) <= chrome; power-idle-hidden <= chrome; cmux-terminal
  idle-wakeups-home <= 1.0/s (today 8.6), also checked by the home session.
- D7 energy-saver (tabs-static with energy.saver=always and a visible 120 fps animated page with no input): page rAF
  <= 31/s; tree wakeups <= 0.6 x tabs-static on the same run; debug.energy reports saver=true, reason `setting`. Run
  again as energy-saver-auto with `debug.energy.simulate {on_battery: true, percent: 15}`: reason `battery`.
- D8 the saver adds no visible latency: bench-typing key->frame p95 with energy.saver=always within +0.5 ms of off,
  for a native terminal and for the Chromium agent composer (task 135); split-spring pane motion 0 dropped frames at
  120 Hz in both modes; a Chromium page scroll in saver keeps 120 Hz with 0 dropped frames while input is active.
- D9 Rust idle tests on fleet macOS and Linux (Linux through task 131): crates/cmux-tui/tests/idle_wakeups.rs (existing
  case plus holder mode, 20 terminals, all app streams, hook plugin) and crates/acpmux/tests/daemon_idle.rs (plus a
  watched transcript and a pending `_acpmux/wait`) have a median window of <= 5 context switches per 10 s and <= 50 ms
  CPU.
- D10 Swift unit tests green on the fleet: MainWakeUpQueueTests (coalescing, 8 and 32 ms grid in uptime ns, clamp to
  latest, no re-arm when unchanged, 2 ms slice, concurrent inserts from 4 threads), DemandTimerLeewayTests,
  DemandTimerMainQueueTests, EnergyPolicyResolverTests, BatteryLevelTests, SuspendWatchTests, CEFPumpScheduleTests
  (no follow-up chain, absolute deadlines), FrameSchedulerRateClassTests.
- D11 `pmset -g assertions` recorded by idle-budget lists no assertion held by a cmux pid in any idle session, unless
  the session turned on `session.keepAwake` or the phone keep-awake setting; signed-in runs with both off.
- D12 debug.wakeups ledger in tabs-static: no owner above 0.1/s except `CEFMessagePump` reason `delayed` and the
  `allowed_periodic` owners; `BusyWatchdog.window` 0.0/s; CEFPumpStats `earlyPasses` 0 (after 046).
- D13 signed-in app+daemon <= 1.0/s; app-quit tree (daemon, holders, hosts, acpmux) <= 0.1/s; external-churn (10
  writes/s in a watched project, Chrome History appends, app hidden) app <= 1.0/s; with `pmset displaysleepnow`,
  signed-in app <= light-hidden.
- D14 agent sessions: agent-idle app+daemon+acpmux <= 1.0/s and the hidden pane's agent-harness 0 wakeups after its
  freeze; agent-working-visible app+cef-renderer+cef-gpu <= 35/s; busy-hidden app <= 2/s.
- D15 after the settle, in every idle session: 0 disk bytes written per kind, 0 unified-log lines per process, and no
  network bytes outside `allowed_periodic` owners.
- D16 process roles: the app is napped in light-hidden, minimized and occluded; hidden Chromium renderers and the
  extension process are best-effort; terminal-host and daemon are never backgrounded while a terminal is visible; idle
  pooled acpmux agents are `PRIO_DARWIN_BG`.
- D17 visibility: in light-hidden, minimized and occluded every Chromium tab reports `hidden`; a hidden unfrozen page
  runs no rAF and <= 1 timer wake/s.

## 6. Machine queues

Each hit is one work item. The queue command is the acceptance: after the task, its hits in the task's scope are 0 or
carry a closed-vocabulary escape whose code shape matches.

- Q1 Swift sleeps without tolerance (71 hits, checked):
  `cd Packages/macOS/CmuxNext/Sources && rg -n 'Task\.sleep\(|\.sleep\((for|until):' . | grep -v tolerance`. Each becomes
  a DemandTimer, a Backoff, a `clock.sleep(for:tolerance: WakeLeeway...)` or an event. Q10 (hand-rolled one-shot
  deadlines under `wakeup-allow:` that should be DemandTimer, about 60 hits:
  `rg -n 'wakeup-allow:' Packages/macOS/CmuxNext/Sources | rg -i 'deadline|one-shot'`) folds into the same tasks.
  Tasks 019a-d.
- Q2 app-linked Shared packages (104 hits):
  `rg -n --glob '!**/Tests/**' --glob '!**/TestSupport/**' --glob '!**/Mock/**' --glob '*.swift' 'Timer\.scheduledTimer|Timer\.publish|makeTimerSource\(|CFRunLoopTimerCreate|CADisplayLink\(|CVDisplayLink|displayLink\(target:|Task\.sleep\(|\.sleep\((for|until):|\bwhile\s+true\b|\brepeat\s*\{|while\s+!\s*(Task\.)?isCancelled' Packages/Shared/{CmuxGhosttyKit,CMUXAuthCore,CmuxInstallAuthCore,CmuxAuthRuntime,CMUXMobileCore,CmuxTheme,CmuxAppAttest,CmuxAgentBrands,CmuxAgentCursor,CmuxHomeCore,CmuxFeedPushCore,CmuxHomeRender,CmuxAgentQuestion,CmuxMessagesLab,CmuxIrxTransport,CmuxVNC,CmuxScreenKit,CmuxSentryTelemetry} Packages/macOS/CmuxUpdater | grep -v wakeup-allow`.
  After 005: `wakeup-audit.py --lang swift-shared --queue`. Tasks 051, 052, 067a-f.
- Q3 webviews timers: `cd webviews && rg -n -g '*.ts' -g '*.tsx' -g '!**/*.test.*' -g '!**/*.gallery.*' -g '!**/test/**' -g '!**/dev-server/**' -g '!src/gallery/**' 'setInterval\(' src`
  (15) and `rg -n -g '*.css' -g '*.ts' -g '*.tsx' -g '!**/*.test.*' -g '!**/gallery/**' '\binfinite\b' src` (25).
  Q3b (after 110): `wakeup-audit.py --lang web --queue` lists `setTimeout`/`requestAnimationFrame` self-loops. Tasks
  061, 062a-b, 063, 110, 126.
- Q4 Rust timed waits: `python3 -I scripts/cmux-next/wakeup-audit.py --lang rust --queue` (after 005 and 111: the 547
  base hits + about 75 from park_timeout, finite poll/kevent/epoll_wait, sleep_until, interval_at, clock.sleep,
  wait_timeout_while, timeout-in-loop). Each line carries `loop` or `oneshot`; `loop` lines are fixed first. Runtime
  priority comes from D9 and Q9 owners. Groups: cmux-tui machine/remote/owner/link, cli/app/bin/config, other;
  core terminal_host_runtime, journal+mux, server+surface, rest; chatmux-relay; cmux-remote*; acpmux;
  host/process/pty/holder/platform/util; the rest. Tasks 034, 070-075, 077a-m, 112.
- Q5 tracking areas: `rg -n '\.activeAlways' Packages/macOS/CmuxNext/Sources` (39: Sidebar 10, Design 9, Tabs 6, Browser
  5, other 9). Tasks 055a-c.
- Q6 periodic escapes: `rg -n 'wakeup-allow:.*(harvest|periodic|interval|keepalive|cadence|renewal|polls)' Packages/macOS/CmuxNext/Sources`
  (13 lines, 7 sites). Tasks 032, 064, 066a-c; what stays goes into `allowed_periodic`.
- Q7 per-pass and loop sources: `rg -n 'NSWindow\.didUpdateNotification|TimelineView\(\.(periodic|animation)' Packages/macOS/CmuxNext/Sources`
  (4), `rg -n 'repeatCount\s*=\s*\.infinity' Packages/macOS/CmuxNext/Sources Packages/Shared` (10 + 7, checked), and
  `rg -n 'symbolEffect\(|ProgressView\(\)' Packages/macOS/CmuxNext/Sources`. Tasks 054, 056, 057, 115.
- Q8 Chromium idle tasks (runtime): `scripts/measure/split-spring.sh --suite=cef-idle --vdisplay=120` after 041/109.
  Each `CEF-IDLE-POSTED` line with per_s >= 0.02 on any browser-process thread or in a renderer, GPU, network, storage
  or audio process is one item. Fix with an existing switch first, else a fork patch into 136. Tasks 042-044
  (parallel slots).
- Q9 budget overs (runtime): `scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions all --gate`.
  Each `IDLE-BUDGET-OVER` line with its owner (ledger owner, main run-loop callout, thread name, top frame of
  `/usr/bin/sample`, role, disk, network or log owner) is one item, all parallel after one run. Task 095 seeds it for
  hidden main wakes, 096 for visible power (`POWER-OVER`). Tasks 059, 065, 092-094, 106, 108, 116.
- Q11 display links outside FrameScheduler:
  `rg -n 'displayLink\(target:|CADisplayLink\(|CVDisplayLink' Packages/Shared Packages/macOS --glob '!**/CmuxNextWakeups/**'`
  (3, all MessagesLab). Tasks 050, 051, 053.
- Q12 network idle (runtime, after 105): each process with network bytes outside `allowed_periodic` in the signed-in
  session. Task 121.
- Q13 sync-capable DemandTimer actions: `wakeup-audit.py --queue demand-sync` (DemandTimer schedule closures on the main
  actor whose body has no `await`). Task 133.
- Q14 contingency (only if 014 reports `.isolation` unusable at macOS 14): `rg -n 'DemandTimer\(' Packages/macOS/CmuxNext/Sources`
  grouped App 57, AgentPane 13, Design 12, rest 106. Task 132.
- fork queue: tasks whose files start with `fork:`; collected by 136.
- ghostty-next queue: tasks whose files start with `ghostty-next:`; owner PL-ghostty.

## 7. Risks and decisions

- Decision (made by the program, flagged): `energy.saver` default is `auto` (Chrome's default family). Auto also
  triggers on macOS Low Power Mode and on thermal serious while on battery. Chrome has neither trigger. The saver lowers
  web page frame sinks to 30 Hz, the one place it touches visible content, against CLAUDE.md's "throttling only for
  work the person cannot see". Mitigation: sinks with input in the last 1 s and cmux's own pages are exempt (a cmux
  divergence from Chrome), D8 checks native and Chromium typing and Chromium scroll, and "Turn off for now" is one
  click. A reviewer may want default `off`; switching is a one-line default change.
- Decision (flagged): the cursor blink fallback (069) stops the blink after 15 s with no input (GTK's
  `gtk-cursor-blink-timeout`), which is visible. It ships behind `terminal.cursorBlinkTimeout` (default 15 s, 0 =
  never stop) and only if 068 does not land in time.
- `@isolated(any)` `.isolation` extraction (SE-0431) is expected to work at the macOS 14 target. If not, Q14 (task 132)
  becomes 4 parallel slots; 065 and the queue benefits wait for it.
- With CEF in process, Chromium's own tasks (1.1-2.2/s) wake the cmux main thread and its ThreadPool threads. D4 may
  hold only after Q8 and 046, or with the F2 host on by default (another program). If not, D4 is judged with the host
  flag on and the gap is reported.
- Fork cadence: one fork API bump with every fork patch (136) needs one Chromium build (hours) and one pin; F2 and
  cef-layer also pin the fork. The app gates every call on the fork API, so a late pin delays only fork-dependent
  benefits (saver frame cap, absolute pump times, visibility, renderer pid, priority).
- Leeway changes timing by up to 8 ms (32 ms in saver) for flexible deadlines, and up to 1 s for deadlines of 10 s or
  more. Tests that run on a real clock may flake; Wakeups tests use ManualClock.
- MainWakeUpQueue carries every main deadline and the CEF fire date. A bug stalls all of them. Mitigation: pure heap,
  exhaustive tests, ledger counters, debug.energy view, and CEF work outside the heap loop.
- Measurement noise: fleet load averages of 270-320 were seen. energy-test-phase waits for load < 4 and uses medians.
  D6 needs Google Chrome (and uBO in it) on the measure host. Fleet minis have no battery: auto mode is checked with
  `debug.energy.simulate` (123) and unit tests only.
- 047 changes the wakeup counter; earlier numbers (including Chrome's) are not comparable. 091 re-baselines; nobody
  works against D2-D6 numbers before 047 lands.
- Ownership and conflicts: acpmux (PL-acpmux; pl-acpmux-audit is 34 files, +2301/-288, so 070 asks the owner to land it
  and only adds the wait poll removal), ghostty-next (PL-ghostty; 068, 069, 114), request-thread QoS (the QoS program;
  076 and 038 are background only), CEFShim/CEF (F2, cef-layer, the CmuxNextBrowser split), Motion (Performance Lead).
- 121 touches `workers/device-hub/` and `workers/presence/` (BSL directories): no outside contributor code.
- 102 needs a staging test account from the fleet secrets; the token never goes into code or logs.
- The pre-push guardrail (006) is skipped by an agent that bypasses hooks; `wakeup-audit --strict` in the test phase is
  the backstop.
- Hiding WKWebViews (059, 116) may change WebKit behavior (media in hidden tabs, find state, inspector). Tabs with
  audio or capture stay visible to WebKit (Memory Saver rules). Show must not miss the switch frame; the instant-switch
  bench runs before and after.
- Freezing harnesses (117) must never stop a harness with a running tool, terminal, pending permission or turn.

## 8. Task table

Size: S <= 150 changed lines, M <= 400, L > 400 (split before start if possible). Rule 2 (red first, fleet runs)
applies to every task that changes behavior and is not repeated per row. "fork:" and "ghostty-next:" files live in those
repositories.

### Summary

| ID | Title | Size | Depends on | Queue |
| --- | --- | --- | --- | --- |
| 001 | Land the remainder of origin/pl-idle-s | S | - | none |
| 002 | idle-budget.json v2 schema, kinds, sums, allowed_periodic | S | - | none |
| 003 | idle-budget sessions tabs-static, minimized, energy-saver; energy, assertions, saver/thermal guard | M | 002, 130 | none |
| 004 | chrome-static reference session (with uBO) | M | 003 | none |
| 005 | wakeup-audit.py full-tree audit, queues, escape vocabulary, loop/oneshot | M | - | none |
| 006 | Pre-push guardrail family wakeup-ext | M | 005, 113 | none |
| 007 | debug.energy | S | 013, 023, 021, 022, 024 | none |
| 008 | Idle wakeup histogram per launch | S | 007 | none |
| 009 | Daemon idle test matrix | M | - | none |
| 010 | acpmux idle tests: watched transcript, pending wait | S | - | none |
| 011 | DelayPolicy and WakeLeeway | S | - | none |
| 012 | DemandTimer delay policy and tolerance | S | 011 | none |
| 013 | MainWakeUpQueue | M | 011 | none |
| 014 | DemandTimer main-actor actions on MainWakeUpQueue; sync overload | M | 012, 013, 024 | none |
| 015 | Backoff leeway | S | 011 | none |
| 016 | CEF delayed fire date on MainWakeUpQueue; CEF work outside the heap loop | M | 013, 024 | none |
| 017 | Delete the pre-API-7 follow-up chain | S | 016 | none |
| 018 | CEF pump ledger reasons | S | 016 | none |
| 019a | Q1 sleeps: CmuxNextApp | M | 012, 015 | Q1 |
| 019b | Q1 sleeps: Daemon, DaemonService, Control, Compat | S | 012, 015 | Q1 |
| 019c | Q1 sleeps: AgentPane, HomeEngine, Feed, Devices | S | 012, 015 | Q1 |
| 019d | Q1 sleeps: remaining modules | M | 019a, 019b, 019c | Q1 |
| 020 | Rust wake module: deadlines, EnergyMode, MaintenanceClock | M | - | none |
| 021 | CmuxNextEnergy target: power, LPM, thermal | M | - | none |
| 022 | EnergyPolicyResolver and energy.saver setting | M | 021 | none |
| 023 | EnergyPolicy value in CmuxNextWakeups | S | 013 | none |
| 024 | Composition root wiring | S | 022, 023 | none |
| 025 | Energy Saver session actions | S | 024 | none |
| 026 | Energy Saver indicator and hover card | M | 025 | none |
| 027 | Motion loops static under saver | S | 024 | none |
| 028 | FrameScheduler opt-in ambient class | M | 023, 024 | none |
| 029 | Fork API cmux_cef_set_energy_saver with input exemption | M | - | fork |
| 030 | Shim and Swift binding for the saver fork API | S | 029, 024, 136 | none |
| 031 | Hibernation neighbor radius and WebKit render rate follow EnergyPolicy | S | 024 | none |
| 032 | Background polls stretch in saver, pause when nothing shows | M | 024 | Q6 |
| 033 | Daemon energy op, CLI and MCP parity | M | 020, 024 | none |
| 034 | acpmux maintenance on MaintenanceClock | S | 020, 070 | Q4 |
| 035 | KeepAwake reads the shared power source | S | 024 | none |
| 036 | Docs: idle-wakeups sec. 9, user doc, threading-model | S | 022, 013 | none |
| 037 | Per-fire 2 ms budget; fork pump slice | S | 013 | fork |
| 038 | Background process priority for idle acpmux helpers | S | 070 | none |
| 039 | Saver freezes CPU-heavy hidden tabs (FreezingPolicy) | S | 024 | none |
| 040 | Chromium AlignWakeUps and BatterySaverModeAlignWakeUps on | S | - | none |
| 041 | cef-idle-probe emits CEF-IDLE-POSTED | S | - | none |
| 042 | Q8 slot A | M | 109, 040 | Q8 |
| 043 | Q8 slot B | M | 109, 040 | Q8 |
| 044 | Q8 slot C and closing record | M | 109, 040 | Q8 |
| 045 | Chromium Host: same switches and saver wire message | M | 029, 040, 004 | none |
| 046 | Fork API: absolute delayed run time, leeway, precise | M | 016 | fork |
| 047 | Counters as Chrome defines them; billed energy; coalition | M | 002 | none |
| 048 | Chromium page visibility check and fix | M | 003 | Q9 |
| 050 | Home FrameTick through FrameScheduler | S | - | Q11 |
| 051 | FlightRecorder only while enabled | S | - | Q2 |
| 052 | NativeScroll one-shot timers | S | - | Q2 |
| 053 | Materials fade as a CA animation | S | - | Q11 |
| 054 | Replace didUpdateNotification observers | M | - | Q7 |
| 055a | Q5 tracking areas: Sidebar | S | 006 | Q5 |
| 055b | Q5 tracking areas: Design, Tabs | S | 006 | Q5 |
| 055c | Q5 tracking areas: rest | S | 006 | Q5 |
| 056 | LoopVisibility for infinite CA loops | M | 027 | Q7 |
| 057 | Sleepy clock per minute | S | - | Q7 |
| 058 | Power inputs off main; edge-only main hop; no-battery Macs | S | 021 | none |
| 059 | Hidden WebKit browser tabs hidden to WebKit | M | 003 | Q9 |
| 060 | webviews pageClock | S | - | Q3 |
| 061 | Q3 clocks onto useNow | M | 060 | Q3 |
| 062a | Q3 polls part 1 | S | 060 | Q3 |
| 062b | Q3 polls part 2 | S | 060 | Q3 |
| 063 | Q3 CSS infinite static under saver and motion off | S | 134 | Q3 |
| 064 | DaemonConnection heartbeat silence-based, visibility-aware | M | 012 | Q6 |
| 065 | BusyWatchdog flexible window end | S | 014 | Q9 |
| 066a | ErrorJournal harvest on NSBackgroundActivityScheduler | S | - | Q6 |
| 066b | GitHub feed on NSBackgroundActivityScheduler | S | 032 | Q6 |
| 066c | DeviceHub ping, lease renewal, triage | S | 012 | Q6 |
| 067a | Q2 CmuxIrxTransport | M | 005 | Q2 |
| 067b | Q2 CmuxHomeCore | S | 005 | Q2 |
| 067c | Q2 CmuxAuthRuntime | S | 005 | Q2 |
| 067d | Q2 CmuxUpdater | S | 005 | Q2 |
| 067e | Q2 CMUXMobileCore | S | 005 | Q2 |
| 067f | Q2 VNC, ScreenKit, InstallAuthCore, MessagesLab rest | S | 005, 050, 051, 052, 053 | Q2 |
| 068 | Ghostty cursor blink on the render server | L | - | ghostty-next |
| 069 | Ghostty blink timeout fallback behind a setting | S | - | ghostty-next |
| 070 | acpmux: owner lands pl-acpmux-audit; remove the 1 s wait poll | S | 010 | Q4 |
| 071 | acpmux pool RSS cap without ps | S | 020, 070 | Q4 |
| 072 | acpmux leader exit by NOTE_EXIT / pidfd | S | 070 | Q4 |
| 074 | acpmux peer ping and hand keepalive after silence | S | 070 | Q4 |
| 075 | remote_cli acpmux_peer renewal from lease expiry | S | - | Q4 |
| 076 | Rust background thread QoS | S | 020 | none |
| 077a | Q4 machine_provider_client.rs | S | 005, 020, 111 | Q4 |
| 077b | Q4 remote_runtime, local_owner, machine_agent, link, transports | M | 005, 020, 111 | Q4 |
| 077c | Q4 cmux-tui CLI, app, bin, config, plugin_manager | M | 005, 111 | Q4 |
| 077d | Q4 cmux-tui other src | S | 077a, 077b, 077c | Q4 |
| 077e | Q4 core terminal_host_runtime | M | 005, 020, 111 | Q4 |
| 077f | Q4 core journal_* and mux | M | 005, 020, 009, 111 | Q4 |
| 077g | Q4 core server and surface | M | 005, 020, 111 | Q4 |
| 077h | Q4 core rest | S | 077e, 077f, 077g | Q4 |
| 077i | Q4 chatmux-relay | S | 005, 020, 111 | Q4 |
| 077j | Q4 cmux-remote* | M | 005, 020, 111 | Q4 |
| 077k | Q4 acpmux remainder | M | 034, 071, 072, 074 | Q4 |
| 077l | Q4 host, process, pty, holder, platform, util | M | 005, 020, 111 | Q4 |
| 077m | Q4 the rest | M | 077d, 077h, 077i, 077j, 077k, 077l | Q4 |
| 090 | energy-test-phase.py orchestrator | M | 003, 004, 005, 100-106, 135 | none |
| 091 | Record the measured numbers | S | 090 | none |
| 092 | Q9 slot A | M | 090 run | Q9 |
| 093 | Q9 slot B | M | 090 run | Q9 |
| 094 | Q9 slot C (spawn more while overs remain) | M | 090 run | Q9 |
| 095 | Root cause of hidden main wakes (107/s) | S | 001, 100 | Q9 |
| 096 | Attribute visible idle power (122 vs 51.2 mW) | S | 003, 004, 047 | Q9 |
| 100 | Shipping measurement mode | M | 003 | none |
| 101 | One hang watcher: Sentry ANR off, watchdog episodes to Sentry | M | 100 | none |
| 102 | Sessions signed-in, home, occluded, app-quit, external-churn | M | 003, 100 | none |
| 103 | Agent sessions and agent-harness kind | M | 102 | none |
| 104 | Every process has a kind; other fails --gate | S | 002 | none |
| 105 | Disk, network, log, WindowServer metrics | M | 002 | none |
| 106 | Process role and App Nap audit | S | 104 | Q9 |
| 107 | Hidden Chromium renderers best-effort (fork, if needed) | M | 106 | fork |
| 108 | Built-in uBlock Origin idle cost | M | 104, 041 | Q9 |
| 109 | Q8 on every Chromium thread and process | S | 041 | Q8 |
| 110 | webviews self-loop rule and fixes | S | 005, 060 | Q3 |
| 111 | Rust audit patterns | S | 005 | Q4 |
| 112 | Rust millisecond spin loops | M | 111 | Q4 |
| 113 | wakeup-audit for CEFShim C++/ObjC and ghostty-next Zig | S | 005 | none |
| 114 | ghostty-next animation wakes follow the saver | M | 024 | ghostty-next |
| 115 | Infinite loops in Shared packages and SwiftUI loop effects | M | 056, 005 | Q7 |
| 116 | cmux's own WKWebViews hidden to WebKit; lazy fallback WKWebView | M | 103, 104 | Q9 |
| 117 | acpmux freezes idle harnesses of hidden sessions | M | 070, 103 | none |
| 118 | Agent pane sends visibility edges | S | 117 | none |
| 119 | Hidden terminal output batched to 1/s | M | 103 | none |
| 120 | Sleep, wake and screen sleep | M | 021, 023 | none |
| 121 | Q12 network idle: silent sockets | M | 102, 105 | Q12 |
| 122 | Phone Access iroh endpoint only when usable | S | 102 | none |
| 123 | debug.energy.simulate | S | 007, 022 | none |
| 124 | Per-tab renderer attribution | M | 007 | fork |
| 124a | Per-tab renderer attribution with the Chromium Host on | M | 124, p01-process-022 | none |
| 125 | High-energy tab badge with Discard | M | 124 | none |
| 126 | Visible ambient indicators step at <= 30 Hz | M | 060, 103 | Q3 |
| 127 | Watchers driven by other apps pause or stretch | M | 102, 024 | none |
| 128 | Chromium Host App Nap while all pages hidden | S | 045, 106 | none |
| 129 | Energy Saver completeness: highlight, settings row, surfaces | S | 022, 025, 026 | none |
| 130 | One shared tab-page server and Chromium process classifier | S | 002 | none |
| 131 | Linux runner for the Rust idle tests | S | 090 | none |
| 132 | Contingency: explicit onMain DemandTimer migration | M | 014 (only if it reports failure) | Q14 |
| 133 | Q13 sync DemandTimer actions use the sync overload | M | 014 | Q13 |
| 134 | WebTheme data-cmux-energy attribute | S | 024 | none |
| 135 | D8 benches: Chromium composer typing and page scroll | S | 003 | none |
| 136 | Fork bundle: one API bump, one build, one pin | M | 029, 037, 046, 048, 107, 124, Q8 fork items | fork |
| 137 | Daemon reads the power source itself | S | 033 | none |
| 138 | GlassModeWatch and BackdropVideoView follow EnergyPolicy | S | 024, p11-codebase-039 | none |

### Phase P0: measurement and budget

#### p14-energy-001 Land the remainder of origin/pl-idle-s
- Files: `scripts/measure/perf-idle-power.sh`, `scripts/perf-bench/xbench.py`, `scripts/perf-bench/benchhelper.swift`,
  `scripts/perf-bench/README.md`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/WindowHandlers.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/WindowActionCatalog.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextActions/Localizable.xcstrings`, `plans/cmux-next/idle-wakeups.md`.
- Change: cherry-pick ae57277e31b, b3a70bf5db6, 1e28b135bc7, 12beb941430, 069bc0c6c9d (not 3cfee72f3f5, superseded by
  d6fb6bf85ee). Resolve against HEAD; keep HEAD's idle-budget.py.
- Acceptance: `git cherry HEAD origin/pl-idle-s | grep '^+'` lists only 3cfee72f3f5. Show/Hide All Windows accepts
  hidden=true|false. xbench records power-idle-hidden only when the app is hidden.
- Test phase: `cmux-ci build cmux --ref SHA`; `python3 scripts/perf-bench/xbench.py --help`; one xbench
  power-idle-hidden row on a fleet mini.
- Size S.

#### p14-energy-002 idle-budget.json v2
- Files: `scripts/cmux-next/idle-budget.json`, `scripts/cmux-next/idle-budget.py`,
  `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: schema v2 `sessions.<name>.kinds.<kind>.{wakeups_per_s, wakeups_max, main_wakes_per_s, energy_mw,
  threads_max, disk_bytes_per_s, log_lines, role}`, `sessions.<name>.sums.{"app+daemon", "tree"}`,
  `ratio_to_chrome` rows, `allowed_periodic: [{owner, period_s, why}]`, `assertions_allowed_when` (session.keepAwake
  or phone keep-awake on). `kind()` classifies `Chromium Host.app/Contents/MacOS/` as cef-host. `over_budget()` judges
  sums, per-session overrides and ratios; `cron_rows()` emits the sum rows. light-webkit keeps the owner's 0 limits
  (app main, holder, terminal-host) and adds app 0.5, daemon 0.2, acpmux 0.1; light gets app 1.0, main 0.5; other
  limits are D3-D7. `_doc` records the change with the Performance Lead.
- Acceptance: unit tests: kind() of a Chromium Host path == 'cef-host'; app 0.7 + daemon 0.4 gives
  IDLE-BUDGET-OVER for app+daemon; a v1 file still loads; the sessions and numbers of D2-D7 exist; an assertion while
  keep-awake is off is an over.
- Test phase: `python3 scripts/cmux-next/tests/test_idle_budget.py` (no build).
- Size S.

#### p14-energy-003 idle-budget sessions, energy, assertions, saver/thermal guard
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/procs.py`, `scripts/cmux-next/split-spring-terminal.py`,
  `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: sessions tabs-static (1 visible static Chromium tab, 10 hidden Chromium, 5 hidden WebKit, from the shared
  page server of 130, settle past `browser.freezeHiddenTabs`), minimized (window.minimize action), energy-saver
  (energy.saver=always plus a visible `/anim.html` 120 fps rAF counter read over DevTools at the window ends). Record
  `ri_energy_nj` per process and sum per kind and tree. Record `pmset -g assertions` lines of pids in the set. Record
  debug.energy saver state and `ProcessInfo.thermalState`; refuse (`--gate`) a run whose saver state differs from
  what the session asked, and mark rows taken at thermal >= serious. Add suite args to split-spring.
- Acceptance: unit tests cover the session table, energy aggregation (fixture rusage -> mW), the saver mismatch
  refusal. The report JSON has `assertions`, `energy_mw` per kind, `saver`, `thermal`. Unknown session refused.
- Test phase: unit tests; `scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions tabs-static,energy-saver`
  on a measure host (report in the commit).
- Size M. Depends: 002, 130.

#### p14-energy-004 chrome-static reference session
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/xbench.py`, `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: reuse xbench's Chrome launcher (APFS profile clone, `--user-data-dir`, same switches, CDP `/json/new`) to open
  the tabs-static page set in `/Applications/Google Chrome.app` with uBlock Origin installed (the same version cmux
  bundles), measure the same window, classify browser, renderer, extension, gpu, utility. `over_budget()` evaluates the
  ratio rows (tree wakeups, energy, cef-host vs browser, cef-gpu vs gpu).
- Acceptance: with `chrome-static` the report has a `chrome` block and `ratio_to_chrome` per row; a fixture of 40/s vs
  63.5/s at limit 0.5 is flagged; a run without uBO in Chrome is marked `unequal`.
- Test phase: unit tests; one fleet run of `--sessions tabs-static,chrome-static`.
- Size M. Depends: 003.

#### p14-energy-005 wakeup-audit.py
- Files: `scripts/cmux-next/wakeup-audit.py`, `scripts/cmux-next/tests/test_wakeup_audit.py`.
- Change: one script with check-concurrency.sh WAKEUP_RULES regexes over: Swift CmuxNext Sources; Swift app-linked Shared
  packages + CmuxUpdater (list read from Package.swift `.package(path:`); Rust cmux-tui/crates/*/src (skip `#[cfg(test)]
  mod` bodies, tests/, benches/, examples/); webviews/src (setInterval, CSS `infinite`); plus TimelineView(.periodic /
  .animation), NSWindow.didUpdateNotification, `.activeAlways`. Escapes: `wakeup-allow: <word> <reason>` with the
  closed vocabulary deadline|backoff|bounded|cli-only|fixture|debug|periodic; any other word is a hit under
  `--strict`. Rust hits get `loop` (inside `loop`/`while` with no blocking event on the same path) or `oneshot`.
  Modes `--json`, `--queue` (`group<TAB>file:line<TAB>rule<TAB>loop|oneshot`), `--queue demand-sync` (Q13), `--lang`,
  `--strict` (exit 1 on unescaped hits, bad escape words, or periodic escapes beyond `allowed_periodic`).
- Acceptance: fixture tests: a Rust `recv_timeout` in `#[cfg(test)] mod` is ignored; in src reported; escaped not; an
  escape with word `because` fails `--strict`; a periodic escape not listed fails. On this checkout: Rust hits 547 +/-
  5, shared 104 +/- 3.
- Test phase: `python3 scripts/cmux-next/tests/test_wakeup_audit.py`; `python3 -I scripts/cmux-next/wakeup-audit.py --queue | wc -l`.
- Size M.

#### p14-energy-006 Pre-push guardrail family wakeup-ext
- Files: `scripts/cmux-next/guardrails.py`, `scripts/cmux-next/tests/test_guardrails.py`.
- Change: family `wakeup-ext` with scopes outside SOURCES (app-linked Shared, CmuxUpdater, cmux-tui/crates/*/src,
  webviews/src, CEFShim/src from 113) importing wakeup-audit's rules and escape vocabulary. Refuses added lines only.
  Not added to any CI job.
- Acceptance: `guardrails.py --list` shows wakeup-ext with why/do/escape. Tests: added `setInterval(` in webviews/src
  refused; added `thread::sleep(` in a crate src refused; same line with `// wakeup-allow: deadline ...` passes; an
  added `dispatch_after` in CEFShim refused; unchanged base hits not refused.
- Test phase: `python3 scripts/cmux-next/tests/test_guardrails.py`; `python3 scripts/cmux-next/prepush-gate.py` on a
  scratch commit.
- Size M. Depends: 005, 113.

#### p14-energy-007 debug.energy
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/EnergyReport.swift`
  (the report; the app-size guardrail refuses new App files),
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugWakeups.swift` (the `EnergyReport(services:)` adapter),
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/AppControl.swift`.
- Change: returns `policy` (isSaver, reason, wakeAlignmentMs, ambientMaxFPS, webFrameRate, pollStretch), `inputs`
  (featureEnabled, lowPowerMode, onBattery, hasBattery, batteryPercent, thermal, setting, sessionOverride,
  suspended, screensAsleep, reason), `wake_queue` (entries, fires, firesPerSecond, coalescedFires, alignmentMs;
  the queue has no slices since the 013 fixer), `ledger_top` (10 owners), `processes` (energyNj, interruptWakeups,
  packageIdleWakeups from the one ProcessUsage sample), `cef` (energySaver applied|unsupported, earlyPasses).
  Top-level keys snake_case, fields camelCase (idle-budget.py reads `policy.isSaver`). Process sampling off the
  main actor, as DebugWakeups.
- Acceptance: registered next to debug.wakeups; top-level keys exactly policy, inputs, wake_queue, ledger_top,
  processes, cef; no main-actor await around sampling.
- Test phase: `cmux-ci build cmux --ref SHA --tag energy-v1`; `CMUX_TAG=energy-v1 scripts/cmux-debug-cli.sh debug.energy`.
- Size S. Depends: 013, 023, 021, 022, 024.

#### p14-energy-008 Idle wakeup histogram per launch
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/IdleEnergyStats.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/IdleEnergyStatsTests.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/EnergyReport.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugWakeups.swift`.
- Change: no timer of its own; at each natural main wake after 60 s with no input, record the app's interrupt
  wakeups/s (rusage delta) into buckets 0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 50+; keep p50/p95/p99 per launch; expose in
  debug.energy. The PL-telemetry sink can read it later.
- Acceptance: injected uptime and rusage: 3 idle minutes at 0.2/s fall in 0.25; a minute with input is not recorded;
  recording schedules no DemandTimer.
- Test phase: `cmux-ci run --class isolated --script 'swift test --package-path Packages/macOS/CmuxNext --filter IdleEnergyStatsTests' --ref SHA`.
- Size S. Depends: 007.

#### p14-energy-009 Daemon idle test matrix
- Files: `cmux-tui/crates/cmux-tui/tests/idle_wakeups.rs`.
- Change: new cases on assert_idle: `CMUX_TUI_TERMINAL_HOST_MODEL=holder` (judges the holder too); 20 `cat` terminals;
  every stream the app keeps (events, notifications, sidebar, terminal attach x20, browser frames); a journal hook
  plugin. Same thresholds (5 switches per window, 50 ms CPU).
- Acceptance: 4 new `#[test]` fns `cmux_next_daemon_idle_holder_mode`, `_twenty_terminals`, `_all_app_streams`,
  `_with_hook_plugin`; no threshold change.
- Test phase: `cmux-ci run --class isolated --script 'cd cmux-tui && cargo test -p cmux-tui --test idle_wakeups' --ref SHA`
  (macOS; Linux through 131); red/green per case.
- Size M.

#### p14-energy-010 acpmux idle tests
- Files: `cmux-tui/crates/acpmux/tests/daemon_idle.rs`.
- Change: cases for one watched transcript that does not change and one pending `_acpmux/wait` on an idle session;
  both <= 5 csw per 10 s.
- Acceptance: 2 new `#[test]` fns; red at the base (400 ms watch poll, 1 s wait poll), green after 070 and the owner's
  land.
- Test phase: `cmux-ci run --class isolated --script 'cd cmux-tui && cargo test -p acpmux --test daemon_idle' --ref SHA`.
- Size S.

#### p14-energy-047 Counters as Chrome defines them
- Files: `scripts/perf-bench/procs.py`, `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/xbench.py`,
  `scripts/cmux-next/tests/test_idle_budget.py`, `scripts/cmux-next/idle-budget.json`.
- Change: stop summing `buf[4] + buf[5]`. Report `interrupt_wakeups_per_s` (Chrome GetIdleWakeupsPerSecond, Activity
  Monitor; the judged metric) and `pkg_idle_wakeups_per_s` (GetPackageIdleWakeupsPerSecond). Add `ri_billed_energy`,
  `ri_serviced_energy` (rusage v6) and the app's resource coalition (`coalition_info_resource_usage`: energy,
  energy_billed_to_me, gpu_time, platform_idle_wakeups), so work moved to the render server still counts. Re-measure
  the Chrome xbench rows with the same counters.
- Acceptance: fixture interrupt 10 / pkg_idle 4 gives 10/s and 4/s, not 14/s; report has energy_mw_cpu,
  energy_mw_billed, gpu_ms_per_s per kind; a coalition read failure is null, not 0.
- Test phase: unit tests; one xbench run of cmux-chromium and chrome with the new columns.
- Size M. Depends: 002.

#### p14-energy-095 Root cause of hidden main wakes
- Files: `scripts/cmux-next/idle-budget.py`, `plans/cmux-next/idle-wakeups.md`.
- Change: run light-hidden and minimized with `/usr/bin/sample` of the main thread (3 x 10 s), the debug.wakeups ledger
  and a run-loop observer callout count, in shipping mode (100). Emit `HIDDEN-WAKE owner<TAB>per_s<TAB>top frame` per
  source. Each line becomes a Q9 item.
- Acceptance: the commit has the report with sha and host; every source above 0.1/s is a named line; no source changes.
- Test phase: `split-spring --suite=idle-budget -- --sessions light-hidden,minimized` on a quiet host.
- Size S. Depends: 001, 100.

#### p14-energy-096 Attribute visible idle power
- Files: `scripts/perf-bench/bench_power.py`, `scripts/cmux-next/idle-budget.py`.
- Change: per-process billed energy and WindowServer energy for cmux-chromium and Chrome with 1 visible static tab; list
  every FrameClient that ticks at idle (candidates GlassBackdropFeed per-frame client, BackdropVideoView, NightSky,
  infinite CA loops). Emit `POWER-OVER owner mW`.
- Acceptance: the breakdown sums to within 10% of the measured total; every owner above 2 mW is named.
- Test phase: one fleet run with Chrome installed; report attached.
- Size S. Depends: 003, 004, 047.

#### p14-energy-100 Shipping measurement mode
- Files: `scripts/cmux-next/bench_launch.py`, `scripts/cmux-next/idle-budget.py`, `scripts/cmux-next/tests/test_idle_budget.py`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Windows/WindowDrawPolicy.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageWebView+Debug.swift`.
- Change: env `CMUX_NEXT_BENCH_SHIPPING_DRAW=1` makes `isAutomationLaunch` and `rendersWhenCovered` false. idle-budget
  launches with it plus `CMUX_NEXT_DEV_SENTRY=1` and `CMUX_NEXT_DEV_HANG_REPORTS=1`, activates the app once before the
  settle, reads the bundle's build configuration and refuses `--gate` on Debug. Report fields build_config,
  sentry_started, hang_reports, draws_when_occluded, activated.
- Acceptance: unit tests: launch env holds the 3 keys; a Debug fixture with `--gate` exits non-zero with the reason; a
  WindowDrawPolicy test gives false with the automation env plus the new key; the 5 fields exist.
- Test phase: unit tests; on a Release+bench-hooks tagged build, light and light-hidden with shipping draw on and off.
- Size M. Depends: 003.

#### p14-energy-101 One hang watcher
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextCrashReporting/CrashReporter.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/HangReports/WatchdogReporting.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextCrashReportingTests/CrashReporterOptionsTests.swift`.
- Change: measure the Sentry ANR thread first (per-thread report, 100). Then `options.enableAppHangTracking = false`
  and send MainThreadWatchdog episodes (its kernel timer runs only while main is awake) to Sentry as app-hang events
  with the main-thread sample. Chrome: one HangWatcher per process.
- Acceptance: options().enableAppHangTracking == false; with an injected sink one 8 s episode gives exactly one event;
  idle-budget light (Sentry on) shows no Sentry ANR thread in threads_ran.
- Test phase: `swift test --filter "CrashReporterOptions|WatchdogReporting"` on the fleet; light before/after with Sentry on.
- Size M. Depends: 100.

#### p14-energy-102 Sessions signed-in, home, occluded, app-quit, external-churn
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/cmux-next/idle-budget.json`, `scripts/cmux-next/bench_launch.py`,
  `scripts/perf-bench/benchhelper.swift`, `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: signed-in (staging test account from the fleet secrets; Phone Access and feeds on; keep-awake settings off);
  home (Home selected); occluded (benchhelper full-screen window covers cmux); app-quit (quit after settle; measure
  daemon, holders, hosts, acpmux alone); external-churn (10 writes/s in a watched project, Chrome History fixture
  appends with Keep in Sync on, app hidden). Budgets per D13, D6 home, D3 occluded. The token never reaches logs.
- Acceptance: unit tests for the table and rows; unknown session refused.
- Test phase: unit tests; one fleet run of the 5 sessions.
- Size M. Depends: 003, 100.

#### p14-energy-103 Agent sessions and agent-harness kind
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/cmux-next/idle-budget.json`, `scripts/perf-bench/procs.py`,
  `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: agent-idle (two agent panes after a finished turn with the acpmux mock harness, one visible and one in a
  hidden workspace, plus pool entries); agent-working-visible (a turn whose mock model sends nothing for 60 s);
  busy-hidden (a hidden terminal prints one line per 100 ms). Kind agent-harness = descendants of `__agent-host`
  including pooled. Budgets per D14 (harness reported, judged after 117).
- Acceptance: kind() under `__agent-host` == 'agent-harness'; rows exist; unknown session refused.
- Test phase: unit tests; one fleet run of the 3 sessions.
- Size M. Depends: 102.

#### p14-energy-104 Every process has a kind
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/procs.py`, `scripts/cmux-next/idle-budget.json`,
  `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: kinds cef-extension (`--extension-process`), cef-network, cef-storage, cef-audio, crash-watcher (`/bin/zsh -f`
  child), cua-helper, crashpad, chromium-host; webkit split into webkit-app-page and webkit-browser-tab from the
  debug.wakeups pid list. Budgets cef-extension 0.1, cef-network 0.2, crash-watcher 0, cua-helper 0. Any `other:*` in
  the app's tree is IDLE-BUDGET-OVER under `--gate`.
- Acceptance: fixture command lines map to each kind; an unclassified child is an over with kind=other; no null wakeup
  limit for a cef-* kind.
- Test phase: unit tests; a tabs-static run listing every kind.
- Size S. Depends: 002.

#### p14-energy-105 Disk, network, log and WindowServer metrics
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/procs.py`, `scripts/cmux-next/idle-budget.json`,
  `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: per process `ri_diskio_byteswritten` deltas, network bytes and active connections (`nettop -P -x -L` over the
  window), unified-log lines (`log show --predicate` on the pid set, ndjson count), WindowServer wakeups delta against a
  reference window with cmux hidden (reported, not judged). Budgets per D15.
- Acceptance: fixtures give disk_bytes_per_s, network and log counts per kind; 4 KB written by the app prints an over.
- Test phase: unit tests; light and signed-in on the fleet.
- Size M. Depends: 002.

#### p14-energy-106 Process role and App Nap audit
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/perf-bench/procs.py`, `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: record priority and flags (`ps -o pid=,pri=,nice=,flags=`; darwinbg via `taskinfo` where present). Expected
  roles per D16. Each mismatch prints `IDLE-BUDGET-OVER owner=role`.
- Acceptance: a fixture ps output gives a role per process and flags a hidden renderer at foreground priority.
- Test phase: unit tests; tabs-static and minimized.
- Size S. Depends: 104. Queue Q9.

#### p14-energy-123 debug.energy.simulate
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextEnergy/EnergyMonitor.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/EnergyReport.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugWakeups.swift`, `scripts/cmux-next/energy-test-phase.py`.
- Change: `debug.energy.simulate {on_battery, percent, thermal, low_power, suspended}` compiled only in Debug and
  `CMUX_BENCH_HOOKS` builds; overrides EnergyMonitor inputs; clearing restores real inputs. energy-test-phase runs D7
  auto with on_battery and 15%.
- Acceptance: absent from Release without bench hooks (compile-time `#if`); simulate 15% on battery gives saver with
  reason battery; clear restores.
- Test phase: `cmux-ci build cmux --ref SHA --tag energy-sim`; `CMUX_TAG=energy-sim scripts/cmux-debug-cli.sh debug.energy.simulate ...`.
- Size S. Depends: 007, 022.

#### p14-energy-130 One shared tab-page server and Chromium process classifier
- Files: `scripts/cmux-next/idle-budget.py`, `scripts/cmux-next/browser-idle-cost-live.py`, `scripts/cmux-next/bench_idle.py`.
- Change: factor the static-page server and the Chromium process classifier out of browser-idle-cost-live.py and
  bench_idle.py into one module that idle-budget tabs-static/minimized and the perf100 lane import.
- Acceptance: one copy of each; browser-idle-cost-live.py output unchanged on a fixture.
- Test phase: unit tests; one browser-idle-cost-live run.
- Size S. Depends: 002.

#### p14-energy-135 D8 benches: Chromium composer typing and page scroll
- Files: `scripts/cmux-next/bench-typing.py`, `scripts/cmux-next/idle-budget.py`, `scripts/cmux-next/tests/test_idle_budget.py`.
- Change: bench-typing gets a `--surface agent-composer-chromium` mode (key->frame in a Chromium-hosted composer page)
  and a scroll mode for a Chromium page (frames presented during a 2 s scripted scroll at 120 Hz, dropped frames
  counted), each with `--energy-saver on|off` through the config.
- Acceptance: `--dry-run` prints both commands; a fixture result is parsed into p50/p95 and dropped frames.
- Test phase: one fleet run of both modes with saver off and on.
- Size S. Depends: 003.

### Phase P1: coalescing primitives

#### p14-energy-011 DelayPolicy and WakeLeeway
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/DelayPolicy.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/WakeLeeway.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/WakeLeewayTests.swift`.
- Change: `enum DelayPolicy { precise, flexibleNoSooner, flexiblePreferEarly }`. `WakeLeeway.window(delay:policy:alignment:)`:
  precise and delay < 36 ms -> leeway 0, no alignment; precise >= 36 ms -> flexibleNoSooner (MaybeOverrideDelayPolicy);
  flexible < 1 s -> leeway = alignment (8 ms, 32 ms in saver); flexible >= 1 s -> align up to the next whole uptime
  second, leeway min(delay/10, 1 s). Doc comments cite delay_policy.h, task_features.h, Blink's wake_up_budget_pool.h
  and Apple's Energy Efficiency Guide (10% rule), and say why cmux differs from Chrome's flat 8 ms.
- Acceptance: table test: (20 ms, precise) -> 0; (100 ms, precise) -> 8 ms; (450 ms, flexible) -> 8 ms; (5 s, flexible)
  -> 500 ms and a whole-second fire; (60 s) -> 1 s; saver gives 32 ms in place of 8.
- Test phase: `swift test --filter WakeLeewayTests` on the fleet.
- Size S.

#### p14-energy-012 DemandTimer delay policy and tolerance
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/DemandTimer.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextWakeupsTestSupport/ManualClock.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/DemandTimerLeewayTests.swift`.
- Change: `init(owner:policy: = .flexibleNoSooner, clock:, ledger:, energy: EnergyPolicySource = .normal)`; schedule()
  calls `clock.sleep(for:tolerance:)` with WakeLeeway. ManualClock records tolerances and fires exactly at the deadline.
- Acceptance: schedule(after: .seconds(5)) asks tolerance 0.5 s; a .precise 20 ms schedule asks 0; existing DemandTimer
  tests unchanged and green.
- Test phase: `swift test --filter DemandTimer` on the fleet.
- Size S. Depends: 011.

#### p14-energy-013 MainWakeUpQueue
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/MainWakeUpQueue.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/MainWakeUpHeap.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/MainWakeUpQueueTests.swift`.
- Change: a pure `MainWakeUpHeap` of (deadline ns, latest ns, policy, owner, id, action) in CLOCK_UPTIME_RAW ns, held in a
  `Mutex`. One CFRunLoopTimer in common modes, created once and parked far in the future. `insert` and `cancel` are
  callable from any thread; they re-arm only when the computed fire date changes and is earlier than the armed one
  (`CFRunLoopTimerSetNextFireDate`), else no wake. fireDate = min(alignUp(earliest flexible deadline, grid),
  min(latest)); precise entries fire at their deadline; grid 8 ms or 32 ms (EnergyPolicy, 023); conversion to
  CFAbsoluteTime only at arm; tolerance = min(latest) - fireDate set before the date. A fire (main) pops every due
  entry, runs main-actor actions in deadline order and records one ledger entry per owner plus one
  `MainWakeUpQueue.fire`. cancel is O(log n). No Task, no pool thread.
- Acceptance: heap tests: 5 flexible entries at 100, 103, 105, 107, 110 ms with 8 ms leeway fire as 2 aligned wakes; an
  aligned fire date is an exact multiple of the grid in uptime ns; a fire date is never after any entry's latest; a
  precise 10 ms entry is never aligned; cancel of the earliest re-arms to the next; a repeated insert with the same
  earliest makes no re-arm call; an entry inserted during a fire that is due runs in the same pass; 4 threads x 1000
  concurrent inserts lose nothing (TSan clean). File <= 300 lines.
- Test phase: `swift test --filter MainWakeUpQueueTests` on the fleet, also with `--sanitize=thread`.
- Size M. Depends: 011.

#### p14-energy-014 DemandTimer main-actor actions on MainWakeUpQueue; sync overload
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/DemandTimer.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/DemandTimerMainQueueTests.swift`.
- Change: read the `@isolated(any)` action's `.isolation`. When it is `MainActor.shared` and a MainWakeUpQueue is
  injected (AppServices passes the app's), insert into the queue; on fire create one `Task { @MainActor in await
  action() }` inside the callout. Add `scheduleOnMain(after:tolerance:_ action: @escaping @MainActor () -> Void)` that
  runs inline in the callout. Generation and claim semantics stay (593f5f97c61). Async call sites do not change. If
  `.isolation` is unusable at the macOS 14 target, stop and report: task 132 starts.
- As landed (spec change): the sync variant is `scheduleOnMain`, not an overload of `schedule`. A trailing closure
  with no `await` matches both, so an overload would silently turn a closure written off the main actor into
  main-actor work. Sync sites therefore move by rename in 133, not by overload resolution. The `mainWork:` init takes
  no `clock:`: a main-actor action runs on the queue's uptime, which stops while the Mac sleeps and which a
  `ManualClock` does not drive. Tests of migrated owners fire the queue (`WakeUpQueueRig`); a deadline that must count
  system sleep uses a nonisolated action. A dropped entry is freed with no timer or queue lock held, because its
  action may own another timer.
- Acceptance: a main-actor action at 100 ms runs with 0 pool-thread hops (a test seam counts `clock.sleep` calls == 0
  and the ledger shows one `MainWakeUpQueue.fire`); the sync overload runs inline (no Task); reset and cancel still
  win over a fire; a nonisolated action uses the Task path.
- Test phase: `swift test --filter DemandTimer` on the fleet. No production timer gets a queue here, so the
  idle-budget light ledger (`MainWakeUpQueue.fire`, no pool wake per DemandTimer fire) is evidence for 019a-d and 133.
- Size M. Depends: 012, 013.

#### p14-energy-015 Backoff leeway
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/Backoff.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/BackoffTests.swift`.
- Change: Backoff.wait sleeps with tolerance max(8 ms, 10% of the step); jitter stays; ledger reason `backoff`.
- Acceptance: ManualClock records 50 ms -> 8 ms, 2 s -> 200 ms; existing tests pass.
- Test phase: `swift test --filter Backoff` on the fleet.
- Size S. Depends: 011.

#### p14-energy-016 CEF delayed fire date on MainWakeUpQueue
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpTimer.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFMessagePump.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFRuntime.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFMessagePumpTests.swift`.
- Change: replace `CEFRunLoopPumpTimer` with a pump timer whose delayed requests are MainWakeUpQueue entries
  (flexibleNoSooner, queue alignment). On fire the entry does not run CEF; it posts one `CFRunLoopPerformBlock` that
  runs `CefDoMessageLoopWork` after the cmux entries of the same fire. Immediate and cross-thread "now" requests keep
  the existing CFRunLoopPerformBlock / CEFPumpCrossThreadGate path. The beginWork guard against nested re-entry stays.
  Remove CFRunLoopTimerCreateWithHandler and its wakeup-allow. Read the CmuxNextBrowser split move list first.
- Acceptance: `rg -n CFRunLoopTimerCreate Packages/macOS/CmuxNext/Sources` returns 0. With a fake queue, a 100 ms CEF
  request and a DemandTimer at 104 ms share one fire; a nested run loop inside a CEF pass does not delay a cmux
  deadline due in the same fire; a "now" request never waits for the timer.
- Test phase: `swift test --filter CEFMessagePump` on the fleet; idle-budget tabs-static app main wakes <= before.
- Size M. Depends: 013.

#### p14-energy-017 Delete the pre-API-7 follow-up chain
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpSchedule.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFRuntime.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFPumpScheduleTests.swift`.
- Change: delete SafetyNet, standard, safetyNetTolerance, followUps, armedSafetyNetInterval, nextFollowUp,
  firstFollowUp, sliceMayHaveCutWork. A fork below API 27 still loads with demand-only scheduling and one diagnostic log
  line (no WebKit fallback; no CEFShimLibrary change). Tell cef-layer and F2 owners.
- Acceptance: `rg -n 'followUps|safetyNet' Packages/macOS/CmuxNext/Sources/CmuxNextBrowser` returns 0;
  CEFPumpSchedule.swift < 100 lines; follow-up tests deleted, demand-driven tests kept.
- Test phase: `swift test --filter CEFPump` on the fleet.
- Size S. Depends: 016.

#### p14-energy-018 CEF pump ledger reasons
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFMessagePump.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpStats.swift`.
- Change: each pass records owner `CEFMessagePump` with reason now|delayed|kept|reentered; CEFPumpStats gets
  `earlyPasses` (a pass followed within 2 ms by a delayed request under 2 ms), measured before 046.
- Acceptance: ledger keys exist; existing counters unchanged; fake ledger sees `delayed` for a 100 ms request; a fixture
  sequence increments earlyPasses.
- Test phase: `swift test --filter CEFMessagePump` on the fleet; split-spring --suite=cef-idle records earlyPasses.
- Size S. Depends: 016.

#### p14-energy-019a Q1 sleeps: CmuxNextApp
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/**`.
- Change: every Q1 and Q10 hit under CmuxNextApp: a one-shot deadline moves to DemandTimer; a bounded retry to Backoff;
  a raw sleep that must stay passes `tolerance:` from WakeLeeway and keeps a closed-vocabulary escape. A periodic loop
  becomes an event or DemandTimer, never a sleep with tolerance.
- Acceptance: `rg -n 'Task\.sleep\(|\.sleep\((for|until):' Packages/macOS/CmuxNext/Sources/CmuxNextApp | grep -v tolerance`
  returns 0; no behavior change other than slack; ManualClock tests pass.
- Test phase: `swift test --filter CmuxNextAppTests` on the fleet.
- Size M. Depends: 012, 015. Queue Q1.

#### p14-energy-019b Q1 sleeps: Daemon, DaemonService, Control, Compat
- Files: `Packages/macOS/CmuxNext/Sources/{CmuxNextDaemon,CmuxNextDaemonService,CmuxNextControl,CmuxNextCompat}/**`.
- Change, acceptance: as 019a for these four directories.
- Test phase: `swift test --filter "CmuxNextDaemonTests|CmuxNextControlTests"` on the fleet.
- Size S. Depends: 012, 015. Queue Q1.

#### p14-energy-019c Q1 sleeps: AgentPane, HomeEngine, Feed, Devices
- Files: `Packages/macOS/CmuxNext/Sources/{CmuxNextAgentPane,CmuxNextHomeEngine,CmuxNextFeed,CmuxNextDevices}/**`.
- Change, acceptance: as 019a for these four directories.
- Test phase: `swift test --filter "AgentPane|HomeEngine|Feed|Devices"` on the fleet.
- Size S. Depends: 012, 015. Queue Q1.

#### p14-energy-019d Q1 sleeps: remaining modules
- Files: `Packages/macOS/CmuxNext/Sources/**` (hits left after 019a-c).
- Change: as 019a.
- Acceptance: `rg -n 'Task\.sleep\(|\.sleep\((for|until):' Packages/macOS/CmuxNext/Sources | grep -v tolerance | grep -v CmuxNextWakeups`
  returns 0.
- Test phase: full CmuxNext `swift test` on the fleet.
- Size M. Depends: 019a, 019b, 019c. Queue Q1.

#### p14-energy-020 Rust wake module: deadlines, EnergyMode, MaintenanceClock
- Files: `cmux-tui/crates/cmux-tui-core/src/wake/mod.rs`, `cmux-tui/crates/cmux-tui-core/src/wake/maintenance.rs`,
  `cmux-tui/crates/cmux-tui-core/src/wake/energy.rs`, `cmux-tui/crates/cmux-tui-core/src/lib.rs`,
  `plans/cmux-next/threading-model.md`.
- Change: `wake::deadline(now, delay, Policy)` gives the aligned instant (8 ms grid, 32 ms in saver; 10% leeway for
  >= 1 s). `EnergyMode`: AtomicBool plus a notify. `MaintenanceClock`: one `mux-maintenance` thread per process at
  utility QoS (076 helper); `register(name, period, skippable_in_saver, job)`; next instant from `SystemTime` on a
  5-minute wall grid; macOS waits on kqueue `EVFILT_TIMER` with `NOTE_ABSOLUTE|NOTE_LEEWAY` (30 s) plus `EVFILT_USER`
  for register and mode changes; Linux sets `PR_SET_TIMERSLACK` and waits on a Condvar; nothing registered -> blocking
  wait with no timeout; after a sleep gap, overdue jobs spread over one leeway window and each runs once; in saver a
  skippable job waits up to 4x its period. Durability jobs (output_store flush/snapshot, journal_retention checkpoint,
  journal_maintenance) are not allowed on it: a doc comment and a debug assertion on known names say so.
- Acceptance: injected-clock tests: periods 300, 600, 900 s fire in 1 wake at t=900; nothing registered -> no timed
  wait; saver gaps up to 4x for skippable only; a simulated 2 h sleep runs each job once; the armed kevent carries
  NOTE_LEEWAY (macOS). No `thread::sleep` in the module.
- Test phase: `cmux-ci run --class isolated --script 'cd cmux-tui && cargo test -p cmux-tui-core wake::' --ref SHA`
  (macOS and Linux).
- Size M.

#### p14-energy-037 Per-fire 2 ms budget; fork pump slice
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/MainWakeUpQueue.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/MainWakeUpQueueTests.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpSchedule.swift`, `fork:libcef/browser/browser_message_loop.cc`.
- Change: a fire runs due entries until 2 ms (injected clock), then re-arms for now, so NSEvents run between. Fork patch
  (into 136): `MessagePumpExternal::Run` exits after one DoWork batch or 2 ms, and asks for "now" when work remains.
  CEFPumpSchedule.timeSlice becomes 2 ms when the fork API has the patch.
- Acceptance: 50 due entries of 0.1 ms run in 3 fires; a fake input source queued between fires runs before the second;
  timeSlice <= 2 ms on the new fork API.
- Test phase: `swift test --filter MainWakeUpQueueTests`; bench-typing with a busy Chromium page, key->frame p99 before
  and after.
- Size S. Depends: 013. Queue fork (patch part).

#### p14-energy-046 Fork API: absolute delayed run time, leeway, precise
- Files: `fork:libcef/browser/browser_message_loop.cc`, `fork:include/cef_cmux.h`,
  `Packages/macOS/CmuxNext/CEFShim/src/shim_client.mm`, `Packages/macOS/CmuxNext/CEFShim/src/shim_internal.h`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFMessagePump.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpSchedule.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPumpStats.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFPumpScheduleTests.swift`.
- Change: fork callback `cmux_on_schedule_delayed(int64 run_time_ticks_ns, int64 leeway_ns, bool precise)` in the
  TimeTicks base (CLOCK_UPTIME_RAW on Mac); ScheduleWork stays separate. The shim forwards it; CEFPumpSchedule stores
  the absolute deadline and uses Chromium's leeway (precise -> 0) as a MainWakeUpQueue entry. With this API,
  `enable-features` adds `TimerSlackMac` (040 note). Old forks keep the ms path.
- Acceptance: on the new API no path turns a delayed request into immediate; table test: 7.9 ms with 8 ms leeway arms at
  7.9 ms with tolerance 8 ms; precise arms with 0; an old fork keeps the ms path; the cross-thread gate compares ns.
- Test phase: fork build through 136; `swift test --filter CEFPump`; split-spring --suite=cef-idle: earlyPasses 0 and
  pump wakes/s down in tabs-static (numbers in the commit).
- Size M. Depends: 016. Queue fork.
- Fork ref: manaflow-ai/cef `cp/p14-energy-046` (18f4828a, on 037's `cp/p14-energy-037`), with no API number (136
  numbers it). cmux finds `cmux_set_on_schedule_delayed` by symbol (`cmux_shim_set_schedule_delayed` returns 1), so a
  fork without it keeps the ms path.
- TimerSlackMac is not tied to this API (046 review): with the handler set, the fork's MessagePumpExternal overrides
  ScheduleDelayedWork and AdjustDelayedRunTime, so the UI thread arms no base timer and the flag changes only renderer,
  GPU and utility processes and the browser's non-UI threads (page `setTimeout` may fire up to its leeway late). It is
  the default-off feature `cefTimerSlack` (process `chromium`) until a run measures those wakes and page timer latency.
- earlyPasses on the absolute path: a delayed pass is early when it began before the run time it serves, or when
  Chromium reports that run time or an earlier one during the pass. A later run time is the next task, however close.
  The 2 ms re-ask rule stays for the ms path only.

#### p14-energy-132 Contingency: explicit onMain DemandTimer migration
- Files: the Q14 hit files under `Packages/macOS/CmuxNext/Sources/**`, `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/DemandTimer.swift`.
- Change: only if 014 reports `.isolation` unusable: add `DemandTimer(owner:onMain: true)` and migrate the main-actor
  sites in 4 parallel slots (App 57, AgentPane 13, Design 12, rest).
- Acceptance: every main-actor DemandTimer site passes `onMain: true`; the 014 tests pass with the explicit init.
- Test phase: full CmuxNext `swift test` on the fleet.
- Size M. Depends: 014 (failure report). Queue Q14.

#### p14-energy-133 Q13 sync DemandTimer actions use the sync overload
- Files: the Q13 hit files under `Packages/macOS/CmuxNext/Sources/**`.
- Change: a main-actor DemandTimer closure with no `await` moves from `schedule(after:)` to
  `scheduleOnMain(after:tolerance:_:)` (no Task per fire), a rename at each site (014 landed a separate name, not an
  overload). A site's tests that advance a `ManualClock` move to firing the queue. Mechanical, reviewed per module.
  The light-ledger evidence for DemandTimer on the queue (`MainWakeUpQueue.fire`, no pool wake) comes from here.
- Acceptance: `wakeup-audit.py --queue demand-sync` prints 0 lines; tests unchanged.
- Test phase: full CmuxNext `swift test` on the fleet.
- Size M. Depends: 014. Queue Q13.

### Phase P2: Energy Saver

#### p14-energy-021 CmuxNextEnergy target
- Files: `Packages/macOS/CmuxNext/Package.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextEnergy/EnergyMonitor.swift`,
  `.../CmuxNextEnergy/BatteryLevel.swift`, `.../CmuxNextEnergy/ThermalStateWatch.swift`,
  `.../CmuxNextEnergy/PowerSourceMonitor.swift`, `.../CmuxNextEnergy/LowPowerMode.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextKeepAwake/PowerSourceMonitor.swift` (moved),
  `Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/LowPowerMode.swift` (moved),
  `plans/cmux-next/architecture-layers.json`, `plans/cmux-next/OWNERS.md`.
- Change: `git mv` PowerSourceMonitor and LowPowerMode/LowPowerModeObservation into the new service target; add
  BatteryLevel, ThermalStateWatch (one observer per app) and `@MainActor @Observable EnergyMonitor` (holds inputs).
  Only CmuxNextApp depends on CmuxNextEnergy. Consumers that read LowPowerMode today (WebKitEngine,
  BrowserHibernation, GlassModeWatch, BackdropVideoView) read `EnergyPolicySource` (CmuxNextWakeups) or an injected
  closure. OWNERS row (Performance Lead).
- Acceptance: target builds; `rg -c IOPSNotificationCreateRunLoopSource Packages/macOS/CmuxNext/Sources` == 1 (or 0
  after 058); only CmuxNextApp imports CmuxNextEnergy (`rg -l 'import CmuxNextEnergy'`); arch-layers and arch-ratchet
  pass with no raised edge.
- Test phase: `cmux-ci build cmux --ref SHA`; `python3 scripts/cmux-next/arch-ratchet.py`; prepush-gate.
- Size M.

#### p14-energy-022 EnergyPolicyResolver and energy.saver setting
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextEnergy/EnergyPolicyResolver.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Energy.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/EnergySaverSetting.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextEnergyTests/EnergyPolicyResolverTests.swift`.
- Change: setting energy.saver auto|onBattery|always|off. Pure resolver (setting, lowPowerMode, onBattery, hasBattery,
  percent, thermal, sessionOff) -> (isSaver, reason). auto = LPM, or onBattery and percent < 20, or onBattery and
  thermal >= serious. onBattery = onBattery. sessionOff wins until the battery -> AC edge or any setting change. Reasons
  lowPowerMode|battery|thermal|setting. Doc comment states the divergences from Chrome (LPM, thermal on battery).
  Localized title and help per value; generated schema files are not hand-edited.
- Acceptance: table test: each mode; 19% vs 20% (strict <); LPM while plugged in -> on; thermal critical plugged in ->
  off in auto; thermal serious on battery -> on; sessionOff cleared on battery -> AC and on setting change. Strings in
  xcstrings for en plus the catalog's languages; localization audit in the commit.
- Test phase: `swift test --filter EnergyPolicyResolverTests` on the fleet.
- Size M. Depends: 021.

#### p14-energy-023 EnergyPolicy value in CmuxNextWakeups
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/EnergyPolicy.swift`, `.../CmuxNextWakeups/MainWakeUpQueue.swift`,
  `.../CmuxNextWakeups/DemandTimer.swift`, `.../CmuxNextWakeups/FrameScheduler.swift`.
- Change: `struct EnergyPolicy: Sendable, Equatable { isSaver; reason; wakeAlignment; ambientMaxFPS; webFrameRate;
  pollStretch; suspended; screensAsleep; onBattery }`. `EnergyPolicySource`: Mutex-held value with change observers.
  MainWakeUpQueue and DemandTimer read wakeAlignment; FrameScheduler reads ambientMaxFPS and screensAsleep. No AppKit
  or IOKit.
- Acceptance: switching the source to saver re-aligns pending flexible entries to 32 ms and leaves precise entries.
- Test phase: `swift test --filter "MainWakeUpQueueTests|EnergyPolicy"` on the fleet.
- Size S. Depends: 013.
- As landed (review fixes): only `EnergyPolicy`, `EnergyPolicySource` and `MainWakeUpQueue(energy:)`, with no
  default source. As in Chrome, an entry keeps the leeway it was inserted with and the grid applies at wake time
  (`AdjustDelayedRunTime`), so a switch snaps pending entries to 32 ms only up to their latest time. DemandTimer and
  FrameScheduler do not change here. 012 owns DemandTimer's `policy:` and tolerance (precise asks 0), and 028 owns the
  ambient rate class and its source (every FrameScheduler gets it, MainWorkScheduler's too). Still open for 012/014/024:
  how the 188 `DemandTimer(` sites that use defaults get the app's source. A static setter
  (`DemandTimer.setProcessDefaults`) breaks arch-ratchet `stateful_singletons`. So 014 adds a seam that the
  composition root sets once (for example, the MainWakeUpQueue it injects carries the source), or 024 threads the queue
  through the sites and its "+30 lines" acceptance changes.

#### p14-energy-024 Composition root wiring
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices+EnergyHost.swift`.
- Change: build EnergyMonitor and MainWakeUpQueue once; pass EnergyPolicySource to DemandTimer defaults,
  FrameScheduler, CEFRuntime, WebKitEngine, BrowserHibernation, GlassModeWatch, BackdropVideoView, DaemonService, and an
  `onBattery` closure to KeepAwakeService. Wiring and one-line forwards only.
- Acceptance: no `static shared` energy state; AppServices grows <= 30 lines; the Host file has one-line forwards.
- Test phase: `cmux-ci build cmux --ref SHA --tag energy-v1`; debug.energy shows inputs.
- Size S. Depends: 022, 023.
- As landed (review fixes): `MainWorkScheduler` owns the app's one `EnergyPolicySource` (`energy`) and
  `MainWakeUpQueue` (`wakeUps`). The daemon, Cloud, SSH and server services already get the scheduler by init, so a
  DemandTimer, CEF or FrameScheduler owner reaches both with no static setter and no second injection path. This
  answers 023's open question. `EnergyPolicyDriver` (CmuxNextEnergy) is the source's one writer. It feeds the
  `energy.saver` setting and each `EnergyMonitor` input change to `EnergyPolicyResolver`, as Chrome's
  `BatterySaverModeManager` re-resolves on the pref and on the power state, and it publishes nothing until both are
  known. KeepAwake keeps one `onBattery` writer, the monitor link. The consumers change in their own tasks, which
  now say where they read the source: DemandTimer 012/014 (sites with no scheduler keep 8 ms until 019a-d and 133
  move them), CEF 016, FrameScheduler 028 (`mainWork.frames`, `FrameScheduler.app`, per-window), BrowserHibernation
  and WebKitEngine 031, DaemonService 033, GlassModeWatch and BackdropVideoView 138 (after p11-codebase-039).

#### p14-energy-025 Energy Saver session actions
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/EnergyActionCatalog.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextActions/Localizable.xcstrings`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/EnergyHandlers.swift`.
- Change: actions energy.saver.turnOffForNow and energy.saver.turnOnNow via `registry.bindEffect(id, effect:)` returning
  `.done`; palette entries with localized titles; no shortcut.
- Acceptance: bindEffect, no await, no I/O; localized catalog entries; action-wait guardrail passes.
- Test phase: `swift test --filter EnergyActions` on the fleet.
- Size S. Depends: 024.

#### p14-energy-026 Energy Saver indicator and hover card
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/SidebarEnergyIndicator.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Localizable.xcstrings`.
- Change: leaf glyph in the sidebar footer only while isSaver; hover card with the reason (Low Power Mode / battery at
  N% / hot Mac on battery / setting) and "Turn off for now" (025). Observes only the policy value; Motion-gated fade
  (`Motion.indicators`); no TimelineView, no timer.
- Acceptance: the view observes only EnergyPolicySource; no TimelineView/timer; PR has a real capture.
- Test phase: `cmux-ci capture <sha> --state scene:energy-saver --pr N`.
- Size M. Depends: 025.

#### p14-energy-027 Motion loops static under saver
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/Motion+AppKit.swift`,
  `.../CmuxNextDesign/Motion/MotionGate.swift`, `.../CmuxNextDesign/Motion/Motion.swift`.
- Change: MotionPolicy gets an `energySaver` input; under saver `animatesLoops` is false, so spin/step/sweep/breath/pulse
  helpers return nil and the static glyph shows. Normal mode keeps today's frame-rate range. Performance Lead note in
  the commit.
- Acceptance: under saver spinAnimation() == nil; in normal mode the animation is unchanged (test compares the
  object); person-started movement and fade durations unchanged under saver.
- Test phase: `swift test --filter Motion` on the fleet.
- Size S. Depends: 024.

#### p14-energy-028 FrameScheduler opt-in ambient class
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/FrameScheduler.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/FrameClient.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/FrameSchedulerRateClassTests.swift`.
- Change: FrameClient gets `rate: .motion | .ambient` (default .motion for every existing client, including
  `isAnimation: false` clients). The link range is the highest active class: motion 80-120; ambient alone up to
  policy.ambientMaxFPS (30 under saver, motion range otherwise). `.ambient` is opt-in per client, owner-reviewed
  (first candidate GlassBackdropFeed after 096). screensAsleep stops ambient clients.
- Acceptance: TerminalFrameHold, FrameBatchQueue, ResizeCoordinator and the probes report .motion; ambient alone under
  saver -> max 30; motion + ambient -> 80-120; ambient outside saver -> motion range.
- Test phase: `swift test --filter FrameScheduler`; bench-typing key->frame unchanged; split-spring 0 dropped frames.
- Size M. Depends: 023.

#### p14-energy-029 Fork API cmux_cef_set_energy_saver with input exemption
- Files: `fork:include/cef_cmux.h`, `fork:libcef/browser/cmux_energy_saver.cc`, `fork:libcef/browser/cmux_energy_saver.h`.
- Change: `cmux_cef_set_energy_saver(bool enabled, const char* exempt_scheme)` on the UI thread: throttles frame sinks
  to 30 Hz except sinks of `exempt_scheme` pages (cmux's own) and sinks with input in the last 1 s (released on input,
  re-throttled 1 s after the last event; a cmux divergence from `StartThrottlingAllFrameSinks`);
  `MessagePump::OverrideAlignWakeUpsState(true, 32 ms)` or reset; `SetBatterySaverMode(enabled)` on every
  RenderProcessHost and BrowserChildProcessHost, also those launched later. Requires
  `BatterySaverModeAlignWakeUps` (040) to have effect in children. Patch goes into 136.
- Acceptance: header declares it under the new fork API; a browser test: a sink with no input is at 30 Hz after the call
  and released after false; a sink with input in the last 1 s is not throttled; a renderer's leeway is 32 ms in saver.
- Test phase: fork CI build (136); idle-budget energy-saver: anim page rAF <= 31/s; D8 Chromium scroll at 120 Hz.
- Size M. Queue fork.
- Fork ref: manaflow-ai/cef `cp/p14-energy-029` (11649d01, on 124's `cp/p14-energy-124`), with no API number (136
  numbers it). Files follow the fork layout: `libcef/browser/cmux/cmux_energy_saver.{h,cc}`, the BUILD.gn entry, and
  one call in `CefBrowserContentsDelegate::ObserveWebContents` that watches every CEF page. Throttling is per page
  (`UpdateThrottlingFrameSinks` on the primary main frame; viz throttles the sinks embedded in it, so input in any
  widget of a page releases the whole page). `cmux_battery_saver_embedder_owned.patch` gives Chrome's
  `BatterySaverModeManager` no provider, so Chrome's battery saver never turns on and cmux's saver is the only writer of
  the frame sink throttle, the wake-up leeway and the child process mode. Embedder test:
  `scripts/test-cmux-embedder.sh energy-saver`, run with Chrome's battery saver pref set to always on.

#### p14-energy-030 Shim and Swift binding for the saver fork API
- Files: `Packages/macOS/CmuxNext/CEFShim/src/shim_process.mm`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h`,
  `.../CmuxNextBrowser/CEF/CEFShimABI.swift`, `.../CmuxNextBrowser/CEF/CEFRuntime.swift`,
  `.../CmuxNextBrowser/CEF/CEFForkFeatures.swift`.
- Change: shim export `cmux_shim_set_energy_saver`, no-op below the fork API; CEFRuntime observes EnergyPolicySource,
  calls it on each edge and once after CefInitialize with the `cmux` scheme exempt; reports applied|unsupported to
  debug.energy.
- Acceptance: guarded by forkAPIVersion; a repeated state makes no call; fake shim sees one call per edge.
- Test phase: `cmux-ci build cmux --ref SHA`; idle-budget energy-saver rAF <= 31.
- Size S. Depends: 029, 024, 136.

#### p14-energy-031 Hibernation neighbor radius and WebKit render rate follow EnergyPolicy
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation/BrowserHibernation.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/WebKit/WebKitEngine.swift`.
- Change: replace LowPowerMode observation with EnergyPolicySource; in saver neighbor radius 0 and WebKit low render
  rate. The freeze grace is not shortened (039 does Chrome's CPU rule). Until the `energySaver` feature is on by
  default, the driver publishes macOS Low Power Mode as `EnergyPolicy.lowPowerFallback` while the feature is off,
  and these consumers read `EnergyPolicy.pageSaver` (saver or fallback), so default builds keep Low Power Mode's
  near-60 fps WebKit, neighbor radius 0 and short page lifecycle window (p14-energy-021). The resolver holds the
  thermal reason until nominal or plug-in, so a Mac flapping between fair and serious makes one saver edge.
- Acceptance: `rg -n 'LowPowerMode' Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/WebKit`
  returns 0; existing hibernation tests pass with a saver case.
- Test phase: `swift test --filter "Hibernation|WebKitRenderRate"` on the fleet.
- Size S. Depends: 024.

#### p14-energy-032 Background polls stretch in saver and pause when nothing shows them
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextFeed/GitHubFeedSource.swift`,
  `.../CmuxNextApp/ErrorJournal/ErrorJournalService.swift`, `.../CmuxNextApp/Cloud/CloudAccessAsks.swift`,
  `.../CmuxNextWebUpdates/**`.
- Change: each poll multiplies its interval by pollStretch; the web-updates minute poll and the GitHub feed stop while no
  cmux window is visible (visibility injected from App) and refresh once on show.
- Acceptance: ManualClock tests: GitHub interval 4x under saver; all windows hidden -> no refresh scheduled; show -> one.
- Test phase: `swift test --filter "GitHubFeed|ErrorJournal|WebUpdates"` on the fleet.
- Size M. Depends: 024. Queue Q6.

#### p14-energy-033 Daemon energy op, CLI and MCP parity
- Files: `cmux-tui/crates/cmux-tui-core/src/server/energy_op.rs`, `cmux-tui/crates/cmux-tui/src/cli/energy.rs`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextDaemonService/DaemonService+Energy.swift`.
- Change: ops `energy.set {saver, reason}` (an override of the daemon's own reading, 137) and `energy.status`; the
  handler flips `wake::EnergyMode` and notifies (< 2 ms, no I/O). The app sends energy.set after the turn on each edge.
  CLI `cmux energy [status|on|off|auto]` (on/off/auto send an app action over the control socket; status reads both).
  MCP tool parity per cmux-next-feature.
- Acceptance: handler only flips and notifies; Rust op round-trip test; app sends only on an edge; CLI help localized
  where the CLI localizes.
- Test phase: `cargo test -p cmux-tui-core energy` on the fleet.
- Size M. Depends: 020, 024.

#### p14-energy-034 acpmux maintenance on MaintenanceClock
- Files: `cmux-tui/crates/acpmux/src/catalog/mod.rs`, `cmux-tui/crates/acpmux/src/hub/health_view.rs`,
  `cmux-tui/crates/acpmux/src/hub/file_uploads.rs`, `cmux-tui/crates/acpmux/src/daemon.rs`.
- Change: catalog REFRESH_EVERY, health view and the 24 h upload sweep register on one MaintenanceClock (async adapter:
  one tokio task waits on the clock); catalog fetch is `skippable_in_saver: false` if it gates a correctness path.
  Energy mode reaches acpmux through its control channel. Tell PL-acpmux.
- Acceptance: `rg -n 'time::interval' cmux-tui/crates/acpmux/src/{catalog,hub}` returns 0; the acpmux idle test with all
  three registered shows no wake inside a 30 s window.
- Test phase: `cargo test -p acpmux` on the fleet.
- Size S. Depends: 020, 070. Queue Q4.

#### p14-energy-035 KeepAwake reads the shared power source
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextKeepAwake/KeepAwakeService.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextKeepAwake/KeepAwakePolicy.swift`.
- Change: KeepAwakeService takes an injected `onBattery` stream/closure from AppServices instead of its own
  PowerSourceMonitor; no import of CmuxNextEnergy.
- Acceptance: KeepAwakeService constructs no PowerSourceMonitor; keep-awake tests pass with a fake input.
- Test phase: `swift test --filter KeepAwake` on the fleet.
- Size S. Depends: 024.

#### p14-energy-036 Docs
- Files: `plans/cmux-next/idle-wakeups.md`, `docs/energy-saver.md`, `plans/cmux-next/threading-model.md`.
- Change: idle-wakeups sec. 9 (budget file, MainWakeUpQueue, DelayPolicy, policy table, Chrome references and
  divergences, allowed_periodic, escape vocabulary). User doc: what the saver changes and never changes, how to turn
  it off. threading-model: MaintenanceClock and MainWakeUpQueue rows.
- Acceptance: docs only; localization audit noted; links resolve.
- Test phase: none (docs).
- Size S. Depends: 022, 013.

#### p14-energy-039 Saver freezes CPU-heavy hidden tabs
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Hibernation/BrowserHibernation.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/BrowserHibernationSaverTests.swift`.
- Change: in saver a hidden tab whose renderer used >= the threshold of one core (Chrome kFreezingHighCPUProportion
  value, cited) over the last sample window freezes on the next natural wake; low-CPU tabs keep the grace; all
  existing exemptions (audio, capture, form input) apply.
- Acceptance: injected usage: saver hidden 30% -> freezes; 1% -> grace; playing 30% -> no; out of saver -> unchanged.
- Test phase: `swift test --filter BrowserHibernationSaverTests`; energy-saver with one hidden busy page.
- Size S. Depends: 024.

#### p14-energy-058 Power inputs off main; edge-only hop; no-battery Macs
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextEnergy/BatteryLevel.swift`,
  `.../CmuxNextEnergy/PowerSourceMonitor.swift`, `.../CmuxNextEnergy/EnergyMonitor.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextEnergyTests/BatteryLevelTests.swift`.
- Change: `notify_register_dispatch` on kIOPSNotifyPowerSource (and kIOPSNotifyPercentChange only while on battery) on a
  utility queue; percent = current/full capacity; hop to main only when onBattery or the below-20 flag flips; no
  IOPMPowerSource -> nothing registered, hasBattery false (settings hides onBattery).
- Acceptance: fake source: 30 percent changes 80->50% -> 0 main deliveries; 20->19% -> 1; AC->battery -> 1; desktop
  fake -> no registration, hasBattery false.
- Test phase: `swift test --filter BatteryLevelTests`; debug.energy on a fleet mini shows hasBattery=false.
- Size S. Depends: 021.

#### p14-energy-114 ghostty-next animation wakes follow the saver
- Files: `ghostty-next:src/renderer/Thread.zig`, `ghostty-next:src/apprt/embedded.zig`, `ghostty-next:include/ghostty.h`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyRuntime.swift`.
- Change: `ghostty_app_set_energy_saver(bool)`: in saver the custom-shader and kitty animation wake interval has a
  33 ms floor and scrollback compression runs at utility QoS; GhosttyRuntime forwards policy edges. Typing and output
  frames untouched. Coordinate with PL-ghostty.
- Acceptance: ghostty-next test: animated shader wakes no closer than 33 ms in saver; cmux fake runtime gets one call
  per edge.
- Test phase: ghostty-next CI; `swift test --filter Ghostty`; energy-saver with a custom shader.
- Size M. Depends: 024. Queue ghostty-next.

#### p14-energy-120 Sleep, wake and screen sleep
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextEnergy/SuspendWatch.swift`,
  `.../CmuxNextWakeups/EnergyPolicy.swift`, `.../CmuxNextDaemon/Connection/ConnectionHeartbeat.swift`,
  `.../CmuxNextDevices/DeviceHubSocket.swift`, `.../CmuxNextFeed/Wire/CloudFeedSource.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextEnergyTests/SuspendWatchTests.swift`.
- Change: observe willSleep, didWake, screensDidSleep, screensDidWake once; EnergyPolicy `suspended`, `screensAsleep`.
  Keepalive and poll owners stop on either. On didWake each socket reconnects once after NWPathMonitor reports a
  satisfied path, with 0-2 s jitter. screensAsleep counts as every window hidden.
- Acceptance: willSleep -> 0 pings; didWake + satisfied path -> exactly 1 reconnect per socket; screensDidSleep stops
  ambient frame clients.
- Test phase: `swift test --filter "SuspendWatch|Heartbeat|DeviceHub"`; signed-in with `pmset displaysleepnow`.
- Size M. Depends: 021, 023.

#### p14-energy-129 Energy Saver completeness
- Files: `release-notes/next/energy-saver.md`, `plans/cmux-next/action-surfaces.json`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/**`.
- Change: one curated highlight per release-notes/next/WRITING.md; settings page row for energy.saver (hides onBattery
  when hasBattery is false); action-surfaces export lists the two actions; localization audit for 022, 025, 026.
- Acceptance: highlight follows WRITING.md; row shows in Settings; export lists energy.saver.turnOffForNow and
  turnOnNow; audit in the commit.
- Test phase: `scripts/measure/export-action-surfaces.sh`; `cmux-ci capture <sha> --state scene:settings-energy`.
- Size S. Depends: 022, 025, 026.

#### p14-energy-134 WebTheme data-cmux-energy attribute
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Windows/WebTheme.swift`, `webviews/src/ui/theme/bootstrap.ts`.
- Change: the shared WebTheme bootstrap sets `data-cmux-energy="saver"` on saver edges, next to `data-cmux-motion`.
- Acceptance: a test: saver on -> attribute present in the bootstrap payload; off -> absent; no other bootstrap change.
- Test phase: `swift test --filter WebTheme`; `cd webviews && bun run check`.
- Size S. Depends: 024.

#### p14-energy-136 Fork bundle: one API bump, one build, one pin
- Files: `fork:include/cef_cmux.h`, `fork:<patches of 029, 037, 046, 048, 107, 124 and Q8>`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFForkFeatures.swift`, the CEF pin file.
- Change: collect every p14 fork patch on one integration branch, bump the fork API once, run one Chromium build, land
  one pin commit in cmux. Coordinate the pin with F2 and cef-layer.
- Integration branch (136): manaflow-ai/cef `cp/p14-energy-136` (ce852697). Base: the API 31 train
  `cp/p01-process-178` with the API 32 fence `cp/p03-rendering-042` merged in (31's
  `cmux_browser_resize_fence` gives way to 32's). On it: 037 (2 ms slice), 046 (absolute delayed work), 124
  (renderer pid), and `cmux_ui_thread_no_batches.patch`, which closes 037's open item: under the external
  pump `BrowserUIThreadScheduler` runs one task per `DoWork` instead of an 8 ms `kRunTasksByBatches` batch
  (`content/browser/scheduler/browser_ui_thread_scheduler.cc`, `SetCanRunTasksByBatches` only when the UI
  pump factory is not overridden). `CMUX_CEF_API_VERSION` 33 numbers them all
  (`CEFForkFeatures.p14BundleForkAPI`). Embedder cases `pump-slice` and `pump-delayed` are new.
  Still to merge before the one build: 029 (no fork patch yet; cmux binds it by symbol and gates it on 33),
  any Q8 fork patch (042-044) and 048's fork part if 048 finds one. 107 needs none. At the pin: this line has
  no API 28/29 (cmux.34's capture and renderer paths), so `rendererPathsForkAPI` (29) must not read 33 as
  having them; the in-process shim has no renderer-path exports today, so `rendererPaths` stays false.
- Acceptance: the fork header lists every new function under one API number; the pin commit names the fork build; the
  cmux side compiles against old and new API.
- Test phase: fork CI build; `cmux-ci build cmux --ref SHA`; idle-budget tabs-static and energy-saver.
- Size M. Depends: 029, 037, 046, 048, 107, 124, Q8 fork items. Queue fork.
- 037 notes (manaflow-ai/cef `cp/p14-energy-037`, 361b930f5db4 and 70565d658a58): the fork part clamps
  `MaxTimeSlice` to 2 ms and keeps `MessagePumpExternal::Run`'s loop over `DoWork` until the slice ends. That
  loop is the batch. Chrome's `MessagePumpCFRunLoopBase::RunWork` runs one `DoWork`, and on the browser UI
  thread that `DoWork` is an 8 ms batch (`kRunTasksByBatches`, on by default on Mac; `BrowserUIThreadScheduler`
  sets `SetCanRunTasksByBatches(true)`). An exit after the first `DoWork` would keep that 8 ms batch, or with
  batching off make one embedder pass per task. Open for 136: one `DoWork` can itself run an 8 ms batch, so the
  2 ms bound does not hold yet. Bound the UI thread's batch under the external pump (a fork patch to the batch
  duration, or no batching on that thread only). Do not use `--disable-features=RunTasksByBatches`, because
  child processes inherit it. cmux judges passes by the switch's 2 ms from fork API 26
  (`CEFPumpSchedule.pumpTimeSliceSwitchForkAPI`, the first API built on 066b083f), so 136 needs no cmux gate for 037.
- 043 notes (Q8 slot B; manaflow-ai/cef `cp/p14-energy-043`, 4ab03f16dd2b, on the bundle tip ce8526971c0b): patch
  `cmux_cpu_health_tracker_hidden_ui`. Location: `CpuHealthTracker`'s `cpu_probe_timer_`
  (chrome/browser/performance_manager/user_tuning/cpu_health_tracker.cc). `PerformanceDetectionManager` makes it on
  every desktop platform, with no feature gate, and it samples system CPU every 15 s (`kCPUSampleFrequency`) for
  Chrome's toolbar performance intervention button. With `--cmux-tabbed-windows` the tracker makes no `CpuProbe`
  (Chromium already handles a null probe), so it starts no timer. per_s from the source: CrBrowserMain 0.067 timer +
  0.067 reply, a ThreadPool worker 0.067 (`cpu_probe_mac.cc` `CpuProbeMac::Update`); after, 0. No API number and no
  cmux gate: cmux passes `cmux-tabbed-windows` for every fork API >= 1 (`CEFCpuHealthTrackerSwitchTests`). Not
  claimed here, because other branches have them: HangWatcher, sync and OptimizationHints (p13-webui-084), and the
  PartitionAlloc memory reclaimer (042).
- 044 notes (manaflow-ai/cef `cp/p14-energy-044`, 27a449ef65521e51, one commit on the bundle tip ce852697): patch
  `cmux_disk_space_check_backoff` (Q8 record below). It needs no API number and no cmux gate: the app makes no new call.
  Its test is `components_unittests --gtest_filter=MacSystemMemoryPressureEvaluatorTest.*`. 043 and 044 each add
  their patch after the same entry in `patch/patch.cfg` and in `CMUX.md`, so the two fork branches conflict there:
  136 keeps both entries, 043 first, then 044.

#### p14-energy-138 GlassModeWatch and BackdropVideoView follow EnergyPolicy
- Files: `.../CmuxNextApp/GlassModeWatch.swift`, `.../CmuxNextApp/AppServices+Glass.swift`,
  `.../CmuxNextDesign/BackdropVideoView.swift`, `.../CmuxNextDesign/WindowMaterialView.swift`.
- Change: the rest of 024's consumer list. `GlassModeWatch(energy:onChange:)` replaces its LowPowerMode input with
  `mainWork.energy`. `BackdropVideoPlayers` is built by the composition root once p11-codebase-039 removes `.shared`,
  and it pauses the video wallpaper under the saver instead of reading `ProcessInfo.isLowPowerModeEnabled`.
- Acceptance: `rg isLowPowerModeEnabled` in BackdropVideoView == 0; glass and backdrop tests pass with a saver case;
  Low Power Mode still applies through the saver's auto mode.
- Test phase: `swift test --filter "GlassLens|BackdropVideo"` on the fleet.
- Size S. Depends: 024, p11-codebase-039.

#### p14-energy-137 Daemon reads the power source itself
- Files: `cmux-tui/crates/cmux-tui-core/src/wake/power.rs`, `cmux-tui/crates/cmux-tui-core/src/wake/energy.rs`.
- Change: on macOS the daemon registers `notify_register_file_descriptor` for `com.apple.system.powersources.source`
  on the MaintenanceClock thread's kqueue (no extra thread, no polling) and reads on-battery and percent with
  IOPSCopyPowerSourcesInfo; the app's energy.set is an override. On Linux it reads nothing and follows the app.
- Acceptance: a test with a fake notify source: an AC->battery edge sets EnergyMode per the same rule as the app; an
  app override wins until cleared; no timed wait added.
- Test phase: `cargo test -p cmux-tui-core wake::power`; app-quit session.
- Size S. Depends: 033.

### Phase P3: CEF pump and Chromium idle cost

#### p14-energy-040 Chromium AlignWakeUps and BatterySaverModeAlignWakeUps on
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFSwitchesTests.swift`.
- Change: append `enable-features=AlignWakeUps,BatterySaverModeAlignWakeUps` (merged into CEF's list), with a comment
  citing task_features.h, message_pump_apple.mm and content_features.cc, why field-trial-config left them off, and why
  TimerSlackMac waits for 046. Confirm in the fork source which pump the UI thread uses and cite it.
- Acceptance: the switch test asserts both features for every fork API >= 27; no second enable-features entry; no
  TimerSlackMac before the 046 API.
- Test phase: `swift test --filter CEFSwitches`; tabs-static renderer, GPU and utility wakeups before and after.
- Size S.

#### p14-energy-041 cef-idle-probe emits CEF-IDLE-POSTED
- Files: `scripts/cmux-next/cef-idle-probe.py`, `scripts/cmux-next/tests/test_cef_idle_probe.py`.
- Change: print `CEF-IDLE-POSTED {"process","thread","location","per_s"}` sorted by per_s from the trace summary;
  `--queue` keeps per_s >= 0.02; prints the cmux pump counters for comparison.
- Acceptance: a recorded trace fixture: 3 locations above threshold in, 1 below out.
- Test phase: `python3 -I scripts/cmux-next/cef-idle-probe.py --help`; one split-spring --suite=cef-idle run.
- Size S.

#### p14-energy-109 Q8 on every Chromium thread and process
- Files: `scripts/cmux-next/cef-idle-probe.py`, `scripts/cmux-next/tests/test_cef_idle_probe.py`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift`.
- Change: `--queue` covers every browser-process thread (CrBrowserMain, ThreadPool workers, Chrome_IOThread) and the
  renderer (main, compositor), GPU (main, VizCompositor), network, storage and audio processes. Seed list to check
  against Chromium sources: Media Router discovery, component updater, GCM, Optimization Guide,
  NetworkQualityEstimator, SpareRenderProcessHostManager. Safe Browsing and CRLSet stay.
- Acceptance: parser test: ThreadPoolBackgroundWorker, NetworkService, renderer and GPU locations above threshold are
  in the queue, one below is not; each line names process and thread.
- Test phase: unit tests; split-spring --suite=cef-idle.
- Size S. Depends: 041. Queue Q8.

#### p14-energy-042 / 043 / 044 Q8 slots A, B, C
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift`, `fork:<per location>`.
- Change: all Q8 items fan out in parallel after one probe run; each slot takes the next unclaimed location: an
  existing switch/disable-features first (cites the Chromium file), else a fork patch into 136. One location per
  commit. Slot C also writes the closing record: tabs-static app main wakes, and which locations Chromium needs (so the
  F2 host carries them). Spawn more slots while items remain.
- Acceptance: each commit names its location and before/after per_s; no feature used by a visible surface is disabled
  without an equivalent (stated).
- Test phase: split-spring --suite=cef-idle before/after; idle-budget tabs-static `--gate`.
- Size M each. Depends: 109, 040. Queue Q8.

Q8 record (044, 2026-10-26). The rates come from the Chromium 154.0.8037.58 sources, not from a run: no probe run
existed when the slots started. The lead's fleet run (`split-spring --suite=cef-idle --vdisplay=120` with `--queue`,
then `idle-budget tabs-static --gate`) gives the measured values and adds a slot for each queue line that remains.

| Slot | Location (process, thread) | Fix | per_s before | per_s after |
| --- | --- | --- | --- | --- |
| 042 | `MemoryReclaimerSupport::Run` (each process with PartitionAlloc, main thread; the app's CrBrowserMain too) | switch `PartitionAllocAdaptiveMemoryReclaimInterval`, landed | 0.25 per process | 0.017 per process |
| 043 | `CpuHealthTracker`'s `cpu_probe_timer_` (chrome/browser/performance_manager/user_tuning/cpu_health_tracker.cc; browser: a timer task and a reply on CrBrowserMain, a `CpuProbeMac::Update` on a ThreadPool worker) | fork patch `cmux_cpu_health_tracker_hidden_ui` (043 notes in 136) | 0.067 each | 0 |
| 044 | `SystemMemoryPressureEvaluator::CheckDiskSpace` (browser: a timer task and a reply on CrBrowserMain, a statfs on a ThreadPool worker) | fork patch `cmux_disk_space_check_backoff` (044 notes in 136) | 0.2 each | 0.017 each with 60 GiB free, 0.0033 each with 300 GiB or more |

- tabs-static app main wakes from Chromium, these locations only: before about 0.78/s on CrBrowserMain (0.25 reclaim,
  0.067 CPU probe timer, 0.067 CPU probe reply, 0.2 disk timer, 0.2 disk reply). After 136 is pinned: about 0.024/s
  with 300 GiB or more free, about 0.05/s with 60 GiB free (the reclaim and the disk check; the CPU probe is 0). The
  fleet run replaces these numbers.
- Q8 locations that p13-webui-084 claims (manaflow-ai/cmux `cp/p13-webui-084`, d436f89d40f): `disable-sync`, and
  `disable-features=EnableHangWatcher,EnableHangWatcherOnGpuProcess` (a HangWatcher thread in each Chromium process
  wakes every 10 s, 0.1/s) and `disable-features=OptimizationHints`. That branch is pushed but is not on
  perf/chrome-parity when this record is written, so these locations still run on the base. No Q8 slot takes them;
  the fleet run counts them against 084. They are not on CrBrowserMain, so the totals above do not include them.
- Locations Chromium needs. They stay at the rates below. With the F2 host on, the browser-process ones run in the host,
  not on the app's main thread. 045 gives the host the same switches, and the fork patch is in the host's Chromium too.
  - Safe Browsing and CRLSet updates (section E). The component updater checks 1 min after start, then every 5 h
    (configurator_impl.cc).
  - PartitionAlloc reclaim at its adaptive interval: memory goes back to the system.
  - The disk space check at its adaptive interval: Chrome's critical memory pressure vote below 250 MiB free.
  - `BatteryStateSampler`: 1/min (base/power_monitor/battery_state_sampler.cc). Chrome's Battery Saver uses it.
    This is under the threshold.
- Q8 item kept at Chromium's rate: GPU process, `GpuWatchdogThread::OnWatchdogTimeout` on the GpuWatchdog thread
  every 25 s on Mac (0.04/s; `kGpuWatchdogTimeout`, gpu/ipc/common/gpu_watchdog_timeout.h). It kills and restarts a
  hung GPU process. An existing switch sets a longer period and keeps the watchdog: `GetGpuWatchdogTimeout`
  (gpu/ipc/service/gpu_watchdog_thread.cc) reads the `watchdog_timeout_seconds` param of
  `ConfigurableGPUWatchdogTimeout` (gpu/config/gpu_finch_features.cc) and `--gpu-watchdog-timeout-seconds`
  (gpu/config/gpu_switches.cc), which `GpuProcessHost` copies to the GPU process (content/browser/gpu/gpu_process_host.cc,
  `kSwitchNames`). It stays at 25 s for this reason: `OnWatchdogTimeout` kills the process only when the GPU main
  thread was armed with no progress for one whole period, so a hang is found 1 to 2 periods after it starts. Under the
  threshold needs a period above 50 s (60 s gives 0.017/s), and then every Chromium pane stays frozen 60 to 120 s
  before the GPU process restarts, instead of 25 to 50 s. The saving is 0.023 wakes/s on a GPU-process thread, not on
  the app's main thread. If the fleet run puts a GPU-process thread over its budget, the next slot passes
  `gpu-watchdog-timeout-seconds=60` with this trade-off in its commit.

#### p14-energy-045 Chromium Host: same switches and saver wire message
- Files: `Packages/macOS/CmuxNext/CEFShim/src/browser_host_main.mm`, `Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h`,
  `.../CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostSession.swift`,
  `.../CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostConfiguration.swift`.
- Change: the host gets the same CEFSwitches (040, Q8 disables; TimerSlackMac is safe there because it runs
  `CefRunMessageLoop`, Chrome's native pump) and a versioned wire message `energy_saver(bool)` that calls the 029 API in
  the host. Coordinate with F2.
- Acceptance: the message has a version field; the host ignores it below the fork API; a fake connection sees it on each
  edge.
- Test phase: tabs-static with the host flag on: cef-host <= chrome-static browser process.
- Size M. Depends: 029, 040, 004.

#### p14-energy-048 Chromium page visibility check and fix
- Files: `scripts/cmux-next/idle-budget.py`, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFPaneHost.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFTab+Freeze.swift`, `fork:<visibility API if needed>`.
- Change: in tabs-static, light-hidden, minimized and occluded, read `document.visibilityState` and a rAF counter over
  DevTools for every Chromium tab before the freeze grace ends. If a hidden tab, or the visible tab of a minimized or
  covered window, reports `visible`, add a fork/shim call (into 136) that sets WebContents HIDDEN or OCCLUDED from the
  pane host's visibility and window occlusion.
- Acceptance: the report has visibility_state per tab per session; in minimized, light-hidden and occluded every tab is
  `hidden`; a hidden unfrozen page runs no rAF and <= 1 timer wake/s.
- Test phase: idle-budget tabs-static, minimized, light-hidden, occluded.
- Size M. Depends: 003. Queue Q9.

#### p14-energy-107 Hidden Chromium renderers best-effort (fork, if needed)
- Files: `fork:content/browser/child_process_launcher_helper_mac.cc`, `fork:libcef/browser/cmux_process_priority.cc`,
  `Packages/macOS/CmuxNext/CEFShim/src/shim_process.mm`.
- Change: if 106 shows hidden renderers at foreground priority (for example the Mach task-port provider is not wired for
  cmux helpers), wire it so `Process::SetPriority(kBestEffort)` applies and `kUserBlocking` returns on show. If they
  are already backgrounded, record the evidence and change no code.
- Acceptance: the 106 role check passes for hidden renderers in tabs-static; a shown tab returns to foreground in the
  same run.
- Test phase: fork CI (136); tabs-static role rows.
- Size M. Depends: 106. Queue fork.
- Status: open. The acceptance is not met yet: no tabs-static run has given role rows. The note below is an
  unverified source reading, not evidence, and it does not close the task.
- Unverified source finding (2026-10-26, Chromium 154.0.8037.58, manaflow-ai/cef `cmux/8037`): the source suggests that
  no fork patch is needed. The task port is wired in content for every child, with no embedder seam:
  `RenderProcessHostImpl::OnChannelConnected` calls `ChildProcessTaskPortProvider::OnChildProcessLaunched`, the helper
  answers `GetTaskPort` with its own task (`content/child/child_thread_impl.cc`), and
  `ChildProcessLauncherHelper::SetProcessPriorityOnLauncherThread` (`child_process_launcher_helper_mac.cc`) calls
  `Process::SetPriority` with that provider (`CanSetPriority()` is true on Mac). cmux helpers run `CefExecuteProcess`
  (`helper_main.mm`). CEF does not override `IsRendererProcessPriorityEnabled` and neither CEF nor `CEFSwitches` passes
  `--disable-renderer-backgrounding`. `kUserVisibleProcessPriority` is off, so the Mac roles would be kBestEffort
  (hidden) and kUserBlocking (shown). Visibility comes from the native view (Chrome style:
  `ChromeBrowserHostImpl::WasHidden` is NOTIMPLEMENTED). `idle-wakeups.md` sec. 7 measured `document.visibilityState`
  and wakeups of hidden tabs, not task roles or base priority, so it does not show that hidden renderers are
  kBestEffort. Two known causes can leave a hidden renderer in the foreground: AMFI allow-everything on the host
  (Chromium then logs "will not collect child process task ports"; check `nvram boot-args`), and a page that does not
  report hidden (048).
- What the bench now measures (idle-budget.py): in tabs-static only (`judge_shown_renderers`), the window's role read
  judges hidden renderers best-effort and the renderers the census marks shown (Home, the shown tab) `not-background`.
  After the window, the `reshow` step selects a hidden Chromium tab that was read best-effort (tab.focus), reads the
  roles again until its renderer is `not-background` and the tab shown before is best-effort (10 s at most), and
  prints `IDLE-BUDGET-OVER tabs-static cef-renderer role ... phase=reshow` for each renderer that does not change.
- To close: one fleet run of `scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions
  tabs-static,minimized`, attached here with `nvram boot-args` from the same host. It must show the hidden renderer
  pids with observed `suppressed` or `darwinbg`, the shown ones with observed `default`, the `IDLE-BUDGET-RESHOW` record
  with the reshown tab back at `default`, and no role over. If a hidden renderer stays in the foreground with neither
  known cause, or the reshown one does not come back, this task gets the fork patch.

#### p14-energy-108 Built-in uBlock Origin idle cost
- Files: `scripts/cmux-next/bundle-ublock.sh`, `scripts/cmux-next/fetch-ublock.sh`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFBuiltInExtensions.swift`, `plans/cmux-next/idle-wakeups.md`.
- Change: measure cef-extension in tabs-static; profile its timers through cef-idle-probe (extension DevTools target);
  remove idle periodic work with uBO admin settings in the bundle (asset updates >= 1 h via alarms, no rewrite of
  unchanged caches). If still above 0.1/s, record the remaining owner and the option of MV3 uBO Lite in saver.
- Acceptance: cef-extension wakeups/s before and after in the commit; tabs-static cef-extension <= 0.1/s or the named
  remaining owner.
- Test phase: idle-budget tabs-static, chrome-static.
- Size M. Depends: 104, 041. Queue Q9.

#### p14-energy-124 Per-tab renderer attribution
- Files: `fork:include/cef_cmux.h`, `Packages/macOS/CmuxNext/CEFShim/src/shim_browser.mm`,
  `.../CmuxNextBrowser/CEF/CEFShimABI.swift`, `.../CmuxNextWakeups/ProcessUsage.swift`,
  `.../CmuxNextControl/Diagnostics/BusyWatchdog.swift`, `.../CmuxNextControl/Diagnostics/EnergyReport.swift`,
  `.../CmuxNextApp/Control/DebugWakeups.swift`.
- Change: fork API `cmux_cef_browser_renderer_pid(browser_id)` (RenderProcessHost handle) into 136; ProcessUsage groups
  renderer CPU, wakeups and energy per tab; debug.energy lists tabs; a BusyWatchdog record names the tabs of a busy
  renderer.
- Acceptance: shim test with a fake fork returns the pid; two tabs sharing one renderer both show its usage and the
  record names both.
- Test phase: fork CI (136); `swift test --filter "ProcessUsage|BusyWatchdog"`; debug.energy on tabs-static.
- Scope: in process. With the Chromium Host on, the renderers are the host's children: the remote shim answers no
  pid and no tab lists a renderer until 124a. The busy watchdog reads a tab snapshot the App publishes (a tab's
  mount and load-phase changes), never the main actor.
- Size M. Depends: 007. Queue fork.

#### p14-energy-124a Per-tab renderer attribution with the Chromium Host on
- Files: `plans/cmux-next/chromium-host-ops.json`, `Packages/macOS/CmuxNext/ChromiumHost/client/remote_shim.mm`
  (generated), `.../CmuxNextBrowser/CEF/CEFTab+Processes.swift`, `.../CmuxNextApp/Control/DebugWakeups.swift`.
- Change: `cmux_shim_renderer_pid` becomes an async op the host answers with its shim's pid (the reply path of
  p01-process-022, like `cmux_shim_renderer_client_ids`); `AppProcesses.sample` and `chromiumHelpers` list the
  Chromium Host's children next to the app's, classified by `ChromiumHelperProcess`.
- Acceptance: with the host on, two tabs on one renderer both show its usage in debug.energy `tabs` and a busy
  renderer's record names both.
- Test phase: `swift test --filter "ProcessUsage|BusyWatchdog|CEFTabRendererPID"`; debug.energy on tabs-static
  with the host flag on.
- Size M. Depends: 124, p01-process-022. Queue none.

#### p14-energy-125 High-energy tab badge with Discard
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabHoverCard+Energy.swift`,
  `.../CmuxNextApp/Hibernation/HighEnergyTabs.swift`, `.../CmuxNextTabs/Localizable.xcstrings`.
- Change: no timer of its own; at natural wakes a hidden tab whose attributed renderer used > 5% CPU over the last 60 s
  shows "Using high energy" in its hover card with Discard (BrowserHibernation's discard). Visible tabs are never
  flagged (Chrome PerformanceDetectionManager CPU rule).
- Acceptance: injected usage: hidden 8% flagged, 3% not, visible never; strings localized; no new DemandTimer.
- Test phase: `swift test --filter HighEnergyTabs`; `cmux-ci capture --state scene:high-energy-tab`.
- Size M. Depends: 124.

#### p14-energy-128 Chromium Host App Nap while all pages hidden
- Files: `Packages/macOS/CmuxNext/CEFShim/src/browser_host_main.mm`, `Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h`,
  `.../CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostSession.swift`.
- Change: wire message `visibility(visible_count)`; the host holds `NSActivityUserInitiatedAllowingIdleSystemSleep` only
  while a page shows and lets App Nap apply when every page is hidden.
- Acceptance: fake connection: 1 begins the activity, 0 ends it, repeats do not churn; a visible page keeps rAF at
  display rate with the app idle.
- Test phase: tabs-static with the host on: cef-host napped when all hidden (106 rows).
- Size S. Depends: 045, 106.

### Phase P4: hidden and idle cost zero

#### p14-energy-050 Home FrameTick through FrameScheduler
- Files: `Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/FrameTick.swift`,
  `.../MessagesLabHome/Cmux/PaneHost.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextHome/**`.
- Change: FrameTick takes an injected `FrameTickSource`; CmuxNext Home passes an adapter over `FrameScheduler.forView`
  (a .motion client: Home typing is key->frame). Standalone MessagesLab keeps its own link behind an escape.
- Acceptance: `rg -n 'displayLink\(target:' Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux` returns 0 on
  the cmux path; Home typing lands at frame start (existing PaneHost test).
- Test phase: `swift test --filter Home`; bench-typing home unchanged.
- Size S. Queue Q11.

#### p14-energy-051 FlightRecorder only while enabled
- Files: `Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/FlightRecorder.swift`.
- Change: the sampling link and the 60 Hz burst timer start only when `FlightRecorder.enabled` and stop at settle;
  both lines `// wakeup-allow: debug FlightRecorder.enabled only`.
- Acceptance: enabled == false -> kick() and burst() create no link and no timer (test); lines escaped.
- Test phase: `swift test --package-path Packages/Shared/CmuxMessagesLab` on the fleet.
- Size S. Queue Q2.

#### p14-energy-052 NativeScroll one-shot timers
- Files: `Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/NativeScroll.swift`.
- Change: the 3 one-shot `Timer.scheduledTimer` (expand, show, hide) use an injected one-shot scheduler that CmuxNext
  backs with DemandTimer; the standalone default sets `.tolerance` = max(8 ms, 10%) with `wakeup-allow: deadline`.
- Acceptance: each site uses the seam or sets tolerance; no repeating timer.
- Test phase: `swift test --package-path Packages/Shared/CmuxMessagesLab`.
- Size S. Queue Q2.

#### p14-energy-053 Materials fade as a CA animation
- Files: `Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Materials.swift`.
- Change: replace the per-fade display link with a CA opacity animation (render server) gated through the host's motion
  switch (an injected gate; with motion off the change applies in one frame).
- Acceptance: `rg -n 'displayLink\(target:' .../Materials.swift` returns 0; motion-off test applies at once.
- Test phase: `cmux-ci build cmux --ref SHA`; Home gallery entry.
- Size S. Queue Q11.

#### p14-energy-054 Replace didUpdateNotification observers
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextRemoteBrowser/Pane/RemoteBrowserSurfaces.swift`,
  `.../CmuxNextApp/Windows/WindowOverlayLayer.swift`, `.../CmuxNextDesign/Overlay/WindowOverlayHost.swift`.
- Change: observe only what each needs: frame (didResize/didMove), key state, occlusion, contentView KVO, layout
  callbacks.
- Acceptance: `rg -n 'didUpdateNotification' Packages/macOS/CmuxNext/Sources` returns 0; a key press with no geometry
  change runs no overlay sync (counter test).
- Test phase: `swift test --filter "Overlay|RemoteBrowser"`.
- Size M. Queue Q7.

#### p14-energy-055a / 055b / 055c Q5 tracking areas
- Files: 055a `CmuxNextSidebar/**`; 055b `CmuxNextDesign/**`, `CmuxNextTabs/**`; 055c `CmuxNextBrowser/**`,
  `CmuxNextPalette/**`, `CmuxNextTerminal/**`, `CmuxNextMacScreen/**`, `CmuxNextLayout/**`, `CmuxNextHomeEngine/**`,
  `CmuxNextHome/**` (under Packages/macOS/CmuxNext/Sources).
- Change: `.activeAlways` -> `.activeInActiveApp` unless hover must work while cmux is inactive; then keep it with
  `// wakeup-allow: bounded <why hover in an inactive app>`. Terminal mouse reporting and Chromium page hover keep it.
- Acceptance: wakeup-audit reports 0 unescaped `.activeAlways` in the slot's modules (055c: in all Sources).
- Test phase: `swift test --filter` for the modules.
- Size S each. Depends: 006. Queue Q5.

#### p14-energy-056 LoopVisibility for infinite CA loops
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/Motion+AppKit.swift`,
  `.../CmuxNextDesign/Motion/LoopVisibility.swift`, `.../CmuxNextDesign/NightSky/NightSkyView.swift`,
  `.../CmuxNextDesign/Motion/Motion+Wiggle.swift`, `.../CmuxNextSidebar/Views/SidebarNowPlayingControls.swift`.
- Change: one adapter per window observes occlusionState, miniaturize and app hide once; removes and re-adds registered
  loop animations. All 10 CmuxNext `repeatCount = .infinity` sites register. It exposes a `LoopHost` protocol for 115.
- Acceptance: fake window: visible -> hidden removes the keys; visible re-adds; an rg check in the test that all 10
  sites register.
- Test phase: `swift test --filter LoopVisibility`; minimized session: app 0 frames.
- Size M. Depends: 027. Queue Q7.

#### p14-energy-057 Sleepy clock per minute
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/SleepyMode/SleepySceneView.swift`,
  `.../CmuxNextSidebar/Views/WorkspaceHoverCard.swift`.
- Change: TimelineView(.periodic(by: 1)) -> .everyMinute; workingAgents is observed, not polled per tick;
  WorkspaceHoverCardTimelineView has no periodic schedule.
- Acceptance: `rg -n 'TimelineView\(\.(periodic|animation)' Packages/macOS/CmuxNext/Sources` returns 0.
- Test phase: `cmux-ci build cmux --ref SHA`; Sleepy Mode capture.
- Size S. Queue Q7.

#### p14-energy-059 Hidden WebKit browser tabs hidden to WebKit
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/WebKit/WebKitTab.swift`,
  `.../CmuxNextBrowser/WebKit/WebKitPageContainer.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/WebKitHiddenTabTests.swift`.
- Change: step 1: measure per-tab wakeups in tabs-static (today 11/s; may be the WebKit GPU process); step 2: set
  `isHidden` on a hidden tab's WKWebView (WebKit's ActivityState::IsVisible) and measure; step 3 only if > 0.5/s
  remains: detach from the window, reattach before the switch commit. Tabs with audio or capture stay visible.
- Acceptance: hidden tab -> WebKit reports hidden (visibilityState via evaluate); show causes no reload (delegate
  counters); an audio tab stays visible; instant-switch first-frame p95 not worse.
- Test phase: tabs-static per webkit-browser-tab <= 0.5/s; `swift test --filter WebKitHiddenTab`; instant-switch bench.
- Size M. Depends: 003. Queue Q9.

#### p14-energy-060 webviews pageClock
- Files: `webviews/src/ui/pageClock.ts`, `webviews/src/ui/useNow.ts`, `webviews/test/pageClock.test.ts`.
- Change: one setTimeout chain per page and granularity (1 s or 60 s) aligned to the next boundary; ref-counted;
  stops when hidden or unsubscribed; fires once on visible. `// wakeup-allow: bounded page clock, visible and subscribed only`.
- Acceptance: fake timers: 5 subscribers at 1 s -> 1 timer; hidden -> 0; aligned; `bun run check` passes.
- Test phase: `cd webviews && bun run check && bun test test/pageClock.test.ts`.
- Size S. Queue Q3.

#### p14-energy-061 Q3 clocks onto useNow
- Files: `webviews/src/agent-session/acpmux/conversation/WorkingFor.tsx`, `.../conversation/ActivityLine.tsx`,
  `webviews/src/pages/home-channels/RunCard.tsx`, `.../newtab/NowPlayingPlayer.tsx`, `.../newtab/NewTabExtras.tsx`,
  `.../subagents/SubagentGroup.tsx`, `webviews/src/pages/chief-views/ChiefViewsPage.tsx`,
  `.../run-board/variants/timeline/TimelineRunBoard.tsx`.
- Change: each setInterval clock uses useNow; elapsed labels switch to 60 s granularity at >= 60 s.
- Acceptance: `rg -n 'setInterval\(' <these 8 files>` returns 0; gallery entries render (gallery compare attached).
- Test phase: `bun run check`; `scripts/gallery-compare.sh`.
- Size M. Depends: 060. Queue Q3.

#### p14-energy-062a / 062b Q3 polls
- Files: 062a `webviews/src/diff-viewer/freshness.ts`, `.../chips/pullRequestStore.ts`, `webviews/src/optchat-inspector/store.ts`;
  062b `.../run-board/RunBoard.tsx`, `.../variants/compare/CompareRunBoard.tsx`, `.../harnesses/HarnessesScreen.tsx`,
  `.../acpmux/streamDebug.ts`.
- Change: host push where the host has one; else poll only while visible on pageClock at 60 s with one check on
  visible. streamDebug: `wakeup-allow: debug stream debug panel open only`.
- Acceptance: no setInterval in these files (062b: `rg -n 'setInterval\(' webviews/src -g '!**/gallery/**'` only escaped);
  a test shows no timer while hidden.
- Test phase: `bun run check && bun test`.
- Size S each. Depends: 060. Queue Q3.

#### p14-energy-063 Q3 CSS infinite static under saver and motion off
- Files: `webviews/src/styles.css`, `webviews/src/ui/wave.css`, `.../conversation/conversation.css`,
  `.../harnesses/harnesses.css`, `webviews/src/prototypes/subagents/subagents.css`.
- Change: every `infinite` selector gets `:root[data-cmux-energy="saver"]` and `:root[data-cmux-motion="off"]` rules with
  `animation: none` and the static state.
- Acceptance: each of the 25 declarations has a matching override (a test counts them); gallery shows the static saver
  state.
- Test phase: `bun run check`; `scripts/gallery-compare.sh`.
- Size S. Depends: 134. Queue Q3.

#### p14-energy-064 DaemonConnection heartbeat silence-based and visibility-aware
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/ConnectionHeartbeat.swift`,
  `.../CmuxNextDaemon/Connection/DaemonConnectionConfiguration.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/StoppedOwnerTests.swift`.
- Change: identify only after `interval` with no inbound frame (10% leeway). 15 s while a window is visible or a request
  waits; 60 s flexible while hidden for connections with a notification stream (bridge/remote: a lost server over a
  closed lid must still be found); none for other hidden connections; one identify at activation or window show.
  Visibility is injected by the App (the Daemon target knows no windows).
- Acceptance: StoppedOwnerTests pass (wedged owner found within 30 s while visible); hidden and idle 60 s with no stream
  -> 0 identifies; hidden with a stream -> 1 per 60 s; inbound traffic every 5 s -> 0; activation -> 1.
- Test phase: `swift test --filter "StoppedOwner|Heartbeat"`.
- Size M. Depends: 012. Queue Q6.

#### p14-energy-065 BusyWatchdog flexible window end
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/BusyWatchdog.swift`.
- Change: the DemandTimer that ends a 10 s window is flexibleNoSooner with 10 s leeway on MainWakeUpQueue; the window is
  judged with real elapsed time.
- Acceptance: with no other wake the end fires at most once per 20 s; rates use elapsed time; ledger
  BusyWatchdog.window 0.0 in light.
- Test phase: `swift test --filter BusyWatchdog`; light ledger.
- Size S. Depends: 014. Queue Q9.

#### p14-energy-066a ErrorJournal harvest on NSBackgroundActivityScheduler
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/ErrorJournal/ErrorJournalService.swift`.
- Change: replace the 300 s loop with NSBackgroundActivityScheduler (interval 300, tolerance 120, .background, repeats);
  the block runs a Sendable harvest only when the journal folder changed (FolderWatch flag) and posts one main-actor
  intent; pause by invalidate/recreate.
- Acceptance: `rg -n 'sleep\(' ErrorJournalService.swift` returns 0; fake scheduler: no folder change -> body not
  called; TSan clean.
- Test phase: `swift test --filter ErrorJournal` (also with thread sanitizer).
- Size S. Queue Q6.

#### p14-energy-066b GitHub feed on NSBackgroundActivityScheduler
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextFeed/GitHubFeedSource.swift`.
- Change: scheduler with the configured interval, 25% tolerance, pollStretch; invalidated while no feed surface shows,
  recreated with one refresh on show; the block posts a main-actor intent.
- Acceptance: no periodic sleep loop; tests for hidden pause, show refresh, saver stretch; TSan clean.
- Test phase: `swift test --filter GitHubFeed`.
- Size S. Depends: 032. Queue Q6.

#### p14-energy-066c DeviceHub ping, lease renewal, triage
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextDevices/DeviceHubSocket.swift`,
  `.../CmuxNextHomeEngine/Router/ModelRouterLease.swift`, `.../CmuxNextApp/Cloud/CloudAccessAsks.swift`.
- Change: ping only after pingInterval of silence in both directions, 10% leeway; lease renewal a flexible DemandTimer at
  expiry minus margin; triage a bounded DemandTimer loop with leeway. What stays goes into allowed_periodic.
- Acceptance: `rg -n 'wakeup-allow:.*(ping interval|keepalive period)' Packages/macOS/CmuxNext/Sources/CmuxNextDevices`
  returns 0; traffic every 5 s -> 0 pings.
- Test phase: `swift test --filter "DeviceHub|ModelRouterLease|CloudAccess"`.
- Size S. Depends: 012. Queue Q6.

#### p14-energy-067a..f Q2 Shared packages
- Files: 067a `Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/**`; 067b `Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/**`;
  067c `Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/**`; 067d `Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/**`;
  067e `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/**`; 067f `Packages/Shared/{CmuxVNC,CmuxScreenKit,CmuxInstallAuthCore,CmuxMessagesLab}/Sources/**`.
- Change: each hit becomes an event (NWPathMonitor, connection state), a bounded Backoff with tolerance, or a
  closed-vocabulary escape with tolerance. 067b: Mock sources excluded only if not linked into the release app
  (verify). 067d: update cadence on NSBackgroundActivityScheduler or a flexible deadline. 067f: VNCDemoServer timer
  `fixture`.
- Acceptance: wakeup-audit `--queue` lists 0 unescaped hits in the slot's packages; 067f: `--strict` passes for all
  app-linked Shared packages.
- Test phase: `swift test --package-path <package>` on the fleet; 067f `cmux-ci build cmux --ref SHA`.
- Size 067a M, others S. Depends: 005 (067f also 050, 051, 052, 053). Queue Q2.

#### p14-energy-068 Ghostty cursor blink on the render server
- Files: `ghostty-next:src/renderer/Thread.zig`, `ghostty-next:src/renderer/generic.zig`, `ghostty-next:src/renderer/Metal.zig`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalSurfaceView.swift`.
- Change: a blinking cursor is drawn into its own CALayer sublayer whose opacity runs a CA keyframe animation with the
  blink period; the renderer's blink timer and per-tick rebuild go away for that mode; focus and visibility rules stay.
  With PL-ghostty.
- Acceptance: renderer-wakeup counter 0 over 10 s for a focused idle blinking cursor; a new TerminalIdleCursorFrameTests
  case red before, green after.
- Test phase: ghostty-next CI; `swift test --filter TerminalIdleCursorFrameTests`; light with a focused terminal.
- Size L. Queue ghostty-next.

#### p14-energy-069 Ghostty blink timeout fallback behind a setting
- Files: `ghostty-next:src/renderer/Thread.zig`, `Packages/macOS/CmuxNext/Sources/CmuxNextSettings/**`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TerminalIdleCursorFrameTests.swift`.
- Change: after `terminal.cursorBlinkTimeout` (default 15 s, 0 = never) with no key or output the blink stops and the
  cursor stays solid; input or output restarts it. Lands only if 068 is not ready by hour 48. With PL-ghostty.
- Acceptance: a focused visible blinking cursor draws 0 frames from 16 s to 26 s at rest (red before); a key restarts
  the blink; the setting at 0 keeps today's behavior; strings localized.
- Test phase: ghostty-next CI; `swift test --filter TerminalIdleCursorFrameTests`.
- Size S. Queue ghostty-next.

#### p14-energy-110 webviews self-loop rule and fixes
- Files: `scripts/cmux-next/wakeup-audit.py`, `webviews/src/agent-session/acpmux/conversation/backgroundTaskOutput.ts`,
  `webviews/src/agent-session/acpmux/links.ts`, `webviews/src/ui/glass/lens.ts`,
  `webviews/src/agent-session/acpmux/layoutWatch.ts`, `webviews/src/agent-session/acpmux-preview/PreviewApp.tsx`.
- Change: web rule: a function passing itself to setTimeout or requestAnimationFrame in its own body is a hit unless
  escaped `bounded <deadline>`. backgroundTaskOutput.ts:148 (1.2 s poll, also hidden): host push, or pageClock only
  while visible. links.ts:103/139 (REVEAL_WAIT_MS) and lens.ts (STABLE_FRAMES) get `bounded` escapes; layoutWatch and
  PreviewApp `debug`. Every other self-loop among the 35 rAF files gets a fix or an escape.
- Acceptance: `wakeup-audit --lang web --queue` lists 0 unescaped self-loops; backgroundTaskOutput schedules no timer
  while hidden (test); `bun run check` passes.
- Test phase: `bun run check && bun test`; `test_wakeup_audit.py`.
- Size S. Depends: 005, 060. Queue Q3.

#### p14-energy-113 wakeup-audit for CEFShim and ghostty-next
- Files: `scripts/cmux-next/wakeup-audit.py`, `scripts/cmux-next/guardrails.py`, `scripts/cmux-next/tests/test_wakeup_audit.py`.
- Change: `--lang cxx` over `Packages/macOS/CmuxNext/CEFShim/src`: dispatch_after, NSTimer, CFRunLoopTimer,
  PostDelayedTask/CefPostDelayedTask, sleep_for/usleep, `for (;;)`/`while (true)` with no blocking read within 3 lines.
  `--lang zig` over ghostty-next/src when checked out: xev.Timer .run/.reset, std.Thread.sleep (report-only, to
  PL-ghostty). The cxx rule feeds the 006 guardrail.
- Acceptance: on the checkout CEFShim has 0 timers and the ReadWire loop in browser_host_main.mm is reported as blocking;
  the Zig report lists render_h, cursor_h, compression, termio scroll/coalesce/sync_reset, search refresh, Exec termios.
- Test phase: `test_wakeup_audit.py`.
- Size S. Depends: 005.

#### p14-energy-115 Infinite loops in Shared packages and SwiftUI loop effects
- Files: `Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Motion/Animate.swift`,
  `Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Vendor/appkit-native/SidebarDrawing.swift`,
  `.../MessagesLabHome/Vendor/catalyst/Transcript.swift`, `.../MessagesLabHome/Vendor/appkit-native/Compose.swift`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/UpdateSheetView.swift`, `scripts/cmux-next/wakeup-audit.py`.
- Change: the 7 Shared loops take an injected `LoopHost` (register/unregister, static in saver) that CmuxNext backs with
  LoopVisibility (056). The audit rule covers `symbolEffect(` with isActive/repeating (UpdateSheetView:105/108) and
  indeterminate `ProgressView()`/`startAnimation(` (ScreenSessionView:188); those stop while their window is not
  visible.
- Acceptance: wakeup-audit reports 0 unescaped infinite loops in app-linked Shared targets; a Home loop is removed when
  the fake window occludes.
- Test phase: `swift test --package-path Packages/Shared/CmuxMessagesLab` and `.../CmuxHomeRender`; home session.
- Size M. Depends: 056, 005. Queue Q7.

#### p14-energy-116 cmux's own WKWebViews hidden to WebKit
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneView.swift`,
  `.../CmuxNextPages/PageWebView.swift`, `.../CmuxNextAgentActivity/AgentActivityHostView.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextPagesTests/PageHiddenTests.swift`.
- Change: when the page's host is hidden (parked tab, hidden workspace, minimized window) the WKWebView is hidden to
  WebKit (isHidden first, as 059), so `document.visibilityState` is hidden; shown in the same turn. A PageWebView whose
  engine is Chromium creates its fallback WKWebView lazily.
- Acceptance: hidden agent pane page reports hidden (evaluate); a Chromium-shown PageWebView has no WKWebView (or no
  web process); show restores without reload.
- Test phase: `swift test --filter "PageHidden|AgentPane"`; agent-idle and light: webkit-app-page <= 0.5/s per hidden page.
- Size M. Depends: 103, 104. Queue Q9.

#### p14-energy-119 Hidden terminal output batched to 1/s
- Files: `cmux-tui/crates/cmux-tui-core/src/surface/terminal_stream.rs`, `cmux-tui/crates/cmux-tui-core/src/surface/attach.rs`,
  `Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Terminal/TerminalAttachment.swift`.
- Change: when every view of an attachment is hidden (the daemon learns it through SetSizeCountsRequest counts:false),
  the writer batches and flushes at most once per 1 s (4 s in saver) or at 256 KB; bells, OSC notifications, title
  changes and exit flush at once; show flushes in the same turn.
- Acceptance: paused-clock test: 50 writes in 1 s to a hidden attachment give 1 frame; a bell is immediate; show flushes
  the rest; a visible attachment is unchanged.
- Test phase: `cargo test -p cmux-tui-core terminal_stream`; busy-hidden app <= 2/s; bench-typing unchanged.
- Size M. Depends: 103.

#### p14-energy-121 Q12 network idle: silent sockets
- Files: `scripts/cmux-next/idle-budget.py`, `Packages/macOS/CmuxNext/Sources/CmuxNextFeed/Wire/CloudFeedSource.swift`,
  `.../CmuxNextCloud/Hands/HandApprovalWire.swift`, `workers/device-hub/`, `workers/presence/`.
- Change: for each persistent WebSocket (DeviceHubSocket, CloudFeedSource, HandApprovalWire, iroh relay) the client
  pings only after a silence budget and the server does not ping an idle client more often (Durable Objects answer with
  hibernation auto-response). What stays goes into allowed_periodic.
- Acceptance: signed-in has no `IDLE-BUDGET-OVER owner=network`; each changed socket has a test: traffic every 5 s with a
  15 s budget -> 0 pings.
- Test phase: idle-budget signed-in; worker tests for changed workers.
- Size M. Depends: 102, 105. Queue Q12.

#### p14-energy-122 Phone Access iroh endpoint only when usable
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextPhoneAccess/MobileHostService.swift`,
  `.../CmuxNextMobile/Host/MobileIrxHost+Endpoint.swift`,
  `Packages/macOS/CmuxNext/Tests/CmuxNextPhoneAccessTests/MobileHostBindTests.swift`.
- Change: bind only while a phone is paired (MobileHostHistory not empty) or the pairing page is open; measure the bound
  endpoint's keepalive and record it in allowed_periodic.
- Acceptance: signed in, Phone Access on, no phone -> no endpoint; pairing page open -> one; first pairing keeps it;
  signed-in with no phone has no IrohLib thread.
- Test phase: `swift test --filter MobileHostBind`; signed-in.
- Size S. Depends: 102.

#### p14-energy-126 Visible ambient indicators step at <= 30 Hz
- Files: `webviews/src/ui/pageClock.ts`, `webviews/src/ui/ambientStep.ts`, `webviews/src/styles.css`, `webviews/src/ui/wave.css`,
  `webviews/src/agent-session/acpmux/conversation/conversation.css`.
- Change: ambient loops in cmux's own pages (working spinner, shimmer, wave) step from pageClock at 15-30 Hz (a data
  attribute or custom property on an aligned timer) or use an animated image; stop when hidden; person-started motion
  unchanged.
- Acceptance: agent-working-visible app+cef-renderer+cef-gpu <= 35/s (before number in the commit); gallery compare
  shows the same frames.
- Test phase: `bun run check`; `scripts/gallery-compare.sh`; agent-working-visible.
- Size M. Depends: 060, 103. Queue Q3.

#### p14-energy-127 Watchers driven by other apps pause or stretch
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/FileExplorer/FileTreeWatcher.swift`,
  `.../CmuxNextApp/AgentRecents/ChatsFeed.swift`, `.../CmuxNextBrowserImport/Import/ImportHistorySync.swift`,
  `.../CmuxNextWakeups/FolderChanges.swift`.
- Change: a watcher whose output no visible surface shows stops (a hidden workspace's file tree) and catches up once on
  show; others coalesce through a flexible DemandTimer with 10% leeway times pollStretch. AgentTurnStateFeed stays live.
- Acceptance: hidden file tree gets 0 callbacks for 100 writes and 1 refresh on show; ImportHistorySync delay 4x in saver.
- Test phase: `swift test --filter "FileTreeWatcher|ImportHistorySync|ChatsFeed"`; external-churn app <= 1/s.
- Size M. Depends: 102, 024.

### Phase P5: Rust daemon and acpmux

#### p14-energy-038 Background process priority for idle acpmux helpers
- Files: `cmux-tui/crates/cmux-tui-platform/src/process_priority.rs`, `cmux-tui/crates/acpmux/src/hub/pool/mod.rs`,
  `cmux-tui/crates/acpmux/src/daemon.rs`.
- Change: `process_priority::set_self(BestEffort|UserVisible)`: macOS `setpriority(PRIO_DARWIN_PROCESS, 0,
  PRIO_DARWIN_BG)`; Linux nice 10. Applied to pooled and prewarmed agents until assigned and to acpmux with no attached
  session; reverted in the same turn on assignment or attach. Not for terminal hosts or holders. Tell PL-acpmux.
- Acceptance: macOS test reads back background after BestEffort and not after UserVisible; the pool assigns only after
  the revert; call-site list in the commit.
- Test phase: `cargo test -p cmux-tui-platform process_priority && cargo test -p acpmux pool`; light acpmux before/after.
- Size S. Depends: 070.

#### p14-energy-070 acpmux: owner lands pl-acpmux-audit; remove the 1 s wait poll
- Files: `cmux-tui/crates/acpmux/src/server/wait.rs`, `cmux-tui/crates/acpmux/src/hub/watch.rs`.
- Change: send PL-acpmux a request to land origin/pl-acpmux-audit (34 files, +2301/-288; it replaces the 400 ms watch
  POLL with the notify crate). Do not cherry-pick. On top of the owner's land: the wait wakes only on hub events and its
  deadline (remove the 1 s re-evaluate poll, wait.rs:174 on the branch).
- Acceptance: after the owner's land, `rg -n 'from_millis\(400\)|from_millis\(1000\)' cmux-tui/crates/acpmux/src/hub/watch.rs cmux-tui/crates/acpmux/src/server/wait.rs`
  returns 0; 010 tests green.
- Test phase: `cargo test -p acpmux` on macOS and Linux.
- Size S. Depends: 010. Queue Q4.

#### p14-energy-071 acpmux pool RSS cap without ps
- Files: `cmux-tui/crates/acpmux/src/hub/pool/reaper.rs`, `cmux-tui/crates/cmux-tui-platform/src/process_resources.rs`.
- Change: tree_rss_bytes via libproc (proc_listchildpids + proc_pid_rusage phys_footprint) on macOS and /proc on Linux;
  no fork/exec; the cap check runs on MaintenanceClock once for all entries.
- Acceptance: `rg -n '"ps"' cmux-tui/crates/acpmux/src/hub/pool` returns 0; a unit test sums a fake child tree.
- Test phase: `cargo test -p acpmux pool`.
- Size S. Depends: 020, 070. Queue Q4.

#### p14-energy-072 acpmux leader exit by NOTE_EXIT / pidfd
- Files: `cmux-tui/crates/acpmux/src/agent.rs`, `cmux-tui/crates/cmux-process/src/child.rs`.
- Change: replace LEADER_CHECK (still on the owner's branch) and try_wait with an exit future (kqueue EVFILT_PROC
  NOTE_EXIT; pidfd on Linux; the waitid thread as fallback), selected with the stdout lines.
- Acceptance: `rg -n 'LEADER_CHECK' cmux-tui/crates/acpmux/src` returns 0; the leader-exit-with-descendant-stdout test
  passes.
- Test phase: `cargo test -p acpmux agent`.
- Size S. Depends: 070. Queue Q4.

#### p14-energy-074 acpmux peer ping and hand keepalive after silence
- Files: `cmux-tui/crates/acpmux/src/peer.rs`, `cmux-tui/crates/acpmux/src/hand/link.rs`.
- Change: the ping/keepalive deadline resets on every frame either way; fires after ping_every/KEEPALIVE of silence with
  10% slack; dead-path logic unchanged. Replaces `interval_at`.
- Acceptance: paused tokio clock: a frame every 5 s with 15 s interval -> 0 pings; 16 s silence -> 1.
- Test phase: `cargo test -p acpmux peer`.
- Size S. Depends: 070. Queue Q4.

#### p14-energy-075 remote_cli acpmux_peer renewal from lease expiry
- Files: `cmux-tui/crates/cmux-tui/src/remote_cli/acpmux_peer.rs`.
- Change: RENEW_EVERY interval -> `sleep_until(expiry - margin)` re-armed after each renewal; backoff after failure.
- Acceptance: no `time::interval` in the file; paused time renews once per lease.
- Test phase: `cargo test -p cmux-tui acpmux_peer`.
- Size S. Queue Q4.

#### p14-energy-076 Rust background thread QoS
- Files: `cmux-tui/crates/cmux-tui-platform/src/thread_qos.rs`, `cmux-tui/crates/cmux-tui-core/src/journal_kernel.rs`,
  `cmux-tui/crates/cmux-tui-core/src/journal_hooks.rs`, `cmux-tui/crates/cmux-tui-core/src/wake/maintenance.rs`.
- Change: `thread_qos::set_current(Utility|Background)` (pthread_set_qos_class_self_np on macOS, no-op elsewhere) as the
  first statement of journal maintenance, fanout tailer, hook workers, reapers, kitty budget worker, MaintenanceClock.
  Request and stream threads stay with the QoS program.
- Acceptance: macOS test reads back qos_class_self(); rg list of call sites in the commit.
- Test phase: `cargo test -p cmux-tui-platform thread_qos`; idle-budget thread report.
- Size S. Depends: 020.

#### p14-energy-077a..m Q4 Rust groups
- Files: 077a `cmux-tui/crates/cmux-tui/src/machine_provider_client.rs`; 077b `.../cmux-tui/src/{remote_runtime.rs,local_owner.rs,machine_agent/**,link/**,machine_provider_transport.rs,agent_browser_provider.rs}`;
  077c `.../cmux-tui/src/{cli,app,bin,config,plugin_manager}/**`, `client_log.rs`; 077d rest of `.../cmux-tui/src/**`;
  077e `.../cmux-tui-core/src/terminal_host_runtime/**`; 077f `.../cmux-tui-core/src/{journal_hooks.rs,journal_plugin.rs,journal_kernel.rs,mux/**}`;
  077g `.../cmux-tui-core/src/{server,surface}/**`; 077h rest of `.../cmux-tui-core/src/**`; 077i `cmux-tui/crates/chatmux-relay/src/**`;
  077j `cmux-tui/crates/{cmux-remote,cmux-remote-browser,cmux-remote-browser-host,cmux-remote-protocol}/src/**`;
  077k `cmux-tui/crates/acpmux/src/**`; 077l `cmux-tui/crates/{cmux-host,cmux-process,cmux-pty,cmux-holder,cmux-holder-v3,cmux-tui-platform,cmux-tui-util}/src/**`;
  077m `cmux-tui/crates/{cmux-browser-host,cmux-tui-cdp,cmux-rd-host,cmux-app-host,cmux-wg,cmux-weft,cmux-relay,cmux-tui-cloud-conversations,cmux-flow-trace,cmux-mux2}/src/**`, `cmux-tui/bindings/**`.
- Change: each `loop` hit becomes an event (channel close, readiness, exit), a `wake::deadline` one-shot, the shared
  backoff or MaintenanceClock (durability jobs stay dirty-triggered); each `oneshot` hit gets a closed-vocabulary escape
  if it stays. 077c: `cli-only` only in files under cli/, bin/ or functions called only from a CLI entry (stated);
  status segments and status_command watch are fixed. 077e keeps the 100 ms backpressure re-check (only while a stream
  is full) as `bounded`. 077g's 2 s write timeout is `deadline`. 077l: cmux-holder-v3 is a frozen fixture (`fixture`).
  077k: tell PL-acpmux.
- Acceptance: `wakeup-audit --lang rust --queue` lists 0 hits in the slot's paths; 077m: `--lang rust --strict` exits 0.
- Test phase: `cargo test -p <crates>` on the fleet; 077e/077f also the idle_wakeups tests.
- Size per summary. Depends: per summary. Queue Q4.

#### p14-energy-111 Rust audit patterns
- Files: `scripts/cmux-next/wakeup-audit.py`, `scripts/cmux-next/guardrails.py`, `scripts/cmux-next/tests/test_wakeup_audit.py`.
- Change: add `park_timeout`, `libc::poll(` with a timeout not -1/0, `libc::kevent(` with a timespec, `epoll_wait`, tokio
  `sleep_until(`, `interval_at(`, `clock.sleep`/`clock.sleep_until`, `wait_timeout_while`, and `tokio::time::timeout(`
  around recv/wait inside a `loop`. New hits fold into 077a-m by directory.
- Acceptance: fixture per pattern (hit, escaped, `#[cfg(test)]`); on the checkout the added count is about 75 +/- 10.
- Test phase: `test_wakeup_audit.py`; `wakeup-audit.py --lang rust --queue | wc -l`.
- Size S. Depends: 005. Queue Q4.

#### p14-energy-112 Rust millisecond spin loops
- Files: `cmux-tui/crates/cmux-tui/src/app/mux_ingress.rs`,
  `cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime/shared/host_serve.rs`, `cmux-tui/crates/cmux-pty/src/input_queue.rs`,
  `cmux-tui/crates/cmux-mux2/src/macos/mux2d_os.rs`, `cmux-tui/crates/cmux-tui/src/remote_runtime.rs`,
  `cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs`.
- Change: mux_ingress.rs:219 1 ms park loop -> park/unpark or a Condvar signalled by the starter and stop;
  host_serve.rs:295/309/325 try_lock + 1 ms park -> blocking locks in one fixed order under the deadline; input_queue
  ROOM_POLL 1 ms -> poll POLLOUT on the PTY master until ROOM_WAIT; mux2d_os.rs:30 100 ms loop -> poll with the
  remaining deadline; 10 ms DAEMON_AUTH_LEASE_RETRY_INTERVAL and HOST_CONNECT_RETRY_INTERVAL -> shared backoff or a
  readiness event.
- Acceptance: `rg -n 'park_timeout\(Duration::from_millis\(1\)\)|remaining.min\(Duration::from_millis\(1\)\)|ROOM_POLL|from_millis\(10\)' <these files>`
  returns 0; a regression test per site counts loop iterations (red at the base).
- Test phase: `cargo test -p cmux-pty -p cmux-tui-core terminal_host -p cmux-tui mux_ingress` on the fleet.
- Size M. Depends: 111. Queue Q4.

#### p14-energy-117 acpmux freezes idle harnesses of hidden sessions
- Files: `cmux-tui/crates/acpmux/src/hub/freeze.rs`, `cmux-tui/crates/acpmux/src/hub/idle.rs`,
  `cmux-tui/crates/acpmux/src/config/pool.rs`, `cmux-tui/crates/acpmux/src/server/visibility.rs`,
  `scripts/cmux-next/idle-budget.json`.
- Change: op `_acpmux/visibility {session, visible}`. An attached-but-hidden session with no turn, no pending
  permission, no running background task or terminal tool for freezeAfterSeconds (300, 30 in saver) gets its harness
  process group SIGSTOPped; prompt, show, permission or inbound request does SIGCONT before anything is forwarded. In
  saver, pool.park and no new pool entries on battery. Status shows `frozen`. With PL-acpmux.
- Acceptance: fake process controller + paused clock: hidden idle 300 s -> 1 stop; prompt -> cont before request bytes;
  a running background task blocks the freeze; show thaws in the same turn; idle-budget.json's agent-idle
  `agent-harness.hidden_wakeups_max` goes from null (reported, IDLE-BUDGET-NOT-JUDGED since 103) to 0, so --gate
  judges D14's hidden harness.
- Test phase: `cargo test -p acpmux freeze`; agent-idle: hidden pane harness 0 wakeups.
- Size M. Depends: 070, 103.

#### p14-energy-118 Agent pane sends visibility edges
- Files: `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneSocket.swift`,
  `.../CmuxNextAgentPane/AgentPaneView.swift`, `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneVisibilityTests.swift`.
- Change: on each hidden/shown edge send one `_acpmux/visibility` after the turn (fire and forget, never awaited in a
  handler).
- Acceptance: hide, hide, show -> exactly 2 messages; no main-actor await.
- Test phase: `swift test --filter AgentPaneVisibility`.
- Size S. Depends: 117.

### Phase P6: test phase

#### p14-energy-090 energy-test-phase.py orchestrator
- Files: `scripts/cmux-next/energy-test-phase.py`, `scripts/cmux-next/tests/test_energy_test_phase.py`.
- Change: one entry point for D1-D17: wakeup-audit --strict; split-spring idle-budget (all sessions, --gate, shipping
  mode); cef-idle; bench-typing native and Chromium composer and Chromium scroll with saver on and off; xbench with
  Chrome; cargo idle tests (macOS through cmux-ci, Linux through 131); Swift filters through cmux-ci; D7 auto via
  simulate. Waits for load < 4. Writes Markdown and JSON with pass/fail per D-check and the rows for perf-lead.md sec. 5.
- Acceptance: `--dry-run` prints the exact command per check; fixture outputs parse into pass/fail; not referenced from
  `.github/workflows`.
- Test phase: unit tests; one full fleet run after P5.
- Size M. Depends: 003, 004, 005, 100, 101, 102, 103, 104, 105, 106, 135.

#### p14-energy-091 Record the measured numbers
- Files: `plans/cmux-next/perf-lead.md`, `plans/cmux-next/speed-of-sound-DESIGN.md`, `plans/cmux-next/idle-wakeups.md`,
  `scripts/cmux-next/idle-budget.json`.
- Change: paste the report rows (host, macOS, refresh rate, sha, counter version); set threads_max from the first run;
  mark perf-lead row 9; re-baseline the Chrome reference with 047 counters.
- Acceptance: every number cites its fleet job id and sha.
- Test phase: none (docs and budget numbers).
- Size S. Depends: 090.

#### p14-energy-092 / 093 / 094 Q9 slots
- Files: named by the over line.
- Change: after one 090 run, every `IDLE-BUDGET-OVER`, `HIDDEN-WAKE` (095) and `POWER-OVER` (096) line is one item; slots
  run in parallel, each takes the next unclaimed owner and fixes it by the rules of B, C and F. Spawn more slots while
  overs remain.
- Acceptance: a red/green test where a seam exists, and the idle-budget row before and after; the program ends when
  `idle-budget --gate` is green for every session.
- Test phase: split-spring --suite=idle-budget for the affected session; finally energy-test-phase.py.
- Size M each. Depends: the first 090 run. Queue Q9.

#### p14-energy-131 Linux runner for the Rust idle tests
- Files: `scripts/cmux-next/energy-test-phase.py`.
- Change: add the Testbox (or the Linux fleet class) command for `cargo test -p cmux-tui --test idle_wakeups` and
  `-p acpmux --test daemon_idle`. No CI job.
- Acceptance: `--dry-run` prints a Linux command that is not a .github workflow.
- Test phase: one Linux run recorded in the report.
- Size S. Depends: 090.

## 9. Order for the 72 h

- Hour 0, in parallel: 001, 002, 005, 009, 010, 011, 020, 021, 029 (fork patch start), 040, 041, 047, 050-054, 057,
  060, 066a, 068, 075, 104, 105, 130; send the PL-acpmux land request (070) and the PL-ghostty and F2/cef-layer notes.
- Day 1: 003, 004, 100, 012-018, 022, 023, 037, 046, 058, 109 then the Q8 fan-out (042-044+), 111, 112, 113, 006,
  055a-c, 061, 062a-b, 064, 066c, 067a-f, 076, 095 (first measurement), 102, 103, 106, 135, 019a-c.
- Day 2: 024-028, 030-036, 039, 048, 056, 059, 063, 065, 066b, 069 (if 068 is late), 071, 072, 074, 077a-l, 101, 107,
  108, 110, 114-127, 133, 134, 136 (fork bundle build and pin by hour 48), 137, 019d, 096.
- Day 3: 038, 045, 077m, 128, 129, 132 (only if needed), 090 full run, 092-094+ parallel slots on every over, 131,
  091 records the numbers on the tip.
