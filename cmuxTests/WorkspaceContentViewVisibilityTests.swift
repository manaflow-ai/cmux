import Testing
import AppKit
import CmuxNotifications
import CmuxUpdater
import CoreGraphics
import Observation
import SwiftUI
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
final class WorkspaceContentViewVisibilityTests {
    private final class MinimalModeBodyProbeCounts {
        var contentViewBody = 0
        var workspaceContentBody = 0
        var verticalTabsSidebarBody = 0

        func reset() {
            contentViewBody = 0
            workspaceContentBody = 0
            verticalTabsSidebarBody = 0
        }
    }

    private static func restoreFocusTarget(
        workspaceId: UUID = UUID(),
        panelId: UUID = UUID(),
        intent: PanelFocusIntent = .panel
    ) -> CommandPaletteRestoreFocusTarget {
        CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func sidebarResizerCursorReleaseSchedulerCancelsReplacedDelayedRelease() async {
        let clock = SidebarTestManualClock()
        let scheduler = SidebarResizerCursorReleaseScheduler(clock: clock)
        let releaseEvents = AsyncStream<Bool>.makeStream()
        defer { releaseEvents.continuation.finish() }
        var releaseIterator = releaseEvents.stream.makeAsyncIterator()
        var releases: [Bool] = []

        scheduler.schedule(force: false, delay: .zero) { force in
            releases.append(force)
            releaseEvents.continuation.yield(force)
        }
        #expect(releases.isEmpty)
        let immediateRelease = await releaseIterator.next()
        #expect(immediateRelease == false)
        #expect(releases == [false])
        releases.removeAll()

        scheduler.schedule(force: false, delay: .milliseconds(50)) { force in
            releases.append(force)
            releaseEvents.continuation.yield(force)
        }
        await clock.waitUntilSleeping(for: .milliseconds(50))
        clock.advance(by: .milliseconds(49))
        for _ in 0..<3 {
            await Task.yield()
        }
        #expect(releases.isEmpty)

        clock.advance(by: .milliseconds(1))
        let hoverExitRelease = await releaseIterator.next()
        #expect(hoverExitRelease == false)
        #expect(releases == [false])
        releases.removeAll()

        scheduler.schedule(force: false, delay: .milliseconds(200)) { force in
            releases.append(force)
            releaseEvents.continuation.yield(force)
        }
        await clock.waitUntilSleeping(for: .milliseconds(200))
        scheduler.schedule(force: true, delay: .milliseconds(10)) { force in
            releases.append(force)
            releaseEvents.continuation.yield(force)
        }
        await clock.waitUntilSleeping(for: .milliseconds(10))

        clock.advance(by: .milliseconds(10))
        let replacementRelease = await releaseIterator.next()
        #expect(replacementRelease == true)
        #expect(releases == [true])

        await clock.waitUntilIdle()
        clock.advance(by: .milliseconds(190))
        scheduler.schedule(force: true, delay: .zero) { force in
            releases.append(force)
            releaseEvents.continuation.yield(force)
        }
        let sentinelRelease = await releaseIterator.next()
        #expect(sentinelRelease == true)
        #expect(releases == [true, true])
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorClearsOnlyStaleTargets() {
        let coordinator = CommandPaletteFocusRestoreCoordinator()
        let firstTarget = Self.restoreFocusTarget()
        let secondTarget = Self.restoreFocusTarget()

        coordinator.request(target: firstTarget)
        #expect(coordinator.pendingTarget?.host == firstTarget.host)

        #expect(
            !coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: nil,
                focusedPanelId: nil,
                targetPanelExists: true
            )
        )
        #expect(
            !coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: firstTarget.host,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget?.host == firstTarget.host)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: secondTarget.host,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: firstTarget.host,
                focusedPanelId: secondTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: firstTarget.host,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: false
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: secondTarget)
        #expect(coordinator.pendingTarget?.host == secondTarget.host)

        #expect(coordinator.claimRestoreAttempt())
        #expect(!coordinator.claimRestoreAttempt())
        coordinator.finishRestoreAttempt()

        for _ in 0..<4 {
            #expect(coordinator.claimRestoreAttempt())
            #expect(coordinator.pendingTarget?.host == secondTarget.host)
            coordinator.finishRestoreAttempt()
        }
        #expect(!coordinator.claimRestoreAttempt())
        #expect(coordinator.pendingTarget?.host == nil)

        coordinator.request(target: secondTarget)
        #expect(coordinator.claimRestoreAttempt())

        coordinator.clear()
        #expect(coordinator.pendingTarget?.host == nil)

        let dockTarget = CommandPaletteRestoreFocusTarget(
            host: .windowDock(UUID()),
            panelId: UUID(),
            intent: .browser(.webView)
        )
        coordinator.request(target: dockTarget)
        #expect(
            !coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: dockTarget.host,
                focusedPanelId: dockTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget?.host == dockTarget.host)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                currentHost: firstTarget.host,
                focusedPanelId: dockTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget == nil)
    }

    @Test
    @MainActor
    func testMinimalModeToggleDoesNotReevaluateChromeHeavyBodies() async throws {
        _ = NSApplication.shared

        let suiteName = "WorkspaceContentViewVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            WorkspacePresentationModeSettings.Mode.standard.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )

        let tabManager = TabManager()
        for _ in 0..<6 {
            tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let notificationStore = TerminalNotificationStore.shared
        let counts = MinimalModeBodyProbeCounts()
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .environment(
                \.minimalModeInvalidationProbe,
                MinimalModeInvalidationProbe(
                    contentViewBody: { counts.contentViewBody += 1 },
                    workspaceContentBody: { counts.workspaceContentBody += 1 },
                    verticalTabsSidebarBody: { counts.verticalTabsSidebarBody += 1 }
                )
            )
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        #expect(counts.contentViewBody > 0)
        #expect(counts.workspaceContentBody > 0)
        #expect(counts.verticalTabsSidebarBody > 0)

        counts.reset()
        defaults.set(
            WorkspacePresentationModeSettings.Mode.minimal.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        await Self.drainMainRunLoop(for: window)

        #expect(
            counts.contentViewBody == 0,
            "Minimal-mode toggles must not re-evaluate the whole ContentView body."
        )
        #expect(
            counts.workspaceContentBody == 0,
            "Minimal-mode toggles must not re-evaluate WorkspaceContentView/Bonsplit content."
        )
        #expect(
            counts.verticalTabsSidebarBody == 0,
            "Minimal-mode toggles must not rebuild the vertical sidebar render context."
        )
    }

    @Test
    @MainActor
    func testUnreadChangeUpdatesOnlyAffectedSidebarRow() async throws {
        _ = NSApplication.shared

        let suiteName = "WorkspaceContentViewUnreadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )

        let tabManager = TabManager()
        let workspaceId = try #require(tabManager.selectedTabId)
        let unaffectedWorkspace = tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let unread = SidebarUnreadModel()
        let counts = MinimalModeBodyProbeCounts()
        let root = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: UUID(),
            sidebarUnread: unread
        )
            .environmentObject(tabManager)
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .environment(
                \.minimalModeInvalidationProbe,
                MinimalModeInvalidationProbe(
                    contentViewBody: { counts.contentViewBody += 1 },
                    workspaceContentBody: { counts.workspaceContentBody += 1 },
                    verticalTabsSidebarBody: { counts.verticalTabsSidebarBody += 1 }
                )
            )
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)
        let workspaceCell = try #require(
            window.contentView.flatMap { root in
                Self.descendants(of: root)
                    .compactMap { $0 as? SidebarWorkspaceRowTableCellView }
                    .first { $0.currentModelForMeasurement?.workspaceId == workspaceId }
            }
        )
        let unaffectedWorkspaceCell = try #require(
            window.contentView.flatMap { root in
                Self.descendants(of: root)
                    .compactMap { $0 as? SidebarWorkspaceRowTableCellView }
                    .first {
                        $0.currentModelForMeasurement?.workspaceId == unaffectedWorkspace.id
                    }
            }
        )
        var appliedUnreadCount: Int?
        var unaffectedApplyCount = 0
        workspaceCell.applyModelProbeForTesting = { model in
            appliedUnreadCount = model.unreadCount
        }
        unaffectedWorkspaceCell.applyModelProbeForTesting = { _ in
            unaffectedApplyCount += 1
        }
        counts.reset()

        unread.apply(
            totalUnreadCount: 1,
            summaries: [
                workspaceId: SidebarWorkspaceUnreadSummary(
                    unreadCount: 1,
                    latestNotificationText: "Pi finished"
                ),
            ],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceId, surfaceId: nil),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        await Self.drainMainRunLoop(for: window)

        #expect(
            counts.contentViewBody == 0,
            "Unread changes must update their leaf consumers without rebuilding ContentView."
        )
        #expect(
            counts.workspaceContentBody == 0,
            "Unread changes must not rebuild terminal or browser content."
        )
        #expect(
            counts.verticalTabsSidebarBody == 0,
            "Unread changes must not rebuild every row through VerticalTabsSidebar."
        )
        #expect(
            appliedUnreadCount == 1,
            "The affected visible AppKit row must still receive the unread badge."
        )
        #expect(
            unaffectedApplyCount == 0,
            "An unread change must not reconfigure an unaffected AppKit row."
        )
        #expect(
            unaffectedWorkspaceCell.currentModelForMeasurement?.unreadCount == 0,
            "An unread change must not copy its badge into a neighboring workspace row."
        )
    }

    @Test
    @MainActor
    func testUnreadApplyPublishesOneAtomicSnapshot() {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let unread = SidebarUnreadModel()
        var publicationCount = 0
        withObservationTracking {
            _ = unread.snapshot
        } onChange: {
            publicationCount += 1
        }
        let summaries = [
            workspaceId: SidebarWorkspaceUnreadSummary(
                unreadCount: 1,
                latestNotificationText: "Pi finished"
            ),
        ]
        let surfaceKeys: Set<SidebarSurfaceUnreadKey> = [
            SidebarSurfaceUnreadKey(workspaceId: workspaceId, surfaceId: surfaceId),
        ]
        let focusedIndicators = [workspaceId: surfaceId]
        let manualUnreadWorkspaceIds: Set<UUID> = [workspaceId]

        unread.apply(
            totalUnreadCount: 1,
            summaries: summaries,
            unreadSurfaceKeys: surfaceKeys,
            focusedReadIndicatorByWorkspaceId: focusedIndicators,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        #expect(publicationCount == 1)

        withObservationTracking {
            _ = unread.snapshot
        } onChange: {
            publicationCount += 1
        }
        unread.apply(
            totalUnreadCount: 1,
            summaries: summaries,
            unreadSurfaceKeys: surfaceKeys,
            focusedReadIndicatorByWorkspaceId: focusedIndicators,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        #expect(publicationCount == 1, "Applying an equivalent snapshot must stay silent.")
    }

    @Test
    func minimalModeSidebarFooterKeepsOnlyUpgradeControl() {
        let minimalControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible($0, presentationMode: .minimal)
        }
        let standardControls = SidebarFooterControl.allCases.filter {
            SidebarFooterPresentationPolicy.isVisible($0, presentationMode: .standard)
        }

        #expect(minimalControls == [.upgrade])
        #expect(standardControls == SidebarFooterControl.allCases)
    }

    @Test
    func sidebarAccountPictureAndIconPresentationsStayDistinct() {
        let picture = SidebarAccountButtonPresentation.resolve(
            isSignedIn: true,
            prefersProfileIcon: false,
            hasProfilePicture: true
        )
        let toggledIcon = SidebarAccountButtonPresentation.resolve(
            isSignedIn: true,
            prefersProfileIcon: true
        )
        let signedOutIcon = SidebarAccountButtonPresentation.resolve(
            isSignedIn: false,
            prefersProfileIcon: false
        )
        let missingPictureIcon = SidebarAccountButtonPresentation.resolve(
            isSignedIn: true,
            prefersProfileIcon: false,
            hasProfilePicture: false
        )

        #expect(picture.visual == .profilePicture)
        #expect(picture.size == SidebarFooterButtonMetrics.accountAndHelpVisualSize)
        #expect(
            SidebarAccountButtonPresentation.defaultProfileIconSystemName
                == "person.crop.circle"
        )
        #expect(
            toggledIcon.visual == .profileIcon(
                systemName: SidebarAccountButtonPresentation.defaultProfileIconSystemName
            )
        )
        #expect(toggledIcon.size == SidebarFooterButtonMetrics.accountAndHelpVisualSize)
        #expect(signedOutIcon == toggledIcon)
        #expect(missingPictureIcon == toggledIcon)
        #expect(
            SidebarFooterButtonMetrics.profilePictureSize
                == SidebarFooterButtonMetrics.helpIconSize
        )
        #expect(
            SidebarFooterButtonMetrics.profileIconSize
                == SidebarFooterButtonMetrics.helpIconSize
        )
        #expect(
            SidebarFooterCircularIconStyle.standard.pointSize
                == SidebarFooterButtonMetrics.accountAndHelpVisualSize
        )
        #expect(SidebarFooterCircularIconStyle.standard.weight == .regular)
#if DEBUG
        #expect(SidebarFooterProfileIconDebugSettings.defaultIcon == .cropCircle)
        #expect(
            SidebarFooterHelpIconDebugSettings.defaultWeight.fontWeight
                == SidebarFooterCircularIconStyle.standard.weight
        )
#endif
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test
    func testNonSelectedNonRetiringWorkspaceIsFullyHidden() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0
            )
        )
    }

    @Test
    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                paneHasSelectedTab: true,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: false,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseForStaleFocusedPanelWhenAnotherTabIsSelected() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: false,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    @Test
    func testRenderedVisiblePanelPolicyPrefersSelectedTabOverStaleFocusedPanel() {
        let paneId = UUID()
        let selectedPanelId = UUID()
        let staleFocusedPanelId = UUID()

        #expect(
            WorkspacePanelVisibilityPolicy.visiblePanelIdForRenderedPane(
                paneId: paneId,
                selectedPanelId: selectedPanelId,
                firstPanelId: selectedPanelId,
                focusedPanelId: staleFocusedPanelId,
                focusedPanelPaneId: paneId
            ) == selectedPanelId
        )
    }

    @Test
    func testRenderedVisiblePanelPolicyFallsBackToFocusedPanelOnlyDuringSelectionGap() {
        let paneId = UUID()
        let focusedPanelId = UUID()

        #expect(
            WorkspacePanelVisibilityPolicy.visiblePanelIdForRenderedPane(
                paneId: paneId,
                selectedPanelId: nil,
                firstPanelId: UUID(),
                focusedPanelId: focusedPanelId,
                focusedPanelPaneId: paneId
            ) == focusedPanelId
        )
    }

    @Test
    func testTmuxWorkspacePaneOverlayRectReturnsMatchingPaneFrame() {
        let paneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneID.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: paneID.id.uuidString,
            timestamp: 0
        )

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneOverlayRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ) ==
            CGRect(x: 677.5, y: 28, width: 500, height: 292)
        )
    }

    @Test
    @MainActor
    func testTmuxWorkspacePaneUnreadRectsIncludeFocusedReadIndicator() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected selected workspace geometry")
        let panelId = try #require(workspace.focusedPanelId, "Expected selected workspace geometry")
        let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId), "Expected selected workspace geometry")
        let paneId = try #require(workspace.paneId(forPanelId: panelId), "Expected selected workspace geometry")

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneId.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: surfaceId.uuid.uuidString,
                    tabIds: [surfaceId.uuid.uuidString]
                )
            ],
            focusedPaneId: paneId.id.uuidString,
            timestamp: 0
        )

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneUnreadRects(
                workspace: workspace,
                notificationStore: store,
                layoutSnapshot: snapshot
            ) ==
            [CGRect(x: 677.5, y: 28, width: 500, height: 292)]
        )
    }
}
