import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
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

    func testInteractiveGeometryResizeUsesImmediatePortalSyncDecision() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: true
            ),
            "Interactive resize should use the immediate portal sync path"
        )
    }

    func testTerminalStatusBarLayoutReservesBottomRows() {
        let frames = TerminalStatusBarLayout.frames(
            in: CGRect(x: 0, y: 0, width: 120, height: 80),
            rowCount: 2,
            cellHeight: 10,
            isVisible: true
        )

        XCTAssertEqual(frames.statusBarFrame, CGRect(x: 0, y: 0, width: 120, height: 20))
        XCTAssertEqual(frames.terminalFrame, CGRect(x: 0, y: 20, width: 120, height: 60))
        XCTAssertEqual(frames.reservedHeight, 20)
    }

    func testTerminalStatusBarLayoutLeavesTerminalUsableWhenRowsExceedHeight() {
        let frames = TerminalStatusBarLayout.frames(
            in: CGRect(x: 0, y: 0, width: 120, height: 24),
            rowCount: 10,
            cellHeight: 10,
            isVisible: true
        )

        XCTAssertEqual(frames.statusBarFrame, CGRect(x: 0, y: 0, width: 120, height: 14))
        XCTAssertEqual(frames.terminalFrame, CGRect(x: 0, y: 14, width: 120, height: 10))
        XCTAssertEqual(frames.reservedHeight, 14)
    }

    func testTerminalStatusBarConfigurationNormalizesUserDefaults() throws {
        let suiteName = "cmux-terminal-status-bar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: TerminalStatusBarSettings.enabledKey)
        defaults.set(50, forKey: TerminalStatusBarSettings.heightRowsKey)
        defaults.set("  printf status  \n", forKey: TerminalStatusBarSettings.commandKey)
        defaults.set(0.01, forKey: TerminalStatusBarSettings.refreshIntervalKey)

        let configuration = TerminalStatusBarConfiguration.current(defaults: defaults)

        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.heightRows, TerminalStatusBarSettings.maximumHeightRows)
        XCTAssertEqual(configuration.command, "printf status")
        XCTAssertEqual(configuration.refreshInterval, TerminalStatusBarSettings.minimumRefreshInterval)
    }
}
