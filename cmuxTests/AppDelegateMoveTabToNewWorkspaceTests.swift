import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateMoveTabToNewWorkspaceTests: XCTestCase {
    func testMoveSurfaceToNewWorkspaceCreatesSinglePanelWorkspaceFromPanelTitle() throws {
        try withRegisteredMoveContext { app, windowId, manager in
            let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
            let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
            let remainingPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
            let movedPanel = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
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
            XCTAssertNotNil(sourceWorkspace.panels[remainingPanelId])
            XCTAssertEqual(result.paneId, destinationWorkspace.paneId(forPanelId: movedPanel.id)?.id)
        }
    }

    func testMoveSurfaceToNewWorkspacePreservesTerminalTextBoxStateWhenDefaultsEnabled() throws {
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
            let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
            let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
            let movedPanel = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
            XCTAssertFalse(movedPanel.isTextBoxActive)

            defaults.set(true, forKey: showKey)
            defaults.set(true, forKey: focusKey)

            let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
                panelId: movedPanel.id,
                focus: false,
                focusWindow: false
            ))

            let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
            let destinationPanel = try XCTUnwrap(destinationWorkspace.panels[movedPanel.id] as? TerminalPanel)
            XCTAssertFalse(destinationPanel.isTextBoxActive)
            XCTAssertNotEqual(destinationPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
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
            let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
            let onlyPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)

            XCTAssertFalse(app.canMoveSurfaceToNewWorkspace(panelId: onlyPanelId))
            XCTAssertNil(app.moveSurfaceToNewWorkspace(panelId: onlyPanelId, focus: false, focusWindow: false))
            XCTAssertEqual(manager.tabs.count, 1)
            XCTAssertNotNil(sourceWorkspace.panels[onlyPanelId])
        }
    }

    func testMoveTerminalBonsplitTabToExistingWorkspaceClosesEmptiedSourceWorkspace() throws {
        try withRegisteredMoveContext { app, _, manager in
            let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
            let movedPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
            let movedBonsplitTabId = try XCTUnwrap(sourceWorkspace.surfaceIdFromPanelId(movedPanelId)?.uuid)
            let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
            let destinationOriginalPanelId = try XCTUnwrap(destinationWorkspace.focusedTerminalPanel?.id)

            XCTAssertTrue(app.canMoveBonsplitTab(tabId: movedBonsplitTabId, toWorkspace: destinationWorkspace.id))
            XCTAssertTrue(app.moveBonsplitTab(
                tabId: movedBonsplitTabId,
                toWorkspace: destinationWorkspace.id,
                focus: false,
                focusWindow: false
            ))

            XCTAssertFalse(manager.tabs.contains { $0.id == sourceWorkspace.id })
            XCTAssertEqual(manager.tabs.map(\.id), [destinationWorkspace.id])
            XCTAssertTrue(sourceWorkspace.panels.isEmpty)
            XCTAssertNotNil(destinationWorkspace.panels[movedPanelId])
            XCTAssertNotNil(destinationWorkspace.panels[destinationOriginalPanelId])
            XCTAssertEqual(destinationWorkspace.panels.count, 2)
        }
    }

    func testMoveSurfaceToExistingWorkspaceClosesEmptiedSourceWorkspaceAndFocusesDestination() throws {
        try withRegisteredMoveContext { app, _, manager in
            let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
            let movedPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
            let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
            let destinationOriginalPanelId = try XCTUnwrap(destinationWorkspace.focusedTerminalPanel?.id)

            XCTAssertTrue(app.moveSurface(
                panelId: movedPanelId,
                toWorkspace: destinationWorkspace.id,
                focus: true,
                focusWindow: false
            ))

            XCTAssertFalse(manager.tabs.contains { $0.id == sourceWorkspace.id })
            XCTAssertEqual(manager.tabs.map(\.id), [destinationWorkspace.id])
            XCTAssertTrue(sourceWorkspace.panels.isEmpty)
            XCTAssertNotNil(destinationWorkspace.panels[movedPanelId])
            XCTAssertNotNil(destinationWorkspace.panels[destinationOriginalPanelId])
            XCTAssertEqual(destinationWorkspace.panels.count, 2)
            XCTAssertEqual(manager.selectedWorkspace?.id, destinationWorkspace.id)
            XCTAssertEqual(destinationWorkspace.focusedPanelId, movedPanelId)
        }
    }

    private func withRegisteredMoveContext(_ body: (AppDelegate, UUID, TabManager) throws -> Void) rethrows {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer {
            teardownTabManagerForTesting(manager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            drainMainActorTasksForTesting()
        }
        try body(app, windowId, manager)
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
