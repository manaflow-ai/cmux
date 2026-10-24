# cmux-next codebase health (measured)

Measured 2026-10-23 at feat-cmux-next `fda987b0336` plus this tree's changes to `plans/cmux-next/perf-lead.md`, `scripts/cmux-next/codebase-health.py` by `scripts/cmux-next/codebase-health.py --write` (rerun it to refresh; do not edit numbers by hand).
Scope: tracked Swift in `Packages/macOS/CmuxNext/Sources`, comments stripped (section 6's perf-hot markers:
every tracked Swift file). The pre-push guardrails
(`scripts/cmux-next/guardrails.py`, run by `prepush-gate.py`) refuse NEW instances of the ratcheted rows;
the debt below never blocks a push. Owners: [OWNERS.md](OWNERS.md). Guardrail rules: section 6.

## 1. Concurrency, state and instrumentation debt

| Pattern | Lines | Files | Without the waiver comment | Why it matters |
|---|---:|---:|---:|---|
| `static let/var shared` singletons | 141 | 138 | 140 (no `singleton-allow:`) | runtime state behind a global; construct at the composition root and inject (CLAUDE.md Package design discipline) |
| `MainActor.assumeIsolated` | 235 | 163 | 73 (no `main-proof:`) | traps off main; each needs `// main-proof: <why>` (crash_ratchet.py counts the rest) |
| `@unchecked Sendable` | 67 | 60 | 41 (no `crash-allow:`) | a data race the compiler cannot see; needs `// crash-allow: <safety argument>` |
| `nonisolated(unsafe)` | 33 | 20 | 10 (no `crash-allow:`) | as above |
| raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex) | 25 | 21 | - | CLAUDE.md: actor, or the CmuxNextCompat Mutex carve-out |
| CmuxNextCompat `Mutex` uses (the sanctioned lock) | 224 | 159 | - | sanctioned; listed for scale |
| `Task.sleep` | 25 | 22 | 0 (no `wakeup-allow:`) | allowed only as a bounded, cancellable delay |
| clock sleeps `.sleep(for:/until:)` | 69 | 58 | 5 (no `wakeup-allow:`) | as above |
| `DispatchQueue.main.async` | 14 | 9 | - | use @MainActor and await |
| `asyncAfter` | 0 | 0 | - | banned (check-concurrency.sh); an injected Clock |
| NotificationCenter observers (`MainActorObservation(` wrapper sites included) | 167 | 118 | - | each one wakes on every post of its name; the wrapper is still an observer |
| custom `Notification.Name` declarations | 13 | 11 | - | a broadcast signal: every observer reacts, O(all) |
| `NSHostingView` / `NSHostingController` | 30 | 22 | - | a SwiftUI graph inside AppKit; costly on hot paths |
| `#if DEBUG` blocks | 412 | 293 | - | DEBUG-only instrumentation is not in Release builds |
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` | 0 | 0 | - | CLAUDE.md: @Observable |

<details><summary>`static let/var shared` singletons: 141 in 138 files (top 10)</summary>

```
   2  CmuxNextBrowser/Core/SiteZoomLevels.swift
   2  CmuxNextPages/WebBundleOverlay.swift
   2  CmuxNextTabs/TabUserIcon.swift
   1  CmuxNextActions/ContextMenuCatalog.swift
   1  CmuxNextActions/ShortcutEditEnvironment.swift
   1  CmuxNextAgentActivity/AgentLaneStore.swift
   1  CmuxNextAgentLanes/AgentPriorityMarks.swift
   1  CmuxNextAgentLanes/AgentTurnStateFeed.swift
   1  CmuxNextAgentLanes/ChiefSidebar.swift
   1  CmuxNextAgentLanes/SidebarChatHistoryFeed.swift
      ... 128 more files
```
</details>

<details><summary>`MainActor.assumeIsolated`: 235 in 163 files (top 10)</summary>

```
   9  CmuxNextTerminal/GhosttyRuntimeCallbacks.swift
   5  CmuxNextBrowser/CEF/CEFRuntime+Events.swift
   5  CmuxNextTabs/TabAccessibilityElement.swift
   4  CmuxNextApp/Pages/Files/MarkdownShare/MarkdownLiveShareServer.swift
   4  CmuxNextDesign/Diagnostics/LayoutPassGuard.swift
   4  CmuxNextDesign/PointerHover.swift
   4  CmuxNextSidebar/Views/SidebarListView.swift
   4  CmuxNextSidebar/Views/SidebarView.swift
   3  CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift
   3  CmuxNextApp/NewTab/NewTabSparePool.swift
      ... 153 more files
```
</details>

<details><summary>`@unchecked Sendable`: 67 in 60 files (top 10)</summary>

```
   3  CmuxNextDictation/SpeechAnalyzerAudioInput.swift
   2  CmuxNextApp/Server/ServerHelperClient.swift
   2  CmuxNextCompat/Mutex.swift
   2  CmuxNextRemoteView/Decode/RemoteVideoDecoder.swift
   2  CmuxNextRemoteView/Present/MetalYUVRenderer.swift
   2  CmuxNextServerHelper/ServerFixPriorStore.swift
   1  CmuxNextAgentActivity/AgentActivityLineConnection.swift
   1  CmuxNextAgentPane/AcpmuxCheckedLine.swift
   1  CmuxNextAgentPane/AcpmuxRemotePersonKeys.swift
   1  CmuxNextAgentPane/AcpmuxStatusClient.swift
      ... 50 more files
```
</details>

<details><summary>`nonisolated(unsafe)`: 33 in 20 files (top 10)</summary>

```
   6  CmuxNextCrashReporting/TaskExceptionPorts.swift
   4  CmuxNextTabs/TabAccessibilityElement.swift
   3  CmuxNextCrashReporting/AlternateSignalStacks.swift
   2  CmuxNextApp/BrowserNowPlaying.swift
   2  CmuxNextPalette/PaletteRankerBridge.swift
   2  CmuxNextVSCodeServer/ServeWebProcess.swift
   1  CmuxNextAgentPane/AcpmuxLogProgress.swift
   1  CmuxNextAgentPane/AcpmuxVersionHandoff.swift
   1  CmuxNextApp/Control/DebugHints.swift
   1  CmuxNextApp/Crash/AppRunMarker.swift
      ... 10 more files
```
</details>

<details><summary>raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex): 25 in 21 files (top 10)</summary>

```
   2  CmuxNextApp/HostPressure/HostPressureSampling.swift
   2  CmuxNextApp/NativeCaretAccessory.swift
   2  CmuxNextCompat/Mutex.swift
   2  CmuxNextServerHelper/ServerFixPriorStore.swift
   1  CmuxNextAgentPane/AcpmuxEnvironment+BuildHomeAdoption.swift
   1  CmuxNextApp/Crash/UncaughtExceptionRecorder.swift
   1  CmuxNextApp/HostPressure/HostPressureService.swift
   1  CmuxNextApp/Server/ServerHelperClient.swift
   1  CmuxNextBrowser/CEF/ChromiumPageTextAccessory.swift
   1  CmuxNextBrowserImport/Sources/BrowserFolderGrants.swift
      ... 11 more files
```
</details>

<details><summary>CmuxNextCompat `Mutex` uses (the sanctioned lock): 224 in 159 files (top 10)</summary>

```
   7  CmuxNextControl/Diagnostics/MainThreadWatchdog.swift
   5  CmuxNextControl/Diagnostics/BusyWatchdog.swift
   4  CmuxNextCrashReporting/LagSpikeReporter.swift
   4  CmuxNextDaemon/Terminal/TerminalAttachment.swift
   3  CmuxNextAgentPane/AcpmuxVersionHandoff.swift
   3  CmuxNextAgentPane/RemoteAcpmuxWire.swift
   3  CmuxNextDaemon/Connection/LineTransport.swift
   3  CmuxNextDaemon/Connection/PageRelayHandshake.swift
   3  CmuxNextRemote/AddMachine/HostCLI.swift
   2  CmuxNextAgentActivity/AgentActivityLineConnection.swift
      ... 149 more files
```
</details>

<details><summary>`Task.sleep`: 25 in 22 files (top 10)</summary>

```
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
   2  CmuxNextApp/Handlers/CloudHandlers.swift
   2  CmuxNextCompat/MainThreadEngineStart.swift
   1  CmuxNextAgentPane/AcpmuxLogProgress.swift
   1  CmuxNextAgentPane/AcpmuxVersionHandoff.swift
   1  CmuxNextAgentPane/AgentPaneDeadline.swift
   1  CmuxNextAgentPane/AgentPaneSeed.swift
   1  CmuxNextApp/Cloud/CloudAccessAsks.swift
   1  CmuxNextApp/Cloud/CloudMove.swift
   1  CmuxNextApp/Crash/AppRunMarker.swift
      ... 12 more files
```
</details>

<details><summary>clock sleeps `.sleep(for:/until:)`: 69 in 58 files (top 10)</summary>

```
   3  CmuxNextPhone/Live/SimulatorKitHID.swift
   2  CmuxNextApp/Feed/FeedService.swift
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
   2  CmuxNextApp/Handlers/CloudHandlers.swift
   2  CmuxNextBrowser/Omnibox/Suggest/OmniboxRemoteFetch.swift
   2  CmuxNextCompat/MainThreadEngineStart.swift
   2  CmuxNextComputerUse/ComputerUseHelperV2.swift
   2  CmuxNextDaemon/Launch/ProcessRunner.swift
   2  CmuxNextDesign/WebKitRenderRate+Reshow.swift
   2  CmuxNextDiff/DiffSidecarProcess.swift
      ... 48 more files
```
</details>

<details><summary>`DispatchQueue.main.async`: 14 in 9 files (top 10)</summary>

```
   5  CmuxNextTerminal/GhosttyRuntimeCallbacks.swift
   2  CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift
   1  CmuxNextApp/Focus/NoActivateKeyboardGuard.swift
   1  CmuxNextBrowser/CEF/CEFEngine+Passwords.swift
   1  CmuxNextBrowser/CEF/CEFRuntime+Events.swift
   1  CmuxNextSidebar/Views/SidebarListView+PointerEnd.swift
   1  CmuxNextTasks/SocketTasksSource.swift
   1  CmuxNextTerminal/GhosttyRuntime+Background.swift
   1  CmuxNextWakeups/MainDelivery.swift
```
</details>

<details><summary>NotificationCenter observers (`MainActorObservation(` wrapper sites included): 167 in 118 files (top 10)</summary>

```
   4  CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift
   4  CmuxNextDesign/HoverCards/HoverCardCoordinator.swift
   3  CmuxNextApp/Focus/FocusEffectApplier.swift
   3  CmuxNextApp/Windows/WindowOverlayLayer.swift
   3  CmuxNextDesign/Overlay/WindowOverlayHost.swift
   3  CmuxNextDesign/ScrollEdgeFade.swift
   3  CmuxNextDesign/StatusIndicator/StatusIndicatorAppearance.swift
   3  CmuxNextPages/PageWebView.swift
   3  CmuxNextSidebar/Views/SidebarListView.swift
   3  CmuxNextSidebar/Views/SidebarView.swift
      ... 108 more files
```
</details>

<details><summary>custom `Notification.Name` declarations: 13 in 11 files (top 10)</summary>

```
   2  CmuxNextDesign/Motion/Motion.swift
   2  CmuxNextSidebar/Store/SidebarDocStore.swift
   1  CmuxNextApp/ComputerUse/ComputerUseSetup.swift
   1  CmuxNextBrowser/CEF/CEFHostView.swift
   1  CmuxNextBrowser/Engine/BrowserWindowOcclusion.swift
   1  CmuxNextControl/Diagnostics/HangEpisodeRecorder.swift
   1  CmuxNextDesign/HoverCards/HoverCardTiming.swift
   1  CmuxNextDesign/Toast/CmuxToastAvoidance.swift
   1  CmuxNextDesign/WindowMaterialView.swift
   1  CmuxNextSidebar/Model/SidebarModel.swift
      ... 1 more files
```
</details>

<details><summary>`NSHostingView` / `NSHostingController`: 30 in 22 files (top 10)</summary>

```
   3  CmuxNextApps/Render/AppSceneHostingView.swift
   3  CmuxNextApps/Section/AppSectionProvider.swift
   2  CmuxNextBookmarks/UI/BookmarkManagerHostView.swift
   2  CmuxNextHistory/HistoryPageHostView.swift
   2  CmuxNextServer/ServerHostView.swift
   2  CmuxNextUpdater/UpdateSheetController.swift
   1  CmuxNextApp/Checklist/WorkspaceTodoPageService.swift
   1  CmuxNextApp/Handlers/BrowserDownloadsPopup.swift
   1  CmuxNextApp/Handlers/ChiefMemoryPageService.swift
   1  CmuxNextApp/RightSidebar/DockSectionHostView.swift
      ... 12 more files
```
</details>

<details><summary>`#if DEBUG` blocks: 412 in 293 files (top 10)</summary>

```
   6  CmuxNextPages/PageWebView+Chromium.swift
   6  CmuxNextUpdater/UpdaterService+Flow.swift
   5  CmuxNextAgentPane/AgentPaneView+Loading.swift
   5  CmuxNextApp/Control/BenchSpans.swift
   5  CmuxNextApp/RemoteView/RemoteBrowserPages.swift
   5  CmuxNextDaemon/Store/DaemonStore+MirrorCheck.swift
   4  CmuxNextApp/Focus/WindowScopedShortcutHintModifierMonitor.swift
   4  CmuxNextApp/RemoteView/MachineBrowserPages.swift
   4  CmuxNextDesign/PointerHover.swift
   4  CmuxNextDictation/OnDeviceDictationTranscriber.swift
      ... 283 more files
```
</details>

## 2. NotificationCenter broadcast signals

167 observer registrations; 13 custom names. A name observed by a
per-instance view or window class wakes every instance on every post: O(all), not O(changed).

| Name | Observer sites | `object: nil` | Post sites | Per-instance observer files |
|---|---:|---:|---:|---|
| `reduceMotionDidChange` | 5 | 4 | 1 | `AgentPaneView.swift`, `PageWebView.swift` |
| `configDidChange` | 3 | 3 | 1 | `TerminalHostView.swift` |
| `browserChildWindowPagesNeedUpdate` | 2 | 1 | 3 | `CEFHostView.swift` |
| `itemFaviconsChanged` | 1 | 1 | 1 | `SidebarListView.swift` |
| `refusedNotification` | 1 | 1 | 2 | `SidebarListView.swift` |
| `settledNotification` | 1 | 1 | 1 | `SidebarListView.swift` |
| `speedDidChange` | 1 | 1 | 4 | `PageWebView.swift` |
| `accessibilityTrustChanged` | 2 | 2 | 0 | - |
| `cmuxToastAvoidanceDidChange` | 1 | 1 | 1 | - |
| `didChange` | 1 | 0 | 2 | - |
| `hoverCardsDidChange` | 1 | 1 | 2 | - |
| `inactiveDimDidChange` | 1 | 1 | 1 | - |
| `geometryDidChange` | 0 | 0 | 1 | - |

Every observed name (system and custom), by per-instance observer files (a view or window class that
registers per instance: N instances = N wakes per post):

<details><summary>Observed names</summary>

```
 43 sites   8 per-instance  name  (HostPressureIndicatorView.swift, BackdropVideoView.swift, HomeNativeTranscriptView.swift, BrowserPopupWindow.swift, RemoteInputCaptureView.swift)
  9 sites   6 per-instance  accessibilityDisplayOptionsDidChangeNotification  (AgentPaneView.swift, WindowRootView.swift, ThemedFieldBox.swift, WindowSurfaceView.swift, PageWebView.swift)
  7 sites   5 per-instance  didChangeOcclusionStateNotification  (AgentPaneVisibilityProbe.swift, StatusIndicatorView.swift, PhoneScreenView.swift, SidebarListView.swift, SidebarNoticeCardView.swift)
 13 sites   4 per-instance  willCloseNotification  (NewTabSparePool.swift, GroupCustomColor.swift, HoverReveal.swift, PageHostPool+Windows.swift)
  4 sites   4 per-instance  boundsDidChangeNotification  (ScrollEdgeFade.swift, PaletteListView.swift, SidebarView.swift, TerminalScroller.swift)
  7 sites   3 per-instance  didBecomeKeyNotification  (NewTabSparePool.swift, ActiveAppKeyPanel.swift, PageHostPool+Windows.swift)
  7 sites   2 per-instance  frameDidChangeNotification  (ScrollEdgeFade.swift, SidebarView.swift)
  5 sites   2 per-instance  reduceMotionDidChange  (AgentPaneView.swift, PageWebView.swift)
  3 sites   2 per-instance  preferredScrollerStyleDidChangeNotification  (NotificationsPanelView.swift, SidebarView.swift)
  3 sites   1 per-instance  configDidChange  (TerminalHostView.swift)
  2 sites   1 per-instance  browserChildWindowPagesNeedUpdate  (CEFHostView.swift)
  2 sites   1 per-instance  didChangeScreenParametersNotification  (ChiefPetPanel.swift)
  1 sites   1 per-instance  itemFaviconsChanged  (SidebarListView.swift)
  1 sites   1 per-instance  speedDidChange  (PageWebView.swift)
 16 sites   0 per-instance  didBecomeActiveNotification
```
</details>

Example O(all) cause: `browserChildWindowPagesNeedUpdate` is posted per layout change by
`WindowRootView+MainPane` and `WindowOverlayLayer`; every `CEFHostView` (one per page, moving or not)
observes it and posts geometry (perf-lead.md issue 2). Fix shape: notify only the hosts whose rect changed.

## 3. Target sizes

`CmuxNextApp`: **142,128 lines** of 610,926 in `Sources` (23 %); 784,909 lines with Tests and the package manifest.
Every edit in the App target re-emits the whole module (check-app-size.sh), so new code goes in a feature target.

<details><summary>Lines per target (15 largest)</summary>

```
 142,128  CmuxNextApp  [app]
  47,493  CmuxNextBrowser  [ui]
  36,650  CmuxNextSidebar  [ui]
  33,131  CmuxNextDesign  [ui]
  32,809  CmuxNextDaemon  [service]
  30,390  CmuxNextAgentPane  [ui]
  20,695  CmuxNextSettings  [ui]
  18,761  CmuxNextActions  [ui]
  13,499  CmuxNextLayout  [ui]
  11,982  CmuxNextControl  [service]
  11,710  CmuxNextPalette  [ui]
  11,569  CmuxNextHomeEngine  [ui]
  11,107  CmuxNextTabs  [ui]
   9,185  CmuxNextTerminal  [ui]
   8,883  CmuxNextUpdater  [ui]
```
</details>

## 4. Target graph vs the 5-layer rule

`Package.swift`: 146 targets (105 non-test: 2 app, 61 ui, 23 service, 16 core, 2 foundation, 1 other; 41 test). The App depends directly on 96 targets; 12 targets have no
in-package dependency; the longest dependency chain is 10 targets. The graph is flat: almost every
feature is a leaf that the App wires, and domain state and UI share targets (every UI target is main-actor
by default via `uiSwiftSettings`), so CLAUDE.md layer 3 (domain) and 4 (UI) are not separate.

Layer per target is inferred from its sources: `ui` imports AppKit/SwiftUI/WebKit; `service` does I/O
(FileManager, Process, sockets, URLSession, XPC, SQLite, Keychain, UserDefaults, DispatchSource); `core` neither;
`foundation` (CmuxNextCompat, CmuxNextWakeups) is importable by every layer. A heuristic: read each edge before acting.
**63 edges break the rule** (upward edges, or UI straight onto a service):

<details><summary>Layer violations</summary>

```
 25  UI depends on a service directly (needs a domain model or protocol seam)
 19  service depends upward on ui
 12  core depends upward on ui
  7  core depends upward on service

CmuxNextAccounts -> CmuxNextCodeRouter: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextAgentCursorVisibility -> CmuxNextAgentCursor: core depends upward on ui
CmuxNextAgentIntegrations -> CmuxNextDaemon: core depends upward on service
CmuxNextAgentIntegrations -> CmuxNextPages: core depends upward on ui
CmuxNextAgentIntegrations -> CmuxNextSettings: core depends upward on ui
CmuxNextAgentLanes -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextAgentPane -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextAgentPane -> CmuxNextRemoteFetch: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextAgentUpdates -> CmuxNextActions: core depends upward on ui
CmuxNextAgentUpdates -> CmuxNextDaemon: core depends upward on service
CmuxNextAgentUpdates -> CmuxNextDaemonService: core depends upward on ui
CmuxNextAgentUpdates -> CmuxNextPages: core depends upward on ui
CmuxNextAgentUpdates -> CmuxNextSettings: core depends upward on ui
CmuxNextApps -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextBridge -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextBrowser -> CmuxNextRemoteFetch: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextBrowserHistory -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextChiefPetWiring -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextChiefViews -> CmuxNextActions: service depends upward on ui
CmuxNextChiefViews -> CmuxNextAgentActivity: service depends upward on ui
CmuxNextChiefViews -> CmuxNextBridge: service depends upward on ui
CmuxNextChiefViews -> CmuxNextDaemonService: service depends upward on ui
CmuxNextChiefViews -> CmuxNextDesign: service depends upward on ui
CmuxNextChiefViews -> CmuxNextHome: service depends upward on ui
CmuxNextChiefViews -> CmuxNextPages: service depends upward on ui
CmuxNextChiefViews -> CmuxNextSettings: service depends upward on ui
CmuxNextCodeRouter -> CmuxNextCloud: service depends upward on ui
CmuxNextControl -> CmuxNextActions: service depends upward on ui
CmuxNextControl -> CmuxNextSettings: service depends upward on ui
CmuxNextCookieImport -> CmuxNextBrowserImport: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextDaemonRecovery -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextDaemonService -> CmuxNextControl: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextDaemonService -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextDesign -> CmuxNextDesignTokens: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextFilesUI -> CmuxNextFiles: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextHomeEngine -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextHostedChief -> CmuxNextHomeEngine: service depends upward on ui
CmuxNextImportCards -> CmuxNextBrowserImport: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextImportCards -> CmuxNextImportSuggestions: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextKeepAwake -> CmuxNextBridge: core depends upward on ui
CmuxNextKeepAwake -> CmuxNextDaemon: core depends upward on service
CmuxNextKeepAwake -> CmuxNextSettings: core depends upward on ui
CmuxNextMacScreen -> CmuxNextControl: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextMacScreen -> CmuxNextDevices: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextMobileHost -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextMobileHost -> CmuxNextMobile: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextOnboarding -> CmuxNextBrowserImport: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextPhoneAccess -> CmuxNextDaemonService: service depends upward on ui
CmuxNextPhoneAccess -> CmuxNextSettings: service depends upward on ui
CmuxNextRemote -> CmuxNextCloud: service depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextActions: service depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextBrowser: service depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextDaemonService: service depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextSettings: service depends upward on ui
CmuxNextScreenshots -> CmuxNextFiles: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextStash -> CmuxNextDaemon: core depends upward on service
CmuxNextStash -> CmuxNextDaemonService: core depends upward on ui
CmuxNextStash -> CmuxNextHistory: core depends upward on ui
CmuxNextWebUpdates -> CmuxNextControl: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextWorkspaceNaming -> CmuxNextBridge: core depends upward on ui
CmuxNextWorkspaceNaming -> CmuxNextDaemon: core depends upward on service
CmuxNextWorkspaceNaming -> CmuxNextDesignTokens: core depends upward on service
CmuxNextWorkspaceRepair -> CmuxNextDaemon: core depends upward on service
```
</details>

## 5. Docs, scripts, workflows

- `plans/cmux-next`: 579 tracked files, 392 Markdown (321 at the top level).
- Stale references (a `.md` named in plans/cmux-next docs or scripts/cmux-next that no tracked file has): **7** targets.
- `scripts/cmux-next`: 577 files at the top level, 887 tracked in total.
- `.github/workflows`: 211 files.

<details><summary>Stale references (missing doc: files that name it)</summary>

```
ORG-BACKUP.md: scripts/cmux-next/terminal-path-links-live.py
every-action.md: scripts/cmux-next/every-action-sweep.py
perf-speed-of-light.md: scripts/cmux-next/codebase-health.py, scripts/cmux-next/perf-gate.py
plans/cmux-next/decisions.md: plans/cmux-next/codebase-health.md, plans/cmux-next/onboarding.md
plans/cmux-next/do-audit.md: plans/cmux-next/chief-done.md, plans/cmux-next/codebase-health.md
plans/cmux-next/perf-speed-of-light.md: plans/cmux-next/codebase-health.md, scripts/cmux-next/perf-gate.py
plans/cmux-next/remote-hosts/DESIGN.md: plans/cmux-next/codebase-health.md, plans/cmux-next/object-sync/DESIGN.md
```
</details>

## 6. Guardrails (pre-push, local, never CI)

`scripts/cmux-next/guardrails.py`, run by the pre-push hook through `prepush-gate.py --pre-push`, looks only at
lines the push adds under `Packages/macOS/CmuxNext/Sources` and takes well under a second. Per file and rule it
is a count ratchet: an edit of a line that already has the debt adds none, and a line moved from another file
does not count. Removed lines pay only when they were debt in the base (same context and escape rules), and an
unchanged line counts when the push changes its context (a new loop around a sleep, `struct` -> `class`). Lines a
push only brings in from origin/feat-cmux-next (a merge or a rebase onto it) never count. Refusals print the rule,
why, the right pattern and the escape. One rule is not per line: `app-size` is a net count over the push in
CmuxNextApp source lines (CI's lexer, as `check-app-size.sh --base` counts them), where removed App lines pay
for added ones and code moved into the App from a package is growth. It refuses the root's wiring over its budget
(`ROOT_BUDGET` in guardrails.py, `--list` prints it; lines moved into the root count) and a new App file that is
neither a move nor the push's one `AppServices+<Domain>Host.swift` of one-line forwards; growth of the App total
and of the App outside the composition root warns (bytes added, the package the code goes to) until the large
domains are out of CmuxNextApp. It is the only App-size limit in force on a
push. Skip one rule for one push with
`CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>"` (the other rules still refuse) and say so in your report.
`guardrails.py --list` prints every rule.
If the script itself fails, the hook prints a warning and lets the push through.
It also warns (never refuses) when a push changes a `// perf-hot:` function (names the bench,
`scripts/cmux-next/perf-hot-benches.json`) or an area in [OWNERS.md](OWNERS.md).

Perf-hot markers per path id, from every tracked Swift file. An id with no marker never warns: its owner
marks the hot function (a trailing `// perf-hot: <budget> <path-id>` on the line that has `func`, `init` or
`var` adds no line; or a comment line right above the declaration). Whether a marker warns is what
`guardrails.check` itself reports for a push that edits every line of the marked files (its own diff scope and
declaration parser, not a copy), so a marker outside the hook's diff scope, or on a line the hook does not
read as a declaration, is flagged: an edit of that function warns nobody.

Marked: 11 of 13 path ids (19 markers); 10 of 13 warn at push; 3 of 19 markers never warn.

- `key-dispatch`: CmuxNextActions/KeyBindingTable+Sequence.swift:27 (not on a declaration line the hook parses (a multi-line signature's last line?): no warning), CmuxNextApp/Focus/ChordTracker.swift:93 (not on a declaration line the hook parses (a multi-line signature's last line?): no warning), CmuxNextApp/Focus/KeyRouter.swift:179, CmuxNextApp/Focus/KeyRouter.swift:235, CmuxNextApp/Notifications/NotificationCenterService+Lookup.swift:43
- `terminal-key`: CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift:14
- `home-key`: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/PaneHost.swift:669 (outside the pre-push hook's diff scope: no warning)
- `palette-key`: CmuxNextPalette/PaletteModel+Search.swift:109
- `omnibar-key`: CmuxNextBrowser/Omnibox/OmnibarReducer.swift:220
- `motion-frame`: CmuxNextLayout/Views/ScreenContentView+Motion.swift:14, CmuxNextLayout/Views/ScreenContentView+Motion.swift:90
- `frame-tick`: CmuxNextWakeups/FrameScheduler.swift:224
- `drag-frame`: CmuxNextApp/Drag/TabDragSession+Ghost.swift:38
- `tab-switch`: CmuxNextBrowser/CEF/CEFLayerHosting.swift:117
- `workspace-switch`: **no marker** (owner PL-switch)
- `cef-geometry`: CmuxNextApp/Windows/WindowOverlayLayer.swift:333, CmuxNextApp/Windows/WindowOverlayLayer.swift:362, CmuxNextBrowser/CEF/CEFHostView.swift:218, CmuxNextBrowser/CEF/CEFLayerHosting.swift:137
- `cmd-tab`: CmuxNextDesign/WindowKeyFamily.swift:89
- `new-tab`: **no marker** (owner PL-cef-tab)

