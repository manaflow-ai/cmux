# Launch work still ahead of the first frame

Source: `Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift` at
`354ac70ce252` (2026-11-16), method `finishLaunching`.
This is an implementation handoff inventory, not a passing runtime registry.
The shell-first reorder must move these call sites before a registry can truthfully
declare them stage 1 or 2. The Rust stage-0 allowlist remains exactly
`read_launch_record`, `make_window`, `put_saved_image`, `commit_first_frame`,
`finish_launching`; the last name means the shell check-in, not the entire current
Swift method of that name.

All direct calls below currently execute or enqueue their work before the first
frame completion opens `firstFrame`. An asynchronous body can continue later;
starting it in this method is still pre-frame work.

| Current pre-frame call site | Work to relocate |
| --- | --- |
| `DaemonService.prestart` | Resolve and prepare the daemon |
| `BrowserDesignModeController.tempFiles.removeAll` | Enqueue crash-file cleanup |
| `QuitSignal.install` | Signal handlers |
| `control.startWatchdog`, `DebugTimings.install` | Watchdog and diagnostic installation |
| `NativeCaretAccessory.install` | Text-field accessory configuration |
| `WindowPlacement` assignments, `disableRelaunchOnLogin` | Placement and relaunch policy |
| `LastAppCLIPointer.publishAtLaunch` | Publish CLI location |
| `appCopyGuide.start` | Copy and install guidance |
| `SettingsController.readAtLaunch` | Read settings |
| `TerminalThemeSetting.prime`, `BrowserImportGate.prime` | Apply launch settings |
| `ThemeBridge.start`, `BackdropImageStore.shared.desktop.start` | Theme and backdrop services |
| `PageDescriptor.register*Root` | Page resource roots |
| `AppServices`, `AppProcessRoot.adopt` | Construct and retain services |
| `AgentPaneScrollAnchors` | Configure saved scroll anchors |
| `windowRecord.watchLaunch` | Debug launch recording |
| `WatchdogReporting.install`, watchdog/reveal wiring | Hang reporting and reveal hooks |
| `LaunchTimesRecorder` | Construct recorder (its write already waits for frame and Home) |
| `debugSettings.start` | Debug settings |
| `AppActions.bind`, `HandlerCoverage.verify`, palette binding | Action graph |
| `GhosttyKeybindSync.start`, `GhosttyConfigLiveReload.start`, `TerminalHooks.install` | Terminal configuration and hooks |
| `startSettingsAndControl` | Settings and control composition |
| `newTabSpares.prewarm` | Hidden spare page |
| `MainMenu.make`, `WindowActivation.activateApp` | Menu and activation |
| `launchSettle.install`, `DaemonPrompts.start`, `healthFeeds.start` | Daemon readiness and feeds |
| `services.daemon.start` | Start connection |
| `FeaturePolicyEnforcer.start`, `services.startCloud` | Feature policy and Cloud |
| `windows.onPresent`, `onFirstWindow`, palette/menu callbacks | Window and menu callbacks |
| `browserProfiles.load` | Browser profile storage |
| `home.start`, `harnessIcons.start`, mouse buttons, keybindings file | Home and input services |
| `bookmarks.start`, `history.start` | Browser state |
| `FirstPartyPageSchemes.install`, `ChromiumPageHost` | Page host composition |
| `windows.restoreWhenLoaded` | Full window restore; replace first shell construction with record-only path |
| `observeBorders`, `observeGlass`, `UpdateFeedPosting.follow` | Appearance and update observers |
| `startChromiumRuntime` | Runtime service |
| `WebAuthSessionWindows`, `WebAuthSessionHandler.install` | Web sign-in handling |
| Apple-event handler, content-appeared hook, `CmuxServicesProvider` | External-open integration |
| `openedURLs.start`, `firstFrame.armBackstop` | Delivery and fallback |

Existing deferred groups must continue running on every launch: first-frame
callbacks start non-paint services, post-frame feeds and later-tab warmups;
launch-settle callbacks warm the palette, icon catalog, cleanup and open panel.
Classify the work when the reorder actually schedules it, not by its intended future stage.
