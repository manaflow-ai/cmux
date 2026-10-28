# cmux-next codebase health (measured)

Measured 2026-10-24 at feat-cmux-next `c30802b35f8` plus this tree's changes to `scripts/cmux-next/arch-layers.py`, `scripts/cmux-next/arch_counts.py`, `scripts/cmux-next/codebase-health.py`, `scripts/cmux-next/tests/test_arch_layers.py` by `scripts/cmux-next/codebase-health.py --write` (rerun it to refresh; do not edit numbers by hand).
Scope: tracked Swift in `Packages/macOS/CmuxNext/Sources` and in the Sources of every local package it links,
directly or through another one (the arch ratchet's scope, arch_counts.py method v5), comments stripped
(section 3's App share: CmuxNext's Sources only; section 6's perf-hot markers: every tracked Swift file).
The pre-push guardrails
(`scripts/cmux-next/guardrails.py`, run by `prepush-gate.py`) refuse NEW instances of the ratcheted rows;
the debt below never blocks a push. Owners: [OWNERS.md](OWNERS.md). Guardrail rules: section 6.

## 1. Concurrency, state and instrumentation debt

| Pattern | Lines | Files | Without the waiver comment | Why it matters |
|---|---:|---:|---:|---|
| stateful singletons and globals (arch_counts `stateful_singletons`) | 204 | 180 | - | runtime state behind a global, under any name; construct at the composition root and inject (CLAUDE.md Package design discipline) |
| global mutable statics (arch_counts `global_mutable_statics`) | 478 | 228 | - | a static or file-scope var, lock or cache: state no owner injects |
| `MainActor.assumeIsolated` | 202 | 129 | 152 (outside seam adapters) | traps off main; allowed only in a small seam adapter with `// main-proof: <why>` |
| NotificationCenter observers (registrations through wrappers such as `MainActorObservation(`, KVO included; arch_counts `observer_sites`) | 336 | 141 | - | each one wakes on every post of its name |
| custom `Notification.Name` declarations (arch_counts `app_broadcast_names`) | 13 | 11 | - | a broadcast signal: every observer reacts, O(all) |
| `@unchecked Sendable` | 154 | 112 | 104 (no `crash-allow:`) | a data race the compiler cannot see; needs `// crash-allow: <safety argument>` |
| `nonisolated(unsafe)` | 58 | 40 | 33 (no `crash-allow:`) | as above |
| raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex) | 120 | 82 | - | CLAUDE.md: actor, or the CmuxNextCompat Mutex carve-out |
| CmuxNextCompat `Mutex` uses (the sanctioned lock) | 243 | 169 | - | sanctioned; listed for scale |
| `Task.sleep` | 64 | 46 | 32 (no `wakeup-allow:`) | allowed only as a bounded, cancellable delay |
| clock sleeps `.sleep(for:/until:)` | 164 | 125 | 92 (no `wakeup-allow:`) | as above |
| `DispatchQueue.main.async` | 47 | 27 | - | use @MainActor and await |
| `asyncAfter` | 0 | 0 | - | banned (check-concurrency.sh); an injected Clock |
| `NSHostingView` / `NSHostingController` | 30 | 22 | - | a SwiftUI graph inside AppKit; costly on hot paths |
| `#if DEBUG` blocks | 497 | 329 | - | DEBUG-only instrumentation is not in Release builds |
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` | 0 | 0 | - | CLAUDE.md: @Observable |

<details><summary>stateful singletons and globals (arch_counts `stateful_singletons`): 204 in 180 files (top 10)</summary>

```
   8  CmuxNextSignposts/Signposter.swift
   4  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift
   3  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/HeaderBar.swift
   2  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/MediaCache.swift
   2  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/TiledBubble.swift
   2  CmuxNextAgentActivity/AgentLaneStore.swift
   2  CmuxNextAgentPane/AgentChatPullRequestReader.swift
   2  CmuxNextAgentPane/AgentPaneSuggestedTasks.swift
   2  CmuxNextAgentPane/AgentPaneView.swift
   2  CmuxNextBrowser/Core/SiteZoomLevels.swift
      ... 170 more files
```
</details>

<details><summary>global mutable statics (arch_counts `global_mutable_statics`): 478 in 228 files (top 10)</summary>

```
  29  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/Transcript.swift
  18  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/WindowView.swift
  16  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift
  10  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/Layout.swift
   8  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/FlightRecorder.swift
   8  CmuxNextApp/Control/DebugTimings.swift
   7  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/SwipeReply.swift
   7  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/MediaCache.swift
   7  CmuxNextApp/Control/DebugLayoutCounters.swift
   7  CmuxNextDesign/ColorTransition/ThemeRepaint.swift
      ... 218 more files
```
</details>

<details><summary>`MainActor.assumeIsolated`: 202 in 129 files (top 10)</summary>

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
      ... 119 more files
```
</details>

<details><summary>NotificationCenter observers (registrations through wrappers such as `MainActorObservation(`, KVO included; arch_counts `observer_sites`): 336 in 141 files (top 10)</summary>

```
  14  CmuxNextApp/Windows/WindowOverlayLayer.swift
  14  CmuxNextDesign/BackdropVideoView.swift
   8  CmuxNextApp/Control/DebugWindowTransition.swift
   8  CmuxNextApp/Feed/FeedService.swift
   8  CmuxNextDesign/StatusIndicator/StatusIndicatorAppearance.swift
   8  CmuxNextRemoteBrowser/Pane/RemoteBrowserSurfaces.swift
   7  CmuxNextDesign/Motion/Motion+LiveResize.swift
   7  CmuxNextDesign/Overlay/WindowOverlayHost.swift
   7  CmuxNextDesign/WindowKeyFamily.swift
   6  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/MessagesLabHomeView.swift
      ... 131 more files
```
</details>

<details><summary>custom `Notification.Name` declarations (arch_counts `app_broadcast_names`): 13 in 11 files (top 10)</summary>

```
   2  CmuxNextDesign/Motion/Motion.swift
   2  CmuxNextSidebar/Store/SidebarDocStore.swift
   1  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/MessagesLabHomeView+Motion.swift
   1  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Cmux/CmuxSidebarView+Motion.swift
   1  CmuxNextAgentPane/AgentPaneView+ContextMenu.swift
   1  CmuxNextBrowser/CEF/CEFHostView.swift
   1  CmuxNextBrowserCore/Engine/BrowserWindowOcclusion.swift
   1  CmuxNextDesign/HoverCards/HoverCardTiming.swift
   1  CmuxNextDesign/WindowMaterialView.swift
   1  CmuxNextSidebar/Model/SidebarModel.swift
      ... 1 more files
```
</details>

<details><summary>`@unchecked Sendable`: 154 in 112 files (top 10)</summary>

```
   7  Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/IrxCtlListAuthOverlays.swift
   5  Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohSystemBonjourDNSService.swift
   5  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift
   5  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenStream.swift
   3  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/AppLog.swift
   3  Packages/Shared/CmuxVNC/Sources/CmuxVNCDemoServer/VNCDemoServer.swift
   3  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/VNCPeerLink.swift
   3  Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/SSHConnection.swift
   3  CmuxNextDictation/SpeechAnalyzerAudioInput.swift
   2  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxCredentialedHTTPSession.swift
      ... 102 more files
```
</details>

<details><summary>`nonisolated(unsafe)`: 58 in 40 files (top 10)</summary>

```
   6  CmuxNextCrashReporting/TaskExceptionPorts.swift
   4  CmuxNextTabs/TabAccessibilityElement.swift
   3  Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Transcript/AttachmentLayout.swift
   3  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/HomeFlightRecorder.swift
   3  CmuxNextCrashReporting/AlternateSignalStacks.swift
   2  Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileRPCISO8601DateParser.swift
   2  CmuxNextApp/BrowserNowPlaying.swift
   2  CmuxNextPalette/PaletteRankerBridge.swift
   2  CmuxNextVSCodeServer/ServeWebProcess.swift
   1  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/UserDefaultsAnalyticsConsentProvider.swift
      ... 30 more files
```
</details>

<details><summary>raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex): 120 in 82 files (top 10)</summary>

```
   6  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift
   4  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/DiagnosticLog.swift
   4  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/Layout.swift
   4  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Vendor/appkit-native/SidebarDrawing.swift
   4  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenStream.swift
   3  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/AppLog.swift
   2  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/OSAllocatedUnfairLock+Portable.swift
   2  Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohReconnectBackoff.swift
   2  Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohSystemBonjourDNSService.swift
   2  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/HomeMarkdownPolicy.swift
      ... 72 more files
```
</details>

<details><summary>CmuxNextCompat `Mutex` uses (the sanctioned lock): 243 in 169 files (top 10)</summary>

```
  10  CmuxNextControl/Diagnostics/MainThreadWatchdog.swift
   5  CmuxNextControl/Diagnostics/BusyWatchdog.swift
   4  CmuxNextCrashReporting/LagSpikeReporter.swift
   4  CmuxNextDaemon/Terminal/TerminalAttachment.swift
   3  CmuxNextAgentPane/AcpmuxVersionHandoff.swift
   3  CmuxNextAgentPane/RemoteAcpmuxWire.swift
   3  CmuxNextDaemon/Connection/LineTransport.swift
   3  CmuxNextDaemon/Connection/PageRelayHandshake.swift
   3  CmuxNextRemote/AddMachine/HostCLI.swift
   3  CmuxNextWakeups/MainTaskBoard.swift
      ... 159 more files
```
</details>

<details><summary>`Task.sleep`: 64 in 46 files (top 10)</summary>

```
   5  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenStream.swift
   3  CmuxNextApp/AgentChatUploads.swift
   3  CmuxNextApp/AgentPeerUploads.swift
   3  Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/TestSupport/UpdateTestSupport.swift
   2  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/AppLog.swift
   2  Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/IrxControlPlaneClient.swift
   2  Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/IrxRelayCredentialAutopilot.swift
   2  Packages/Shared/CmuxScreenKit/Sources/CmuxScreenKit/ScreenSession.swift
   2  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/VNCWebRTCHost.swift
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
      ... 36 more files
```
</details>

<details><summary>clock sleeps `.sleep(for:/until:)`: 164 in 125 files (top 10)</summary>

```
   5  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenStream.swift
   4  Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Mock/MockHomeSource.swift
   3  Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/BrowserSignIn/HostBrowserSignInFlow.swift
   3  Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohHostRuntime+PolicyRefresh.swift
   3  CmuxNextApp/AgentChatUploads.swift
   3  CmuxNextApp/AgentPeerUploads.swift
   3  CmuxNextPhone/Live/SimulatorKitHID.swift
   3  Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/TestSupport/UpdateTestSupport.swift
   2  Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxRetryAfterPolicy.swift
   2  Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthCoordinator+PostSignInTimeout.swift
      ... 115 more files
```
</details>

<details><summary>`DispatchQueue.main.async`: 47 in 27 files (top 10)</summary>

```
   5  CmuxNextTerminal/GhosttyRuntimeCallbacks.swift
   4  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LinkPreviews.swift
   4  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/RowDrawing.swift
   3  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Compose.swift
   3  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/Vendor/appkit-native/SidebarView.swift
   3  Packages/Shared/CmuxVNCWebRTC/Sources/CmuxVNCWebRTC/ScreenVideoView.swift
   2  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/SpellCheck.swift
   2  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/LongText.swift
   2  Packages/Shared/CmuxScreenKit/Sources/CmuxScreenKitUI/ScreenViewController.swift
   2  CmuxNextApp/Focus/InputVerificationService+NoActivateGuard.swift
      ... 17 more files
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

<details><summary>`#if DEBUG` blocks: 497 in 329 files (top 10)</summary>

```
  22  Packages/iOS/CmuxMobileSupport/Sources/CmuxMobileSupport/UITestConfig.swift
   7  CmuxNextControl/Diagnostics/BurstTrace.swift
   6  CmuxNextPages/PageWebView+Chromium.swift
   6  CmuxNextUpdater/UpdaterService+Flow.swift
   5  CmuxNextAgentPane/AgentPaneView+Loading.swift
   5  CmuxNextApp/Control/BenchSpans.swift
   5  CmuxNextApp/RemoteView/RemoteBrowserPages.swift
   5  CmuxNextDaemon/Store/DaemonStore+MirrorCheck.swift
   4  Packages/iOS/CmuxMobileSupport/Sources/CmuxMobileSupport/Debug/UITestConfig+AgentFeedPreview.swift
   4  Packages/iOS/CmuxMobileSupport/Sources/CmuxMobileSupport/Debug/UITestConfig+NotificationFeedPreview.swift
      ... 319 more files
```
</details>

## 2. NotificationCenter broadcast signals

336 observer registrations; 12 custom names. A name observed by a
per-instance view or window class wakes every instance on every post: O(all), not O(changed).

| Name | Observer sites | Every sender (no `object:`, or `object: nil`) | Post sites | Per-instance observer files |
|---|---:|---:|---:|---|
| `reduceMotionDidChange` | 7 | 7 | 1 | `AgentPaneView.swift`, `PageWebView.swift` |
| `configDidChange` | 3 | 3 | 1 | `TerminalHostView.swift` |
| `browserChildWindowPagesNeedUpdate` | 2 | 1 | 3 | `CEFHostView.swift` |
| `cmuxNextInspectUIElement` | 1 | 1 | 1 | `UIInspectorController.swift` |
| `itemFaviconsChanged` | 1 | 1 | 1 | `SidebarListView.swift` |
| `refusedNotification` | 1 | 1 | 2 | `SidebarListView.swift` |
| `settledNotification` | 1 | 1 | 1 | `SidebarListView.swift` |
| `speedDidChange` | 1 | 1 | 4 | `PageWebView.swift` |
| `accessibilityTrustChanged` | 2 | 2 | 0 | - |
| `hoverCardsDidChange` | 1 | 1 | 2 | - |
| `inactiveDimDidChange` | 1 | 1 | 1 | - |
| `geometryDidChange` | 0 | 0 | 1 | - |

Every observed name (system and custom), by per-instance observer files (a view or window class that
registers per instance: N instances = N wakes per post):

<details><summary>Observed names</summary>

```
145 sites   8 per-instance  name  (Compose.swift, HostPressureIndicatorView.swift, BackdropVideoView.swift, SidebarNowPlayingControls.swift, TerminalSurfaceView.swift)
  7 sites   7 per-instance  boundsDidChangeNotification  (Compose.swift, NativeScroll.swift, SidebarView.swift, SidebarView.swift, TerminalScroller.swift)
 11 sites   6 per-instance  accessibilityDisplayOptionsDidChangeNotification  (AgentPaneView.swift, ThemedFieldBox.swift, PageWebView.swift, TerminalHostView.swift, WindowRootView.swift)
  7 sites   5 per-instance  didChangeOcclusionStateNotification  (PhoneScreenView.swift, SidebarListView.swift, SidebarNoticeCardView.swift, AgentPaneVisibilityProbe.swift, StatusIndicatorView.swift)
 13 sites   4 per-instance  willCloseNotification  (PageHostPool+Windows.swift, NewTabSparePool.swift, HoverReveal.swift, GroupCustomColor.swift)
 27 sites   3 per-instance  ?  (BackdropVideoView.swift, HoverReveal.swift, MessagesLabHomeView.swift)
  8 sites   3 per-instance  didBecomeKeyNotification  (PageHostPool+Windows.swift, NewTabSparePool.swift, ActiveAppKeyPanel.swift)
  4 sites   3 per-instance  preferredScrollerStyleDidChangeNotification  (NativeScroll.swift, SidebarView.swift, NotificationsPanelView.swift)
  9 sites   2 per-instance  n  (Materials.swift, SidebarView.swift)
  7 sites   2 per-instance  frameDidChangeNotification  (SidebarView.swift, ScrollEdgeFade.swift)
  7 sites   2 per-instance  reduceMotionDidChange  (AgentPaneView.swift, PageWebView.swift)
  3 sites   1 per-instance  configDidChange  (TerminalHostView.swift)
  3 sites   1 per-instance  didChangeScreenParametersNotification  (ChiefPetPanel.swift)
  2 sites   1 per-instance  browserChildWindowPagesNeedUpdate  (CEFHostView.swift)
  1 sites   1 per-instance  cmuxNextInspectUIElement  (UIInspectorController.swift)
```
</details>

Example O(all) cause: `browserChildWindowPagesNeedUpdate` is posted per layout change by
`WindowRootView+MainPane` and `WindowOverlayLayer`; every `CEFHostView` (one per page, moving or not)
observes it and posts geometry (perf-lead.md issue 2). Fix shape: notify only the hosts whose rect changed.

## 3. Target sizes

`CmuxNextApp`: **143,341 lines** of 623,817 in CmuxNext's `Sources` (23 %); 808,872 lines with Tests and the package manifest.
Every edit in the App target re-emits the whole module (check-app-size.sh), so new code goes in a feature target.

<details><summary>Lines per target (15 largest)</summary>

```
 143,341  CmuxNextApp  [app]
  42,757  CmuxNextBrowser  [ui]
  36,937  MessagesLabHome  [ui]
  36,823  CmuxNextSidebar  [ui]
  33,662  CmuxNextDesign  [ui]
  33,653  CmuxNextDaemon  [service]
  30,942  CmuxNextAgentPane  [ui]
  30,399  CmuxIrohTransport  [service]
  20,909  CmuxNextSettings  [domain]
  20,271  CMUXMobileCore  [core]
  19,777  CmuxNextActions  [core]
  13,991  CmuxIrxTransport  [service]
  13,799  CmuxNextControl  [service]
  13,693  CmuxNextLayout  [ui]
  11,749  CmuxNextPalette  [ui]
```
</details>

## 4. Target graph vs the 5-layer rule

`Package.swift` and its local packages' manifests: 185 targets (144 non-test: 1 app, 51 ui, 12 domain, 50 service, 30 core; 41 test). The App depends directly on 104 targets; 32 targets have no
dependency among them; the longest dependency chain is 11 targets.

Layer per target from `plans/cmux-next/architecture-layers.json`; the rule is arch_counts.py's `layers()`,
the one plans/cmux-next/arch-ratchet.json and the pre-push ratchet hold: hard, a core/service/domain target
that depends on a ui or app target; soft, a service target that depends on a domain target; upward, any
other edge that points up a layer (core -> service/domain).
**33 hard, 12 soft and 3 upward edges break the rule; 0 targets are unplaced:**

<details><summary>Layer violations</summary>

```
hard  CmuxMobileRPC (domain) -> CmuxMobileSupport (ui)
hard  CmuxNextAgentCursor (domain) -> CmuxNextDesign (ui)
hard  CmuxNextAgentIntegrations (service) -> CmuxNextPages (ui)
hard  CmuxNextAgentUpdates (service) -> CmuxNextPages (ui)
hard  CmuxNextBridge (domain) -> CmuxAgentBrands (ui)
hard  CmuxNextBridge (domain) -> CmuxNextIcons (ui)
hard  CmuxNextBridge (domain) -> CmuxNextLayout (ui)
hard  CmuxNextBridge (domain) -> CmuxNextSidebar (ui)
hard  CmuxNextBridge (domain) -> CmuxNextTabs (ui)
hard  CmuxNextBrowserAutomation (service) -> CmuxNextBrowser (ui)
hard  CmuxNextBrowserHistory (service) -> CmuxNextBrowser (ui)
hard  CmuxNextBrowserHost (service) -> CmuxNextBrowser (ui)
hard  CmuxNextChromiumWarmup (service) -> CmuxNextBrowser (ui)
hard  CmuxNextComputerUse (service) -> CmuxNextAgentActivity (ui)
hard  CmuxNextDaemonService (service) -> CmuxNextAgentPane (ui)
hard  CmuxNextDaemonService (service) -> CmuxNextApps (ui)
hard  CmuxNextDaemonService (service) -> CmuxNextLayout (ui)
hard  CmuxNextDiff (service) -> CmuxNextAgentPane (ui)
hard  CmuxNextDiff (service) -> CmuxNextPages (ui)
hard  CmuxNextHostedChief (service) -> CmuxNextHomeEngine (ui)
hard  CmuxNextMobileHost (service) -> CmuxNextAgentPane (ui)
hard  CmuxNextMobileHost (service) -> CmuxNextDesign (ui)
hard  CmuxNextMobileHost (service) -> CmuxNextPages (ui)
hard  CmuxNextMobileHost (service) -> CmuxNextRemoteBrowser (ui)
hard  CmuxNextNowPlaying (domain) -> CmuxNextAgentPane (ui)
hard  CmuxNextNowPlaying (domain) -> CmuxNextBrowser (ui)
hard  CmuxNextNowPlaying (domain) -> CmuxNextSidebar (ui)
hard  CmuxNextRemoteLocalhostService (service) -> CmuxNextBrowser (ui)
hard  CmuxNextSettings (domain) -> CmuxNextDesign (ui)
hard  CmuxNextStash (service) -> CmuxNextHistory (ui)
hard  CmuxNextWebUpdates (service) -> CmuxNextAgentPane (ui)
hard  CmuxNextWebUpdates (service) -> CmuxNextPages (ui)
hard  CmuxNextWebUpdates (service) -> CmuxNextUpdater (ui)
soft  CmuxNextAgentIntegrations (service) -> CmuxNextSettings (domain)
soft  CmuxNextAgentUpdates (service) -> CmuxNextSettings (domain)
soft  CmuxNextComputerUse (service) -> CmuxNextSettings (domain)
soft  CmuxNextControl (service) -> CmuxNextSettings (domain)
soft  CmuxNextDaemonService (service) -> CmuxNextBridge (domain)
soft  CmuxNextDiff (service) -> CmuxNextSettings (domain)
soft  CmuxNextKeepAwake (service) -> CmuxNextBridge (domain)
soft  CmuxNextKeepAwake (service) -> CmuxNextSettings (domain)
soft  CmuxNextMobileHost (service) -> CmuxNextSettings (domain)
soft  CmuxNextPhoneAccess (service) -> CmuxNextSettings (domain)
soft  CmuxNextRemoteLocalhostService (service) -> CmuxNextSettings (domain)
soft  CmuxNextWebUpdates (service) -> CmuxNextSettings (domain)
upward  CmuxNextAgentCursorVisibility (core) -> CmuxNextAgentCursor (domain)
upward  CmuxNextWorkspaceNaming (core) -> CmuxNextBridge (domain)
upward  CmuxNextWorkspaceNaming (core) -> CmuxNextDaemon (service)
```
</details>

## 5. Docs, scripts, workflows

- `plans/cmux-next`: 593 tracked files, 406 Markdown (335 at the top level).
- Stale references (a `.md` named in plans/cmux-next docs or scripts/cmux-next that no tracked file has): **9** targets.
- `scripts/cmux-next`: 596 files at the top level, 912 tracked in total.
- `.github/workflows`: 211 files.

<details><summary>Stale references (missing doc: files that name it)</summary>

```
ORG-BACKUP.md: scripts/cmux-next/terminal-path-links-live.py
every-action.md: scripts/cmux-next/every-action-sweep.py, scripts/cmux-next/tests/test_every_action_sweep.py
perf-speed-of-light.md: scripts/cmux-next/codebase-health.py, scripts/cmux-next/perf-gate.py
perf-status.md: scripts/cmux-next/terminal-cmd-click-e2e.py
plans/cmux-next/decisions.md: plans/cmux-next/codebase-health.md, plans/cmux-next/onboarding.md
plans/cmux-next/do-audit.md: plans/cmux-next/chief-done.md, plans/cmux-next/codebase-health.md
plans/cmux-next/perf-speed-of-light.md: plans/cmux-next/codebase-health.md, scripts/cmux-next/perf-gate.py
plans/cmux-next/remote-hosts/DESIGN.md: plans/cmux-next/codebase-health.md, plans/cmux-next/object-sync/DESIGN.md
plans/cmux-next/threading-model.md: plans/cmux-next/codebase-health.md, scripts/cmux-next/guardrails.py
```
</details>

## 6. Guardrails (pre-push, local, never CI)

`scripts/cmux-next/guardrails.py`, run by the pre-push hook through `prepush-gate.py --pre-push`, looks only at
lines the push adds under `Packages/macOS/CmuxNext/Sources` and takes well under a second. Per file and rule it
is a count ratchet: an edit of a line that already has the debt adds none, and a line moved from another file
does not count. Removed lines pay only when they were debt in the base (same context and escape rules), and an
unchanged line counts when the push changes its context (`struct` -> `class` around a static, a view renamed to a row) or deletes its escape comment. Lines a
push only brings in from origin/feat-cmux-next (a merge or a rebase onto it) never count. Refusals print the rule,
why, the right pattern and the escape. One rule is not per line: `app-size` is a net count over the push in
CmuxNextApp source lines (CI's lexer, as `check-app-size.sh --base` counts them), where removed App lines pay
for added ones and code moved into the App from a package is growth. It refuses the root's wiring over its budget
(`ROOT_BUDGET` in guardrails.py, `--list` prints it; lines moved into the root count) and a new App file that is
neither a move nor the push's one `AppServices+<Domain>Host.swift` of one-line forwards; growth of the App total
and of the App outside the composition root warns (bytes added, the package the code goes to) until the large
domains are out of CmuxNextApp. `app-type`, a second net rule, refuses a new type in an existing App file
or in a new App file that passes as a move, when the type is not a move (any depth: top-level, in an
`extension`, or a nested type over `PRIVATE_TYPE_MAX` source lines with its `extension` blocks in the file).
They are the only App-size limits in force on a push. Skip one rule for one push with
`CMUX_GUARDRAILS_SKIP_REASON="<rule>[,<rule>]: <why>"` (the other rules still refuse) and say so in your report.
`guardrails.py --list` prints every rule. The guardrails also run the arch ratchet (`arch-ratchet.py`): the
arch_counts rows of section 1 and the layer edges of section 4 may not rise over a push, and their totals in
`plans/cmux-next/arch-ratchet.json` only go down; their one escape is a dated exception in that file (the skip
variable does not skip them).
If the script itself fails, the hook prints a warning and lets the push through.
It also warns (never refuses) when a push changes a `// perf-hot:` function (names the bench,
`scripts/cmux-next/perf-hot-benches.json`) or an area in [OWNERS.md](OWNERS.md).

Perf-hot markers per path id, from every tracked Swift file. An id with no marker never warns: its owner
marks the hot function (a trailing `// perf-hot: <budget> <path-id>` on the line that has `func`, `init` or
`var`, or on the line with the body's `{` of a wrapped signature, adds no line; or a comment line right above
the declaration). Which declaration a marker marks is what the hook's own resolver says, and whether it
warns is what `guardrails.check` itself reports for a push that edits every line of the marked files (its own
diff scope, not a copy), so a marker outside the hook's diff scope, or one that marks no declaration, is
flagged: an edit of that function warns nobody.

Marked: 13 of 15 path ids (23 markers); 13 of 15 warn at push; 1 of 23 markers never warn.

- `cef-host-input`: CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostConnection.swift:63
- `key-dispatch`: CmuxNextActions/KeyBindingTable+Sequence.swift:26, CmuxNextApp/Focus/ChordTracker.swift:92, CmuxNextApp/Focus/KeyRouter.swift:177, CmuxNextApp/Focus/KeyRouter.swift:236, CmuxNextApp/Notifications/NotificationCenterService+Lookup.swift:46
- `terminal-key`: CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift:14
- `home-key`: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/PaneHost.swift:678 (outside the pre-push hook's diff scope: no warning), CmuxNextHome/NativeTranscript/HomeNativeTranscriptView+Attachments.swift:276
- `palette-key`: CmuxNextPalette/PaletteModel+Search.swift:109
- `omnibar-key`: CmuxNextBrowser/Omnibox/OmnibarReducer.swift:220
- `motion-frame`: CmuxNextLayout/Views/ScreenContentView+Motion.swift:14, CmuxNextLayout/Views/ScreenContentView+Motion.swift:90
- `frame-tick`: CmuxNextWakeups/FrameScheduler.swift:232
- `drag-frame`: CmuxNextApp/Drag/TabDragSession+Ghost.swift:38
- `tab-switch`: CmuxNextBrowser/CEF/CEFLayerHosting.swift:148, CmuxNextDesign/Motion/MotionPath.swift:100
- `workspace-switch`: **no marker** (owner PL-switch)
- `cef-geometry`: CmuxNextApp/Windows/WindowOverlayLayer.swift:333, CmuxNextApp/Windows/WindowOverlayLayer.swift:362, CmuxNextBrowser/CEF/CEFHostView.swift:222, CmuxNextBrowser/CEF/CEFLayerHosting.swift:208
- `cmd-tab`: CmuxNextDesign/WindowKeyFamily.swift:89
- `new-tab`: **no marker** (owner PL-cef-tab)
- `action-budget`: CmuxNextActions/ActionBudgetMonitor.swift:113

