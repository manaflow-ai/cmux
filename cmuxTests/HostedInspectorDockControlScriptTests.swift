import JavaScriptCore
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

    func testReexecutingScriptDoesNotWrapMissingDockMethod() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in
            exception = value?.toString()
        }
        context.evaluateScript(
            """
            var updateCount = 0;
            var rightCount = 0;
            var WI = {
                DockConfiguration: {
                    Left: "left",
                    Right: "right",
                    Bottom: "bottom",
                    Detached: "detached",
                    Undocked: "undocked"
                },
                dockConfiguration: "detached",
                _dockRight: function(event) {
                    rightCount += 1;
                    return "right";
                },
                _togglePreviousDockConfiguration: function(event) {
                    return "toggle";
                },
                _updateDockNavigationItems: function() {
                    updateCount += 1;
                },
                _dockBottomTabBarButton: { element: { style: {} } },
                _dockBottomNavigationItem: { element: { style: {} } },
                _dockBottomButton: { element: { style: {} } },
                _dockLeftTabBarButton: { element: { style: {} } },
                _dockRightTabBarButton: { element: { style: {} } },
                _detachTabBarButton: { element: { style: {} } },
                _detachNavigationItem: { element: { style: {} } },
                _undockTabBarButton: { element: { style: {} } },
                _undockButton: { element: { style: {} } }
            };
            """
        )

        let source = HostedInspectorDockControlScript(
            allowSideDock: true,
            detachedFromHostWindow: true
        ).source
        context.evaluateScript(source)
        context.evaluateScript(source)

        XCTAssertNil(exception)
        XCTAssertEqual(context.evaluateScript("typeof WI._dockLeft").toString(), "undefined")
        XCTAssertEqual(context.evaluateScript("typeof WI.__cmuxOriginalDockLeft").toString(), "undefined")
        XCTAssertEqual(context.evaluateScript("WI._dockRight({}); rightCount").toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("updateCount").toInt32(), 2)
    }
}
