import JavaScriptCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Hosted inspector dock control script")
struct HostedInspectorDockControlScriptTests {
    @Test func detachedInspectorShowsDockTargetsAndHidesUndockButtons() throws {
        let context = try makeDockControlContext(dockConfiguration: "detached")
        context.evaluateScript(
            HostedInspectorDockControlScript(
                allowSideDock: true,
                detachedFromHostWindow: true
            ).source
        )

        #expect(context.evaluateScript("WI._dockLeftTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._dockRightTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._dockBottomTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._detachTabBarButton.hidden").toBool() == true)
        #expect(context.evaluateScript("WI._undockButton.hidden").toBool() == true)
    }

    @Test func attachedInspectorShowsUndockAndNonCurrentDockTargets() throws {
        let context = try makeDockControlContext(dockConfiguration: "bottom")
        context.evaluateScript(
            HostedInspectorDockControlScript(
                allowSideDock: true,
                detachedFromHostWindow: false
            ).source
        )

        #expect(context.evaluateScript("WI._dockLeftTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._dockRightTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._dockBottomTabBarButton.hidden").toBool() == true)
        #expect(context.evaluateScript("WI._detachTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._undockButton.hidden").toBool() == false)
    }

    @Test func sideDockDisallowedHidesSideTargetsAndRoutesToBottom() throws {
        let context = try makeDockControlContext(dockConfiguration: "detached")
        context.evaluateScript(
            """
            var bottomCount = 0;
            var leftCount = 0;
            var rightCount = 0;
            WI._dockBottom = function(event) { bottomCount += 1; return "bottom"; };
            WI._dockLeft = function(event) { leftCount += 1; return "left"; };
            WI._dockRight = function(event) { rightCount += 1; return "right"; };
            """
        )

        context.evaluateScript(
            HostedInspectorDockControlScript(
                allowSideDock: false,
                detachedFromHostWindow: true
            ).source
        )

        #expect(context.evaluateScript("WI._dockLeftTabBarButton.hidden").toBool() == true)
        #expect(context.evaluateScript("WI._dockRightTabBarButton.hidden").toBool() == true)
        #expect(context.evaluateScript("WI._dockBottomTabBarButton.hidden").toBool() == false)
        #expect(context.evaluateScript("WI._dockLeft({}); bottomCount").toInt32() == 1)
        #expect(context.evaluateScript("WI._dockRight({}); bottomCount").toInt32() == 2)
        #expect(context.evaluateScript("leftCount").toInt32() == 0)
        #expect(context.evaluateScript("rightCount").toInt32() == 0)
    }

    @Test func reexecutingScriptDoesNotWrapMissingDockMethod() throws {
        let context = try #require(JSContext())
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

        #expect(exception == nil)
        #expect(context.evaluateScript("typeof WI._dockLeft").toString() == "undefined")
        #expect(context.evaluateScript("typeof WI.__cmuxOriginalDockLeft").toString() == "undefined")
        #expect(context.evaluateScript("WI._dockRight({}); rightCount").toInt32() == 1)
        #expect(context.evaluateScript("updateCount").toInt32() == 2)
    }

    private func makeDockControlContext(dockConfiguration: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var updateCount = 0;
            var WI = {
                DockConfiguration: {
                    Left: "left",
                    Right: "right",
                    Bottom: "bottom",
                    Detached: "detached",
                    Undocked: "undocked"
                },
                dockConfiguration: "\(dockConfiguration)",
                _dockBottomTabBarButton: { element: { style: {} } },
                _dockBottomNavigationItem: { element: { style: {} } },
                _dockBottomButton: { element: { style: {} } },
                _dockLeftTabBarButton: { element: { style: {} } },
                _dockRightTabBarButton: { element: { style: {} } },
                _detachTabBarButton: { element: { style: {} } },
                _detachNavigationItem: { element: { style: {} } },
                _undockTabBarButton: { element: { style: {} } },
                _undockButton: { element: { style: {} } },
                _updateDockNavigationItems: function() { updateCount += 1; }
            };
            """
        )
        return context
    }
}
