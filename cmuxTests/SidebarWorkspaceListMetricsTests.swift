import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceListMetricsTests: XCTestCase {
    func testTopScrimDoesNotFadeFirstWorkspaceRow() {
        let firstRowTop = SidebarWorkspaceScrollInsets.workspaceList.top
            + SidebarWorkspaceListMetrics.rowVerticalPadding

        XCTAssertEqual(
            firstRowTop,
            SidebarWorkspaceListMetrics.firstRowTopOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SidebarWorkspaceListMetrics.topScrimHeight,
            firstRowTop,
            accuracy: 0.001
        )
    }
}
