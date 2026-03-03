import XCTest
@testable import cmux_DEV

final class TerminalSidebarStoreTests: XCTestCase {
    @MainActor
    func testInitialSelectionDefaultsToFirstWorkspace() {
        let store = TerminalSidebarStore()
        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertEqual(store.selectedWorkspaceID, store.workspaces.first?.id)
    }

    @MainActor
    func testAddWorkspaceSelectsNewWorkspace() {
        let store = TerminalSidebarStore()
        let initialCount = store.workspaces.count

        store.addWorkspace()

        XCTAssertEqual(store.workspaces.count, initialCount + 1)
        XCTAssertEqual(store.selectedWorkspaceID, store.workspaces.last?.id)
    }
}
