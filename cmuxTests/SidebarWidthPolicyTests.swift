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

    func testMinimalModeSidebarWorkspaceRowsStartAtTop() {
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.workspaceScrollTopVisibilityInset(titlebarHeight: 32, isMinimalMode: true),
            0,
            accuracy: 0.5,
            "Minimal mode should not push workspace tabs below titlebar space"
        )
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.sidebarTopScrimHeight(titlebarHeight: 32, isMinimalMode: true),
            0,
            accuracy: 0.5,
            "Minimal mode should not keep the titlebar scrim above workspace tabs"
        )
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.titlebarDragHandleHeight(titlebarHeight: 32, isMinimalMode: true),
            0,
            accuracy: 0.5,
            "Minimal mode should not keep a titlebar drag strip above workspace tabs"
        )
    }

    func testStandardModeSidebarKeepsTitlebarReservation() {
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.workspaceScrollTopVisibilityInset(titlebarHeight: 32, isMinimalMode: false),
            40,
            accuracy: 0.5
        )
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.sidebarTopScrimHeight(titlebarHeight: 32, isMinimalMode: false),
            52,
            accuracy: 0.5
        )
        XCTAssertEqual(
            VerticalTabsSidebarLayoutMetrics.titlebarDragHandleHeight(titlebarHeight: 32, isMinimalMode: false),
            32,
            accuracy: 0.5
        )
    }
}
