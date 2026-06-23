import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class HostedInspectorDockControlScriptTests: XCTestCase {
    func testDetachedInspectorScriptRepairsBottomAndWindowButtons() {
        let source = HostedInspectorDockControlScript(
            allowSideDock: true,
            detachedFromHostWindow: true
        ).source

        XCTAssertTrue(source.contains("const detachedFromHostWindow = true;"))
        XCTAssertTrue(source.contains("WI.__cmuxDetachedFromHostWindow = detachedFromHostWindow;"))
        XCTAssertTrue(source.contains("WI._dockBottomTabBarButton"))
        XCTAssertTrue(source.contains("WI._dockBottomNavigationItem"))
        XCTAssertTrue(source.contains("WI._dockBottomButton"))
        XCTAssertTrue(source.contains("WI._detachTabBarButton"))
        XCTAssertTrue(source.contains("WI._detachNavigationItem"))
        XCTAssertTrue(source.contains("WI._undockTabBarButton"))
        XCTAssertTrue(source.contains("WI._undockButton"))
        XCTAssertTrue(source.contains("const hideDockTargets = detached;"))
        XCTAssertTrue(source.contains("hideDockTargets || disallowSideDock || dockedLeft"))
        XCTAssertTrue(source.contains("hideDockTargets || disallowSideDock || dockedRight"))
        XCTAssertTrue(source.contains("hideDockTargets || dockedBottom"))
        XCTAssertFalse(source.contains("stopImmediatePropagation"))
        XCTAssertFalse(source.contains("cmuxDevToolsDock"))
    }
}
