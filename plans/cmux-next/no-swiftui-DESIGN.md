# No SwiftUI in the macOS app (design)

Status: wave 0 (lint and plan) landed; wave 1 (hot paths) in progress.
Owner: Chief subagent "Remove SwiftUI from macOS", 2026-10-21.

## Why

The user (u9493, 2026-10-21): "Ideally we don't use SwiftUI anywhere." The
left sidebar (`CmuxNextSidebar`) is already AppKit. SwiftUI still draws 164
source files under `Packages/macOS` (11,390 lines), behind 26 `NSHostingView`
or `NSHostingController` bridges. Each bridge brings its own layout pass,
its own invalidation graph (AttributeGraph) and its own animation clock on
the main thread, beside the AppKit tree. On hot paths (sidebars, Home,
popovers, overlays) that is the source of the "orthogonal change re-renders
every row" class of spin (issue 2586) and of layout work that AppKit views
skip. SwiftUI semantics also change between macOS majors without notice
(issue 4529), and the app supports macOS 14 to 27.

Chief's first count (137 files) missed `public import SwiftUI` and
`import struct SwiftUI.X`; the lint below counts every form.

## Rules

1. New macOS UI is AppKit (`NSView`, `NSStackView`, `NSTableView`,
   `NSCollectionView`, `CALayer`) built from `CmuxNextDesign` (Typography,
   Palette, Metrics, Motion, `StatusIndicatorView`, glass). A page whose
   content is a document (rich text, long lists of mixed cards) may use the
   one Chromium web view factory instead.
2. `scripts/cmux-next/check-no-swiftui.py` fails a file under `Packages/macOS`
   that imports SwiftUI outside `scripts/cmux-next/no-swiftui-allowlist.txt`.
   The allowlist only shrinks: a stale entry fails, and on CI an entry that
   the base commit did not have fails. It runs as a blocking step ("No new
   SwiftUI") in `.github/workflows/cmux-next.yml`, not as a warn-only style
   check; its self-test is `scripts/cmux-next/tests/check-no-swiftui.test.sh`.
   A finding the base commit already had (a SwiftUI import a push landed past
   the gate, or an entry already stale there) is a base red: the step warns
   and fails only on what the change itself adds.
3. A port deletes the file's allowlist line in the same commit.
4. Each port lands test-first: a red commit with a behaviour test (the host
   builds no `NSHostingView`, its rows react to clicks and model changes),
   then the green port. Hot paths also get a perf budget in the a436 perf gate.
5. Rows keep the snapshot boundary: AppKit rows take value snapshots and an
   action bundle, never a store reference.
6. Strings keep their existing localization keys; a port adds no new
   user-facing strings unless it adds them to every catalog.

## What uses SwiftUI (by module)

"Hot" means drawn while the user works (always-visible chrome, a popover or
overlay on a frequent action, or a page that updates live), so a SwiftUI
graph there costs frames. "Cold" means a page or window opened on demand.

| Module | Files | Lines | View types | Bridges | Path | What it draws | Target |
|---|---:|---:|---:|---:|---|---|---|
| `CmuxNextApps/Section` | 1 | 134 | 0 | 1 | **hot** | App sections inside the left sidebar | AppKit (scene renderer, see Apps) |
| `CmuxNextApp/RightSidebar` | 2 | 100 | 1 | 1 | **hot** | Right sidebar Dock section (the Machines host is AppKit) | AppKit rows |
| `CmuxNextServer/AddMachine` (`MachineSection`) | done | | | | | Right sidebar Machines section list: AppKit (`MachineSectionView`) | |
| `CmuxNextFeed` + `/Views` | 18 | 1,437 | 31 | 1 | **hot** | Feed panel / Inbox page, live updates | AppKit table (or web view) |
| `CmuxNextApp/Handlers` | 2 | 644 | 4 | 2 | **hot** | Browser downloads popover; Chief memory page | AppKit popover; page follows ChiefMemory |
| `CmuxNextApp/SleepyMode` | 2 | 162 | 1 | 1 | **hot** | Full-screen sleepy overlay, animated | `CALayer` scene |
| `CmuxNextHome/Conversations` | 6 | 375 | 4 | 1 | **hot** | Home group info sheet (members, contacts) | AppKit sheet |
| `CmuxNextUpdater` | 2 | 233 | 1 | 1 | **hot** | Update sheet (release notes, buttons) | AppKit sheet |
| `CmuxNextAgentActivity` | 2 | 22 | 0 | 0 | hot (values) | `Color` helper, empty `EnvironmentValues` extension | delete SwiftUI half |
| `CmuxNextDesign/Motion` | 3 | 579 | 0 | 0 | **hot** (values) | `SwiftUI.Animation` passed to `NSAnimationContext.animate` (macOS 15+) for retargetable springs; `Motion+SwiftUI` adapter for SwiftUI views | see "Motion" below |
| `CmuxNextTasks` + `/Views` | 15 | 897 | 25 | 1 | warm | Tasks page | AppKit |
| `CmuxNextServer/Views` + host | 23 | 1,485 | 38 | 1 | warm | Server page (machines, processes) | AppKit |
| `CmuxNextServer/AddMachine` (card) | 2 of 3 | ~440 | 5 | 1 | cold | Add Machine card | AppKit |
| `CmuxNextHistory` | 7 | 712 | 5 | 2 | warm | History and Stash pages | `NSTableView` |
| `CmuxNextBookmarks/UI` | 8 | 621 | 6 | 2 | warm | Bookmark manager page, edit bubble popover | `NSOutlineView`, AppKit popover |
| `CmuxNextApp/Vault` | 4 | 181 | 2 | 1 | cold | Vault list | AppKit |
| `CmuxNextApp/Checklist` | 3 | 180 | 2 | 1 | cold | Workspace todo page | AppKit |
| `CmuxNextApp/TaskManager`, `CmuxNextResources/TaskManager` | 2 | 161 | 1 | 1 | warm (live) | Task manager page | `NSTableView` |
| `CmuxNextChiefMemory` | 3 | 259 | 3 | 0 | cold | Chief memory inspector | AppKit |
| `CmuxNextAccounts/Views` | 4 | 358 | 6 | 0 | cold | Accounts palette and section | AppKit |
| `CmuxNextAppPermissions/UI` | 3 | 106 | 1 | 0 | cold | App permissions | AppKit |
| `CmuxNextApps/Store` (+`/Views`) | 15 | 1,577 | 26 | 1 | cold | App store | Chromium web view (it is a catalog page) |
| `CmuxNextApps/Render` | 11 | 756 | 13 | 1 | hot via Section | Declarative app scene renderer (`AppSceneView`) | AppKit renderer of the same scene tree |
| `CmuxNextSettingsWindow` (+Debug, Views) | 8 | 628 | 9 | 2 | cold (DEBUG) | Debug settings window | AppKit form |
| `CmuxNextDesign` (bridges) | 12 | ~560 | 1 | 0 | n/a | SwiftUI adapters of AppKit design pieces: `ThemedSpinner` (wraps `StatusIndicatorView`), glass button style, themed field and picker, thin scrollers, toast, overlay, tooltip, dialog button, unresolved tokens | delete when the last consumer is gone |
| `CmuxNextIcons` | 4 | 120 | 2 | 0 | n/a | `Icon` SwiftUI view and environment | delete with last consumer |
| Tests | 5 | — | — | — | n/a | Tests of the SwiftUI adapters | delete with the adapters |

Exact per-file rows are in the appendix.

### Hot-path notes

- Spinners: every SwiftUI spinner is `ThemedSpinner`, an `NSViewRepresentable`
  around the AppKit `StatusIndicatorView` (Core Animation, no per-frame
  main-thread work). a465 found the native spinners fine; the spinner work
  is not a SwiftUI port.
- Home chat, panes and the tab bar draw no SwiftUI today (Home chat is a
  Chromium web view; panes and tabs are AppKit). Only Home's group info
  sheet is SwiftUI.
- The left sidebar is AppKit, except the App sections it mounts
  (`AppSectionHostingView`, one `NSHostingView` per mounted App section,
  plus an `NSHostingController` used only to measure height). That makes
  `CmuxNextApps/Render` a hot path even though the store is cold.
- The update card in the sidebar is AppKit; only the update sheet is SwiftUI.

### Motion

`Motion.animate(_ spring:)` passes a `SwiftUI.Animation.spring` to
`NSAnimationContext.animate(_:changes:completion:)` (macOS 15+). That is the
only system API that makes `animator()` changes retargetable (a new change
keeps the current presentation value and velocity), which the sidebar and
Home drag springs rely on. No SwiftUI view or hosting is involved; SwiftUI
is linked for the `Animation` value type. Replacing it needs an AppKit
spring engine (`CASpringAnimation` with additive retargeting, or a
`CADisplayLink` integrator) that matches today's feel, proven by the
motion golden tests (`cmux-next-motion-golden.yml`) and the a436 perf gate
before and after. Order: last in wave 1, behind its own bench, so a spring
regression never rides along with a view port. `Motion+SwiftUI.swift`
(SwiftUI `Animation` for SwiftUI views) goes when its consumers go.

## Port order

Wave 0 (landed): this plan, the lint, the allowlist.

Wave 1, hot paths (each its own slice, red test then port):
1. `CmuxNextApp/RightSidebar` Dock section (the Machines section list is done: `MachineSectionView`).
2. `CmuxNextAgentActivity` SwiftUI half (value helpers only).
3. `CmuxNextUpdater` update sheet.
4. `CmuxNextApp/SleepyMode` overlay as `CALayer`s.
5. `CmuxNextHome/Conversations` group info sheet.
6. `CmuxNextApp/Handlers` downloads popover.
7. `CmuxNextApps/Section` + `CmuxNextApps/Render`: an AppKit renderer for
   the scene tree, sections first.
8. `CmuxNextFeed`.
9. `CmuxNextDesign/Motion` spring engine (bench-gated, see above).

Wave 2, live pages: TaskManager, History/Stash, Bookmarks (page and
bubble), Tasks, Server.

Wave 3, cold pages: ChiefMemory (and the Handlers page service), Vault,
Checklist, Accounts, AppPermissions, AddMachine card, debug Settings
window, App store (to a web view).

Wave 4: delete the `CmuxNextDesign` SwiftUI adapters, `CmuxNextIcons`
SwiftUI views and their tests as their consumer counts reach zero; then
remove SwiftUI from the package's linked frameworks and delete the
allowlist and lint exception.

## Verification per slice

- Package tests on the Mac-mini fleet (`cmux-ci run`), never on a laptop.
- A red commit (`--red`) with the behaviour test, then the green port.
- Before and after captures of the surface (fleet capture or tagged build).
- Hot paths: an entry in the a436 perf gate (frame time while the surface
  updates); the port must not raise it.

## Appendix: every file that imports SwiftUI (2026-10-21, feat-cmux-next 972843ddde9)

Columns: lines; SwiftUI view types declared; whether it creates a hosting
bridge; animation call sites (`withAnimation`, `.animation`, `TimelineView`,
transitions); and what the file uses when it declares no view.

| File | Lines | Views | Bridge | Anim | Kind |
|---|---:|---:|---|---:|---|
| `CmuxNextAccounts/Views/AccountRowView.swift` | 151 | 3 |  | 0 | views |
| `CmuxNextAccounts/Views/AccountsPalette.swift` | 88 | 0 |  | 0 | values: Color,Font |
| `CmuxNextAccounts/Views/AccountsSectionView.swift` | 62 | 2 |  | 0 | views |
| `CmuxNextAccounts/Views/PasteField.swift` | 57 | 1 |  | 0 | views |
| `CmuxNextAgentActivity/AgentActivityAppearance.swift` | 6 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextAgentActivity/AgentActivityColor.swift` | 16 | 0 |  | 0 | values: Color |
| `CmuxNextApp/Checklist/WorkspaceTodoPageService.swift` | 60 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/Checklist/WorkspaceTodoPageView.swift` | 53 | 1 |  | 0 | views |
| `CmuxNextApp/Checklist/WorkspaceTodoRow.swift` | 67 | 1 |  | 0 | views |
| `CmuxNextApp/Handlers/BrowserDownloadsPopup.swift` | 468 | 4 | NSHosting | 0 | views |
| `CmuxNextApp/Handlers/ChiefMemoryPageService.swift` | 176 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/RightSidebar/DockSectionHostView.swift` | 63 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/RightSidebar/DockSectionListView.swift` | 35 | 1 |  | 0 | views |
| `CmuxNextApp/RightSidebar/MachineSectionHostView.swift` | 52 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/SleepyMode/SleepyOverlayWindows.swift` | 71 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/SleepyMode/SleepySceneView.swift` | 91 | 1 |  | 2 | views |
| `CmuxNextApp/TaskManager/TaskManagerPageService.swift` | 102 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/Vault/VaultColors.swift` | 11 | 0 |  | 0 | values: Color |
| `CmuxNextApp/Vault/VaultHostView.swift` | 68 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApp/Vault/VaultListView.swift` | 51 | 1 |  | 0 | views |
| `CmuxNextApp/Vault/VaultRowView.swift` | 51 | 1 |  | 0 | views |
| `CmuxNextAppPermissions/UI/AppPermissionsColors.swift` | 68 | 0 |  | 0 | values: Color,Font |
| `CmuxNextAppPermissions/UI/AppPermissionsHostView.swift` | 19 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextAppPermissions/UI/PermissionBadges.swift` | 19 | 1 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneAppearance.swift` | 35 | 1 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneBundleImage.swift` | 33 | 1 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneColors.swift` | 89 | 0 |  | 0 | values: Color |
| `CmuxNextApps/Render/AppSceneDecorations.swift` | 83 | 0 |  | 1 | modifiers/extensions |
| `CmuxNextApps/Render/AppSceneHostingView.swift` | 41 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApps/Render/AppSceneMenus.swift` | 55 | 2 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneNodeView.swift` | 97 | 2 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneRowView.swift` | 114 | 3 |  | 1 | views |
| `CmuxNextApps/Render/AppSceneShapes.swift` | 47 | 2 |  | 0 | views |
| `CmuxNextApps/Render/AppSceneStyle.swift` | 102 | 0 |  | 0 | values: EdgeInsets,Font |
| `CmuxNextApps/Render/AppSceneView.swift` | 60 | 2 |  | 0 | views |
| `CmuxNextApps/Section/AppSectionProvider.swift` | 134 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApps/Store/AppStoreContentView.swift` | 43 | 0 | NSHosting | 0 | bridge |
| `CmuxNextApps/Store/Views/AppCloudFeature.swift` | 47 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppDiscoverView.swift` | 121 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppFeatureWindowPreview.swift` | 182 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppFeaturesView.swift` | 251 | 5 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppGrantsView.swift` | 71 | 1 |  | 1 | views |
| `CmuxNextApps/Store/Views/AppIconView.swift` | 123 | 3 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppInstalledView.swift` | 115 | 2 |  | 1 | views |
| `CmuxNextApps/Store/Views/AppListingDetailView.swift` | 181 | 3 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppListingViews.swift` | 81 | 3 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppLivePreview.swift` | 52 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppSectionFrame.swift` | 87 | 2 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppStoreCardStyle.swift` | 37 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppStoreRootView.swift` | 121 | 1 |  | 0 | views |
| `CmuxNextApps/Store/Views/AppsDisconnectedBanner.swift` | 65 | 1 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkEditBubble.swift` | 139 | 0 | NSHosting | 0 | bridge |
| `CmuxNextBookmarks/UI/BookmarkEditView.swift` | 62 | 1 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkEditorSheet.swift` | 72 | 1 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkManagerHostView.swift` | 52 | 0 | NSHosting | 0 | bridge |
| `CmuxNextBookmarks/UI/BookmarkManagerList.swift` | 115 | 1 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkManagerView.swift` | 103 | 1 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkNodeIcon.swift` | 47 | 2 |  | 0 | views |
| `CmuxNextBookmarks/UI/BookmarkPageColors.swift` | 31 | 0 |  | 0 | values: Color |
| `CmuxNextChiefMemory/ChiefMemoryChangeRow.swift` | 29 | 1 |  | 0 | views |
| `CmuxNextChiefMemory/ChiefMemoryInspectorView.swift` | 194 | 1 |  | 0 | views |
| `CmuxNextChiefMemory/ChiefMemoryLineRow.swift` | 36 | 1 |  | 0 | views |
| `CmuxNextDesign/Dialog/CmuxDialogActionButton.swift` | 56 | 1 |  | 0 | views |
| `CmuxNextDesign/GlassButtonStyle.swift` | 15 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextDesign/HairlineDivider.swift` | 25 | 1 |  | 0 | views |
| `CmuxNextDesign/Motion/Motion+AppKit.swift` | 465 | 0 |  | 0 | values: Animation |
| `CmuxNextDesign/Motion/Motion+SwiftUI.swift` | 10 | 0 |  | 1 | values: Animation |
| `CmuxNextDesign/Motion/MotionInFlight.swift` | 104 | 0 |  | 1 | values: Animation |
| `CmuxNextDesign/OverflowButton+SwiftUI.swift` | 35 | 0 |  | 0 | values: CGSize |
| `CmuxNextDesign/Overlay/CmuxOverlayModifier.swift` | 5 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextDesign/StatusIndicator/ThemedSpinner+SwiftUI.swift` | 23 | 0 |  | 0 | values: CGSize |
| `CmuxNextDesign/ThemeTokens+Unresolved.swift` | 15 | 0 |  | 0 | values: Color |
| `CmuxNextDesign/ThemedField+SwiftUI.swift` | 160 | 0 |  | 0 | values: CGSize |
| `CmuxNextDesign/ThemedPicker+SwiftUI.swift` | 69 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextDesign/ThinScrollers+SwiftUI.swift` | 33 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextDesign/Toast/CmuxToastModifier.swift` | 96 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextDesign/Tooltip/ThemedHelpModifier.swift` | 33 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextFeed/FeedAppearance.swift` | 58 | 0 |  | 0 | values: Color |
| `CmuxNextFeed/FeedHostView.swift` | 74 | 0 | NSHosting | 0 | bridge |
| `CmuxNextFeed/Views/FeedAnswerControls.swift` | 80 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedApproveControls.swift` | 73 | 2 |  | 0 | views |
| `CmuxNextFeed/Views/FeedButtonStyle.swift` | 100 | 2 |  | 0 | views |
| `CmuxNextFeed/Views/FeedChoiceControls.swift` | 140 | 2 |  | 0 | views |
| `CmuxNextFeed/Views/FeedEmptyState.swift` | 32 | 2 |  | 0 | views |
| `CmuxNextFeed/Views/FeedGitHubActions.swift` | 94 | 2 |  | 0 | views |
| `CmuxNextFeed/Views/FeedGlyph.swift` | 95 | 3 |  | 0 | views |
| `CmuxNextFeed/Views/FeedIconLabel.swift` | 24 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedInboxHeader.swift` | 83 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedInboxRow.swift` | 46 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedInboxSection.swift` | 27 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedInboxView.swift` | 164 | 3 |  | 0 | views |
| `CmuxNextFeed/Views/FeedListView.swift` | 100 | 3 |  | 0 | views |
| `CmuxNextFeed/Views/FeedNoticeRow.swift` | 48 | 1 |  | 0 | views |
| `CmuxNextFeed/Views/FeedPromptSummary.swift` | 144 | 3 |  | 0 | views |
| `CmuxNextFeed/Views/FeedView.swift` | 55 | 3 |  | 0 | views |
| `CmuxNextHistory/HistoryCookieBackupsView.swift` | 79 | 1 |  | 0 | views |
| `CmuxNextHistory/HistoryFilterLayout.swift` | 69 | 0 |  | 0 | values: CGSize |
| `CmuxNextHistory/HistoryPageHostView.swift` | 71 | 0 | NSHosting | 0 | bridge |
| `CmuxNextHistory/HistoryPageRow.swift` | 96 | 2 |  | 0 | views |
| `CmuxNextHistory/HistoryPageView.swift` | 175 | 1 |  | 0 | views |
| `CmuxNextHistory/StashPageHostView.swift` | 58 | 0 | NSHosting | 0 | bridge |
| `CmuxNextHistory/StashPageView.swift` | 164 | 1 |  | 0 | views |
| `CmuxNextHome/Conversations/HomeGroupAvatar.swift` | 26 | 1 |  | 0 | views |
| `CmuxNextHome/Conversations/HomeGroupContactRow.swift` | 34 | 1 |  | 0 | views |
| `CmuxNextHome/Conversations/HomeGroupInfoColors.swift` | 40 | 0 |  | 0 | values: Color |
| `CmuxNextHome/Conversations/HomeGroupInfoSheet.swift` | 45 | 0 | NSHosting | 0 | bridge |
| `CmuxNextHome/Conversations/HomeGroupInfoView.swift` | 183 | 1 |  | 0 | views |
| `CmuxNextHome/Conversations/HomeGroupMemberRow.swift` | 47 | 1 |  | 0 | views |
| `CmuxNextIcons/EnvironmentValues+Icon.swift` | 10 | 0 |  | 0 | values: Color |
| `CmuxNextIcons/Icon.swift` | 45 | 1 |  | 0 | views |
| `CmuxNextIcons/IconCanvas.swift` | 52 | 1 |  | 0 | views |
| `CmuxNextIcons/View+Icon.swift` | 13 | 0 |  | 0 | values: Color |
| `CmuxNextResources/TaskManager/TaskManagerView.swift` | 59 | 1 |  | 0 | views |
| `CmuxNextServer/AddMachine/AddMachineCard.swift` | 189 | 1 | NSHosting | 0 | views |
| `CmuxNextServer/AddMachine/AddMachineView.swift` | 266 | 3 |  | 1 | views |
| `CmuxNextServer/AddMachine/MachineSection.swift` | 138 | 2 |  | 0 | views |
| `CmuxNextServer/ServerHostView.swift` | 100 | 0 | NSHosting | 0 | bridge |
| `CmuxNextServer/Views/AddedServerBlock.swift` | 19 | 1 |  | 0 | views |
| `CmuxNextServer/Views/ChiefPlacementRow.swift` | 25 | 1 |  | 0 | views |
| `CmuxNextServer/Views/CodeStatusLine.swift` | 29 | 1 |  | 0 | views |
| `CmuxNextServer/Views/QRCodeImage.swift` | 51 | 1 |  | 0 | views |
| `CmuxNextServer/Views/ServerAlertControls.swift` | 48 | 2 |  | 0 | views |
| `CmuxNextServer/Views/ServerAlertRow.swift` | 24 | 1 |  | 0 | views |
| `CmuxNextServer/Views/ServerAppearance.swift` | 63 | 0 |  | 0 | values: Color |
| `CmuxNextServer/Views/ServerApproverView.swift` | 202 | 3 |  | 1 | views |
| `CmuxNextServer/Views/ServerComponents.swift` | 49 | 2 |  | 0 | views |
| `CmuxNextServer/Views/ServerDashboardPanel.swift` | 129 | 3 |  | 0 | views |
| `CmuxNextServer/Views/ServerErrorBanner.swift` | 20 | 1 |  | 0 | views |
| `CmuxNextServer/Views/ServerHeader.swift` | 64 | 2 |  | 0 | views |
| `CmuxNextServer/Views/ServerHealthVariants.swift` | 87 | 2 |  | 0 | views |
| `CmuxNextServer/Views/ServerHealthView.swift` | 84 | 3 |  | 1 | views |
| `CmuxNextServer/Views/ServerListPanel.swift` | 106 | 3 |  | 0 | views |
| `CmuxNextServer/Views/ServerPairingVariants.swift` | 69 | 3 |  | 0 | views |
| `CmuxNextServer/Views/ServerPairingView.swift` | 53 | 2 |  | 0 | views |
| `CmuxNextServer/Views/ServerPanelView.swift` | 84 | 2 |  | 1 | views |
| `CmuxNextServer/Views/ServerRoot.swift` | 39 | 1 |  | 0 | views |
| `CmuxNextServer/Views/ServerRows.swift` | 60 | 3 |  | 0 | views |
| `CmuxNextServer/Views/ServerTextField.swift` | 53 | 0 |  | 0 | modifiers/extensions |
| `CmuxNextServer/Views/WordsGrid.swift` | 27 | 1 |  | 0 | views |
| `CmuxNextSettingsWindow/DebugSettings/DebugSettingsRootView.swift` | 99 | 2 |  | 0 | views |
| `CmuxNextSettingsWindow/DebugSettings/DebugSettingsSidebar.swift` | 86 | 2 |  | 0 | views |
| `CmuxNextSettingsWindow/DebugSettings/DebugSettingsWindowController.swift` | 91 | 0 | NSHosting | 0 | bridge |
| `CmuxNextSettingsWindow/DebugSettings/DebugTunableControls.swift` | 105 | 2 |  | 0 | views |
| `CmuxNextSettingsWindow/DebugSettings/DebugTunableRowView.swift` | 91 | 2 |  | 0 | views |
| `CmuxNextSettingsWindow/SettingsPane.swift` | 30 | 0 | NSHosting | 0 | bridge |
| `CmuxNextSettingsWindow/Views/ScrollEdgeFadeModifier.swift` | 57 | 0 |  | 2 | values: LinearGradient |
| `CmuxNextSettingsWindow/Views/SettingsStyle.swift` | 69 | 1 |  | 0 | views |
| `CmuxNextTasks/TasksAppearance.swift` | 42 | 0 |  | 0 | values: Color |
| `CmuxNextTasks/TasksHostView.swift` | 97 | 1 | NSHosting | 0 | views |
| `CmuxNextTasks/Views/AssigneeMenu.swift` | 52 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/AttentionDot.swift` | 31 | 1 |  | 0 | views |
| `CmuxNextTasks/Views/NewTaskField.swift` | 37 | 1 |  | 0 | views |
| `CmuxNextTasks/Views/OwnerNotRunningView.swift` | 55 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/PlanProgress.swift` | 22 | 1 |  | 0 | views |
| `CmuxNextTasks/Views/StatusGlyph.swift` | 63 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/TaskBadges.swift` | 67 | 3 |  | 0 | views |
| `CmuxNextTasks/Views/TaskDetailView.swift` | 94 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/TaskRow.swift` | 56 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/TasksBoardView.swift` | 100 | 3 |  | 0 | views |
| `CmuxNextTasks/Views/TasksInboxView.swift` | 81 | 1 |  | 0 | views |
| `CmuxNextTasks/Views/TasksListView.swift` | 51 | 2 |  | 0 | views |
| `CmuxNextTasks/Views/TasksView.swift` | 49 | 2 |  | 0 | views |
| `CmuxNextUpdater/UpdateSheetController.swift` | 120 | 0 | NSHosting | 0 | bridge |
| `CmuxNextUpdater/UpdateSheetView.swift` | 113 | 1 |  | 0 | views |
