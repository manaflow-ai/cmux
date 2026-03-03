import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for `Workspace.WorkspaceCloseResult.allClosed`, which gates whether a workspace
/// is removed from the tab list after teardown. The `allClosed == false` path causes
/// `teardownWorkspacePanels` to abort the close and leave the workspace visible.
final class WorkspaceCloseResultTests: XCTestCase {

    // MARK: - allClosed == true

    func testAllClosedWhenAllPanelsSucceeded() {
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: 3,
            closedCount: 3,
            failedPanelIds: []
        )
        XCTAssertTrue(result.allClosed)
    }

    func testAllClosedWhenNoPanelsRequested() {
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: 0,
            closedCount: 0,
            failedPanelIds: []
        )
        XCTAssertTrue(result.allClosed)
    }

    // MARK: - allClosed == false

    func testNotAllClosedWhenFailedPanelIdsNonEmpty() {
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: 2,
            closedCount: 1,
            failedPanelIds: [UUID()]
        )
        XCTAssertFalse(result.allClosed)
    }

    func testNotAllClosedWhenClosedCountUnderRequestedWithNoFailedIds() {
        // Partial close recorded via closedCount mismatch alone (no failedPanelIds entry).
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: 3,
            closedCount: 2,
            failedPanelIds: []
        )
        XCTAssertFalse(result.allClosed)
    }

    func testNotAllClosedWhenFailedIdsNonEmptyEvenIfCountsMatch() {
        // closedCount == requestedCount but a panel ID is recorded as failed.
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: 2,
            closedCount: 2,
            failedPanelIds: [UUID()]
        )
        XCTAssertFalse(result.allClosed)
    }

    func testNotAllClosedWhenAllPanelsFailed() {
        let ids = [UUID(), UUID(), UUID()]
        let result = Workspace.WorkspaceCloseResult(
            requestedCount: ids.count,
            closedCount: 0,
            failedPanelIds: ids
        )
        XCTAssertFalse(result.allClosed)
    }
}
