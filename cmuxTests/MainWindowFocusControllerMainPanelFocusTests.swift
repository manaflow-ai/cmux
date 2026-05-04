import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MainWindowFocusControllerMainPanelFocusTests: XCTestCase {
    func testStaleTerminalFocusFromUnselectedWorkspaceIsRejected() {
        let manager = TabManager()
        let activeWorkspace = manager.addWorkspace(title: "Active", select: true)
        let staleWorkspace = manager.addWorkspace(title: "Stale", select: false)
        manager.selectWorkspace(activeWorkspace)

        guard let activePanelId = activeWorkspace.focusedPanelId,
              let stalePanelId = staleWorkspace.focusedPanelId else {
            XCTFail("Expected both workspaces to have focused terminal panels")
            return
        }

        let focusController = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: manager,
            fileExplorerState: nil
        )

        XCTAssertTrue(
            focusController.noteMainPanelFocusIntent(
                workspaceId: activeWorkspace.id,
                panelId: activePanelId,
                source: .keyboardShortcut
            )
        )
        XCTAssertFalse(
            focusController.allowsTerminalFocus(
                workspaceId: staleWorkspace.id,
                panelId: stalePanelId
            )
        )
        XCTAssertFalse(
            focusController.requestMainPanelFocus(
                workspaceId: staleWorkspace.id,
                panelId: stalePanelId,
                source: .terminalFirstResponder
            )
        )
        XCTAssertEqual(manager.selectedTabId, activeWorkspace.id)
        XCTAssertEqual(activeWorkspace.focusedPanelId, activePanelId)
    }
}
