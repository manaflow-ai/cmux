import XCTest
import Bonsplit
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateMoveTabToNewWorkspaceTests: XCTestCase {
    private final class MoveFixturePanel: NSObject, Panel, ObservableObject {
        let id = UUID()
        let panelType: PanelType = .project
        let title: String

        init(title: String) {
            self.title = title
            super.init()
        }

        var displayTitle: String { title }
        var displayIcon: String? { "hammer" }
        var isDirty: Bool { false }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    func testMoveSurfaceToNewWorkspaceCreatesSinglePanelWorkspaceFromPanelTitle() throws {
        try withRegisteredMoveContext { app, windowId, manager in
            let (sourceWorkspace, remainingPanel) = try addMoveWorkspace(
                to: manager,
                title: "Source",
                select: true
            )
            let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
            let movedPanel = try addMovePanel(
                to: sourceWorkspace,
                paneId: sourcePaneId,
                title: "Build"
            )
            sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Build logs")

            let originalWorkspaceCount = manager.tabs.count
            let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
                panelId: movedPanel.id,
                focus: false,
                focusWindow: false
            ))

            let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
            XCTAssertEqual(result.sourceWindowId, windowId)
            XCTAssertEqual(result.sourceWorkspaceId, sourceWorkspace.id)
            XCTAssertEqual(result.destinationWindowId, windowId)
            XCTAssertEqual(manager.tabs.count, originalWorkspaceCount + 1)
            XCTAssertEqual(destinationWorkspace.title, "Build logs")
            XCTAssertEqual(destinationWorkspace.panels.count, 1)
            XCTAssertNotNil(destinationWorkspace.panels[movedPanel.id])
            XCTAssertNil(sourceWorkspace.panels[movedPanel.id])
            XCTAssertNotNil(sourceWorkspace.panels[remainingPanel.id])
            XCTAssertEqual(result.paneId, destinationWorkspace.paneId(forPanelId: movedPanel.id)?.id)
        }
    }

    func testMoveSurfaceToNewWorkspacePreservesDetachedPanelInstanceWhenDefaultsChange() throws {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        try withRegisteredMoveContext { app, _, manager in
            let (sourceWorkspace, _) = try addMoveWorkspace(
                to: manager,
                title: "Source",
                select: true
            )
            let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
            let movedPanel = try addMovePanel(
                to: sourceWorkspace,
                paneId: sourcePaneId,
                title: "Moved"
            )

            defaults.set(true, forKey: showKey)
            defaults.set(true, forKey: focusKey)

            let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
                panelId: movedPanel.id,
                focus: false,
                focusWindow: false
            ))

            let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
            let destinationPanel = try XCTUnwrap(destinationWorkspace.panels[movedPanel.id] as? MoveFixturePanel)
            XCTAssertTrue(destinationPanel === movedPanel)
        }
    }

    func testBrowserNewWorkspaceMoveRequestsAddressBarFocusIntent() throws {
        let focusIntent = AppDelegate.focusIntentForNewWorkspaceMove(
            panelType: .browser,
            preferredFocusIntent: .browser(.webView)
        )

        XCTAssertEqual(focusIntent, .browser(.addressBar))
    }

    func testMoveSurfaceToNewWorkspaceRejectsOnlyPanel() throws {
        try withRegisteredMoveContext { app, _, manager in
            let (sourceWorkspace, onlyPanel) = try addMoveWorkspace(
                to: manager,
                title: "Only",
                select: true
            )

            XCTAssertFalse(app.canMoveSurfaceToNewWorkspace(panelId: onlyPanel.id))
            XCTAssertNil(app.moveSurfaceToNewWorkspace(panelId: onlyPanel.id, focus: false, focusWindow: false))
            XCTAssertEqual(manager.tabs.count, 1)
            XCTAssertNotNil(sourceWorkspace.panels[onlyPanel.id])
        }
    }

    func testMoveBonsplitTabRouteClosesEmptiedSourceWorkspaceAfterDetachedMove() throws {
        try withRegisteredMoveContext { app, windowId, manager in
            let (sourceWorkspace, movedPanel) = try addMoveWorkspace(
                to: manager,
                title: "Source",
                select: true
            )
            let movedPanelId = movedPanel.id
            let movedBonsplitTabId = try XCTUnwrap(sourceWorkspace.surfaceIdFromPanelId(movedPanelId)?.uuid)
            let (destinationWorkspace, destinationOriginalPanel) = try addMoveWorkspace(
                to: manager,
                title: "Operations",
                select: false
            )

            XCTAssertTrue(app.canMoveBonsplitTab(tabId: movedBonsplitTabId, toWorkspace: destinationWorkspace.id))
            let located = try XCTUnwrap(app.locateBonsplitSurface(tabId: movedBonsplitTabId))
            XCTAssertEqual(located.windowId, windowId)
            XCTAssertEqual(located.workspaceId, sourceWorkspace.id)
            XCTAssertEqual(located.panelId, movedPanelId)
            XCTAssertTrue(located.tabManager === manager)

            let attachedPanelId = try finishDetachedMove(
                app: app,
                manager: manager,
                sourceWindowId: windowId,
                sourceWorkspace: sourceWorkspace,
                destinationWorkspace: destinationWorkspace,
                panel: movedPanel,
                focus: false
            )

            XCTAssertFalse(manager.tabs.contains { $0.id == sourceWorkspace.id })
            XCTAssertEqual(manager.tabs.map(\.id), [destinationWorkspace.id])
            XCTAssertTrue(sourceWorkspace.panels.isEmpty)
            XCTAssertEqual(attachedPanelId, movedPanelId)
            XCTAssertNotNil(destinationWorkspace.panels[movedPanelId])
            XCTAssertNotNil(destinationWorkspace.panels[destinationOriginalPanel.id])
            XCTAssertEqual(destinationWorkspace.panels.count, 2)
        }
    }

    func testExistingWorkspaceDetachedMoveClosesEmptiedSourceWorkspaceAndFocusesDestination() throws {
        try withRegisteredMoveContext { app, windowId, manager in
            let (sourceWorkspace, movedPanel) = try addMoveWorkspace(
                to: manager,
                title: "Source",
                select: true
            )
            let movedPanelId = movedPanel.id
            let (destinationWorkspace, destinationOriginalPanel) = try addMoveWorkspace(
                to: manager,
                title: "Operations",
                select: false
            )

            let located = try XCTUnwrap(app.locateSurface(surfaceId: movedPanelId))
            XCTAssertEqual(located.windowId, windowId)
            XCTAssertEqual(located.workspaceId, sourceWorkspace.id)
            XCTAssertTrue(located.tabManager === manager)

            let attachedPanelId = try finishDetachedMove(
                app: app,
                manager: manager,
                sourceWindowId: windowId,
                sourceWorkspace: sourceWorkspace,
                destinationWorkspace: destinationWorkspace,
                panel: movedPanel,
                focus: true
            )

            XCTAssertFalse(manager.tabs.contains { $0.id == sourceWorkspace.id })
            XCTAssertEqual(manager.tabs.map(\.id), [destinationWorkspace.id])
            XCTAssertTrue(sourceWorkspace.panels.isEmpty)
            XCTAssertEqual(attachedPanelId, movedPanelId)
            XCTAssertNotNil(destinationWorkspace.panels[movedPanelId])
            XCTAssertNotNil(destinationWorkspace.panels[destinationOriginalPanel.id])
            XCTAssertEqual(destinationWorkspace.panels.count, 2)
            XCTAssertEqual(manager.selectedWorkspace?.id, destinationWorkspace.id)
            XCTAssertEqual(destinationWorkspace.focusedPanelId, movedPanelId)
        }
    }

    private func withRegisteredMoveContext(_ body: (AppDelegate, UUID, TabManager) throws -> Void) rethrows {
        let previousShared = AppDelegate.shared
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager(debugCreateInitialWorkspace: false)
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer {
            teardownTabManagerForTesting(manager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            drainMainActorTasksForTesting()
            AppDelegate.shared = previousShared
        }
        try body(app, windowId, manager)
    }

    private func addMoveWorkspace(
        to manager: TabManager,
        title: String,
        select: Bool
    ) throws -> (Workspace, MoveFixturePanel) {
        let transfer = try makeMoveTransfer(title: title)
        let workspace = Workspace(title: title, initialDetachedSurface: transfer)
        workspace.owningTabManager = manager
        workspace.setPortalRenderingEnabled(false, reason: "AppDelegateMoveTabToNewWorkspaceTests.fixture")
        var tabs = manager.tabs
        tabs.append(workspace)
        manager.tabs = tabs
        if select {
            manager.selectedTabId = workspace.id
        }
        let panel = try XCTUnwrap(workspace.panels[transfer.panelId] as? MoveFixturePanel)
        return (workspace, panel)
    }

    private func addMovePanel(
        to workspace: Workspace,
        paneId: PaneID,
        title: String
    ) throws -> MoveFixturePanel {
        let transfer = try makeMoveTransfer(sourceWorkspaceId: workspace.id, title: title)
        let panelId = try XCTUnwrap(workspace.attachDetachedSurface(
            transfer,
            inPane: paneId,
            focus: false
        ))
        return try XCTUnwrap(workspace.panels[panelId] as? MoveFixturePanel)
    }

    private func makeMoveTransfer(
        sourceWorkspaceId: UUID = UUID(),
        panel providedPanel: MoveFixturePanel? = nil,
        title: String
    ) throws -> Workspace.DetachedSurfaceTransfer {
        let panel: MoveFixturePanel
        if let providedPanel {
            panel = providedPanel
        } else {
            panel = MoveFixturePanel(title: title)
        }
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: title,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "project",
            isLoading: false,
            isPinned: false,
            directory: nil,
            ttyName: nil,
            cachedTitle: panel.displayTitle,
            customTitle: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    @discardableResult
    private func finishDetachedMove(
        app: AppDelegate,
        manager: TabManager,
        sourceWindowId: UUID,
        sourceWorkspace: Workspace,
        destinationWorkspace: Workspace,
        panel: MoveFixturePanel,
        focus: Bool
    ) throws -> UUID {
        let transfer = try makeMoveTransfer(
            sourceWorkspaceId: sourceWorkspace.id,
            panel: panel,
            title: panel.displayTitle
        )
        markMoveFixturePanelDetached(panel, from: sourceWorkspace)
        let destinationPane = try XCTUnwrap(
            destinationWorkspace.bonsplitController.focusedPaneId
                ?? destinationWorkspace.bonsplitController.allPaneIds.first
        )
        let attachedPanelId = try XCTUnwrap(destinationWorkspace.attachDetachedSurface(
            transfer,
            inPane: destinationPane,
            focus: false
        ))
        app.cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: manager,
            sourceWindowId: sourceWindowId
        )
        if focus {
            manager.focusTab(destinationWorkspace.id, surfaceId: panel.id, suppressFlash: true)
        }
        return attachedPanelId
    }

    private func markMoveFixturePanelDetached(_ panel: MoveFixturePanel, from workspace: Workspace) {
        if let surfaceId = workspace.surfaceIdFromPanelId(panel.id) {
            workspace.surfaceIdToPanelId.removeValue(forKey: surfaceId)
        }
        workspace.panels.removeValue(forKey: panel.id)
        workspace.panelDirectories.removeValue(forKey: panel.id)
        workspace.panelTitles.removeValue(forKey: panel.id)
        workspace.panelCustomTitles.removeValue(forKey: panel.id)
        workspace.pinnedPanelIds.remove(panel.id)
        workspace.manualUnreadPanelIds.remove(panel.id)
        workspace.surfaceTTYNames.removeValue(forKey: panel.id)
        workspace.surfaceResumeBindingsByPanelId.removeValue(forKey: panel.id)
        workspace.panelSubscriptions.removeValue(forKey: panel.id)
    }

    private func teardownTabManagerForTesting(_ manager: TabManager) {
        for workspace in Array(manager.tabs) {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
        }
    }

    private func drainMainActorTasksForTesting() {
        var didDrain = false
        Task { @MainActor in
            didDrain = true
        }
        let deadline = Date(timeIntervalSinceNow: 1.0)
        while !didDrain && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

}
