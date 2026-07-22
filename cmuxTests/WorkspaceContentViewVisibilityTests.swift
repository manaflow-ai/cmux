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

    private final class AppKitSidebarMountProbeCounts {
        var tableContainerMakes = 0
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
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

    @Test
    func contentViewDoesNotKeepLegacyWorkItemStateForCoalescedReleases() throws {
        let source = try Self.sourceText("Sources/ContentView.swift")
        let legacyState = [
            "sidebarResizerCursorReleaseWorkItem",
            "commandPaletteRestoreTimeoutWorkItem",
        ].filter(source.contains)
        #expect(
            legacyState.isEmpty,
            """
            ContentView must not keep the legacy DispatchWorkItem state properties that \
            previously let queued closures retain prior work-item state:
            \(legacyState.joined(separator: "\n"))
            """
        )
        #expect(
            source.contains("scheduleSidebarResizerCursorRelease(delay: .milliseconds(50))"),
            """
            Sidebar resizer hover exit must keep a short deferred cursor-release window so \
            mouse-down and drag-start callbacks can establish resize state before the cursor \
            can be reset.
            """
        )
    }

    @Test
    @MainActor
    func sidebarResizerCursorReleaseSchedulerCancelsReplacedDelayedRelease() async throws {
        let scheduler = SidebarResizerCursorReleaseScheduler()
        var releases: [Bool] = []

        scheduler.schedule(force: false, delay: .zero) { force in
            releases.append(force)
        }
        #expect(releases.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
        #expect(releases == [false])
        releases.removeAll()

        scheduler.schedule(force: false, delay: .milliseconds(200)) { force in
            releases.append(force)
        }
        scheduler.schedule(force: true, delay: .milliseconds(10)) { force in
            releases.append(force)
        }

        try await Task.sleep(for: .milliseconds(80))
        #expect(releases == [true])

        scheduler.cancelPendingRelease()
        try await Task.sleep(for: .milliseconds(160))
        #expect(releases == [true])
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorClearsOnlyStaleTargets() {
        let coordinator = CommandPaletteFocusRestoreCoordinator()
        let firstTarget = Self.restoreFocusTarget()
        let secondTarget = Self.restoreFocusTarget()

        coordinator.request(target: firstTarget)
        #expect(coordinator.pendingTarget?.workspaceId == firstTarget.workspaceId)

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

    @Test
    @MainActor
    func testSidebarVisibilityToggleKeepsAppKitTableContainerMounted() async throws {
        _ = NSApplication.shared

        let previousUsesCoalescedAnchorFailsafe = WindowTerminalPortal.usesCoalescedAnchorFailsafe
        defer {
            WindowTerminalPortal.usesCoalescedAnchorFailsafe = previousUsesCoalescedAnchorFailsafe
        }

        let suiteName = "WorkspaceContentViewVisibilityTests.AppKitSidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )

        let featureFlags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil }
        )
        featureFlags.setOverride(true, for: CmuxFeatureFlags.appKitSidebarListFlag)

        let tabManager = TabManager()
        for _ in 0..<3 {
            tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let sidebarState = SidebarState()
        let notificationStore = TerminalNotificationStore.shared
        let root = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: UUID(),
            featureFlags: featureFlags
        )
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(sidebarState)
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
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
        let initialContainers = Self.descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(initialContainers.count == 1)
        let initialContainer = try #require(initialContainers.first)
        let focusedWorkspace = try #require(tabManager.selectedWorkspace)
        let focusedPanelId = try #require(focusedWorkspace.focusedPanelId)
        let focusedPanel = try #require(focusedWorkspace.panels[focusedPanelId])
        #expect(window.makeFirstResponder(initialContainer.tableView))
        #expect(window.firstResponder === initialContainer.tableView)

        sidebarState.toggle()
        await Self.drainMainRunLoop(for: window)
        let hiddenContainers = Self.descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(hiddenContainers.count == 1)
        #expect(
            hiddenContainers.first === initialContainer,
            "Hiding the sidebar must preserve the existing AppKit table container."
        )
        let responderAfterHide = try #require(window.firstResponder)
        #expect(
            focusedPanel.ownedFocusIntent(for: responderAfterHide, in: window) != nil,
            "Hiding the sidebar must return keyboard focus to the selected main panel."
        )

        sidebarState.toggle()
        await Self.drainMainRunLoop(for: window)
        let reopenedContainers = Self.descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(reopenedContainers.count == 1)
        #expect(
            reopenedContainers.first === initialContainer,
            "Reopening the sidebar must reuse the existing AppKit table container."
        )
    }

    @Test
    @MainActor
    func appKitSidebarPersistenceIsScopedToDefaultProvider() throws {
        #expect(
            ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.hostedExtensionsProviderId
            )
        )
        let bundledProviderId = try #require(CmuxExtensionSidebarSelection.providers.first?.descriptor.id)
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: bundledProviderId
            )
        )
        let customSidebarsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: customSidebarsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customSidebarsDirectory) }
        let customProviderId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + "lifecycle-test"
        try Data().write(to: customSidebarsDirectory.appendingPathComponent("lifecycle-test.swift"))
        CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(customSidebarsDirectory) {
            #expect(
                !ContentView.retainsDefaultAppKitSidebar(
                    appKitListEnabled: true,
                    effectiveProviderId: customProviderId
                )
            )
        }
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: false,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
    }

    @MainActor
    private static func descendants<View: NSView>(
        of type: View.Type,
        in root: NSView?
    ) -> [View] {
        guard let root else { return [] }
        var matches: [View] = []
        if let match = root as? View {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
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
