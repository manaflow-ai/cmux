import Foundation
import Testing
import func XCTest.XCTAssertFalse
import func XCTest.XCTAssertTrue
import func XCTest.XCTUnwrap

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TabManagerSessionSnapshotTests {
    @Test
    func testClosedWindowRestoreValidationRejectsFailedRestorablePanelRestore() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        XCTAssertTrue(snapshot.hasRestorablePanels)
        XCTAssertFalse(snapshot.hasUsableRestoredContent(
            restoredPanelIdsByWorkspaceIndex: [[:]],
            hasLivePanels: true
        ))
        XCTAssertTrue(snapshot.hasUsableRestoredContent(
            restoredPanelIdsByWorkspaceIndex: [[UUID(): UUID()]],
            hasLivePanels: true
        ))
    }
}
