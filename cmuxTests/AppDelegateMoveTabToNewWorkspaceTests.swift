import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateMoveTabToNewWorkspaceTests: XCTestCase {
    func testMoveSurfaceToNewWorkspaceCreatesSinglePanelWorkspaceFromPanelTitle() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

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

    func testMoveBrowserBonsplitTabToNewWorkspaceRequestsAddressBarFocus() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let browserPanel = try XCTUnwrap(
            sourceWorkspace.newBrowserSurface(
                inPane: sourcePaneId,
                url: try XCTUnwrap(URL(string: "https://example.com")),
                focus: false
            )
        )
        let browserTabId = try XCTUnwrap(sourceWorkspace.surfaceIdFromPanelId(browserPanel.id)?.uuid)
        browserPanel.noteWebViewFocused()
        XCTAssertEqual(browserPanel.preferredFocusIntentForActivation(), .browser(.webView))

        let result = try XCTUnwrap(app.moveBonsplitTabToNewWorkspace(
            tabId: browserTabId,
            focus: true,
            focusWindow: false
        ))

        let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        let movedBrowserPanel = try XCTUnwrap(destinationWorkspace.panels[browserPanel.id] as? BrowserPanel)
        XCTAssertEqual(destinationWorkspace.panels.count, 1)
        XCTAssertFalse(destinationWorkspace.panels.values.contains { $0 is TerminalPanel })
        XCTAssertEqual(destinationWorkspace.focusedPanelId, movedBrowserPanel.id)
        XCTAssertEqual(movedBrowserPanel.preferredFocusIntentForActivation(), .browser(.addressBar))
    }

    func testMoveSurfaceToNewWorkspaceRejectsOnlyPanel() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let onlyPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)

        XCTAssertFalse(app.canMoveSurfaceToNewWorkspace(panelId: onlyPanelId))
        XCTAssertNil(app.moveSurfaceToNewWorkspace(panelId: onlyPanelId, focus: false, focusWindow: false))
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(sourceWorkspace.panels[onlyPanelId])
    }
}
