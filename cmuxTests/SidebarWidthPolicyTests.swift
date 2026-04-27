import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampAllowsNarrowSidebarBelowLegacyMinimum() {
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            184,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampAllowsWideExplorerOnLargeWindows() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(900, availableWidth: 1600),
            900,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampLeavesTerminalWidth() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(10_000, availableWidth: 1000),
            640,
            accuracy: 0.001
        )
    }

    func testRightSidebarClampKeepsMinimumWidth() {
        XCTAssertEqual(
            ContentView.clampedRightSidebarWidth(20, availableWidth: 1000),
            276,
            accuracy: 0.001
        )
    }

    func testLeadingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.leading.hitRange(dividerX: 200)

        XCTAssertEqual(range.lowerBound, 194, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 204, accuracy: 0.001)
        XCTAssertTrue(range.contains(196))
        XCTAssertTrue(range.contains(202))
        XCTAssertFalse(range.contains(193.9))
        XCTAssertFalse(range.contains(204.1))
    }

    func testTrailingSidebarResizeRangeFavorsSidebarSide() {
        let range = SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: 680)

        XCTAssertEqual(range.lowerBound, 676, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 686, accuracy: 0.001)
        XCTAssertTrue(range.contains(678))
        XCTAssertTrue(range.contains(684))
        XCTAssertFalse(range.contains(675.9))
        XCTAssertFalse(range.contains(686.1))
    }
}
