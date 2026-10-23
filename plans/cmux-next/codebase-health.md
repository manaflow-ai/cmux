# cmux-next codebase health (measured)

Measured 2026-10-23 at feat-cmux-next `184fa32532c` by `scripts/cmux-next/codebase-health.py --write` (rerun it to refresh; do not edit numbers by hand).
Scope: tracked Swift in `Packages/macOS/CmuxNext/Sources`, comments stripped. The pre-push guardrails
(`scripts/cmux-next/guardrails.py`, run by `prepush-gate.py`) refuse NEW instances of the ratcheted rows;
the debt below never blocks a push. Owners: [OWNERS.md](OWNERS.md). Guardrail rules: section 6.

## 1. Concurrency, state and instrumentation debt

| Pattern | Lines | Files | Without the waiver comment | Why it matters |
|---|---:|---:|---:|---|
| `static let/var shared` singletons | 149 | 146 | 149 (no `singleton-allow:`) | runtime state behind a global; construct at the composition root and inject (CLAUDE.md Package design discipline) |
| `MainActor.assumeIsolated` | 288 | 182 | 77 (no `main-proof:`) | traps off main; each needs `// main-proof: <why>` (crash_ratchet.py counts the rest) |
| `@unchecked Sendable` | 66 | 59 | 42 (no `crash-allow:`) | a data race the compiler cannot see; needs `// crash-allow: <safety argument>` |
| `nonisolated(unsafe)` | 32 | 19 | 10 (no `crash-allow:`) | as above |
| raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex) | 23 | 20 | - | CLAUDE.md: actor, or the CmuxNextCompat Mutex carve-out |
| CmuxNextCompat `Mutex` uses (the sanctioned lock) | 218 | 154 | - | sanctioned; listed for scale |
| `Task.sleep` | 25 | 22 | 0 (no `wakeup-allow:`) | allowed only as a bounded, cancellable delay |
| clock sleeps `.sleep(for:/until:)` | 66 | 56 | 3 (no `wakeup-allow:`) | as above |
| `DispatchQueue.main.async` | 14 | 9 | - | use @MainActor and await |
| `asyncAfter` | 0 | 0 | - | banned (check-concurrency.sh); an injected Clock |
| NotificationCenter observers | 159 | 112 | - | each one wakes on every post of its name |
| custom `Notification.Name` declarations | 13 | 11 | - | a broadcast signal: every observer reacts, O(all) |
| `NSHostingView` / `NSHostingController` | 30 | 22 | - | a SwiftUI graph inside AppKit; costly on hot paths |
| `#if DEBUG` blocks | 398 | 281 | - | DEBUG-only instrumentation is not in Release builds |
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` | 0 | 0 | - | CLAUDE.md: @Observable |

<details><summary>`static let/var shared` singletons: 149 in 146 files (top 10)</summary>

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
      ... 136 more files
```
</details>

<details><summary>`MainActor.assumeIsolated`: 288 in 182 files (top 10)</summary>

```
   9  CmuxNextTerminal/GhosttyRuntimeCallbacks.swift
   5  CmuxNextBrowser/CEF/CEFRuntime+Events.swift
   5  CmuxNextDesign/HoverCards/HoverCardCoordinator.swift
   5  CmuxNextTabs/TabAccessibilityElement.swift
   4  CmuxNextAgentPane/AgentPaneView.swift
   4  CmuxNextApp/Pages/Files/MarkdownShare/MarkdownLiveShareServer.swift
   4  CmuxNextDesign/Diagnostics/LayoutPassGuard.swift
   4  CmuxNextDesign/PointerHover.swift
   4  CmuxNextDesign/ScrollEdgeFade.swift
   4  CmuxNextPages/PageWebView.swift
      ... 172 more files
```
</details>

<details><summary>`@unchecked Sendable`: 66 in 59 files (top 10)</summary>

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
      ... 49 more files
```
</details>

<details><summary>`nonisolated(unsafe)`: 32 in 19 files (top 10)</summary>

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
      ... 9 more files
```
</details>

<details><summary>raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex): 23 in 20 files (top 10)</summary>

```
   2  CmuxNextApp/NativeCaretAccessory.swift
   2  CmuxNextCompat/Mutex.swift
   2  CmuxNextServerHelper/ServerFixPriorStore.swift
   1  CmuxNextAgentPane/AcpmuxEnvironment+BuildHomeAdoption.swift
   1  CmuxNextApp/Crash/UncaughtExceptionRecorder.swift
   1  CmuxNextApp/Server/ServerHelperClient.swift
   1  CmuxNextBrowser/CEF/ChromiumPageTextAccessory.swift
   1  CmuxNextBrowserImport/Sources/BrowserFolderGrants.swift
   1  CmuxNextDaemon/AgentSession/AgentSessionAttachClient.swift
   1  CmuxNextDaemon/Connection/DaemonEndpoint.swift
      ... 10 more files
```
</details>

<details><summary>CmuxNextCompat `Mutex` uses (the sanctioned lock): 218 in 154 files (top 10)</summary>

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
      ... 144 more files
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

<details><summary>clock sleeps `.sleep(for:/until:)`: 66 in 56 files (top 10)</summary>

```
   3  CmuxNextPhone/Live/SimulatorKitHID.swift
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
   2  CmuxNextApp/Handlers/CloudHandlers.swift
   2  CmuxNextBrowser/Omnibox/Suggest/OmniboxRemoteFetch.swift
   2  CmuxNextCompat/MainThreadEngineStart.swift
   2  CmuxNextComputerUse/ComputerUseHelperV2.swift
   2  CmuxNextDaemon/Launch/ProcessRunner.swift
   2  CmuxNextDesign/WebKitRenderRate+Reshow.swift
   2  CmuxNextDiff/DiffSidecarProcess.swift
   1  CmuxNextAgentPane/AcpmuxLogProgress.swift
      ... 46 more files
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

<details><summary>NotificationCenter observers: 159 in 112 files (top 10)</summary>

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
      ... 102 more files
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

<details><summary>`#if DEBUG` blocks: 398 in 281 files (top 10)</summary>

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
      ... 271 more files
```
</details>

## 2. NotificationCenter broadcast signals

159 observer registrations; 13 custom names. A name observed by a
per-instance view or window class wakes every instance on every post: O(all), not O(changed).

| Name | Observer sites | `object: nil` | Post sites | Per-instance observer files |
|---|---:|---:|---:|---|
| `reduceMotionDidChange` | 5 | 4 | 1 | `AgentPaneView.swift`, `PageWebView.swift` |
| `configDidChange` | 3 | 3 | 1 | `TerminalHostView.swift` |
| `browserChildWindowPagesNeedUpdate` | 2 | 1 | 3 | `CEFHostView.swift` |
| `inactiveDimDidChange` | 1 | 1 | 1 | `WindowMaterialView.swift` |
| `itemFaviconsChanged` | 1 | 1 | 1 | `SidebarListView.swift` |
| `refusedNotification` | 1 | 1 | 2 | `SidebarListView.swift` |
| `settledNotification` | 1 | 1 | 1 | `SidebarListView.swift` |
| `speedDidChange` | 1 | 1 | 4 | `PageWebView.swift` |
| `accessibilityTrustChanged` | 2 | 2 | 0 | - |
| `cmuxToastAvoidanceDidChange` | 1 | 1 | 1 | - |
| `didChange` | 1 | 0 | 2 | - |
| `hoverCardsDidChange` | 1 | 1 | 2 | - |
| `geometryDidChange` | 0 | 0 | 1 | - |

Every observed name (system and custom), by per-instance observer files (a view or window class that
registers per instance: N instances = N wakes per post):

<details><summary>Observed names</summary>

```
 39 sites   8 per-instance  name  (BackdropVideoView.swift, WindowMaterialView.swift, HomeNativeTranscriptView.swift, BrowserPopupWindow.swift, RemoteInputCaptureView.swift)
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
  1 sites   1 per-instance  inactiveDimDidChange  (WindowMaterialView.swift)
  1 sites   1 per-instance  itemFaviconsChanged  (SidebarListView.swift)
  1 sites   1 per-instance  speedDidChange  (PageWebView.swift)
```
</details>

Example O(all) cause: `browserChildWindowPagesNeedUpdate` is posted per layout change by
`WindowRootView+MainPane` and `WindowOverlayLayer`; every `CEFHostView` (one per page, moving or not)
observes it and posts geometry (perf-lead.md issue 2). Fix shape: notify only the hosts whose rect changed.

## 3. Target sizes

`CmuxNextApp`: **141,651 lines** of 589,534 in `Sources` (24 %); 752,415 lines with Tests and the package manifest.
Every edit in the App target re-emits the whole module (check-app-size.sh), so new code goes in a feature target.

<details><summary>Lines per target (15 largest)</summary>

```
 141,651  CmuxNextApp  [app]
  46,835  CmuxNextBrowser  [ui]
  39,502  CmuxNextDesign  [ui]
  36,234  CmuxNextSidebar  [ui]
  32,475  CmuxNextDaemon  [service]
  29,162  CmuxNextAgentPane  [ui]
  20,303  CmuxNextSettings  [ui]
  18,377  CmuxNextActions  [ui]
  13,245  CmuxNextLayout  [ui]
  11,668  CmuxNextControl  [service]
  11,574  CmuxNextPalette  [ui]
  11,262  CmuxNextHomeEngine  [ui]
  10,966  CmuxNextTabs  [ui]
   8,883  CmuxNextUpdater  [ui]
   8,740  CmuxNextHome  [ui]
```
</details>

## 4. Target graph vs the 5-layer rule

`Package.swift`: 135 targets (99 non-test: 2 app, 58 ui, 19 service, 17 core, 2 foundation, 1 other; 36 test). The App depends directly on 91 targets; 13 targets have no
in-package dependency; the longest dependency chain is 9 targets. The graph is flat: almost every
feature is a leaf that the App wires, and domain state and UI share targets (every UI target is main-actor
by default via `uiSwiftSettings`), so CLAUDE.md layer 3 (domain) and 4 (UI) are not separate.

Layer per target is inferred from its sources: `ui` imports AppKit/SwiftUI/WebKit; `service` does I/O
(FileManager, Process, sockets, URLSession, XPC, SQLite, Keychain, UserDefaults, DispatchSource); `core` neither;
`foundation` (CmuxNextCompat, CmuxNextWakeups) is importable by every layer. A heuristic: read each edge before acting.
**62 edges break the rule** (upward edges, or UI straight onto a service):

<details><summary>Layer violations</summary>

```
 22  UI depends on a service directly (needs a domain model or protocol seam)
 17  core depends upward on ui
 15  service depends upward on ui
  8  core depends upward on service

CmuxNextAccounts -> CmuxNextCodeRouter: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextAgentCursor -> CmuxNextDesign: core depends upward on ui
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
CmuxNextFilesUI -> CmuxNextFiles: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextHomeEngine -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextHostedChief -> CmuxNextHomeEngine: service depends upward on ui
CmuxNextImportCards -> CmuxNextBrowserImport: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextImportCards -> CmuxNextImportSuggestions: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextKeepAwake -> CmuxNextBridge: core depends upward on ui
CmuxNextKeepAwake -> CmuxNextDaemon: core depends upward on service
CmuxNextKeepAwake -> CmuxNextSettings: core depends upward on ui
CmuxNextMobileHost -> CmuxNextDaemon: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextMobileHost -> CmuxNextMobile: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextOnboarding -> CmuxNextBrowserImport: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextPhoneAccess -> CmuxNextDaemonService: service depends upward on ui
CmuxNextPhoneAccess -> CmuxNextSettings: service depends upward on ui
CmuxNextRemote -> CmuxNextCloud: service depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextActions: core depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextBrowser: core depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextDaemon: core depends upward on service
CmuxNextRemoteLocalhostService -> CmuxNextDaemonService: core depends upward on ui
CmuxNextRemoteLocalhostService -> CmuxNextRemoteLocalhost: core depends upward on service
CmuxNextRemoteLocalhostService -> CmuxNextSettings: core depends upward on ui
CmuxNextScreenshots -> CmuxNextFiles: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextStash -> CmuxNextDaemon: core depends upward on service
CmuxNextStash -> CmuxNextDaemonService: core depends upward on ui
CmuxNextStash -> CmuxNextHistory: core depends upward on ui
CmuxNextWebUpdates -> CmuxNextControl: UI depends on a service directly (needs a domain model or protocol seam)
CmuxNextWorkspaceNaming -> CmuxNextBridge: core depends upward on ui
CmuxNextWorkspaceNaming -> CmuxNextDaemon: core depends upward on service
CmuxNextWorkspaceNaming -> CmuxNextDesign: core depends upward on ui
CmuxNextWorkspaceRepair -> CmuxNextDaemon: core depends upward on service
```
</details>

## 5. Docs, scripts, workflows

- `plans/cmux-next`: 566 tracked files, 381 Markdown (310 at the top level).
- Stale references (a `.md` named in plans/cmux-next docs or scripts/cmux-next that no tracked file has): **9** targets.
- `scripts/cmux-next`: 560 files at the top level, 866 tracked in total.
- `.github/workflows`: 210 files.

<details><summary>Stale references (missing doc: files that name it)</summary>

```
FLEET-HEALTH.md: scripts/cmux-next/os-smoke/run.sh
ORG-BACKUP.md: scripts/cmux-next/terminal-path-links-live.py
codebase-health.md: plans/cmux-next/OWNERS.md, scripts/cmux-next/guardrails.py
perf-speed-of-light.md: scripts/cmux-next/codebase-health.py, scripts/cmux-next/perf-gate.py
plans/cmux-next/codebase-health.md: scripts/cmux-next/codebase-health.py, scripts/cmux-next/guardrails.py, scripts/cmux-next/perf-hot-benches.json, scripts/cmux-next/prepush-gate.py
plans/cmux-next/decisions.md: plans/cmux-next/onboarding.md
plans/cmux-next/do-audit.md: plans/cmux-next/chief-done.md
plans/cmux-next/perf-speed-of-light.md: scripts/cmux-next/perf-gate.py
plans/cmux-next/remote-hosts/DESIGN.md: plans/cmux-next/object-sync/DESIGN.md
```
</details>

## 6. Guardrails (pre-push, local, never CI)

`scripts/cmux-next/guardrails.py`, run by the pre-push hook through `prepush-gate.py --pre-push`, looks only at
lines the push adds under `Packages/macOS/CmuxNext/Sources` (moved lines do not count) and takes well under
a second. Refusals print the rule, why, the right pattern and the escape. Skip one push with
`CMUX_GUARDRAILS_SKIP_REASON="<rule>: <why>"` and say so in your report. `guardrails.py --list` prints every rule.
It also warns (never refuses) when a push changes a `// perf-hot:` function (names the bench,
`scripts/cmux-next/perf-hot-benches.json`) or an area in [OWNERS.md](OWNERS.md).

