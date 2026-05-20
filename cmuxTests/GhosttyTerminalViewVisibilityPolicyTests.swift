import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testTerminalLaunchEnvironmentClearsInheritedClaudeCodeMarker() {
        var environment = [
            "CLAUDECODE": "1",
            "PATH": "/usr/bin:/bin",
        ]

        GhosttyTerminalView.removeInheritedAgentEnvironment(from: &environment)

        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }

    func testTerminalLaunchEnvironmentClearsClaudeCodeAfterStartupEnvironmentMerge() {
        var environment = TerminalSurface.mergedStartupEnvironment(
            base: ["PATH": "/usr/bin:/bin"],
            protectedKeys: [],
            additionalEnvironment: ["CLAUDECODE": "1"],
            initialEnvironmentOverrides: ["CLAUDECODE": "2"]
        )

        GhosttyTerminalView.removeInheritedAgentEnvironment(from: &environment)

        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }

    func testTerminalLaunchTemporarilyClearsInheritedClaudeCodeProcessEnvironment() {
        let originalValue = getenv("CLAUDECODE").map { String(cString: $0) }
        setenv("CLAUDECODE", "nested-session", 1)
        defer {
            if let originalValue {
                setenv("CLAUDECODE", originalValue, 1)
            } else {
                unsetenv("CLAUDECODE")
            }
        }

        let removedDuringLaunch = GhosttyTerminalView.withRemovedInheritedAgentProcessEnvironment {
            getenv("CLAUDECODE") == nil
        }

        XCTAssertTrue(removedDuringLaunch)
        XCTAssertEqual(getenv("CLAUDECODE").map { String(cString: $0) }, "nested-session")
    }

    func testImmediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testSwiftUIHostGeometryCallbackUsesImmediateSyncWithoutLayoutFlush() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush(let window):
            XCTAssertEqual(window, 3873)
        case .skip:
            XCTFail("Window-attached host callbacks should immediately reconcile portal geometry without layout flushes")
        }
    }

    func testSwiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            XCTFail("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }

}
