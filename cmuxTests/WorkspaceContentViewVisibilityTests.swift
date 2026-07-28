import Testing
import AppKit
import CmuxUpdater
import CoreGraphics
import SwiftUI
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
final class WorkspaceContentViewVisibilityTests {
    private final class ClosureLifetimeSentinel {
        let identifier: Int
        let deinitialized: AsyncStream<Int>.Continuation
        init(identifier: Int, deinitialized: AsyncStream<Int>.Continuation) {
            self.identifier = identifier
            self.deinitialized = deinitialized
        }
        deinit { deinitialized.yield(identifier) }
    }

    private final class WeakReference<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value) {
            self.value = value
        }
    }

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
    func sidebarResizerCursorReleaseSchedulerReleasesSupersededClosuresBeforeFinalDeadline() async {
        let clock = SidebarTestManualClock()
        let scheduler = SidebarResizerCursorReleaseScheduler(clock: clock)
        let releaseEvents = AsyncStream<Int>.makeStream()
        defer { releaseEvents.continuation.finish() }
        var releaseIterator = releaseEvents.stream.makeAsyncIterator()
        let deinitEvents = AsyncStream<Int>.makeStream()
        defer { deinitEvents.continuation.finish() }
        var deinitIterator = deinitEvents.stream.makeAsyncIterator()
        var releases: [Int] = []

        func schedule(_ index: Int, delay: Duration, force: Bool = false)
            -> WeakReference<ClosureLifetimeSentinel> {
            let sentinel = ClosureLifetimeSentinel(
                identifier: index,
                deinitialized: deinitEvents.continuation
            )
            let reference = WeakReference(sentinel)
            scheduler.schedule(force: force, delay: delay) { [sentinel] releasedForce in
                _ = sentinel
                #expect(releasedForce == force)
                releases.append(index)
                releaseEvents.continuation.yield(index)
            }
            return reference
        }

        let immediate = schedule(-1, delay: .zero)
        #expect(releases.isEmpty)
        let immediateRelease = await releaseIterator.next()
        #expect(immediateRelease == -1)
        let immediateDeinit = await deinitIterator.next()
        #expect(immediateDeinit == -1)
        #expect(immediate.value == nil)
        releases.removeAll()

        let sleeping = schedule(-2, delay: .milliseconds(25))
        await clock.waitUntilSleeping(for: .milliseconds(25))
        let superseded = (0..<999).map { schedule($0, delay: .seconds(1)) }
        let final = schedule(999, delay: .milliseconds(50), force: true)
        await clock.waitUntilSleeping(for: .milliseconds(50))
        var canceledIdentifiers: Set<Int> = []
        for _ in 0..<1_000 {
            if let identifier = await deinitIterator.next() {
                canceledIdentifiers.insert(identifier)
            }
        }
        #expect(releases.isEmpty)
        #expect(canceledIdentifiers == Set(0..<999).union([-2]))
        #expect(sleeping.value == nil)
        #expect(superseded.allSatisfy { $0.value == nil })
        #expect(final.value != nil)

        clock.advance(by: .milliseconds(49))
        #expect(releases.isEmpty)
        #expect(final.value != nil)

        clock.advance(by: .milliseconds(1))
        let release = await releaseIterator.next()
        #expect(release == 999)
        #expect(releases == [999])

        await clock.waitUntilIdle()
        let finalDeinit = await deinitIterator.next()
        #expect(finalDeinit == 999)
        #expect(final.value == nil)
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorReplacesBurstAndClearsOnlyStaleTargets() {
        let coordinator = CommandPaletteFocusRestoreCoordinator()
        let firstTarget = Self.restoreFocusTarget(intent: .terminal(.findField))
        let secondTarget = Self.restoreFocusTarget()

        for _ in 0..<1_000 {
            coordinator.request(target: Self.restoreFocusTarget())
        }
        coordinator.request(target: firstTarget)
        #expect(coordinator.pendingTarget?.workspaceId == firstTarget.workspaceId)
        #expect(coordinator.pendingTarget?.panelId == firstTarget.panelId)
        #expect(coordinator.pendingTarget?.intent == firstTarget.intent)

        #expect(
            !coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                selectedWorkspaceId: nil,
                focusedPanelId: nil,
                targetPanelExists: true
            )
        )
        #expect(
            !coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                selectedWorkspaceId: firstTarget.workspaceId,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget?.workspaceId == firstTarget.workspaceId)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                selectedWorkspaceId: secondTarget.workspaceId,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                selectedWorkspaceId: firstTarget.workspaceId,
                focusedPanelId: secondTarget.panelId,
                targetPanelExists: true
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: firstTarget)
        #expect(
            coordinator.clearIfTargetNoLongerMatchesCurrentFocus(
                selectedWorkspaceId: firstTarget.workspaceId,
                focusedPanelId: firstTarget.panelId,
                targetPanelExists: false
            )
        )
        #expect(coordinator.pendingTarget == nil)

        coordinator.request(target: secondTarget)
        #expect(coordinator.pendingTarget?.workspaceId == secondTarget.workspaceId)

        #expect(coordinator.claimRestoreAttempt())
        #expect(!coordinator.claimRestoreAttempt())
        coordinator.finishRestoreAttempt()

        for _ in 0..<4 {
            #expect(coordinator.claimRestoreAttempt())
            #expect(coordinator.pendingTarget?.workspaceId == secondTarget.workspaceId)
            coordinator.finishRestoreAttempt()
        }
        #expect(!coordinator.claimRestoreAttempt())
        #expect(coordinator.pendingTarget?.workspaceId == nil)

        coordinator.request(target: secondTarget)
        #expect(coordinator.claimRestoreAttempt())

        coordinator.clear()
        #expect(coordinator.pendingTarget?.workspaceId == nil)
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
            .environmentObject(notificationStore.sidebarUnread)
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

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
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
