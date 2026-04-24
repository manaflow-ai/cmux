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
            150,
            accuracy: 0.001
        )
    }
}
