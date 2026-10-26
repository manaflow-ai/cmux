# cmux-next startup order: what runs before the first frame, and why

Status: launch order table (p08-startup task 015), read at `cf1f106ddbe` (origin/perf/chrome-parity).
Program spec: [chrome-parity/p08-startup.md](chrome-parity/p08-startup.md). Issue:
[perf-lead.md](perf-lead.md) row 18 (#17587).

This file is the one source for the launch order. Every launch call, eager build and stored
initializer of the launch path has one row here with its `StartupPriority`, its destination and the
reason. `StartupScheduler.criticalAllowlist` (`CmuxNextWakeups/StartupScheduler.swift`) is the list of
the critical rows' post names, in launch order; nothing else may be posted `.critical`
(p08-startup.md rule 12). A new critical name needs a row here with its measured cost.

Chrome does the same split: the `kStartup` queue holds only what the first window needs, and everything
else goes through `AfterStartupTaskUtils::PostTask` until startup completes
(`content/browser/scheduler/browser_task_queues.h`, `chrome/browser/after_startup_task_utils.cc`).

## How to read the tables

Priority:

- `critical`: runs at once, inline, before the first frame. The cell names the post (`critical: Name`);
  the name is in the allowlist.
- `afterFirstFrame`: held until the first window frame commits, then run in post order (main at
  `MainWorkClass.visible`, budgeted per frame, behind input).
- `afterStartup`: held until startup completes (refs at 0 or the 10 s failsafe), then released in post
  order (main: one per idle turn; lane: behind the best-effort fence).
- `onDemand`: built on first use, never at launch (a lazy var with no `_ = x`).
- `main()`: moves to (or stays in) `main()`, before `NSApp.run`, off the delegate.
- `wiring`: stores a closure or a value; does no work at launch; stays inline in its Startup file.
- `root`: the composition root itself (building `AppServices`); not a task.
- `deleted`: the call goes away with the mechanism it belongs to (FirstFrameGate, LaunchSettle, IdleOnce).
- `debug`: DEBUG or bench builds only; absent in Release.
- `not launch`: matched by the queue command but does not run at launch.

`(pane)` after a priority: a live pane build reads what the call sets up. Until task 060 (live window
behind the picture) moves the live window build after the first frame, `WindowManager.restoreWhenLoaded`
still builds the live window in the critical phase. So a `(pane)` row stays inline before the restore, in
today's order, until 060 lands or until its readers wait for it by event (028 does this for profiles and
the page schemes). Its owner task moves it then.

Destination: `main`, or `.lane(<BlockingLane>, <WorkPriority>)` as `StartupDestination` names it. `-` for
rows that are not posts.

Owner: the p08-startup task that moves the call (p08-startup.md section 6 and the task list). A cell
marked "assigned here" names a call the program spec gave no task.

## 1. Critical allowlist

These 14 names are `StartupScheduler.criticalAllowlist`, in this order (the code list equals this table).
The cap is 15. Costs are not measured yet: task 072 seeds them at hour 0 and task 070 checks them
(done check 4: `main_cpu_ms_to_first_frame <= 60`). Until then this column says what the step reads.

| # | Post name | Calls it covers (rows below) | Why the first frame needs it | Cost |
|---|---|---|---|---|
| 1 | `Settings.takeLaunchRead` | `CmuxConfigFile.prepareDefaultURL`, `SettingsController.readAtLaunch`, `TerminalThemeSetting.prime` (O3) | Theme, fonts, background and managed keys come from the settings; a frame in the defaults is wrong. It precedes `ThemeBridge.start` (the Ghostty overrides before the first config load). 025 makes the read a LaunchRead from `main()`; this post only takes it. | to measure (072); today a sync file read |
| 2 | `ThemeBridge.start` | `ThemeBridge.start(` (Q2 26) | Chrome colors derive from the Ghostty theme; first `GhosttyRuntime.shared`. | to measure (072); 026 moves the config bytes off main |
| 3 | `AppActions.bind` | `AppActions.bind` (O11) | Keys work from the first frame (registry handlers). | to measure (030) |
| 4 | `Settings.applyManagedFeaturesNow` | `SettingsController(registry:fileURL:launch:)` (O19), `settings.applyManagedFeaturesNow(` (Q2 80) | Managed (MDM) feature policy applies before any feature or page engine starts (101). The controller is made in this post: its init needs the `ActionRegistry`, which exists only after `AppServices` (O8), so it cannot be in post 1. | to measure (101) |
| 5 | `ManagedPolicyBridge.start` | `ManagedPolicyBridge(...).start()` (O20) | Managed URL filter and updater policy before any page engine (101). | to measure (101) |
| 6 | `TerminalTheme.follow` | `services.terminalTheme.follow(` (Q2 77) | Applies the loaded theme, background and backdrop art at once, so the first frame is not in the defaults. | to measure (072) |
| 7 | `Themes.start` | `services.themes.start(` (Q2 78), `themes.followChromeTheme` (O32) | Per-workspace themes, backgrounds and the app accent are the look of the restored workspaces. | to measure (072) |
| 8 | `MainMenu.make` | `MainMenu.make` (O13) | Menu key equivalents work from the first frame; 030 keeps only the top-level items here if the menu costs > 2 ms. | to measure (030) |
| 9 | `WindowActivation.activateApp` | `WindowActivation.activateApp()` (O14) | The first window shows active (key, not a dimmed title bar that flips a frame later). | to measure (072) |
| 10 | `Daemon.start` | `services.daemon.start(` (Q2 55) | Attaches the prestarted connection; the restore and the terminals need it. 074 moves `LaunchSnapshot.load` off main. | to measure (074) |
| 11 | `FeaturePolicyEnforcer.start` | `FeaturePolicyEnforcer(...).start()` (O15) | Disabled features are enforced before any window shows them (101: not moved). | to measure (101) |
| 12 | `WindowManager.restoreWhenLoaded` | `services.windows.restoreWhenLoaded()` (O25) | The front window (picture after 059, live window before it). | to measure (072, 059) |
| 13 | `WebAuthSessionHandler.install` | `WebAuthSessionHandler.install(` (Q2 30) | Other apps' sign-ins: a launch by one delivers its request right after `applicationDidFinishLaunching` (029). | to measure (072) |
| 14 | `AppleEvents.getURL` | `NSAppleEventManager.setEventHandler` for `kAEGetURL` (O28) | A launch by a URL open delivers the event after launch; without the handler the URL is lost (029, 096). | to measure (072) |

Not critical on purpose, though they run before the first frame today: the control socket (019: bind off
main from `main()`, methods after the first frame), Home and feeds (027), browser data (028, except by
event), platform services (029), the palette (023), Sentry integrations (032), the watchdog and its
reporting (088: from `main()`).

## 2. `main()` steps (`CmuxNextApp/CmuxNextApp.swift`)

P1 target: `main_start` to `main.run` <= 10 ms on main, no file calls (033).

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| M1 | `DebugTimings.makeStartupTrace()` | main() | main | 004 | The trace ring before the first mark; unset costs one getenv. |
| M2 | `DebugTimings.markLaunch("main_start")` | main() | main | 002 | First milestone. |
| M3 | `announceBenchHooksBuild()` | main() | main | 006 | Bench builds say so; no work in Release. |
| M4 | `cmux_early_malloc_zone_registration()` | main() | main | - | Must run while the process has one thread (Chromium's `EarlyMallocZoneRegistration`). |
| M5 | `ChildSignalDefaults.installAppSignalPolicy()` | main() | main | - | Before any socket or pipe exists. |
| M6 | `OpenFileLimit().raise()` | main() | main | - | Before CefInitialize; one setrlimit. |
| M7 | `CloudAuth.captureLaunchEnvironment()` | main() | main | - | Before any thread reads the environment. |
| M8 | `Self.prepareLaunchEnvironment()` | main() | main | 033 | The only environment writes, then the freeze. |
| M9 | `LaunchWarmup.start()` | main() | launch thread | 034 | Starts the launch thread. Its ActionCatalog and SF Symbols stay; `prewarmStrings` becomes afterStartup and `prewarmLoginEnvironment` an afterStartup `.lane(.system, .bestEffort)` post, at `.userBlocking` at once only when a cold daemon needs it now (034). |
| M10 | `AppEnvironment.current(openFiles:)` | main() | main | 033 | Its file reads become LaunchReads. |
| M11 | `environment.sidebarSnapshotFile` / `layoutTemplatesFile` / `homeCachesDirectory` | main() | main | 033 | Path lookups; directory creation moves to a LaunchRead. |
| M12 | `AgentPaneScrollAnchors.shared = ...`, `AgentPaneDraftAttachments.shared = ...` | main() | main | 033 | The 2 singletons become init injection. |
| M13 | `BackgroundWork(hangs:onRan:)` | main() | main | 004 | The lanes every later read uses. |
| M14 | `LaunchOrder.BestEffortFence(raisingOn: work)` | main() | main | 012 | Chrome's `BeginBestEffortFence` (`base/task/thread_pool/thread_pool_instance.h`): idle and best-effort lane work waits for startup complete. Raised before the first launch read is posted; the order of M23 lowers it at completion. |
| M15 | `startupTrace?.start(writingOn:)`, `whenClosed` | main() | main | 004 | The trace file is written on the files lane; a closed trace stops the lane reports. |
| M16 | `launchImages.prefetch`, `TerminalLaunchFrames.prefetch`, `relaunchWake.begin` | main() | `.lane(.files, .userBlocking)` | 001 | The last quit's pictures, decoded while AppKit starts. |
| M17 | `BrowserFaviconLoader.shared.useResolver(SystemRemoteResolver(runner: work))`, `BackdropVideoPlayers.shared.lanes = work` | wiring | - | - | Values: favicon host lookups and the wallpaper's window listing run on `work`'s system lane, never on main or the pool. |
| M18 | `DaemonWireStats.forBuild()` | main() | main | - | nil in Release. |
| M19 | `DaemonService.prestart(...)` | main() | off main | 066 | The daemon connect overlaps AppKit's start. |
| M20 | `CrashOnExceptions.register()` | main() | main | - | DEV and NIGHTLY crash at the throw site, before NSApp. |
| M21 | `CmuxApplication.shared`, `refusesActivation` | main() | main | - | The CEF-ready NSApp subclass before anything touches NSApp. |
| M22 | `InputEventTap()` | main() | main | 012 | The one input tap (p04-input.md 3 (A)); made before the order so the budget's pending-input check observes it, then passed to the delegate by init. |
| M23 | `LaunchOrder(fence:input:)`: `DisplayClock`, `FrameScheduler.install`, `StartupPhase` and its marks, `RenderStarvationGuard`, `MainWorkScheduler`, `StartupScheduler` | main() | main | 012 | The launch's order owners, made before the delegate (Chrome's `BrowserTaskExecutor` and after-startup state, `content/browser/scheduler/browser_task_executor.cc`). At completion it marks `startup_complete` and lowers M14's fence. |
| M24 | `AppDelegate(...)` init: `LaunchImageHold(startup:)`, `LaunchReveal`, `LaunchSettle`, `StartupReferences`, `AppControl` | main() | main | 012, 016 | Takes the order (M23) and the input tap (M22) by init; every deferred call is a post to `order.startup`. FirstFrameGate is deleted, LaunchSettle only reveals the pane region and the launch images are one startup ref (016). |
| M25 | `meterTurns`, `inputTap = delegate.inputTap`, `app.delegate`, `setActivationPolicy(.regular)` | main() | main | - | AppKit setup; the input tap hears every event from the first. |
| M26 | `markLaunch("main.nsapp")`, `markLaunch("main.run")`, `app.run()` | main() | main | - | End of P1. |

Added to `main()` by later tasks (rows Q2 14, 18, 25, 42, O1, O4): the watchdog as the first statement
(088), the LaunchPrefetch reads (025 settings, 026 Ghostty config, 074 launch snapshot, 075 sidebar snapshot
and run marker, 076 Home caches, 077 WebUpdates pointer, 058 front picture), the control socket bind after
the owner check (019), `QuitSignal.install` and `NativeCaretAccessory.install` (033, assigned here: both are
process-wide and need no services), `NSApp.disableRelaunchOnLogin()` (033, assigned here).

## 3. Q2 launch calls (82)

Queue command (p08-startup.md section 6), over `applicationDidFinishLaunching` and `startSettingsAndControl`
in `AppDelegate.swift`:

```sh
awk '/func applicationDidFinishLaunching/,/^    func applicationShouldTerminate/' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift \
  | grep -o -E '[A-Za-z.?]+\.(start|follow|wire|load|install|prewarm|register[A-Za-z]*|activate|attach|keepCurrent|startCloud|startChromiumRuntime|observe[A-Za-z]*|warmWhenIdle|bindRegistryActions|startDaemonSync|watchScope|writeManagedStatus|applyManagedFeaturesNow)\(' | sort -u
```

82 names at `cf1f106ddbe`. The spec's 81 were at `772cdfc45ac`; the one added since is
`GhosttyRuntime.shared.inputSources.start(` (row 16). After 014 the same names live in
`CmuxNextApp/Startup/Startup+<Domain>.swift`, and `startup-lint.py` (104) replaces the awk range.

| # | Call | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| 1 | `AgentPageChats.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | Feeds the agent page's chat list; the first frame shows the cached list (076). |
| 2 | `AppProcessRoot.shared.hangReports?.start(` | afterStartup | main | 079 | Sends the last run's reports; nobody waits for it. |
| 3 | `BrowserLinkClickPreference.follow(` | afterFirstFrame (pane) | main | 028 | Link-click routing in pages; no page loads before the first frame. |
| 4 | `BrowserOmnibarPreference.follow(` | afterFirstFrame (pane) | main | 079 | Omnibar preference of browser panes. |
| 5 | `ChatSettingsPush.start(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | Pushes chat settings to acpmux; no chat starts before the first frame. |
| 6 | `ComputerUseHelperDaemon.shared.follow(` | afterStartup | main | 029 | Computer Use helper process; nothing on screen needs it. |
| 7 | `DaemonPrompts.start(` | afterFirstFrame | main | 079 | OSC 52 clipboard prompts need a live terminal, which attaches after the first frame. |
| 8 | `DebugBrowserExternal.register(` | afterFirstFrame | main | 019 | Control method group (debug methods): one afterFirstFrame post per group. |
| 9 | `DebugCEFDevToolsLayout.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 10 | `DebugCloudMove.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 11 | `DebugDownloads.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 12 | `DebugNowPlaying.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 13 | `DebugTerminalLinks.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 14 | `DebugTimings.install(` | main() | main | 088 | The mark sink and the watchdog hook; installed with the watchdog at the top of `main()`. |
| 15 | `FirstPartyPageSchemes.install(` | afterFirstFrame (pane) | main | 028 | `cmux-page://` must be registered before the first page engine; an engine start before it (an external open, 096) waits for it by event, as for profiles. |
| 16 | `GhosttyRuntime.shared.inputSources.start(` | afterFirstFrame | main (reads on `services.work`) | 079 (assigned here) | Input-source switch keys of the terminal key path; added after `772cdfc45ac`, so no domain task owns it. |
| 17 | `KeepAwakeService.shared.start(` | afterStartup | main | 029 | Power assertion follow; nothing on screen needs it. |
| 18 | `NativeCaretAccessory.install(` | main() | main | 033 (assigned here) | One process-wide `NSTextView` method swap that must precede any text field; needs no services. |
| 19 | `NewTabClosed.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed. |
| 20 | `NewTabPlacesFeed.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed. |
| 21 | `NewTabWeather.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed (network). |
| 22 | `PageDescriptor.registerAgentActivityRoot(` | afterFirstFrame (pane) | main | 079 | Bundle root of a first-party page; read when such a page builds. |
| 23 | `PageDescriptor.registerDiffRoot(` | afterFirstFrame (pane) | main | 079 | Same, the diff page. |
| 24 | `PageDescriptor.registerFilePageRoots(` | afterFirstFrame (pane) | main | 079 | Same, the file pages. |
| 25 | `QuitSignal.install(` | main() | main | 033 (assigned here) | SIGTERM/SIGINT/SIGHUP during launch must quit cleanly (done check 15); the relay needs only the delegate. |
| 26 | `ThemeBridge.start(` | critical: `ThemeBridge.start` | main | 026 | See the allowlist. |
| 27 | `UpdateFeedPosting.follow(` | afterStartup | main | 029 | Update feed posts. |
| 28 | `UserOnlySettingConfirmation.install(` | afterFirstFrame | main | 025 | Confirms user-only setting edits; no edit before the first frame. |
| 29 | `WatchdogReporting.install(` | afterFirstFrame | main | 088 | The watchdog itself runs from `main()` (088); this attaches its reports to services. |
| 30 | `WebAuthSessionHandler.install(` | critical: `WebAuthSessionHandler.install` | main | 029 | See the allowlist. |
| 31 | `control.registerAccountsMethods(` | afterFirstFrame | main | 019 | Control method group; a request before it waits in the startup queue (019, 107). |
| 32 | `control.registerBillingMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 33 | `control.registerCloudMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 34 | `control.registerInputMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 35 | `control.registerMobileMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 36 | `control.registerPageDebugMethods(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 37 | `control.registerRemoteBrowserDebugMethods(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 38 | `control.registerRemoteMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 39 | `control.registerSettingsDebugMethods(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 40 | `control.registerUpdateMethods(` | afterFirstFrame | main | 019 | Control method group. |
| 41 | `control.service?.router.register(` | debug, afterFirstFrame | main | 019 | `debug.chromium_host` methods (`#if DEBUG`). |
| 42 | `control.start(` | main() | `.lane(.system, .userBlocking)` | 019 | Bind and listen off main after the owner check; serve at `MainWorkClass.automation`. Replaces `launchSettle.settled(within: 4 s, images:)` (016 kept its bound: the first terminal frame and the launch images). |
| 43 | `ghosttyConfigLiveReload.start(` | afterFirstFrame | main | 026 | File watchers for live reload; the loaded config is already applied. |
| 44 | `ghosttyKeybinds.start(` | afterFirstFrame | main | 026 | Keeps the binding table's Ghostty keybinds current. |
| 45 | `launchSettle.install(` | deleted | - | 016 | LaunchSettle becomes scheduler refs (012, 013). |
| 46 | `self?.forcedQuitExit.start(` | not launch | - | - | Runs on a second quit signal, inside `QuitSignal`'s closure. |
| 47 | `services.apps.attach(` | afterFirstFrame | main | 019 | App Store control methods (with the control groups). |
| 48 | `services.apps.start(` | afterStartup | main | 029 | App catalog; an App Store request before it waits (S22 path). |
| 49 | `services.bookmarks.follow(` | afterFirstFrame (pane) | main | 028 | Bookmarks settings. |
| 50 | `services.bookmarks.start(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | Bookmarks file read. |
| 51 | `services.browserProfiles.load(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | Profiles; an engine start waits for `profiles.loaded` by event. |
| 52 | `services.cache.browserTabs.preference.follow(` | afterFirstFrame (pane) | main | 028 | Engine preference follow. |
| 53 | `services.chatsFeed?.keepCurrent(` | afterFirstFrame for visible indicator feeds, else afterStartup; its sweep `.lane(.files, .bestEffort)` | main | 097 | `ChatsFeed.started` split: 5 feeds, a sweep, an acpmux connect, a device-ID read. |
| 54 | `services.configActions.start(` | afterFirstFrame | main | 079 | Custom actions from cmux.json for the palette and menus. |
| 55 | `services.daemon.start(` | critical: `Daemon.start` | main | 074 | See the allowlist. |
| 56 | `services.debugSettings.start(` | afterFirstFrame (pane) | main | 079 | DEV and NIGHTLY overrides; read by the window build, so (pane). |
| 57 | `services.globalHotKeys.start(` | afterFirstFrame | main | 029 | System-wide keys within 1 s of launch (029 test). |
| 58 | `services.history.start(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | History store. |
| 59 | `services.history.startDaemonSync(` | afterFirstFrame | main | 028 | History sync with the daemon. |
| 60 | `services.home.start(` | afterFirstFrame if Home shows, else afterStartup | main | 027 | Home's first frame comes from its cache (076). |
| 61 | `services.keybindingsFile.start(` | afterFirstFrame | main | 079 | User keybindings; key sweep 100 ms after the first frame (079 test). |
| 62 | `services.locationTrail.watchScope(` | afterFirstFrame | main | 028 | Location trail scope. |
| 63 | `services.macScreenPages.activate(` | afterStartup | main | 029 | Share This Mac resumes. |
| 64 | `services.mobile.follow(` | afterStartup | main | 029 | Phone access listener. |
| 65 | `services.newTabSpares.prewarm(` | afterStartup | main | 017 | Spare agent page; one service per post. |
| 66 | `services.notifications.follow(` | afterStartup | main | 029 | Notification settings follow. |
| 67 | `services.observeBorders(` | afterFirstFrame | main | 029 | Window border style follow. |
| 68 | `services.observeGlass(` | afterFirstFrame | main | 029 | Glass style follow. |
| 69 | `services.openPanel.warmWhenIdle(` | afterStartup `OpenPanel.warmWhenIdle` | main | 016 | The file picker made ahead at idle (`LaunchFirstOpenWarmups`, after the icon picker). |
| 70 | `services.palette.bindRegistryActions(` | afterFirstFrame | main | 023 | Palette bindings; a palette key before it builds the palette in the key's turn (023). |
| 71 | `services.projectsImport.start(` | afterFirstFrame if Home shows, else afterStartup | main | 027 | Projects import. |
| 72 | `services.registerDeviceHubDebug(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 73 | `services.registerMacScreenDebug(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 74 | `services.remoteLocalhost.follow(` | afterStartup | main | 029 | Remote localhost forwarding settings. Gone (021): `MachineRegistry.makeRemoteLocalhost(following:)` and the `settings` `didSet` follow. |
| 75 | `services.startChromiumRuntime(` | afterFirstFrame (pane) | main | 079 | Runtime pack check; wires the engine reason a browser pane reads. |
| 76 | `services.startCloud(` | afterFirstFrame | main | 020 | Cloud context; no cloud connect before the first frame (027). |
| 77 | `services.terminalTheme.follow(` | critical: `TerminalTheme.follow` | main | 079 | See the allowlist. |
| 78 | `services.themes.start(` | critical: `Themes.start` | main | 079 | See the allowlist. |
| 79 | `services.updater.follow(` | afterStartup | main | 029 | Updater settings follow (Sparkle). |
| 80 | `settings.applyManagedFeaturesNow(` | critical: `Settings.applyManagedFeaturesNow` | main | 101 | See the allowlist. |
| 81 | `settings.start(` | afterFirstFrame | main | 079 | Config file watchers and diagnostics; the launch read is already applied. |
| 82 | `settings.writeManagedStatus(` | afterStartup | `.lane(.files, .bestEffort)` | 025 | MDM status file for osquery, Fleet, Jamf; nobody waits. |

## 4. Other launch steps the Q2 command does not match

The Q2 regex misses calls on an expression (`X(...).start()`), trailing-closure calls and assignments.
These are the remaining steps of `applicationDidFinishLaunching` and `startSettingsAndControl`, in
source order through O41; O42 to O46 were found later and follow at the end.

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| O1 | `control.startWatchdog()` | main() | main | 088 | The watchdog starts as the first statement of `main()`. |
| O2 | `Task.detached { BrowserDesignModeController.tempFiles.removeAll() }` | afterStartup | `.lane(.files, .idle)` | 079 | Design-mode files a crash left; nobody waits. |
| O3 | `settingsFileURL()` (`CmuxConfigFile.prepareDefaultURL`), `SettingsController.readAtLaunch`, `TerminalThemeSetting.prime` | critical: `Settings.takeLaunchRead` | main | 025 | Becomes the settings LaunchRead from `main()`; the post takes it and primes the Ghostty overrides before `ThemeBridge.start`. |
| O4 | `NSApp.disableRelaunchOnLogin()` (no-activate launches) | main() | main | 033 (assigned here) | Process-wide; an agent launch never comes back at login. |
| O5 | `WindowPlacement.noActivate`, `WindowPlacement.testScreen` | wiring | - | - | Values. |
| O6 | `LastAppCLIPointer().publish(cliPath:)` | afterStartup | `.lane(.files, .bestEffort)` | 079 | The CLI shim pointer; nobody waits. |
| O7 | `PageWebView.openPanel`, `PageWebView.chromiumHosting` | wiring | - | 028 | Values; p13-webui 010 deletes the statics. |
| O8 | `AppServices(...)`, `AppProcessRoot.shared.adopt(services)` | root | main | 031, 098 | The composition root; its starts and initializers are sections 5 and 6. |
| O9 | `followsClientRates`, `loopsFollowFrameRate`, `startup.noteLaunch`, `whenFirstSnapshotApplied`, `watchUnavailable`, `presentationChanges.subscribe`, `windows.onRestored` | wiring | - | 012, 013 | The settle references become scheduler refs. |
| O10 | `services.quit.watchdog = ...`, `DebugTimings.markReveal(...)` | wiring | - | 088 | Values. |
| O11 | `AppActions.bind(services)` | critical: `AppActions.bind` | main | 030 | See the allowlist. |
| O12 | `HandlerCoverage.verify(services.registry)`, `registry.unboundActionIDs()` log | debug | - | 030 | Coverage checks; no Release walk. |
| O13 | `NSApp.mainMenu = MainMenu.make(...)` | critical: `MainMenu.make` | main | 030 | See the allowlist. |
| O14 | `WindowActivation.activateApp()` | critical: `WindowActivation.activateApp` | main | 079 | See the allowlist. |
| O15 | `FeaturePolicyEnforcer(services:).start()` | critical: `FeaturePolicyEnforcer.start` | main | 101 | See the allowlist. |
| O16 | `order.startup.post(.afterFirstFrame, "AppServices.startNonPaintServices")` (was `firstFrame.whenOpen`, 016) | afterStartup, one post per service | main | 017 | FreeTierAttest, ssh, serverReach, updater; AgentTabImport and the page host pool. |
| O17 | `windows.onPresent`, `windows.onFirstWindow`, `palette.onPresented`, `palette.openingEventTimestamp`, `iconPicker.onOpened`, `windows.onContentDidAppear`, `NSApp.servicesProvider` | wiring | - | 012, 096 | Closures; the first-window completion calls `firstFrameCommitted()` (012). |
| O18 | `LaunchFirstOpenWarmups(...).post(on:)` | afterStartup `Palette.prepare.0`, `Palette.prepare.1`, then `IconPicker.prepare` | main | 016 | Palette and icon picker warm-up, one idle frame each (`PaletteController.prepareStepNames`). Replaces `launchSettle.whenSettled` and IdleOnce (deleted). |
| O19 | `SettingsController(registry:fileURL:launch:)` | critical: `Settings.applyManagedFeaturesNow` | main | 101 | Needs the registry, so it runs after `AppServices` (O8); made inside the post that applies the managed features (allowlist row 4). |
| O20 | `ManagedPolicyBridge(...).start()` | critical: `ManagedPolicyBridge.start` | main | 101 | See the allowlist. |
| O21 | `launchCleanup.schedule(on: order.startup)` | afterStartup `LaunchCleanup.downloadTempFiles` | main | 016 | Temporary download files of an earlier run. The post only queues the cleanup: `BrowserDownloadTempFiles`' record actor reads the record and deletes the files off main, in order with this run's downloads, so a lane post would add a second queue in front of it. |
| O22 | `mouseSideButtons.start { ... }` | afterFirstFrame | main | 079 | Back and forward mouse buttons. |
| O23 | `TerminalHooks(services:).install()` | afterFirstFrame | main | 079 | App-scoped Ghostty actions; they need a live terminal. |
| O24 | `GhosttyKeybindSync(...)`, `GhosttyConfigLiveReload()` | afterFirstFrame | main | 026 | Built with their starts (Q2 43, 44). |
| O25 | `services.windows.restoreWhenLoaded()` | critical: `WindowManager.restoreWhenLoaded` | main | 059, 060 | See the allowlist. |
| O26 | `order.startup.post(.afterFirstFrame, "AppServices.startLaterTabWarmups")` (was `firstFrame.whenOpen`, 016) | afterStartup | main | 017 | Later tab warm-ups; WKProcessPool warm-up first afterFirstFrame only when a WebKit agent pane shows (017). |
| O27 | `WebAuthSessionWindows(...)`, `WebAuthSessionHandler(broker:)` | critical: `WebAuthSessionHandler.install` | main | 029 | Built inside the install post. |
| O28 | `NSAppleEventManager.shared().setEventHandler(... kAEGetURL)` | critical: `AppleEvents.getURL` | main | 029 | See the allowlist. |
| O29 | `firstFrame.armBackstop(after: .seconds(3))` | deleted | - | 016 | Deleted with FirstFrameGate: the first window is made in the launch turn, so its commit ends the first-frame ref; the scheduler's failsafe and the `noWindow` reason replace the backstop (095). |
| O30 | `WebUpdates.shared.prepare(...)` | main() read, then afterStartup | `.lane(.system, .bestEffort)` | 077 | Pointer read and verify as a LaunchRead before any page requests its entry; channel follow and network check after startup. |
| O31 | `services.palette.sources.settings = SettingsPaletteSource(...)`, `PaletteShortcutEditor(...)` | afterFirstFrame | main | 079 | Palette settings source and shortcut editor. |
| O32 | `services.themes.followChromeTheme(settings)` | critical: `Themes.start` | main | 079 | The app accent and page theme; posted with `themes.start`. |
| O33 | `AgentPageChats.wirePager(...)` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | Agent chat pager. |
| O34 | `Task { feedGitHub ObservationStream }` | afterStartup | main | 079 | GitHub feed config; off by default. |
| O35 | `Task { didBecomeActive -> managedPreferencesMayHaveChanged }` | afterFirstFrame | main | 025 | MDM backstop at activation. |
| O36 | `WorkspaceAutoNameWiring(services:).start(settings:)` | afterFirstFrame | main | 079 | Workspace auto-name variant persist. |
| O37 | `services.followMacScreenSettings(settings)` | afterStartup | main | 029 | Share This Mac settings. |
| O38 | `services.startDeviceHub(settings)` | afterStartup | main | 029 | Device hub. |
| O39 | `services.startHibernation(settings:)` | afterStartup | main | 029 | Tab hibernation. |
| O40 | Settings migrations and classic imports (`migrateLegacyQuitBehavior`, `migrateLegacyWorkspaceRowKeys`, `migrateLegacyPaneToolbarButtons`, `migrateClassicSettings`, `importClassicShortcuts`, `importClassicPreferences`) | main() read (pure transforms in the settings LaunchRead), write-back afterStartup | `.lane(.files, .bestEffort)` | 106 | The first snapshot has the migrated keys; the 2 classic imports after startup. |
| O41 | `RemoteViewDebugMethods(services:).register(on:)`, `BrowserPageService(...).install(on:)` and the passkey hand-off | afterFirstFrame | main | 019 | Control method groups. |
| O42 | `services.startEnergy()` (`EnergyMonitor.start`, `follow`) | afterFirstFrame (pane) | main | 031 (assigned here) | Low Power Mode, battery and thermal inputs for WebKit, KeepAwake and the video wallpaper; until it runs the inputs read nominal, and a tab made before it changes render rate once. |
| O43 | `FrameScheduler.appDisplays.hub = VSyncHub()` (feature `vsyncHub`) | wiring | - | - | A value, off by default. |
| O44 | `services.followEnergySaver(settings)` | afterFirstFrame | main | 029 (assigned here) | The `energy.saver` setting follow; the policy reads the default until then. |
| O45 | `services.settings = settings` (its `didSet`: `madeAgentTabs?.follow`, `browserHost?.follow`, `cloud.hostReplica.follow`) | wiring for the store; the `cloud.hostReplica.follow` moves into the Cloud start post (afterFirstFrame) | main | 020 (assigned here) | The `didSet` reads `cloud`, so today it builds `CloudService` before the first frame (Q1-1); the host replica has nothing to show before the Cloud context starts. |
| O46 | `order.startup.finishRegistration()` | wiring | - | 012 | The last statement of `applicationDidFinishLaunching`: every launch post is registered, so the implicit registration ref ends (Chrome's `StartupObserver`, `chrome/browser/after_startup_task_utils.cc`). |

## 5. `AppServices.init` starts (031)

Starts inside the initializer, outside Q1 and Q1b. 031: init holds no `start()` calls.

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| S1 | `TraceBlackBoxFileSteps.startApp(...)` | root | `.lane(.files, ...)` | - | The black-box ring from the first trace point; the file opens on `.files`. |
| S2 | `SidebarSnapshotStore(file:)` (sync read) | main() read | `.lane(.files, .userBlocking)` | 075 | The sidebar's first frame reads it; becomes a LaunchRead. |
| S3 | `CrashRecoveryService(...)` (`AppRunMarker` read and write) | main() read, write afterFirstFrame | `.lane(.files, .userBlocking)` | 075 | Crash recovery decides the restore; the read is a LaunchRead. |
| S4 | `AppCrashReporting(environment:)` (Sentry, crash forwarders) | root (handlers), integrations afterStartup | `.lane(.files, .bestEffort)` | 032, 078 | Crash and signal handlers at launch; forwarders and session I/O after startup. |
| S5 | `remoteTerminals.start()` | onDemand: the first mount of a remote-terminal tab (a restored window's selected one in its first frame), open, close or move | main | 021 | Restored remote workspace reconnects. Done (021): `AppServices.remoteTerminals` starts it when made. No post: the first frame that shows such a tab needs the service to mount it, and nothing follows a session no tab shows. Its tab chip (`RemoteTerminalService.badge(for:machines:)`) reads only the machines and makes none. |
| S6 | `surfaceInvariant.observeWindowOcclusion()` | afterFirstFrame | main | 031 | Occlusion observer. |
| S7 | `updater.attach(sheet:services:simulating:)`, `serverUpdates.start(registry:)` | afterStartup | main | 031 | Update sheet and server updates. |
| S8 | `input.start(services:)` | afterFirstFrame | main | 031 | Input verification observers. |
| S9 | `browserHost?.start()` | afterStartup | main | 031 | Browser host engine provider (idle until the daemon offers the endpoint). |
| S10 | `notifications.start(services:)` | afterFirstFrame | main | 031 | Banners; nothing to show before the first frame. |
| S11 | `(NSApp as? CmuxApplication)?.inputDispatch`, `keyDownInterceptor`, `crossWindowKeyGuard` and the other NSApp hooks; `cache.*` and `registry.*` closures; `AppMemoryConsumers.registerMemoryConsumers()`; `crashRecovery.observe(cache.cef.crashLog)`; `BrowserLifecycleTrace.shared.configure` | wiring | - | 031 | NSApp input hooks stay in init (031); the rest are closures. |

## 6. Q1 eager builds (18)

Queue command: `awk '/^    init\(environment: AppEnvironment/,/^    }$/' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift | grep -n -E '^\s*_ = [a-z][A-Za-z]*'`.
Target <= 3 (cache, windows, keyRouter).

| # | Build | Priority | Owner | Reason |
|---|---|---|---|---|
| Q1-1 | `_ = cloud` | onDemand once 020 splits out the auth; until then critical by reader, no gain | 020 (auth split assigned here) | Two readers run before the first frame: the `ManagedPolicyBridge.start` critical post reads `cloud.auth` (O20), and the `services.settings` `didSet` reads `cloud.hostReplica` (O45). Removing `_ = cloud` alone defers nothing. 020 makes `CloudAuth` its own `AppServices` member that `CloudService` takes by init, passes the bridge only that auth, and moves the host replica follow into the Cloud start post; then `startCloud` is the first reader. |
| Q1-2 | `_ = feed` | onDemand | 020 | Built by its first reader. |
| Q1-3 | `_ = rightSidebarSections` | onDemand; afterStartup `RightSidebar.prewarm` on main posts the icon build `RightSidebar.icons` on `.lane(.cpu, .idle)` | 022 | The right sidebar is not in the first frame unless shown. A panel built first (a window restored with it shown) posts the same build at afterFirstFrame and shows empty buttons until the images land; no main turn decodes a symbol. |
| Q1-4 | `_ = ssh` | onDemand | 021 | SSH machines start after startup (017). Done (021): made by the `SSH.start` post or a remote action; `AppServices.ssh` sets the install offer and the current policy when made. |
| Q1-5 | `_ = cache` | keep | - | `TabContentCache`: every pane reads it. 024 makes its CEF engine a factory. |
| Q1-6 | `_ = themes` | onDemand (built by the `Themes.start` post) | 022 (assigned here) | The spec's 020-024 lists leave it out; its first reader is critical anyway. |
| Q1-7 | `_ = terminalColors` | keep (022 found it must stay) | - | `TerminalColorSync` is an observer with no reader before the first frame (`TerminalTheme.follow` does not read it; only a Ghostty config change does). Built late, the daemons answer the first terminals' OSC 10/11/12 queries without the painted colors. Making it lazy needs a reader in the Daemon.start post first. |
| Q1-8 | `_ = remoteLocalhost` | onDemand | 021 | Its follow runs after startup (Q2 74). Done (021): made by a remote machine's browser tab (its route, store or loopback chip), a machine browser, or a remote machine's connection; this Mac's pages ask `RemoteLocalhostService.routesToThisMac` and make none. It takes the current settings in the turn it is made, then follows them. |
| Q1-9 | `_ = emptyWorkspaces` | onDemand; afterStartup `EmptyWorkspaceRepair.observe` on main | 022 | A window's content builds it before its frame; with no window shown, the post starts its store observation. |
| Q1-10 | `_ = keyRouter` | keep | - | Keys work from the first frame. |
| Q1-11 | `_ = resources` | onDemand | 022 | Built by its first reader. |
| Q1-12 | `_ = windows` | keep | - | `WindowManager`: the restore. |
| Q1-13 | `_ = dragSession` | onDemand | 022 | First drag. |
| Q1-14 | `_ = previews` | onDemand | 022 | First tab preview. |
| Q1-15 | `_ = remoteTerminals` | onDemand (its start is S5) | 021 | Restored remote workspaces. Done (021). |
| Q1-16 | `_ = palette` | onDemand | 023 | Bindings and hooks afterFirstFrame; a palette key before that builds it in the key's turn. |
| Q1-17 | `_ = configActions` | onDemand (its start is Q2 54) | 022 | Custom actions. |
| Q1-18 | `_ = chromiumWarmup` | onDemand | 024 | CEFEngine factory; the warm-up runs on the scheduler (018). |

022 owns 8 builds (the spec says 6). The extra 2 are Q1-6 and Q1-7. 022 made 7 lazy and kept Q1-7 (above), so
with 020's auth split for Q1-1, Q1 reaches 4, one above the spec's target of 3, until Q1-7 gets its reader. Without the auth split Q1-1 stays built before the
first frame (by the critical `ManagedPolicyBridge.start`), so it does not count toward the target.

## 7. Q1b stored initializers (42)

Queue command: `grep -n -E '^    (let|var|private\(set\) (var|let)) [a-zA-Z]+(: [^=]+)? = [A-Z][A-Za-z.]*[(.]' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift`.
42 hits at `cf1f106ddbe`; the spec's 43 were at `772cdfc45ac`. Since then `inputTap` (p04-input) and
`energyMonitor` (p14-energy) are made outside `AppServices` and passed by init, so they are no longer stored
initializers, and `appEvents` (p06-scheduler-021) was added. Line numbers at `cf1f106ddbe`. Mark: `value-only` (the initializer stores values, no I/O, no observer, no
source), `lazy` (becomes a lazy var built on first use), `posted` (the work in its initializer moves to a
post). The "Init does" column comes from reading each initializer; 098 checks each and changes the
`lazy` and `posted` rows.

| # | Line | Property | Init does | Mark | Owner |
|---|---|---|---|---|---|
| B1 | 49 | `themeStore = ThemeScope.app.store` | A reference to the app store. | value-only | - |
| B2 | 51 | `recoveryDrafts = RecoveryDraftStore(directory:)` | Stores the directory; reads on `load`. | value-only | - |
| B3 | 78 | `autoNameHold = WorkspaceAutoNameHold()` | Empty. | value-only | - |
| B4 | 90 | `machineAsks = SidebarAsks()` | Empty. | value-only | - |
| B5 | 98 | `showcase = ShowcaseState()` | Value. | value-only | - |
| B6 | 109 | `machineHealth = MachineHealthStore()` | Empty. | value-only | - |
| B7 | 112 | `appEvents = AppEvents(center: .default)` | Stores the notification center; observers subscribe per name on use. | value-only | - |
| B8 | 113 | `mobile = MobileHostService(displayName:)` | Stores a closure; the listener starts on `follow`. | value-only | - |
| B9 | 115 | `iphone = IPhoneHostService()` | Starts a task that follows the supervisor's states. | lazy | 098 |
| B10 | 122 | `blocking = BlockingDetector.forProcess()` | A handle to the process table. | value-only | - |
| B11 | 128 | `openPanel = MadeAheadOpenPanel()` | Stores a factory; the panel is made at idle (Q2 69). | value-only | - |
| B12 | 138 | `chromiumRuntime = ChromiumRuntimeService.make()` | Locates the CEF layout and reads the runtime pin file. | lazy (with 024's engine factory); the pin read becomes a LaunchRead | 098, 024 |
| B13 | 140 | `browserStores = BrowserSharedStores.application()` | File-backed site settings and zoom levels per profile. | lazy; any read on `.files` | 098 |
| B14 | 142 | `signInCallbacks = CEFSignInCallbacks()` | Empty. | value-only | - |
| B15 | 144 | `resizes = ResizeCoordinator()` | Stores a closure; its frame client is lazy. | value-only | - |
| B16 | 170 | `surfaceInvariant = SurfaceInvariantMonitor()` | A DemandTimer value; the observer starts in S6. | value-only | 031 |
| B17 | 172 | `input = InputVerificationService()` | Values; observers start in S8. | value-only | 031 |
| B18 | 181 | `workContext = WorkContextTrail()` | Value. | value-only | - |
| B19 | 284 | `browserNativeInputs = BrowserNativeInputs()` | Values. | value-only | - |
| B20 | 286 | `paneTabBars = PaneTabBarChoices()` | One `UserDefaults` array read; every pane build reads it. | value-only (the defaults domain is loaded once per process; 038 if Q5 lists it) | 038 |
| B21 | 288 | `paneFullWidthTabs = PaneFullWidthTabs()` | One `UserDefaults` array read; every pane build reads it. | value-only (as B19) | 038 |
| B22 | 290 | `paneMounts = PaneMounts()` | Value. | value-only | - |
| B23 | 292 | `newTabChoices = NewTabChoiceMemory()` | Stores the defaults; reads on use. | value-only | - |
| B24 | 294 | `newTabWeather = NewTabWeather()` | A `UserDefaults` data read and a JSON decode. | lazy | 098 |
| B25 | 296 | `chiefModelRecents = HomeChiefModelRecents(defaults:)` | Stores the defaults. | value-only | - |
| B26 | 297 | `newTabTypeAhead = NewTabTypeAhead()` | Empty. | value-only | - |
| B27 | 299 | `homeSwitchKeys = HomeSwitchKeysSource()` | Stores the defaults and a reader. | value-only | - |
| B28 | 301 | `memoryPressure = MemoryPressureEvents(source:)` | Starts the kernel memory-pressure source. | posted: afterFirstFrame, main (the level reads normal until then; the restored-page loader runs after startup) | 098 |
| B29 | 331 | `terminalDelegate = TerminalHostDelegate()` | Value. | value-only | - |
| B30 | 333 | `notifications = NotificationCenterService()` | Values; starts in S10. | value-only | 031 |
| B31 | 362 | `chiefPetHomes = ChiefPetHomes()` | Empty. | value-only | - |
| B32 | 364 | `chiefMascotPicks = ChiefMascotPicks(defaults:defaultChief:)` | A `UserDefaults` dictionary read. | lazy | 098 |
| B33 | 387 | `terminalTheme = TerminalThemeSetting(backdropScope:)` | Stores the scope; `follow` is critical. | value-only | - |
| B34 | 421 | `linkHints = LinkHintController()` | Values. | value-only | - |
| B35 | 423 | `reactGrab = ReactGrab(scripts:)` | Stores the loader; loads on use. | value-only | - |
| B36 | 425 | `windowHints = WindowHintController()` | Values. | value-only | - |
| B37 | 442 | `pages = InternalPageTabStore()` | Values. | value-only | - |
| B38 | 446 | `favicons = TabFaviconStore(loader:)` | Stores the loader. | value-only | - |
| B39 | 449 | `hoverCards = HoverCardCoordinator()` | A DemandTimer value; observers with the first source. | value-only | - |
| B40 | 451 | `refusalHUD = RefusalHUD()` | Stores the toast center. | value-only | - |
| B41 | 461 | `burstTrace = BurstTrace()` | Empty. | value-only | - |
| B42 | 463 | `vscodeServeWeb = VSCodeServeWebService(...)` | Stores a planner (home directory, environment) and a launcher. | lazy (only the VS Code page uses it; quit calls it only when built) | 098 |

## 8. How to check

Every name once, and the code allowlist equals the critical rows (task 015 acceptance). The script
runs each queue command (Q2, Q1, Q1b) on the tree and fails when a row is missing, extra, out of order
or (Q1b) at another line, and when a section heading's count is not its row count. From the repository root:

```sh
python3 - <<'EOF'
import re, subprocess
doc = open("plans/cmux-next/startup-DESIGN.md").read()
code = open("Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/StartupScheduler.swift").read()
allow = re.search(r"criticalAllowlist: \[StaticString\] = \[(.*?)\]", code, re.S).group(1)
in_code = re.findall(r'"([^"]+)"', allow)
in_table = re.findall(r"^\| \d+ \| `([^`]+)` \|", doc.split("## 2.")[0], re.M)
in_rows = set(re.findall(r"\| critical: `([^`]+)` \|", doc))
assert in_code == in_table, (in_code, in_table)
assert set(in_table) == in_rows, set(in_table) ^ in_rows
assert len(in_code) <= 15 and len(set(in_code)) == len(in_code)
q2 = subprocess.run(["sh", "-c", r"""awk '/func applicationDidFinishLaunching/,/^    func applicationShouldTerminate/' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift | grep -o -E '[A-Za-z.?]+\.(start|follow|wire|load|install|prewarm|register[A-Za-z]*|activate|attach|keepCurrent|startCloud|startChromiumRuntime|observe[A-Za-z]*|warmWhenIdle|bindRegistryActions|startDaemonSync|watchScope|writeManagedStatus|applyManagedFeaturesNow)\(' | sort -u"""], capture_output=True, text=True).stdout.split()
section = doc.split("## 3.")[1].split("## 4.")[0]
rows = re.findall(r"^\| \d+ \| `([^`]+)` \|", section, re.M)
assert rows == q2, set(rows) ^ set(q2)
def sh(cmd):
    return subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, check=True).stdout.splitlines()
def section_of(head, nxt):
    return doc.split(head)[1].split(nxt)[0]
def counted(head, n):
    assert re.search(rf"^{re.escape(head)}.*\({n}\)$", doc, re.M), (head, n)
counted("## 3. Q2", len(rows))
q1 = [re.search(r"_ = ([a-zA-Z]+)", l).group(1) for l in sh(r"""awk '/^    init\(environment: AppEnvironment/,/^    }$/' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift | grep -n -E '^\s*_ = [a-z][A-Za-z]*'""")]
q1_rows = re.findall(r"^\| Q1-\d+ \| `_ = ([a-zA-Z]+)` \|", section_of("## 6.", "## 7."), re.M)
assert q1_rows == q1, (q1_rows, q1)
counted("## 6. Q1", len(q1))
q1b = [(int(l.split(":", 1)[0]), re.match(r"\s*(?:let|var|private\(set\) (?:var|let)) ([a-zA-Z]+)", l.split(":", 1)[1]).group(1))
       for l in sh(r"""grep -n -E '^    (let|var|private\(set\) (var|let)) [a-zA-Z]+(: [^=]+)? = [A-Z][A-Za-z.]*[(.]' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift""")]
q1b_rows = [(int(n), name) for n, name in re.findall(r"^\| B\d+ \| (\d+) \| `([a-zA-Z]+) = ", section_of("## 7.", "## 8."), re.M)]
assert q1b_rows == q1b, sorted(set(q1b_rows) ^ set(q1b))
counted("## 7. Q1b", len(q1b))
print(f"allowlist {len(in_code)}, Q2 rows {len(rows)}, Q1 rows {len(q1)}, Q1b rows {len(q1b)}: ok")
EOF
```

After 014 splits `AppDelegate.swift` into `Startup/*.swift`, the Q2 rows are checked with
`startup-lint.py` (104) instead of the awk range; the allowlist check is the same.
