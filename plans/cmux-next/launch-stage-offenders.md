# Launch work still ahead of the first frame

The stage-0 shell shows the saved workspace and tab (including Home). In
`AppDelegate.finishLaunching`, `firstFrame` opens on the Core Animation commit
of the restored window, with a three-second backstop for launches without a
window. The Rust stage-0 allowlist covers only `read_launch_record`,
`make_window`, `put_saved_image`, `commit_first_frame` and `finish_launching`.

## After the restored window commits

- Old design-mode cards and deleted workspace folders can be cleaned up then.
  A card attached during this launch keeps its files.
- Publish the external CLI pointer and check whether to offer a move to Applications.
  The second-copy URL listener must register before either copy can hand off URLs.
- Create the launch-times recorder. Subscribe before reading the accumulated marks
  so a front chat that already painted and connected still gets its timing row.
- Verify handler coverage and count unbound actions after binding the menu and shortcuts.
- Probe WebKit for the hidden New Tab spare with the other later-tab warmups.
- Start harness icon, GitHub feed and update-card observers, Cloud machine update
  checks, customization diagnostics, auto-archive and workspace hibernation.
  These read current state when subscribed.

## Work needed through the first interaction

- Daemon preparation, prompts, health and settle subscriptions precede the first
  daemon events. Restore, Home and Cloud authentication supply the saved workspace,
  chat, identity and interactive composer.
- Quit signals and relaunch policy apply throughout startup. The watchdog, hang
  reporting, timing sinks and window recorder need the interval they measure.
- Window placement, settings, import policy, themes, desktop backdrop, scroll
  anchors, launch layout overrides and page roots affect restored content.
  A browser can reopen directly into a named profile or a first-party page.
- Build and retain services, bind actions, key routing, clipboard hooks, mouse
  buttons and menu actions before the window accepts input. Watch Ghostty's
  config files from their initial load so an edit during restore is observed.
- Install page hosts and schemes before a restored page requests a resource.
  Bookmark and history persistence must observe its first navigation. Install
  the Chromium runtime request hook for a restored browser's first request.
- Keep window, appearance and external-open callbacks ready for the initial
  presentation, including launches from a sign-in, Apple event or Services menu.
  Arm the frame backstop even when no window will arrive.

## Original inventory

The table records the audit at `354ac70ce252` (2026-11-16). Several entries mix
first-interaction work with independent maintenance. Runtime scheduling above
describes the split.

| Call site at the audited revision | Work |
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
