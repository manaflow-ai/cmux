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
the page schemes). Its owner task moves it then. `inline (pane)`: a `(pane)` row kept inline after 060
landed (079), because 060 moves the live window build behind the first frame only on the saved-picture
path, and its build slices are afterFirstFrame posts made in `restoreWhenLoaded`, ahead of any later post.

Destination: `main`, or `.lane(<BlockingLane>, <WorkPriority>)` as `StartupDestination` names it. `-` for
rows that are not posts.

Owner: the p08-startup task that moves the call (p08-startup.md section 6 and the task list). A cell
marked "assigned here" names a call the program spec gave no task.

## 1. Critical allowlist

These 14 names are `StartupScheduler.criticalAllowlist`, in this order (the code list equals this table).
The cap is 15. Task 072 seeded the costs that a launch mark brackets at `772cdfc45ac` (section 13, rows
S6 to S17). Each such cost is an upper bound, because its interval also holds other calls. Task 070
checks the costs (done check 4: `main_cpu_ms_to_first_frame <= 60`). Where no mark brackets a step, this
column says what the step reads.

| # | Post name | Calls it covers (rows below) | Why the first frame needs it | Cost |
|---|---|---|---|---|
| 1 | `Settings.takeLaunchRead` | `CmuxConfigFile.prepareDefaultURL`, `SettingsController.readAtLaunch`, `TerminalThemeSetting.prime` (O3) | Theme, fonts, background and managed keys come from the settings; a frame in the defaults is wrong. It precedes `ThemeBridge.start` (the Ghostty overrides before the first config load). 025 makes the read a LaunchRead from `main()`; this post only takes it. | 072 seed: <= 7.5 ms p50 (S6, with 2 other calls); today a sync file read |
| 2 | `ThemeBridge.start` | `ThemeBridge.start(` (Q2 26) | Chrome colors derive from the Ghostty theme; first `GhosttyRuntime.shared`. | 072 seed: <= 4.0 ms p50 (S7, with the 3 page roots); 026 moves the config bytes off main |
| 3 | `AppActions.bind` | `AppActions.bind` (O11) | Keys work from the first frame (registry handlers). | 072 seed: <= 15.7 ms p50 (S9, with 5 other calls); test phase (030): Release launch, `debug.startup` p50/p95 of the `AppActions.bind` record |
| 4 | `Settings.applyManagedFeaturesNow` | `SettingsController(registry:fileURL:launch:)` (O19), `settings.applyManagedFeaturesNow(` (Q2 80), `settings.adoptLaunchRead()` (O47) | Managed (MDM) feature policy applies before any feature or page engine starts (101). The controller is made in this post: its init needs the `ActionRegistry`, which exists only after `AppServices` (O8), so it cannot be in post 1. The launch read becomes its first load in the same step (079), so the first frame is in the file's look. | to measure (101) |
| 5 | `ManagedPolicyBridge.start` | `ManagedPolicyBridge(...).start()` (O20) | Managed URL filter and updater policy before any page engine (101). | to measure (101) |
| 6 | `TerminalTheme.follow` | `services.terminalTheme.follow(` (Q2 77) | Applies the loaded theme, background and backdrop art at once, so the first frame is not in the defaults. Done (079): a critical post. | to measure (072) |
| 7 | `Themes.start` | `services.themes.start(` (Q2 78), `themes.followChromeTheme` (O32) | Per-workspace themes, backgrounds and the app accent are the look of the restored workspaces. Done (079): one critical post for both. | to measure (072) |
| 8 | `MainMenu.make` | `MainMenu.make` (O13) | Menu key equivalents work from the first frame; 030 keeps only the top-level items here if the menu costs > 2 ms. | 072 seed: <= 2.5 ms p50 (S10, `dfl.settings` -> `dfl.menu`); budget 2 ms p95; test phase (030): Release launch `debug.startup` record, and `swift test -c release --filter LaunchMenuAndBindingsTests` fails over it |
| 9 | `WindowActivation.activateApp` | `WindowActivation.activateApp()` (O14) | The first window shows active (key, not a dimmed title bar that flips a frame later). Done (079): a critical post. | to measure (072) |
| 10 | `Daemon.start` | `services.daemon.start(` (Q2 55) | Attaches the prestarted connection; the restore and the terminals need it. 074 moves `LaunchSnapshot.load` off main. | to measure (074) |
| 11 | `FeaturePolicyEnforcer.start` | `FeaturePolicyEnforcer(...).start()` (O15) | Disabled features are enforced before any window shows them (101: not moved). | to measure (101) |
| 12 | `WindowManager.restoreWhenLoaded` | `services.windows.restoreWhenLoaded()` (O25) | The front window (picture after 059, live window before it). | 072 seed: about 94 ms p50 in the call (S12 to S16), plus 49.6 ms commit (S17); 059 |
| 13 | `WebAuthSessionHandler.install` | `WebAuthSessionHandler.install(` (Q2 30) | Other apps' sign-ins: a launch by one delivers its request right after `applicationDidFinishLaunching` (029). | to measure (072) |
| 14 | `AppleEvents.getURL` | `NSAppleEventManager.setEventHandler` for `kAEGetURL` (O28) | A launch by a URL open delivers the event after launch; without the handler the URL is lost (029, 096). | to measure (072) |

Not critical on purpose, though they run before the first frame today: the control socket (019: bind off
main from `main()`, methods after the first frame), Home and feeds (027), browser data (028, except by
event), platform services (029), the palette (023), Sentry integrations (032), the watchdog and its
reporting (088: from `main()`).

## 2. `main()` steps (`CmuxNextApp/CmuxNextApp.swift`)

P1 target: `main_start` to `main.run` <= 10 ms on main, no file calls (033). Open until 066: M19's
`DaemonService.prestart` still resolves the daemon binary and reads the install key on main; every
other step in this table makes no file call.

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| M1 | `DebugTimings.makeStartupTrace()` | main() | main | 004 | The trace ring before the first mark; unset costs one getenv. |
| M2 | `DebugTimings.markLaunch("main_start")` | main() | main | 002 | First milestone. |
| M3 | `announceBenchHooksBuild()` | main() | main | 006 | Bench builds say so; no work in Release. |
| M4 | `cmux_early_malloc_zone_registration()` | main() | main | - | Must run while the process has one thread (Chromium's `EarlyMallocZoneRegistration`). |
| M5 | `ChildSignalDefaults.installAppSignalPolicy()` | main() | main | - | Before any socket or pipe exists. |
| M6 | `OpenFileLimit().raise()` | main() | main | - | Before CefInitialize; one setrlimit. |
| M7 | `CloudAuth.captureLaunchEnvironment()` | main() | main | - | Before any thread reads the environment. |
| M8 | `Self.prepareLaunchEnvironment()` | main() | main | 033 | The only environment writes, then the freeze. `GHOSTTY_RESOURCES_DIR` is the app bundle's `Resources/ghostty` by path (`GhosttyRuntime.bundledResourcesDirectory`), no disk call. Mark `main.environment_frozen`. |
| M9 | `LaunchWarmup().start(catalog:)` | main() | launch thread | 034 | Starts the launch thread. Its ActionCatalog, SF Symbols and display UUIDs stay. The icon pack and catalog (367 KB of JSON, two `swift_once`s the first tab and sidebar icons read; their cost on main is to measure, 072) decode on their own `cmux-next icon warm-up` thread, mark `icons_decoded` (039; drop it if the base profile shows both under 1 ms). `prewarmStrings` moves to O18 (an afterFirstFrame `.lane(.files, .userVisible)` post). `prewarmLoginEnvironment` becomes `DaemonLauncher.captureLoginEnvironment(after:)`: at `.userInitiated` at once only when no environment is remembered (warm daemon or cold), else at `.utility` from the scheduler's completion (034). |
| M10 | `AppEnvironment.current(openFiles:)` | main() | main | 033 | No file call: the shell-integration choice follows the bundle path. Ghostty's resources folder, CLI helper and terminfo (`TERM`) are `GhosttyLaunchProbe`, a `.lane(.files, .userBlocking)` `.blockShutdown` LaunchRead posted before M16; each shell's env and the daemon's `server ensure` (M19) await it. The lanes (M13) are made first. |
| M11 | `environment.sidebarSnapshotFile` / `layoutTemplatesFile` / `homeCachesDirectory` | main() | main | 033 | Path lookups only; each store creates its folder when it first writes. Mark `main.app_environment`. |
| M12 | (was `AgentPaneScrollAnchors.shared = ...`, `AgentPaneDraftAttachments.shared = ...`) | wiring | - | 033 | Gone from main(): `AgentPaneChatStores` is made with the agent tabs (`AgentTabStore.wired`) and reaches each pane's `AgentPageProvider` by init. |
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
| 2 | `AppProcessRoot.shared.hangReports?.start(` | afterStartup | main | 079 | Sends the last run's reports; nobody waits for it. Done (079): post `HangReports.start`. Its consent hook (`HangReportsController.recordUserWrites(of:)`, the person's own writes of `diagnostics.hangReports`) stays inline as wiring, so a write before completion still records consent. |
| 3 | `BrowserLinkClickPreference.follow(` | afterFirstFrame (pane) | main | 028 | Link-click routing in pages; no page loads before the first frame. |
| 4 | `BrowserOmnibarPreference.follow(` | inline (pane) | main | 079 | Omnibar preference of browser panes; 028 keeps the omnibar look in the launch turn too. Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 5 | `ChatSettingsPush.start(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | Pushes chat settings to acpmux; no chat starts before the first frame. |
| 6 | `ComputerUseHelperDaemon.shared.follow(` | afterStartup | main | 029 | Computer Use helper process; nothing on screen needs it. Done (029): post `ComputerUseHelper.follow` (`LaunchServicePosts.platform`). |
| 7 | `DaemonPrompts.start(` | wiring | main | 079 | OSC 52 clipboard reads, browser pairings and the give-back of unclaimed keys: subscriptions to the store's side events, no work until an event comes (the clipboard broker's first hand-off reads an empty store). Kept inline before the daemon start (079): side events keep no backlog, and a trusted subscribe's first events are the daemon's pending pairings (`cmd_subscribe.rs`), so a later start drops them (no Approve dialog) and drops given-back keys. `AppServices.startLocalDaemon` starts the prompts first and returns them, so the order is the call's, not the delegate's line order. |
| 8 | `DebugBrowserExternal.register(` | afterFirstFrame | main | 019 | Control method group (debug methods): one afterFirstFrame post per group. |
| 9 | `DebugCEFDevToolsLayout.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 10 | `DebugCloudMove.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 11 | `DebugDownloads.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 12 | `DebugNowPlaying.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 13 | `DebugTerminalLinks.register(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 14 | `DebugTimings.install(` | main() | main | 088 | The mark sink and the watchdog hook; installed with the watchdog at the top of `main()`. |
| 15 | `FirstPartyPageSchemes.install(` | afterFirstFrame (pane) | main | 028 | `cmux-page://` must be registered before the first page engine; an engine start before it (an external open, 096) waits for it by event, as for profiles. |
| 16 | `GhosttyRuntime.shared.inputSources.start(` | inline (pane) | main (reads on `services.work`) | 079 (assigned here) | Input-source switch keys of the terminal key path; added after `772cdfc45ac`, so no domain task owns it. Kept inline (079), before the restore: its read is already off main, and without the saved picture (default off) the restore can mount a terminal that takes keys before the first afterFirstFrame frame, so a post would leave its first keys without the switch keys. startup-lint (104) lists it as reader-ordered inline. |
| 17 | `KeepAwakeService.shared.start(` | afterStartup | main | 029 | Power assertion follow; nothing on screen needs it. Done (029): post `KeepAwake.start` (`LaunchServicePosts.platform`). |
| 18 | `NativeCaretAccessory.install(` | main() | main | 033 (assigned here) | One process-wide `NSTextView` method swap that must precede any text field; needs no services. |
| 19 | `NewTabClosed.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed. |
| 20 | `NewTabPlacesFeed.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed. |
| 21 | `NewTabWeather.wire(` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | New Tab feed (network). |
| 22 | `PageDescriptor.registerAgentActivityRoot(` | inline (pane) | main | 079 | Bundle root of the agent activity page; read when such a page builds. Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 23 | `PageDescriptor.registerDiffRoot(` | inline (pane) | main | 079 | Bundle root of the diff page; read when such a page builds. Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 24 | `PageDescriptor.registerFilePageRoots(` | inline (pane) | main | 079 | Bundle root of the file pages; read when such a page builds. Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 25 | `QuitSignal.install(` | main() | main | 033 (assigned here) | SIGTERM/SIGINT/SIGHUP during launch must quit cleanly (done check 15); the relay needs only the delegate. |
| 26 | `ThemeBridge.start(` | critical: `ThemeBridge.start` | main | 026 | See the allowlist. |
| 27 | `UpdateFeedPosting.follow(` | afterStartup | main | 029 | Update feed posts. Done (029): post `UpdateFeedPosting.follow` (`LaunchServicePosts.platform`). |
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
| 48 | `services.apps.start(` | afterStartup | main | 029 | App catalog; an App Store request before it waits (S22 path). Done (029): post `Apps.start` (`LaunchServicePosts.platform`). |
| 49 | `services.bookmarks.follow(` | afterFirstFrame (pane) | main | 028 | Bookmarks settings. |
| 50 | `services.bookmarks.start(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | Bookmarks file read. |
| 51 | `services.browserProfiles.load(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | Profiles; an engine start waits for `profiles.loaded` by event. |
| 52 | `services.cache.browserTabs.preference.follow(` | afterFirstFrame (pane) | main | 028 | Engine preference follow. |
| 53 | `services.chatsFeed?.keepCurrent(` | afterFirstFrame for visible indicator feeds, else afterStartup; its sweep `.lane(.files, .bestEffort)` | main | 097 | `ChatsFeed.started` split: 5 feeds, a sweep, an acpmux connect, a device-ID read. |
| 54 | `services.configActions.start(` | afterFirstFrame | main | 079 | Custom actions from cmux.json for the palette and menus. Done (079): post `ConfigActions.start`. |
| 55 | `services.daemon.start(` | critical: `Daemon.start` | main | 074 | See the allowlist. |
| 56 | `services.debugSettings.start(` | inline (pane) | main | 079 | DEV and NIGHTLY overrides (a Release launch returns at once); read by the window build (icon family, tunables). Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 57 | `services.globalHotKeys.start(` | afterFirstFrame | main | 029 | System-wide keys within 1 s of launch (029 test). Done (029): post `GlobalHotKeys.start` (`LaunchServicePosts.platform`). |
| 58 | `services.history.start(` | afterFirstFrame (pane) | main, reads on `.lane(.files, .userVisible)` | 028 | History store. |
| 59 | `services.history.startDaemonSync(` | afterFirstFrame | main | 028 | History sync with the daemon. |
| 60 | `services.home.start(` | afterFirstFrame if Home shows, else afterStartup | main | 027 | Home's first frame comes from its cache (076). |
| 61 | `services.keybindingsFile.start(` | afterFirstFrame | main | 079 | User keybindings from the home daemon, read when it serves them; key sweep 100 ms after the first frame (079 test). Done (079): post `KeybindingsFile.start`. |
| 62 | `services.locationTrail.watchScope(` | afterFirstFrame | main | 028 | Location trail scope. |
| 63 | `services.macScreenPages.activate(` | afterStartup | main | 029 | Share This Mac resumes. Done (029): post `MacScreen.activate` (`LaunchServicePosts.platform`). It used to run in the control socket's served callback; it reads no socket. |
| 64 | `services.mobile.follow(` | afterStartup | main | 029 | Phone access listener. Done (029): post `Mobile.follow` (`LaunchServicePosts.platform`). |
| 65 | `services.newTabSpares.prewarm(` | afterStartup | main | 017, 042 | Spare agent page; one service per post. Done (042): post `NewTabSpares.probe` before `NewTabSpares.warm` (`LaunchServicePosts.laterTabs`). |
| 66 | `services.notifications.follow(` | afterStartup | main | 029 | Notification settings follow. Done (029): post `Notifications.follow` (`LaunchServicePosts.platform`). The launch sets the preferences from the launch read at once, so the first frame's attention marks and mutes are right, and starts the Chief pet at once (`followChiefPet`), so an arrival before startup completes reaches it. |
| 67 | `services.observeBorders(` | afterFirstFrame | main | 029 | Window border style follow. Done (029): post `Borders.observe` (`LaunchServicePosts.platform`). |
| 68 | `services.observeGlass(` | afterFirstFrame | main | 029 | Glass style follow. Done (029): post `Glass.observe` (`LaunchServicePosts.platform`). The launch sets the resolved mode at once (`seedGlass`), so the first frame draws it and the follow repaints only on a change. |
| 69 | `services.openPanel.warmWhenIdle(` | afterStartup `OpenPanel.warmWhenIdle` | main | 016 | The file picker made ahead at idle (`LaunchFirstOpenWarmups`, after the icon picker). |
| 70 | `services.palettes.bindRegistryActions(` | wiring, then afterFirstFrame `Palette.build` | main | 023 | `services.palettes.bindRegistryActions()` (`PaletteOnDemand`) binds the palette's actions and argument collector to closures that resolve the palette at run (no build); `palettes.postBuild` posts `Palette.build` after the first frame; a palette key before it builds the palette in the key's turn (023). |
| 71 | `services.projectsImport.start(` | afterFirstFrame if Home shows, else afterStartup | main | 027 | Projects import. |
| 72 | `services.registerDeviceHubDebug(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 73 | `services.registerMacScreenDebug(` | afterFirstFrame | main | 019 | Control method group (debug methods). |
| 74 | `services.remoteLocalhost.follow(` | afterStartup | main | 029 | Remote localhost forwarding settings. Gone (021): `MachineRegistry.makeRemoteLocalhost(following:)` and the `settings` `didSet` follow. |
| 75 | `services.startChromiumRuntime(` | inline (pane) | main | 079 | Runtime pack check; wires the engine reason a browser pane reads (and the download a restored Chromium pane asks for). Kept inline (079), in today's order before the restore: its readers are page and pane builds, and the pane builds are not behind the first frame on every launch. Without the saved picture (default off) or on a mismatch, the restore mounts the panes as soon as the daemon snapshot and the window state load, which can come before the first afterFirstFrame frame; with the picture, 060's build slices are afterFirstFrame posts made in `restoreWhenLoaded`, so a post made after them runs after the panes. startup-lint (104) lists it as reader-ordered inline. |
| 76 | `services.startCloud(` | afterFirstFrame | main | 020 | Cloud context; no cloud connect before the first frame (027). |
| 77 | `services.terminalTheme.follow(` | critical: `TerminalTheme.follow` | main | 079 | See the allowlist. Done (079). |
| 78 | `services.themes.start(` | critical: `Themes.start` | main | 079 | See the allowlist. Done (079). |
| 79 | `services.updater.follow(` | wiring | main | 029 | Updater settings follow (Sparkle). Stays inline (029): one observation task, no work before the first frame, and `updates.*` (schedule, ring, download policy) must apply before the `Updater.start` post. |
| 80 | `settings.applyManagedFeaturesNow(` | critical: `Settings.applyManagedFeaturesNow` | main | 101 | See the allowlist. |
| 81 | `settings.start(` | afterFirstFrame | main | 079 | Config file watches and the diagnostic toasts. Done (079): post `Settings.start`. The launch read is applied before it by `settings.adoptLaunchRead()` (O47, allowlist row 4); the start reloads once off main, so an edit made since the launch read applies. |
| 82 | `settings.writeManagedStatus(` | afterStartup | `.lane(.files, .bestEffort)` | 025 | MDM status file for osquery, Fleet, Jamf; nobody waits. |

## 4. Other launch steps the Q2 command does not match

The Q2 regex misses calls on an expression (`X(...).start()`), trailing-closure calls and assignments.
These are the remaining steps of `applicationDidFinishLaunching` and `startSettingsAndControl`, in
source order through O41; O42 to O47 were found later and follow at the end.

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| O1 | `control.startWatchdog()` | main() | main | 088 | The watchdog starts as the first statement of `main()`. |
| O2 | `Task.detached { BrowserDesignModeController.tempFiles.removeAll() }` | afterStartup | `.lane(.files, .bestEffort)` | 079, 083 | Design-mode files a crash left; nobody waits. Done (083, which 079 defers to): `LaunchFileJobs` posts `removeEarlierLaunches()` on the files lane at `.idle`, behind the best-effort fence. Each launch writes its cards in its own folder under `base` (`BrowserDesignModeTempFiles.root`), and the cleanup removes every other entry of `base`, so it is safe whenever it runs. Quit removes only this launch's folder. |
| O3 | `settingsFileURL()` (`CmuxConfigFile.prepareDefaultURL`), `SettingsController.readAtLaunch`, `TerminalThemeSetting.prime` | critical: `Settings.takeLaunchRead` | main | 025 | Becomes the settings LaunchRead from `main()`; the post takes it and primes the Ghostty overrides before `ThemeBridge.start`. |
| O4 | `NSApp.disableRelaunchOnLogin()` (no-activate launches) | main() | main | 033 (assigned here) | Process-wide; an agent launch never comes back at login. |
| O5 | `WindowPlacement.noActivate`, `WindowPlacement.testScreen` | wiring | - | - | Values. |
| O6 | `LastAppCLIPointer().publish(cliPath:)` | afterStartup | files lane, `.userVisible`, block shutdown | 079, 083 | The CLI shim pointer. Done (083, which 079 defers to): `LaunchFileJobs` posts it unfenced at `.userVisible` with `blockShutdown`, because a script that opens the app and runs `cmux` at once must get this app's CLI. |
| O7 | `PageWebView.openPanel`, `PageWebView.chromiumHosting` | wiring | - | 028 | Values; p13-webui 010 deletes the statics. |
| O8 | `AppServices(...)`, `AppProcessRoot.shared.adopt(services)` | root | main | 031, 098 | The composition root; its starts and initializers are sections 5 and 6. |
| O9 | `followsClientRates`, `loopsFollowFrameRate`, `startup.noteLaunch`, `whenFirstSnapshotApplied`, `watchUnavailable`, `presentationChanges.subscribe`, `windows.onRestored` | wiring | - | 012, 013 | The settle references become scheduler refs. |
| O10 | `services.quit.watchdog = ...`, `DebugTimings.markReveal(...)` | wiring | - | 088 | Values. |
| O11 | `AppActions.bind(services)` | critical: `AppActions.bind` | main | 030 | See the allowlist. |
| O12 | `HandlerCoverage.verify(services.registry)`, `registry.unboundActionIDs()` log | debug | - | 030 | Coverage checks; no Release walk. |
| O13 | `NSApp.mainMenu = MainMenu.make(...)` | critical: `MainMenu.make` | main | 030 | See the allowlist. |
| O14 | `WindowActivation.activateApp()` | critical: `WindowActivation.activateApp` | main | 079 | See the allowlist. Done (079). |
| O15 | `FeaturePolicyEnforcer(services:).start()` | critical: `FeaturePolicyEnforcer.start` | main | 101 | See the allowlist. |
| O16 | `order.startup.post(.afterFirstFrame, "AppServices.startNonPaintServices")` (was `firstFrame.whenOpen`, 016) | afterStartup, one post per service | main | 017 | FreeTierAttest, ssh, serverReach, updater; AgentTabImport and the page host pool. |
| O17 | `windows.onPresent`, `windows.onFirstWindow`, `palette.onPresented`, `palette.openingEventTimestamp`, `iconPicker.onOpened`, `windows.onContentDidAppear`, `NSApp.servicesProvider` | wiring | - | 012, 096 | Closures; the first-window completion calls `firstFrameCommitted()` (012). |
| O18 | `LaunchFirstOpenWarmups(...).post(on:)` | afterFirstFrame `Palette.prewarmStrings` (`.lane(.files, .userVisible)`, 034); afterStartup `Palette.prepare.0`, `Palette.prepare.1`, then `IconPicker.prepare` | main | 016 | Palette and icon picker warm-up, one idle frame each (`PaletteController.prepareStepNames`); the palette's string tables load off main at the first frame, before completion releases the prepare steps. Replaces `launchSettle.whenSettled` and IdleOnce (deleted). |
| O19 | `SettingsController(registry:fileURL:launch:)` | critical: `Settings.applyManagedFeaturesNow` | main | 101 | Needs the registry, so it runs after `AppServices` (O8); made inside the post that applies the managed features (allowlist row 4). |
| O20 | `ManagedPolicyBridge(...).start()` | critical: `ManagedPolicyBridge.start` | main | 101 | See the allowlist. |
| O21 | `launchCleanup.schedule(on: order.startup)` | afterStartup `LaunchCleanup.downloadTempFiles` | main | 016 | Temporary download files of an earlier run. The post only queues the cleanup: `BrowserDownloadTempFiles`' record actor reads the record and deletes the files off main, in order with this run's downloads, so a lane post would add a second queue in front of it. |
| O22 | `mouseSideButtons.start { ... }` | afterFirstFrame | main | 079 | Back and forward mouse buttons. Done (079): post `MouseSideButtons.start`. |
| O23 | `TerminalHooks(services:).install()` | inline (pane) | main | 079 | App-scoped Ghostty actions and the key-equivalent hooks (`menuMayClaim`, `sendToProgram`, `userKeybindOwns`), read on every key equivalent of a terminal. Kept inline (079), before the restore: it only assigns closures, and without the saved picture (default off) the restore can mount a terminal that takes keys before the first afterFirstFrame frame; with the hooks unset, the menu takes the person's own Ghostty keybinds (nxdog50), a mouse-capturing program loses Cmd-Z and Cmd-A to the Edit menu, and app-scoped actions are dropped. startup-lint (104) lists it as reader-ordered inline. |
| O24 | `GhosttyKeybindSync(...)`, `GhosttyConfigLiveReload()` | afterFirstFrame | main | 026 | Built with their starts (Q2 43, 44). |
| O25 | `services.windows.restoreWhenLoaded()` | critical: `WindowManager.restoreWhenLoaded` | main | 059, 060 | See the allowlist. |
| O26 | `order.startup.post(.afterFirstFrame, "AppServices.startLaterTabWarmups")` (was `firstFrame.whenOpen`, 016) | afterStartup | main | 017, 042 | Later tab warm-ups. No WebKit view before completion but the shown agent tabs', each an afterFirstFrame `AgentTabs.launchView` post after its picture, the focused pane's first; while the focused pane shows a drawing terminal, the other panes' tabs post only once the pane region is ready (`LaunchViewQueue`, 042); the agent pages' WebKit warm-up is the afterStartup post `AgentPane.webKitWarmup`. |
| O27 | `WebAuthSessionWindows(...)`, `WebAuthSessionHandler(broker:)` | critical: `WebAuthSessionHandler.install` | main | 029 | Built inside the install post. |
| O28 | `NSAppleEventManager.shared().setEventHandler(... kAEGetURL)` | critical: `AppleEvents.getURL` | main | 029 | See the allowlist. |
| O29 | `firstFrame.armBackstop(after: .seconds(3))` | deleted | - | 016 | Deleted with FirstFrameGate: the first window is made in the launch turn, so its commit ends the first-frame ref; the scheduler's failsafe and the `noWindow` reason replace the backstop (095). |
| O30 | `WebUpdates.shared.prepare(...)` | main() read, then afterStartup | `.lane(.system, .bestEffort)` | 077 | Pointer read and verify as a LaunchRead before any page requests its entry; channel follow and network check after startup. |
| O31 | `services.palettes.sources.settings = SettingsPaletteSource(...)`, `PaletteShortcutEditor(...)` | afterFirstFrame | main | 079 | Palette settings source and shortcut editor; neither builds the palette (023). Done (079): one post `Palette.settingsSource`. |
| O32 | `services.themes.followChromeTheme(settings)` | critical: `Themes.start` | main | 079 | The app accent and page theme; posted with `themes.start`. Done (079). |
| O33 | `AgentPageChats.wirePager(...)` | afterFirstFrame if Home or an agent page shows, else afterStartup | main | 027 | Agent chat pager. |
| O34 | `Task { feedGitHub ObservationStream }` | afterStartup | main | 079 | GitHub feed config; off by default. Done (079): post `FeedGitHub.follow`, a `ServiceObservation` kept in `lifetimeFollowers` instead of a free task. |
| O35 | `Task { didBecomeActive -> managedPreferencesMayHaveChanged }` | afterFirstFrame | main | 025 | MDM backstop at activation. |
| O36 | `WorkspaceAutoNameWiring(services:).start(settings:)` | afterFirstFrame | main | 079 | Workspace auto-name variant persist. Done (079): post `WorkspaceAutoName.start`. |
| O37 | `services.followMacScreenSettings(settings)` | afterStartup | main | 029 | Share This Mac settings. Done (029): post `MacScreen.followSettings` (`LaunchServicePosts.platform`). |
| O38 | `services.startDeviceHub(settings)` | afterStartup | main | 029 | Device hub. Done (029): post `DeviceHub.start` (`LaunchServicePosts.platform`). |
| O39 | `services.startHibernation(settings:)` | wiring, then afterStartup `Hibernation.measure` | main | 029 | Tab hibernation. Done (029): the hibernation, its agent pages and the warm set budget are made inline before the restore, so a page the restore mounts hidden reports its hide (`tabDidHide`) and becomes a discard candidate; the footprint samples and the occluded-window checker post `Hibernation.measure` (`LaunchServicePosts.platform`). |
| O40 | Settings migrations and classic imports (`migrateLegacyQuitBehavior`, `migrateLegacyWorkspaceRowKeys`, `migrateLegacyPaneToolbarButtons`, `migrateClassicSettings`, `importClassicShortcuts`, `importClassicPreferences`) | main() read (pure transforms in the settings LaunchRead), write-back afterStartup | `.lane(.files, .bestEffort)` | 106 | The first snapshot has the migrated keys; the 2 classic imports after startup. |
| O41 | `RemoteViewDebugMethods(services:).register(on:)`, `BrowserPageService(...).install(on:)` and the passkey hand-off | afterFirstFrame | main | 019 | Control method groups. |
| O42 | `services.startEnergy()` (`EnergyMonitor.start`, `follow`) | afterFirstFrame (pane) | main | 031 (assigned here) | Low Power Mode, battery and thermal inputs for WebKit, KeepAwake and the video wallpaper; until it runs the inputs read nominal, and a tab made before it changes render rate once. |
| O43 | `FrameScheduler.appDisplays.hub = VSyncHub()` (feature `vsyncHub`) | wiring | - | - | A value, off by default. |
| O44 | `services.followEnergySaver(settings)` | afterFirstFrame | main | 029 (assigned here) | The `energy.saver` setting follow; the policy reads the default until then. |
| O45 | `services.settings = settings` (its `didSet`: `madeAgentTabs?.follow`, `browserHost?.follow`, `cloud.hostReplica.follow`) | wiring for the store; the `cloud.hostReplica.follow` moves into the Cloud start post (afterFirstFrame) | main | 020 (assigned here) | The `didSet` reads `cloud`, so today it builds `CloudService` before the first frame (Q1-1); the host replica has nothing to show before the Cloud context starts. |
| O46 | `order.startup.finishRegistration()` | wiring | - | 012 | The last statement of `applicationDidFinishLaunching`: every launch post is registered, so the implicit registration ref ends (Chrome's `StartupObserver`, `chrome/browser/after_startup_task_utils.cc`). |
| O47 | `settings.adoptLaunchRead()` | critical: `Settings.applyManagedFeaturesNow` | main | 079 | The launch read as the controller's first load (design settings, managed keys, the MDM status post), with no file call and no watch; it was the first step of `settings.start`, which now waits for the first frame (Q2 81). |

## 5. `AppServices.init` starts (031)

Starts inside the initializer, outside Q1 and Q1b. 031: init holds no `start()` calls. Done (031): S6 to S10 are
`LaunchServicePosts.serviceStarts` posts (`AppServices.serviceStartPosts()`). Init keeps their wiring, which a
control in the first frame or the launch turn reads: the updater's sheet, card and tip closures and the What's New
record (`UpdaterService.wire`), the `palette.restartServer` binding (`ServerUpdatePresenter.bind`), the no-activate
keyboard guard (`InputVerificationService.startNoActivateGuard`, an NSApp input hook, S11) and the notifications' app
(`NotificationCenterService.wire`; the Chief pet the platform services make in the launch turn needs it).

| # | Step | Priority | Destination | Owner | Reason |
|---|---|---|---|---|---|
| S1 | `TraceBlackBoxFileSteps.startApp(...)` | root | `.lane(.files, ...)` | - | The black-box ring from the first trace point; the file opens on `.files`. |
| S2 | `SidebarSnapshotStore(file:)` (sync read) | main() read | `.lane(.files, .userBlocking)` | 075 | The sidebar's first frame reads it; becomes a LaunchRead. |
| S3 | `CrashRecoveryService(...)` (`AppRunMarker` read and write) | main() read, write afterFirstFrame | `.lane(.files, .userBlocking)` | 075 | Crash recovery decides the restore; the read is a LaunchRead. |
| S4 | `AppCrashReporting(environment:)` (Sentry, crash forwarders) | root (handlers), integrations afterStartup | `.lane(.files, .bestEffort)` | 032, 078 | Crash and signal handlers at launch; forwarders and session I/O after startup. |
| S5 | `remoteTerminals.start()` | onDemand: the first mount of a remote-terminal tab (a restored window's selected one in its first frame), open, close or move | main | 021 | Restored remote workspace reconnects. Done (021): `AppServices.remoteTerminals` starts it when made. No post: the first frame that shows such a tab needs the service to mount it, and nothing follows a session no tab shows. Its tab chip (`RemoteTerminalService.badge(for:machines:)`) reads only the machines and makes none. |
| S6 | `surfaceInvariant.observeWindowOcclusion()` | afterFirstFrame | main | 031 | Occlusion observer. |
| S7 | `updater.startAttachedWork()` (this build's notes, the tip re-pick on activation), `serverUpdates.start()` | afterStartup | main | 031 | The updater's reads and the server update observers; their wiring stays in init. |
| S8 | `input.start(services:)` | afterFirstFrame | main | 031 | Input verification observers; the no-activate keyboard guard stays in init. |
| S9 | `browserHost?.start()` | afterStartup | main | 031 | Browser host engine provider (idle until the daemon offers the endpoint). |
| S10 | `notifications.start()` | afterFirstFrame | main | 031 | Banners; nothing to show before the first frame. A notification the daemon sent before it still arrives. |
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
| Q1-7 | `_ = terminalColors` | built by its reader at the daemon start (024) | 024 | `TerminalColorSync` is an observer with no reader before the first frame (`TerminalTheme.follow` does not read it; only a Ghostty config change does), and built late the daemons would answer the first terminals' OSC 10/11/12 queries without the painted colors. Done (024): `AppServices.startLocalDaemon` (Themes/TerminalColorSync.swift) builds it and applies the colors just before `daemon.start`. It is still built before the first frame (the daemon needs it), so this moves no launch work; it names its reader. |
| Q1-8 | `_ = remoteLocalhost` | onDemand | 021 | Its follow runs after startup (Q2 74). Done (021): made by a remote machine's browser tab (its route, store or loopback chip), a machine browser, or a remote machine's connection; this Mac's pages ask `RemoteLocalhostService.routesToThisMac` and make none. It takes the current settings in the turn it is made, then follows them. |
| Q1-9 | `_ = emptyWorkspaces` | onDemand; afterStartup `EmptyWorkspaceRepair.observe` on main | 022 | A window's content builds it before its frame; with no window shown, the post starts its store observation. |
| Q1-10 | `_ = keyRouter` | keep | - | Keys work from the first frame. |
| Q1-11 | `_ = resources` | onDemand | 022 | Built by its first reader. |
| Q1-12 | `_ = windows` | keep | - | `WindowManager`: the restore. |
| Q1-13 | `_ = dragSession` | onDemand | 022 | First drag. |
| Q1-14 | `_ = previews` | onDemand | 022 | First tab preview. |
| Q1-15 | `_ = remoteTerminals` | onDemand (its start is S5) | 021 | Restored remote workspaces. Done (021). |
| Q1-16 | `_ = palette` | onDemand | 023 | Deleted: `AppServices.palettes` (`PaletteOnDemand`) builds the palette at its first read, then its `whenBuilt` hooks; `Palette.build` afterFirstFrame; a palette key before that builds it in the key's turn. |
| Q1-17 | `_ = configActions` | onDemand (its start is Q2 54) | 022 | Custom actions. |
| Q1-18 | `_ = chromiumWarmup` | onDemand | 024 | Done (024): `TabContentCache.chromium` (`ChromiumEngineSlot`) builds the `CEFEngine` at its first read (a Chromium tab or page, the afterFirstFrame warm-up). The launch readers (`webUI`'s page host, `cefUnavailable`, the link-click, managed-policy, password, search and proxy followers) read the slot and apply through `whenBuilt`, so no engine is built before the first frame unless a Chromium page is opened then. |

022 owns 8 builds (the spec says 6). The extra 2 are Q1-6 and Q1-7. 022 made 7 lazy and kept Q1-7 (above);
024 gave Q1-7 its daemon-start reader, so with 020's auth split for Q1-1, Q1 is 3 (cache, keyRouter, windows). Without the auth split Q1-1 stays built before the
first frame (by the critical `ManagedPolicyBridge.start`), so it does not count toward the target.

## 7. Q1b stored initializers (46)

Queue command: `grep -n -E '^    (let|var|private\(set\) (var|let)) [a-zA-Z]+(: [^=]+)? = [A-Z][A-Za-z.]*[(.]' Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppServices.swift`.
46 hits at `5ac4dd1680c` (task 070); 42 at `cf1f106ddbe` (task 015); the spec's 43 at `772cdfc45ac`. Between
`772cdfc45ac` and `cf1f106ddbe`, `inputTap` (p04-input) and `energyMonitor` (p14-energy) moved out of `AppServices`
(passed by init) and `appEvents` (p06-scheduler-021) was added. Between `cf1f106ddbe` and `5ac4dd1680c`, 5 left
the queue: `openPanel` and `terminalTheme` are lazy vars now, and `mobile`, `chromiumRuntime` and `hoverCards` are
built in `init` (so the queue command no longer matches them). 9 were added: `hiddenLayoutWork`,
`workspaceEvents`, `motionLateCommits`, `oracleTurns`, `switchHits`, `inputFrameSignposts`, `overlayChanges`,
`terminalScreenChanges` and `tabSwitch`. Line numbers at `5ac4dd1680c`. Mark: `value-only` (the initializer
stores values, no I/O, no observer, no source), `lazy` (becomes a lazy var built on first use), `posted` (the
work in its initializer moves to a post). The "Init does" column comes from reading each initializer; 098
checks each and changes the `lazy` and `posted` rows. Of the 9 new rows, only `motionLateCommits` is not
value-only: it adds a main run-loop observer during `AppServices.init`.

| # | Line | Property | Init does | Mark | Owner |
|---|---|---|---|---|---|
| B1 | 57 | `themeStore = ThemeScope.app.store` | A reference to the app store. | value-only | - |
| B2 | 59 | `recoveryDrafts = RecoveryDraftStore(directory:)` | Stores the directory; reads on `load`. | value-only | - |
| B3 | 91 | `autoNameHold = WorkspaceAutoNameHold()` | Empty. | value-only | - |
| B4 | 103 | `machineAsks = SidebarAsks()` | Empty. | value-only | - |
| B5 | 115 | `showcase = ShowcaseState()` | Value. | value-only | - |
| B6 | 127 | `machineHealth = MachineHealthStore()` | Empty. | value-only | - |
| B7 | 129 | `hiddenLayoutWork = HiddenLayoutWork()` | Two counters. | value-only | - |
| B8 | 132 | `appEvents = AppEvents(center: .default)` | Stores the notification center; observers subscribe per name on use. | value-only | - |
| B9 | 136 | `workspaceEvents = AppEvents(center: NSWorkspace.shared.notificationCenter)` | Stores the workspace notification center; observers subscribe per name on use (as `appEvents`). | value-only | - |
| B10 | 150 | `iphone = IPhoneHostService()` | Starts a task that follows the supervisor's states. | lazy | 098 |
| B11 | 155 | `motionLateCommits = MotionLateCommits(displays:)` | The convenience init calls `start()`: adds a `CFRunLoopObserver` (after waiting, before waiting, exit) to the main run loop in common modes, so it runs on every main turn of the launch. | posted: afterFirstFrame, main (it judges commits only while a Motion animation runs; none runs before the first frame) | assigned here (no task yet) |
| B12 | 161 | `oracleTurns = OracleActionTurns()` | An `OracleTurnRecorder` with a 256-slot ring (one array of 256 empty optionals). | value-only | - |
| B13 | 164 | `blocking = BlockingDetector.forProcess()` | A handle to the process table. | value-only | - |
| B14 | 199 | `browserStores = BrowserSharedStores.application()` | File-backed site settings and zoom levels per profile. | lazy; any read on `.files` | 098 |
| B15 | 201 | `signInCallbacks = CEFSignInCallbacks()` | Empty. | value-only | - |
| B16 | 203 | `resizes = ResizeCoordinator()` | Stores a closure; its frame client is lazy. | value-only | - |
| B17 | 221 | `switchHits = SwitchHits(counting:)` | Stores a compile-time flag (`ControlRouter.debugMethodsAllowed`); counters are made on first hit. | value-only | - |
| B18 | 241 | `surfaceInvariant = SurfaceInvariantMonitor()` | A DemandTimer value; the observer starts in S6. | value-only | 031 |
| B19 | 243 | `input = InputVerificationService()` | Values; observers start in S8. | value-only | 031 |
| B20 | 254 | `workContext = WorkContextTrail()` | Value. | value-only | - |
| B21 | 399 | `browserNativeInputs = BrowserNativeInputs()` | Values. | value-only | - |
| B22 | 401 | `paneTabBars = PaneTabBarChoices()` | One `UserDefaults` array read; every pane build reads it. | value-only (the defaults domain is loaded once per process; 038 if Q5 lists it) | 038 |
| B23 | 403 | `paneFullWidthTabs = PaneFullWidthTabs()` | One `UserDefaults` array read; every pane build reads it. | value-only (as `paneTabBars`) | 038 |
| B24 | 405 | `paneMounts = PaneMounts()` | Value. | value-only | - |
| B25 | 407 | `newTabChoices = NewTabChoiceMemory()` | Stores the defaults; reads on use. | value-only | - |
| B26 | 409 | `newTabWeather = NewTabWeather()` | A `UserDefaults` data read and a JSON decode. | lazy | 098 |
| B27 | 411 | `chiefModelRecents = HomeChiefModelRecents(defaults:)` | Stores the defaults. | value-only | - |
| B28 | 412 | `newTabTypeAhead = NewTabTypeAhead()` | Empty. | value-only | - |
| B29 | 414 | `homeSwitchKeys = HomeSwitchKeysSource()` | Stores the defaults and a reader. | value-only | - |
| B30 | 416 | `memoryPressure = MemoryPressureEvents(source:)` | Starts the kernel memory-pressure source. | posted: afterFirstFrame, main (the level reads normal until then; the restored-page loader runs after startup) | 098 |
| B31 | 467 | `terminalDelegate = TerminalHostDelegate()` | Value. | value-only | - |
| B32 | 469 | `notifications = NotificationCenterService()` | Values; starts in S10. | value-only | 031 |
| B33 | 491 | `inputFrameSignposts = InputFrameSignposts()` | Values and one `reserveCapacity`; the `KeyFrameSignpost` is made at the first key. | value-only | - |
| B34 | 521 | `chiefPetHomes = ChiefPetHomes()` | Empty. | value-only | - |
| B35 | 523 | `chiefMascotPicks = ChiefMascotPicks(defaults:defaultChief:)` | A `UserDefaults` dictionary read. | lazy | 098 |
| B36 | 593 | `linkHints = LinkHintController()` | Values. | value-only | - |
| B37 | 595 | `reactGrab = ReactGrab(scripts:)` | Stores the loader; loads on use. | value-only | - |
| B38 | 597 | `windowHints = WindowHintController()` | Values. | value-only | - |
| B39 | 617 | `pages = InternalPageTabStore()` | Values. | value-only | - |
| B40 | 621 | `favicons = TabFaviconStore(loader:)` | Stores the loader. | value-only | - |
| B41 | 626 | `overlayChanges = OverlayChangeFeed()` | A `Mutex` around an empty subscriber table. | value-only | - |
| B42 | 630 | `terminalScreenChanges = OverlayChangeFeed()` | As `overlayChanges`. | value-only | - |
| B43 | 636 | `refusalHUD = RefusalHUD()` | Stores the toast center. | value-only | - |
| B44 | 654 | `burstTrace = BurstTrace()` | Empty. | value-only | - |
| B45 | 658 | `tabSwitch = TabSwitchSignpost()` | Stores the signposter and a `CommitBoundary` closure. | value-only | - |
| B46 | 660 | `vscodeServeWeb = VSCodeServeWebService(...)` | Stores a planner (home directory, environment) and a launcher. | lazy (only the VS Code page uses it; quit calls it only when built) | 098 |

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

## 13. Hour-0 launch seed (072)

These are the first measured rows for Q6 (main CPU before the first frame) and Q5 (main-thread waits).
They come from the tools that exist at `772cdfc45ac`. Status: partial. The `772cdfc45ac` run is complete
at mark-interval level. The `ba1d1a4a239` run, the per-symbol profile and the App Launch template are
still open, for the reasons in "Open" below.

### How it ran

- Run: fleet step `553abcd1be26ba33337a9742` on cmux22-perf, 2026-10-26. Ref `cp/p08-startup-072-m772`
  at `678eeb5a0e4` is `772cdfc45ac` plus measurement scaffolding that is never merged:
  `scripts/cmux-next/launch-seed-072.py`, a `--suite=launch-seed` dispatch in `split-spring-terminal.py`,
  and `CMUX_BLOCKING_PROBE_UNTIL_MS` in `probe.c`.
- Command: `cmux-ci run --class exclusive --measurement --label measure --script
  scripts/measure/split-spring.sh --ref <ref> --artifact artifacts/split-spring/report.json
  --arg=--config=bench --arg=--vdisplay=120 --arg=--suite=launch-seed --arg=--runs=10 --arg=--hangs=16`.
- App: `reload.sh --config bench` (Release optimization, `-DCMUX_BENCH_HOOKS`) on a 120 Hz virtual main display.
- State: bench-startup's realistic seed without the agent chat: 24 workspaces of 3 terminal tabs and a split,
  with project-01's first terminal selected at quit. The daemon stays up (warm).
- Parts: 10 warm launches with every launch mark and `debug.hangs` >= 16 ms; 3 launches under
  `xctrace record --template 'Time Profiler' --all-processes` (pids 92909, 93083, 93236); 3 launches with
  the blocking probe (pids 93317, 93458, 93544).
- Load average before the bench: 16.8 / 13.4 / 10.5, because a 713 s build ended just before it.

### Marks (10 runs, ms since process start)

| Mark | p50 | p95 |
|---|---|---|
| `main_start` | 2934.2 | 2952.9 |
| `main.run` | 2983.1 | 3009.9 |
| `did_finish_launching_start` | 3013.2 | 3034.1 |
| `terminal.launch_frame_shown` (the saved picture in its pane) | 3103.3 | 3125.3 |
| `did_finish_launching_end` | 3153.7 | 3176.8 |
| `first_window_frame_committed` | 3203.8 | 3227.6 |
| `first_terminal_content_applied` | 3286.8 | 3318.7 |
| `first_terminal_frame` | 3386.3 | 3418.2 |
| `main_start` to `first_window_frame_committed`, per run | 270.6 | 280.3 |

Two findings set the order of work:

1. **2.9 s pass before `main()`, and the main thread is almost idle in that time.** The 3 profiles have
   36 to 45 main-thread samples (1 ms each) between process creation and `main_start`. All of them fall in
   one burst that starts about 45 ms before `main_start` (dyld and static initializers). The rest is a wait
   between the launcher's fork and dyld's start. It is either in the launcher before exec or in the
   kernel's exec (code signature, execution policy), and the probe sees neither. Earlier Debug runs did not
   wait like this (`ba1d1a4a239` on cmux20-bench: first frame 499 ms). So the cause is the bench (Release)
   executable or the launcher. The App Launch rerun (Open, item 1) separates the two. Until then, read this
   run relative to `main_start`.
2. **The app's own part is 270.6 ms p50 from `main_start` to the first frame.** Main CPU in that window is
   about 217 ms (3 profiles). Here is the 450 ms gap of the Debug `ba1d1a4a239` run, in an optimized build
   without the launch-read slice: the pane's saved picture is in place at `main_start` + 169 ms, and the
   frame that shows it commits at `main_start` + 270 ms.

### Q6 seed: main CPU before the first frame, by interval

Main-thread CPU from the Time Profiler runs, p50 of 3: 261 ms from process creation to the first frame.
That is 44 ms pre-main, 31 ms CPU in the 79 ms wall from `main_start` to `did_finish_launching_start`,
137 ms CPU in the 140.5 ms wall of `applicationDidFinishLaunching`, and 49 ms CPU in the 49.6 ms commit.
The interval rows cover 217 of the 261 ms (83 %). The rest is the 44 ms pre-main burst, which has no
stack in this pass. Each row is a per-run delta between launch marks (10 runs). File and line are at
`772cdfc45ac`.

| # | Interval | p50 ms | p95 ms | Code (772cdfc45ac) | What runs |
|---|---|---|---|---|---|
| S1 | process start -> `main_start` | 2934.2 | 2952.9 | before `CmuxNextApp.swift:15` | A wait (finding 1). About 44 ms of CPU, in its last burst. |
| S2 | `main_start` -> `main.warmup_started` | 6.3 | 7.4 | `CmuxNextApp.swift:15-38` | Malloc zone, signal policy, open-file limit, CloudAuth capture, `prepareLaunchEnvironment`, `LaunchWarmup.start`. |
| S3 | `main.warmup_started` -> `main.prestart` | 6.3 | 7.3 | `CmuxNextApp.swift:39-54` | `AppEnvironment.current`, the 2 `.shared` stores, `DaemonService.prestart` (binary resolve, install key). |
| S4 | `main.prestart` -> `main.nsapp` | 40.2 | 51.4 | `CmuxNextApp.swift:55-63` | `CrashOnExceptions.register`, `CmuxApplication.shared`, `AppDelegate(environment:daemonPrestart:)`, `setActivationPolicy(.regular)`. The largest step in `main()`. |
| S5 | `main.run` -> `did_finish_launching_start` | 24.6 | 34.6 | `CmuxNextApp.swift:67` (`app.run()`) to `AppDelegate.swift:81` | AppKit's finishLaunching up to the delegate, then `forcedQuitExit` and `control.startWatchdog()`. S2 to S5 take 77 ms wall but only 31 ms CPU. The probe saw less than 3 ms of waits there, so about 45 ms are waits the probe does not see. The likely candidate is mach_msg to WindowServer or launchservicesd; App Launch confirms it. |
| S6 | `did_finish_launching_start` -> `dfl.settings_read` | 7.5 | 8.2 | `AppDelegate.swift:81-102` | `NativeCaretAccessory.install`, `LastAppCLIPointer`, `SettingsController.readAtLaunch`, `TerminalThemeSetting.prime`. |
| S7 | `dfl.settings_read` -> `dfl.theme` | 4.0 | 4.3 | `AppDelegate.swift:103-109` | `ThemeBridge.start` (the first `GhosttyRuntime.shared`) and 3 `PageDescriptor.register*`. |
| S8 | `dfl.theme` -> `dfl.services` | 7.8 | 8.0 | `AppDelegate.swift:110-119`, `AppServices.swift:444-593` | `AppServices.init` (4.2 ms to `services.crash_reporting`), watchdog reporting, debug settings. In 4 of 10 runs the 16 ms stall sample's top cmux frame is `ChromiumRuntimeService.make` -> `CEFRuntimeLayout.locate`. |
| S9 | `dfl.services` -> `dfl.bind` | 15.7 | 16.2 | `AppDelegate.swift:120-131` | `AppActions.bind`, `HandlerCoverage.verify`, `palette.bindRegistryActions`, `GhosttyKeybindSync.start`, `GhosttyConfigLiveReload.start`, `TerminalHooks.install`. The largest step of `applicationDidFinishLaunching` before the window. |
| S10 | `dfl.bind` -> `dfl.menu` | 5.3 | 6.7 | `AppDelegate.swift:132-136` | `startSettingsAndControl` and `newTabSpares.prewarm` (2.8), then `MainMenu.make` (2.5). |
| S11 | `dfl.menu` -> `dfl.home_history` | 5.6 | 5.8 | `AppDelegate.swift:137-208` | `activateApp`, `launchSettle.install`, `DaemonPrompts`, `daemon.start` (launch snapshot applied), `FeaturePolicyEnforcer`, `startCloud`, first-window hooks, `browserProfiles.load`, `home.start`, keybindings file, bookmarks, history, `FirstPartyPageSchemes.install`, `ChromiumPageHost`. |
| S12 | `dfl.home_history` -> `sidebar_rows_shown` | 7.0 | 8.1 | `AppDelegate.swift:209` -> `WindowManager.swift:293` | `restoreWhenLoaded`, `LaunchSnapshotWindow.show`, `WindowController` init, the sidebar rows. |
| S13 | `sidebar_rows_shown` -> `reveal.tabs` | 19.1 | 22.6 | `WindowManager.swift:293-301` | The window's tab strips (24 workspaces in the sidebar; 3 tabs and a split shown). |
| S14 | `reveal.tabs` -> `first_terminal_surface_created` | 10.5 | 13.4 | `WindowManager.swift:301`, `WindowController.swift:270` | `showWorkspace`: the workspace content, then the first Ghostty surface. |
| S15 | `first_terminal_surface_created` -> `terminal.launch_frame_shown` | 7.0 | 9.1 | `PaneController.swift:422` | The terminal panes and their saved frames. Without the launch-read slice, the read and the decode run here. |
| S16 | `terminal.launch_frame_shown` -> `dfl.windows` | 50.0 | 52.4 | `WindowManager.swift:301-310`, `WindowManager.swift:343-358` | The rest of `showWorkspace`, then `present` (`WindowActivation.show`, `onPresent`, full-screen restore) and `onFirstWindow`. The largest single interval: in this turn the window and its tree are made and ordered in, all on main. |
| S17 | `did_finish_launching_end` -> `first_window_frame_committed` | 49.6 | 56.0 | `AppDelegate.swift:162` (the commit's completion block) | AppKit layout and display of the whole window, then the Core Animation commit. CPU-bound (49 ms CPU). |

S12 to S17 take 143 of the 270.6 ms. This is the work that 059 and 060 take off the first frame: the first
frame shows the picture, and the live window builds behind it. After those, the largest intervals left in
`main()` and the delegate are S4 and S9. S4 and S5 go to 033 and 012, S9 to 030, and S12 to S17 to 059
and 060.

After the first frame (3 s window, Time Profiler, p50 of 3): 706 ms of main CPU, in 12 to 13 bursts of
16 ms or more; the longest take 46 to 88 ms. One terminal frame takes 100 ms p50
(`first_terminal_content_applied` -> `first_terminal_frame`), because launch work keeps main busy. From
`debug.hangs`: `CefInitialize` 104 ms and the CEF message pump 31 ms per stall.
`MadeAheadPanelStore`'s `NSOpenPanel()` (`MadeAheadOpenPanel.swift:38`, armed at `AppDelegate.swift:182`)
stalls 203 ms p50 in 10 of 10 runs with only 10 ms of CPU, so it is a wait that the probe does not see.

### Q5 seed: main-thread waits (blocking probe)

3 launches. The probe records only main-thread calls, from its load (exec) to +3204 ms. Because of
finding 1, that window ends after the first frame and also holds work done after the frame. In total the
probe saw 80 ms of waits per launch, and it added about 72 ms of its own. The ms column is the mean per
launch over the 3 launches.

| # | Site (772cdfc45ac) | ms / launch | max ms | Kinds | Before the first frame? | Owner task |
|---|---|---|---|---|---|---|
| W1 | `ChromeWebAppShortcutCopierMain` (CEF) | 44.2 | 69.7 | stat, access, fcntl, waitpid | no (CEF start) | 040, 046 |
| W2 | `ShellWindow.init(contentRect:styleMask:backing:defer:)` | 1.96 | 2.88 | dispatch_sync | yes (S12, the window) | 060 |
| W3 | `CEFRuntime.initialize` closure, `CEFRuntime.swift:399` | 1.87 | 2.58 | access, getattrlist, waitpid | no | 040 |
| W4 | `CmuxApplication.init()` | 1.58 | 1.53 | getattrlist, statfs, stat, dispatch_sync | yes (S4) | 033 |
| W5 | `LegacyHistoryFile.removeGenerationIfUnchanged`, `LegacyHistoryFile.swift:96` | 0.99 | 2.64 | unlinkat | yes (S11, `history.start`) | 028 |
| W6 | `+[NSCGSWindow windowWithWindowID:]` | 0.90 | 2.70 | pthread_mutex_lock | yes (S16) | 060 |
| W7 | `CefInitialize` | 0.70 | 0.06 | getattrlist, open, access | no | 040 |
| W8 | `ImportCardDeck.list()`, `ImportCardDeck.swift:22` | 0.47 | 0.04 | open, fstat, read | to check | - |
| W9 | `CodeSigningTeam.read()`, `FrontendInstallKeyStore.swift:41` | 0.35 | 0.06 | getattrlist, pread | yes (S3, prestart) | 066 |
| W10 | `ConfigFileWatcher.makeSource`, `ConfigFileWatcher.swift:119` | 0.29 | 0.03 | open | yes (S11, watchers) | Q13 |
| W11 | `LegacyHistoryFile.quarantineIfUnchanged()`, `LegacyHistoryFile.swift:121` | 0.24 | 0.15 | renameat | yes (S11) | 028 |
| W12 | `SettingsPageDomains.fontFamilies`, `SettingsPageProvider.swift:417` | 0.24 | 0.02 | getattrlist, open | to check | - |
| W13 | `NSBundle.module`, `resource_bundle_accessor.swift:32` | 0.22 | 0.02 | stat, access | to check | - |
| W14 | `AgentPaneView.startWarmup()`, `AgentPaneView+Warmup.swift:41` | 0.26 | 0.06 | stat, open | no (`launch.agent_page_warmup`) | - |
| W15 | `AcpmuxServerPeer.ownTeam`, `AcpmuxServerPeer.swift:255` | 0.19 | 0.03 | getattrlist, pread | to check | - |

The waits with a cmux frame that run before the first frame (the rows marked yes) add up to 6.3 ms per
launch. Another 13 ms per launch (`__opendir2` 8.2, `fopen` 4.6) has no cmux frame, and the dump does not
say when it ran. Waits are therefore not the main reason the first frame is late. The main reasons are the
main CPU of S4, S9 and S12 to S17 and the wait before `main()` (finding 1). The probe does not see
mach_msg, semaphore_wait and its other known gaps; those are the candidates for the 45 ms of S2 to S5
that is not CPU.

### Open

1. Rerun with the fixed scaffolding. Refs `cp/p08-startup-072-m772` (`0533c04f972`) and
   `cp/p08-startup-072-mba1` (`f5218de9018`) add three things:
   - the launcher's fork-to-exec time (`popen_ms`);
   - profile windows that start at exec;
   - 3 `xctrace record --template 'App Launch' --launch` runs (process life cycle, dyld, static
     initializers).
   The rerun also has the stack fix. In this run, the parser did not read the backtraces in the rows that
   `xctrace export` gave, so S1 to S17 have no symbol rows yet. Q6's rows for symbols of 2 ms or more,
   and the cause of S1, come from the rerun.
2. `ba1d1a4a239` (the launch-read slice) is not measured yet. Fleet steps `abc0910cdb9e086a443fc953`,
   `8d9dcba347563a09f7ccaad3`, `8fd0ae5f72e0540262aad40d` and `fdd69e51786b6bbf5268ee47` stopped in
   `reload.sh` with "cmux-next build needs 40 GiB free on the home volume". So did the `772cdfc45ac`
   reruns `235ca9bea17f7d82082b8e60`, `ba4ef9abdbe5b994752f34d1` and `187cf4ed320f50f06473d18b`. On
   2026-10-26, every online perf host had 30 to 44 GiB free when idle. A step's checkout uses about 8 GB
   before the check, so a host needs about 48 GiB free when idle. `CMUX_NEXT_MIN_FREE_GIB` is not on the
   ci-step allowlist. To rerun, use the command above with the two refs and add `--arg=--app-cache`, so
   that each build is kept for a later part.

## 14. After numbers: the 15 done checks at the tip (070)

Task 070 of [p08-startup.md](chrome-parity/p08-startup.md): one row per done check of its section 5, read at
`5ac4dd1680c` (origin/perf/chrome-parity, 2026-10-26). The perf-lead.md results log has the same 15 rows.

Verdicts: `PASS` and `FAIL` are checked here, from the tree (static counts, files, switches), on a Linux VM
with no build. `FAIL (tree)` means that no run at this sha can pass the check, because a probe, a tool or a pin
that the check reads is not in the tree. `not measured` means that the check needs a run on a fleet GUI mini
with a `--config bench` app of this sha, and that run was not done.

Why the runs were not done: (1) The baseline of task 069 is not on perf/chrome-parity (no `cp/p08-startup-069`
branch, no 069 rows in perf-lead.md), so an A/B against the base has no "before" side. (2) Task 070 ran on a
Linux VM, with no fleet build and no GUI host (the round's one fleet compile belongs to the lead). (3) Checks
3, 4, 9, 10 and 13 fail on the tree, so a run does not change their verdict. Checks 1, 2, 5, 6, 7, 11, 12, 14
and 15 have their tools in the tree; one fleet session runs them with the commands below.

After the table was read, perf/chrome-parity got the partial 069 baseline at `772cdfc45ac` (perf-lead.md,
rows "p08-startup-069 baseline (partial)") and the 072 launch seed (section 13). Reason (1) is now only
partly true: the base has launch marks and an App Launch read, but not the 20 warm and 10 cold runs of
checks 1 and 2. The verdicts below stay as read at `5ac4dd1680c`.

| # | Done check | Verdict at `5ac4dd1680c` | Evidence | The run that gives the verdict |
|---|---|---|---|---|
| 1 | Warm launch (first frame p50 <= 150 ms, p95 <= 180 ms; `window_display` p50 <= 140 ms; live p50 <= 300 / 450 ms; `startup_complete` p50 <= 800 ms) | not measured | No 069 baseline. The last number on record is from before this program: issue #17587 (perf-lead.md row 18), first frame 217-263 ms, live tree 351-936 ms at 24 workspaces. | `python3 scripts/cmux-next/bench-startup.py --app "$NX_APP" --mode warm --profile realistic --runs 20 --require-optimized --json warm.json` |
| 2 | Cold launch (first frame p50 <= 300 ms, p95 <= 360 ms; live p50 <= 600 ms; `startup_complete` p50 <= 1500 ms; cold in >= 8 of 10) | not measured | No 069 baseline. The host must allow `sudo -n purge`. | `bench-startup.py ... --mode cold --temperature cold --runs 10 --json cold.json` |
| 3 | First frame is the picture (`first_commit_layer_tree`, `views_built == 0`, mark order) | FAIL (tree) | `debug.startup` has no `first_commit_layer_tree` field and no `views_built` field: 0 hits for either name in `Packages/`. The order part can be measured: `launch_picture_shown` (CmuxNextLaunch) and `launch.non_paint_services` (bench-startup.py) are marks. | When the two fields are in the tree: `debug.startup` after each warm run of check 1. |
| 4 | Main thread at launch (`main_cpu_ms_to_first_frame <= 60`, `critical_violations == 0`, allowlist <= 15, no early afterStartup task, never `failsafe`, startup-lint 0) | FAIL (tree) | Allowlist: 14 names in `StartupScheduler.criticalAllowlist` (<= 15, PASS). `critical_violations` is in `debug.startup` (StartupTaskLog.swift). `main_cpu_ms_to_first_frame` is not a field (0 hits; `debug.main_cpu` is a per-frame probe, not a launch total). `scripts/cmux-next/startup-lint.py` (task 104) is not in the tree. | When 104 and the field are in the tree: `debug.startup` after each warm run of check 1, and `python3 scripts/cmux-next/startup-lint.py`. |
| 5 | No hangs at launch (0 stalls > 250 ms; 0 main turns > 16 ms except the named turns; main turn p99 <= 4 ms) | not measured | - | `debug.hangs` from process start to `startup_complete + 5 s` on the 20 warm runs of check 1 and the 10 cold runs of check 2. |
| 6 | No blocking at launch (0 sites on main before `startup_complete`; 0 raw calls before the first frame) | not measured | The tool is in the tree: `startup-queue.py blocking` (it refuses a `--config bench` app). The raw-call half (`blocking-probe.sh --until-mark`, p08-18's 084 kinds) was removed in deletion wave 1 (2026-10-29); the base probe has no launch window. | On a `--config bench-checks` app: `python3 scripts/cmux-next/startup-queue.py blocking --app "$NX_APP" --runs 5`. |
| 7 | Chromium in STRESS (CEF starts after `startup_complete` with no visible page, and <= first frame + 20 ms with one, reason `visiblePaneLoadedIdle`; no hidden renderer; loader cap; F2 host kill) | not measured | `visiblePaneLoadedIdle` is a reason in the tree. The check names a `RestoredPageLoader`; at this sha there is no type of that name, and the deferral is `TabContentCache.defersRestoredPages`. | 20 STRESS runs of bench-startup.py, each with the `debug.startup` and `debug.cef` reads; the F2 part needs F2 on. |
| 8 | Static counts (Q1 <= 3; every Q1b initializer marked here; Q3 = 0; startup-lint 0) | FAIL | Q1: 3 (`cache`, `keyRouter`, `windows`), PASS. Q1b: 46 of 46 marked (section 7, refreshed by this task; 41 of 46 before), PASS. Q3: 1 call, `launchSettle.settled(within: .seconds(4), ...)` at `AppDelegate.swift:397`, and 1 timer, `DemandTimer(owner: "LaunchSettle.settled")` at `LaunchSettle.swift:59` (target 0; owners 016 and 018), FAIL. startup-lint.py: not in the tree, FAIL. The script of section 8 stops at its Q2 assertion: the 82 Q2 rows are at `cf1f106ddbe`, and the awk range now gives 41 calls, because the other calls moved into launch lists (for example `HomeService+LaunchList.swift` and the `AppControl.swift` groups). After 014 that check belongs to startup-lint.py. | Static: run the section 6 queue commands again. |
| 9 | Order file (>= 90 % of order symbols resolved; profdata sha in the header matches; cold A/B pageins -30 %, first frame p50 -10 %) | FAIL (tree) | The Release link uses the order file (`ORDER_FILE` and `LD_GENERATE_MAP_FILE = YES` in the cmux-next Release block, task 051). But `Resources/build/cmux-next.order` has 0 symbol lines and no profdata sha in its header, so coverage is 0 of 0 and no sha can match. The refresh (054, `scripts/cmux-next/pgo/refresh.sh`) has not run. | When a refresh commits the order: `python3 scripts/cmux-next/pgo/check.py --app "$NX_APP" --order Resources/build/cmux-next.order --link-map MAP`, then the cold A/B (purge, 10 runs each, same host) with and without the order. |
| 10 | PGO (`-profile-use` on every CmuxNext Swift target, `-Cprofile-use` on cmux-tui and cmux-app-ffi; first frame p50 -5 %; no typing or motion p95 regression > 2 %; Nightly only with the switch on) | FAIL (tree) | `Resources/build/cmux-next.pgo.conf` has `use=0`; `Resources/build/cmux-next.profdata.sha256` has no sha line; `cmux-tui/crates/cmux-tui/pgo.txt` and `cmux-tui/crates/cmux-app-ffi/pgo.txt` do not exist. So no Release build gets either flag. The wiring is in the tree (052: `Package.swift` reads `CMUX_PGO_PROFDATA`; 056: `build-app-ffi.sh` calls `rust-pgo.sh rustflags`). The Linux Rust A/B of section 12 showed no gain (the target needs a fleet Mac). | When a profile is pinned: the Release log of `scripts/cmux-next/check-release-compile.sh`, then 20 warm runs plus `bench-typing.py` and `pane-perf-terminal.py`, with `CMUX_NEXT_PGO_USE=1` and with `CMUX_NEXT_PGO_USE=0`. |
| 11 | Startup tracing (`CMUX_TRACE_STARTUP=5` file loads in Perfetto with app, daemon and CEF tracks; parseable after `kill -9` at 1 s; unset: `trace_ring_bytes == 0`, no CEF switch; `trace.py record --scenario launch-cold`) | not measured | `CMUX_TRACE_STARTUP` is read in the tree (StartupTrace.swift, trace.py); `trace_ring_bytes` is in `DebugTimings.swift`. On Linux, `test_trace_launch` has 1 error at this sha: `test_trace_app_launch_environment` gives `trace.TraceApp` a namespace with no `release` field, and `trace.py` reads that field since `6f8e82441cf` (p09-observability-023). The fault is in the test fixture, not in the tool. | `python3 scripts/cmux-next/trace.py record --scenario launch-cold --app "$NX_APP"` x5, and a `CMUX_TRACE_STARTUP=5` launch killed at 1 s. |
| 12 | Field (the Nightly opt-in report has `launchFirstFrame` and `launchStartupComplete` by temperature, no interrupted launches, the slow-launch ring only after a forced slow launch; PrivacyLeakScanner; off allocates nothing) | not measured | The histograms and their tests are in the tree (`LaunchHistogramTests` and `MetricKitPayloadFuzzTests` in CmuxNextHangReportsTests). Swift does not build here, so they did not run. | A fleet `swift test` of the CmuxNextHangReportsTests filter, then a NIGHTLY-config app with reports on: 10 launches and one forced slow launch, then read the report. |
| 13 | Launch correctness matrix (16 cases, macOS 26 and 27, Tart 14 and 15) | FAIL (tree) | Task 071 is not on perf/chrome-parity: `relaunch-e2e.py` and `restore-trace.py` do not have the done-check-13 cases (1 line of relaunch-e2e.py and 0 lines of restore-trace.py match a case name). | When 071 is in the tree: `relaunch-e2e.py` and `restore-trace.py` on aws-m4pro-5 (26) and aws-m4pro-1 (27), and `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15`. |
| 14 | Idle after launch (3 restored Chromium tabs, from `startup_complete + 5 s` for 30 s: app + daemon <= 1 wakeup/s, main <= 0.5/s; no launch-only timer armed) | not measured | `scripts/cmux-next/bench-idle.sh` and `startup-queue.py arms` (Q13) are in the tree. | bench-idle on a session with 3 restored Chromium tabs, then `startup-queue.py arms`. |
| 15 | Edge launches (`CMUX_NEXT_NO_ACTIVATE=1` completes with reason `noWindow`, p50 < 1 s; a quit 100 ms after launch runs 0 afterStartup tasks) | not measured | `noWindow` is a completion reason in the tree (CmuxNextWakeups). | 10 launches with `CMUX_NEXT_NO_ACTIVATE=1` and the `debug.startup` read; 10 launches that quit at 100 ms, with the startup task log read. |

Totals at `5ac4dd1680c`: 0 PASS, 6 FAIL (3, 4, 8, 9, 10, 13), 9 not measured (1, 2, 5, 6, 7, 11, 12, 14, 15).
The program is not done. What blocks it, in order: the 069 baseline at the base sha; the `debug.startup`
fields of checks 3 and 4; startup-lint.py (104); the Q3 deferral (016, 018); a PGO and order refresh with a
pinned profile (054, then the switch); the correctness cases (071); then one fleet GUI session for this table.

Tool tests run here (Linux, `python3 -m unittest` in `scripts/cmux-next/tests`, 11 modules: bench_launch,
bench_startup, bench_startup_daemon_marks, bench_startup_milestones, launch_journey_results, pgo_check,
pgo_page_fault_order, pgo_scenarios, rust_pgo_scenarios, startup_queue, trace_launch): 336 tests, 24 skipped,
1 error (the `trace_launch` fixture of check 11), 1 failure (`test_bench_launch`: `bench_tagged.py` does not
import under `python3 -I`, `No module named 'bench_launch'`).
