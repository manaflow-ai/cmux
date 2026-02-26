import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerWorkspaceSelectionFallbackTests: XCTestCase {
    func testSelectedWorkspaceForUserActionUsesSelectedWorkspace() {
        let manager = TabManager()
        let secondWorkspace = manager.addWorkspace()

        XCTAssertEqual(manager.selectedWorkspace?.id, secondWorkspace.id)
        XCTAssertEqual(manager.selectedWorkspaceForUserAction()?.id, secondWorkspace.id)
    }

    func testSelectedWorkspaceForUserActionFallsBackToSoleWorkspace() {
        let manager = TabManager()
        guard let soleWorkspace = manager.tabs.first else {
            XCTFail("Expected one initial workspace")
            return
        }

        manager.selectedTabId = nil

        XCTAssertNil(manager.selectedWorkspace)
        XCTAssertEqual(manager.selectedWorkspaceForUserAction()?.id, soleWorkspace.id)
    }

    func testSelectedWorkspaceForUserActionFallsBackWhenSelectionIsStale() {
        let manager = TabManager()
        guard let soleWorkspace = manager.tabs.first else {
            XCTFail("Expected one initial workspace")
            return
        }

        manager.selectedTabId = UUID()

        XCTAssertNil(manager.selectedWorkspace)
        XCTAssertEqual(manager.selectedWorkspaceForUserAction()?.id, soleWorkspace.id)
    }

    func testSelectedWorkspaceForUserActionDoesNotGuessWhenMultipleWorkspacesExist() {
        let manager = TabManager()
        _ = manager.addWorkspace()

        manager.selectedTabId = nil

        XCTAssertNil(manager.selectedWorkspace)
        XCTAssertNil(manager.selectedWorkspaceForUserAction())
    }
}
