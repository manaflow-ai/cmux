import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FullWidthTabCommandTests: XCTestCase {
    func testToggleFocusedFullWidthTabTogglesFocusedPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        XCTAssertTrue(manager.toggleFocusedFullWidthTab())
        XCTAssertEqual(workspace.focusedPanelId, panelId)
        XCTAssertTrue(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))

        XCTAssertTrue(manager.toggleFocusedFullWidthTab())
        XCTAssertEqual(workspace.focusedPanelId, panelId)
        XCTAssertFalse(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))
    }
}
