# cmux-next codebase health (measured)

Measured 2026-10-24 at feat-cmux-next `2086a2197d9` plus this tree's changes to `plans/cmux-next/arch-ratchet.json`, `scripts/cmux-next/arch-layers.py`, `scripts/cmux-next/arch-ratchet.py`, `scripts/cmux-next/arch_counts.py` and 6 more by `scripts/cmux-next/codebase-health.py --write` (rerun it to refresh; do not edit numbers by hand).
Scope: tracked Swift in `Packages/macOS/CmuxNext/Sources`, comments stripped (section 6's perf-hot markers:
every tracked Swift file). The pre-push guardrails
(`scripts/cmux-next/guardrails.py`, run by `prepush-gate.py`) refuse NEW instances of the ratcheted rows;
the debt below never blocks a push. Owners: [OWNERS.md](OWNERS.md). Guardrail rules: section 6.

## 1. Concurrency, state and instrumentation debt

| Pattern | Lines | Files | Without the waiver comment | Why it matters |
|---|---:|---:|---:|---|
| stateful singletons and globals (arch_counts `stateful_singletons`) | 177 | 160 | - | runtime state behind a global, under any name; construct at the composition root and inject (CLAUDE.md Package design discipline) |
| global mutable statics (arch_counts `global_mutable_statics`) | 279 | 175 | - | a static or file-scope var, lock or cache: state no owner injects |
| `MainActor.assumeIsolated` | 198 | 128 | 148 (outside seam adapters) | traps off main; allowed only in a small seam adapter with `// main-proof: <why>` |
| NotificationCenter observers (registrations through wrappers such as `MainActorObservation(`, KVO included; arch_counts `observer_sites`) | 295 | 125 | - | each one wakes on every post of its name |
| custom `Notification.Name` declarations (arch_counts `app_broadcast_names`) | 12 | 10 | - | a broadcast signal: every observer reacts, O(all) |
| `@unchecked Sendable` | 66 | 59 | 41 (no `crash-allow:`) | a data race the compiler cannot see; needs `// crash-allow: <safety argument>` |
| `nonisolated(unsafe)` | 33 | 20 | 10 (no `crash-allow:`) | as above |
| raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex) | 27 | 22 | - | CLAUDE.md: actor, or the CmuxNextCompat Mutex carve-out |
| CmuxNextCompat `Mutex` uses (the sanctioned lock) | 241 | 168 | - | sanctioned; listed for scale |
| `Task.sleep` | 32 | 25 | 0 (no `wakeup-allow:`) | allowed only as a bounded, cancellable delay |
| clock sleeps `.sleep(for:/until:)` | 74 | 60 | 3 (no `wakeup-allow:`) | as above |
| `DispatchQueue.main.async` | 14 | 9 | - | use @MainActor and await |
| `asyncAfter` | 0 | 0 | - | banned (check-concurrency.sh); an injected Clock |
| `NSHostingView` / `NSHostingController` | 30 | 22 | - | a SwiftUI graph inside AppKit; costly on hot paths |
| `#if DEBUG` blocks | 416 | 294 | - | DEBUG-only instrumentation is not in Release builds |
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` | 0 | 0 | - | CLAUDE.md: @Observable |

<details><summary>stateful singletons and globals (arch_counts `stateful_singletons`): 177 in 160 files (top 10)</summary>

```
   8  CmuxNextSignposts/Signposter.swift
   2  CmuxNextAgentActivity/AgentLaneStore.swift
   2  CmuxNextAgentPane/AgentChatPullRequestReader.swift
   2  CmuxNextAgentPane/AgentPaneSuggestedTasks.swift
   2  CmuxNextAgentPane/AgentPaneView.swift
   2  CmuxNextBrowser/Core/SiteZoomLevels.swift
   2  CmuxNextDesign/OverlayMaterial.swift
   2  CmuxNextDesign/PointerHover.swift
   2  CmuxNextDesign/Toast/ToastUndoStep.swift
   2  CmuxNextPages/WebBundleOverlay.swift
      ... 150 more files
```
</details>

<details><summary>global mutable statics (arch_counts `global_mutable_statics`): 279 in 175 files (top 10)</summary>

```
   8  CmuxNextApp/Control/DebugTimings.swift
   7  CmuxNextApp/Control/DebugLayoutCounters.swift
   7  CmuxNextDesign/ColorTransition/ThemeRepaint.swift
   7  CmuxNextDesign/Motion/MotionTrace.swift
   6  CmuxNextCrashReporting/TaskExceptionPorts.swift
   5  CmuxNextDesign/HoverReveal.swift
   5  CmuxNextDesign/SystemScrollers.swift
   5  CmuxNextTerminal/GhosttyRuntime+Background.swift
   4  CmuxNextApp/RemoteView/RemoteBrowserPages.swift
   4  CmuxNextBrowser/UI/ArrowCursorView.swift
      ... 165 more files
```
</details>

<details><summary>`MainActor.assumeIsolated`: 198 in 128 files (top 10)</summary>

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
      ... 118 more files
```
</details>

<details><summary>NotificationCenter observers (registrations through wrappers such as `MainActorObservation(`, KVO included; arch_counts `observer_sites`): 295 in 125 files (top 10)</summary>

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
   6  CmuxNextApp/AgentCursor/AgentCursorVisibilitySource.swift
      ... 115 more files
```
</details>

<details><summary>custom `Notification.Name` declarations (arch_counts `app_broadcast_names`): 12 in 10 files (top 10)</summary>

```
   2  CmuxNextDesign/Motion/Motion.swift
   2  CmuxNextSidebar/Store/SidebarDocStore.swift
   1  CmuxNextAgentPane/AgentPaneView+ContextMenu.swift
   1  CmuxNextBrowser/CEF/CEFHostView.swift
   1  CmuxNextBrowserCore/Engine/BrowserWindowOcclusion.swift
   1  CmuxNextDesign/HoverCards/HoverCardTiming.swift
   1  CmuxNextDesign/Toast/CmuxToastAvoidance.swift
   1  CmuxNextDesign/WindowMaterialView.swift
   1  CmuxNextSidebar/Model/SidebarModel.swift
   1  CmuxNextTerminal/GhosttyRuntime.swift
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
   1  CmuxNextApp/Crash/AppRunMarker.swift
   1  CmuxNextApp/Permissions/SystemPermissionProbe.swift
      ... 10 more files
```
</details>

<details><summary>raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex): 27 in 22 files (top 10)</summary>

```
   2  CmuxNextApp/DaemonTerminalIO.swift
   2  CmuxNextApp/HostPressure/HostPressureSampling.swift
   2  CmuxNextApp/NativeCaretAccessory.swift
   2  CmuxNextCompat/Mutex.swift
   2  CmuxNextServerHelper/ServerFixPriorStore.swift
   1  CmuxNextAgentPane/AcpmuxEnvironment+BuildHomeAdoption.swift
   1  CmuxNextApp/Crash/UncaughtExceptionRecorder.swift
   1  CmuxNextApp/HostPressure/HostPressureService.swift
   1  CmuxNextApp/Server/ServerHelperClient.swift
   1  CmuxNextBrowser/CEF/ChromiumPageTextAccessory.swift
      ... 12 more files
```
</details>

<details><summary>CmuxNextCompat `Mutex` uses (the sanctioned lock): 241 in 168 files (top 10)</summary>

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
      ... 158 more files
```
</details>

<details><summary>`Task.sleep`: 32 in 25 files (top 10)</summary>

```
   3  CmuxNextApp/AgentChatUploads.swift
   3  CmuxNextApp/AgentPeerUploads.swift
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
   2  CmuxNextApp/Handlers/CloudHandlers.swift
   2  CmuxNextCompat/MainThreadEngineStart.swift
   1  CmuxNextAgentPane/AcpmuxLogProgress.swift
   1  CmuxNextAgentPane/AcpmuxVersionHandoff.swift
   1  CmuxNextAgentPane/AgentPaneDeadline.swift
   1  CmuxNextAgentPane/AgentPaneHost.swift
   1  CmuxNextAgentPane/AgentPaneSeed.swift
      ... 15 more files
```
</details>

<details><summary>clock sleeps `.sleep(for:/until:)`: 74 in 60 files (top 10)</summary>

```
   3  CmuxNextApp/AgentChatUploads.swift
   3  CmuxNextApp/AgentPeerUploads.swift
   3  CmuxNextPhone/Live/SimulatorKitHID.swift
   2  CmuxNextApp/Handlers/CloudHandlers+Results.swift
   2  CmuxNextApp/Handlers/CloudHandlers.swift
   2  CmuxNextBrowser/Omnibox/Suggest/OmniboxRemoteFetch.swift
   2  CmuxNextCompat/MainThreadEngineStart.swift
   2  CmuxNextComputerUse/ComputerUseHelperV2.swift
   2  CmuxNextDaemon/Launch/ProcessRunner.swift
   2  CmuxNextDesign/WebKitRenderRate+Reshow.swift
      ... 50 more files
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

<details><summary>`#if DEBUG` blocks: 416 in 294 files (top 10)</summary>

```
   6  CmuxNextPages/PageWebView+Chromium.swift
   6  CmuxNextUpdater/UpdaterService+Flow.swift
   5  CmuxNextAgentPane/AgentPaneView+Loading.swift
   5  CmuxNextApp/Control/BenchSpans.swift
   5  CmuxNextApp/RemoteView/RemoteBrowserPages.swift
   5  CmuxNextDaemon/Store/DaemonStore+MirrorCheck.swift
   4  CmuxNextApp/Focus/WindowScopedShortcutHintModifierMonitor.swift
   4  CmuxNextApp/History/HistoryControl.swift
   4  CmuxNextApp/RemoteView/MachineBrowserPages.swift
   4  CmuxNextDesign/PointerHover.swift
      ... 284 more files
```
</details>

## 2. NotificationCenter broadcast signals

295 observer registrations; 13 custom names. A name observed by a
per-instance view or window class wakes every instance on every post: O(all), not O(changed).

| Name | Observer sites | Every sender (no `object:`, or `object: nil`) | Post sites | Per-instance observer files |
|---|---:|---:|---:|---|
| `reduceMotionDidChange` | 5 | 5 | 1 | `AgentPaneView.swift`, `PageWebView.swift` |
| `configDidChange` | 3 | 3 | 1 | `TerminalHostView.swift` |
| `browserChildWindowPagesNeedUpdate` | 2 | 1 | 3 | `CEFHostView.swift` |
| `cmuxNextInspectUIElement` | 1 | 1 | 1 | `UIInspectorController.swift` |
| `itemFaviconsChanged` | 1 | 1 | 1 | `SidebarListView.swift` |
| `refusedNotification` | 1 | 1 | 2 | `SidebarListView.swift` |
| `settledNotification` | 1 | 1 | 1 | `SidebarListView.swift` |
| `speedDidChange` | 1 | 1 | 4 | `PageWebView.swift` |
| `accessibilityTrustChanged` | 2 | 2 | 0 | - |
| `cmuxToastAvoidanceDidChange` | 1 | 1 | 1 | - |
| `hoverCardsDidChange` | 1 | 1 | 2 | - |
| `inactiveDimDidChange` | 1 | 1 | 1 | - |
| `geometryDidChange` | 0 | 0 | 1 | - |

Every observed name (system and custom), by per-instance observer files (a view or window class that
registers per instance: N instances = N wakes per post):

<details><summary>Observed names</summary>

```
139 sites   7 per-instance  name  (HostPressureIndicatorView.swift, BackdropVideoView.swift, HomeNativeTranscriptView.swift, SidebarNowPlayingControls.swift, TerminalSurfaceView.swift)
  9 sites   6 per-instance  accessibilityDisplayOptionsDidChangeNotification  (AgentPaneView.swift, ThemedFieldBox.swift, PageWebView.swift, TerminalHostView.swift, WindowRootView.swift)
  7 sites   5 per-instance  didChangeOcclusionStateNotification  (PhoneScreenView.swift, SidebarListView.swift, SidebarNoticeCardView.swift, AgentPaneVisibilityProbe.swift, StatusIndicatorView.swift)
 13 sites   4 per-instance  willCloseNotification  (PageHostPool+Windows.swift, NewTabSparePool.swift, HoverReveal.swift, GroupCustomColor.swift)
  4 sites   4 per-instance  boundsDidChangeNotification  (SidebarView.swift, TerminalScroller.swift, ScrollEdgeFade.swift, PaletteListView.swift)
  7 sites   3 per-instance  didBecomeKeyNotification  (PageHostPool+Windows.swift, NewTabSparePool.swift, ActiveAppKeyPanel.swift)
 21 sites   2 per-instance  ?  (BackdropVideoView.swift, HoverReveal.swift)
  7 sites   2 per-instance  frameDidChangeNotification  (SidebarView.swift, ScrollEdgeFade.swift)
  5 sites   2 per-instance  reduceMotionDidChange  (AgentPaneView.swift, PageWebView.swift)
  3 sites   2 per-instance  preferredScrollerStyleDidChangeNotification  (SidebarView.swift, NotificationsPanelView.swift)
  3 sites   1 per-instance  configDidChange  (TerminalHostView.swift)
  3 sites   1 per-instance  didChangeScreenParametersNotification  (ChiefPetPanel.swift)
  2 sites   1 per-instance  browserChildWindowPagesNeedUpdate  (CEFHostView.swift)
  1 sites   1 per-instance  cmuxNextInspectUIElement  (UIInspectorController.swift)
  1 sites   1 per-instance  itemFaviconsChanged  (SidebarListView.swift)
```
</details>

Example O(all) cause: `browserChildWindowPagesNeedUpdate` is posted per layout change by
`WindowRootView+MainPane` and `WindowOverlayLayer`; every `CEFHostView` (one per page, moving or not)
observes it and posts geometry (perf-lead.md issue 2). Fix shape: notify only the hosts whose rect changed.

## 3. Target sizes

`CmuxNextApp`: **143,076 lines** of 621,653 in `Sources` (23 %); 804,741 lines with Tests and the package manifest.
Every edit in the App target re-emits the whole module (check-app-size.sh), so new code goes in a feature target.

<details><summary>Lines per target (15 largest)</summary>

```
 143,076  CmuxNextApp  [app]
  42,444  CmuxNextBrowser  [ui]
  36,823  CmuxNextSidebar  [ui]
  33,568  CmuxNextDaemon  [service]
  33,520  CmuxNextDesign  [ui]
  30,848  CmuxNextAgentPane  [ui]
  20,909  CmuxNextSettings  [domain]
  19,605  CmuxNextActions  [core]
  13,643  CmuxNextLayout  [ui]
  13,337  CmuxNextControl  [service]
  11,748  CmuxNextPalette  [ui]
  11,606  CmuxNextHomeEngine  [ui]
  11,273  CmuxNextTabs  [ui]
   9,315  CmuxNextTerminal  [ui]
   9,001  CmuxNextUpdater  [ui]
```
</details>

## 4. Target graph vs the 5-layer rule

`Package.swift`: 148 targets (107 non-test: 1 app, 46 ui, 6 domain, 37 service, 17 core; 41 test). The App depends directly on 96 targets; 13 targets have no
in-package dependency; the longest dependency chain is 11 targets.

Layer per target from `plans/cmux-next/architecture-layers.json`; the rule is arch_counts.py's `layers()`,
the one plans/cmux-next/arch-ratchet.json and the pre-push ratchet hold: hard, a core/service/domain target
that depends on a ui or app target; soft, a service target that depends on a domain target; upward, any
other edge that points up a layer (core -> service/domain).
**31 hard, 12 soft and 3 upward edges break the rule; 0 targets are unplaced:**

<details><summary>Layer violations</summary>

```
hard  CmuxNextAgentCursor (domain) -> CmuxNextDesign (ui)
hard  CmuxNextAgentIntegrations (service) -> CmuxNextPages (ui)
hard  CmuxNextAgentUpdates (service) -> CmuxNextPages (ui)
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

- `plans/cmux-next`: 589 tracked files, 402 Markdown (331 at the top level).
- Stale references (a `.md` named in plans/cmux-next docs or scripts/cmux-next that no tracked file has): **9** targets.
- `scripts/cmux-next`: 590 files at the top level, 905 tracked in total.
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
plans/cmux-next/threading-model.md: scripts/cmux-next/guardrails.py
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
`var` adds no line; or a comment line right above the declaration). Whether a marker warns is what
`guardrails.check` itself reports for a push that edits every line of the marked files (its own diff scope and
declaration parser, not a copy), so a marker outside the hook's diff scope, or on a line the hook does not
read as a declaration, is flagged: an edit of that function warns nobody.

Marked: 13 of 15 path ids (22 markers); 12 of 15 warn at push; 3 of 22 markers never warn.

- `cef-host-input`: CmuxNextBrowser/CEF/ChromiumHost/ChromiumHostConnection.swift:63
- `key-dispatch`: CmuxNextActions/KeyBindingTable+Sequence.swift:27 (not on a declaration line the hook parses (a multi-line signature's last line?): no warning), CmuxNextApp/Focus/ChordTracker.swift:93 (not on a declaration line the hook parses (a multi-line signature's last line?): no warning), CmuxNextApp/Focus/KeyRouter.swift:179, CmuxNextApp/Focus/KeyRouter.swift:235, CmuxNextApp/Notifications/NotificationCenterService+Lookup.swift:46
- `terminal-key`: CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift:14
- `home-key`: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/PaneHost.swift:678 (outside the pre-push hook's diff scope: no warning)
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

