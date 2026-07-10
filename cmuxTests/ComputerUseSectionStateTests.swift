import XCTest
import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV

final class ComputerUseSectionStateTests: XCTestCase {
    func testAccessibilityGrantedMapping() {
        let state = ComputerUsePermissionRowState.accessibility(granted: true)

        XCTAssertEqual(state.statusText, "Granted")
        XCTAssertTrue(state.grantDisabled)
        XCTAssertNil(state.hintText)
    }

    func testAccessibilityNotGrantedMapping() {
        let state = ComputerUsePermissionRowState.accessibility(granted: false)

        XCTAssertEqual(state.statusText, "Not granted")
        XCTAssertFalse(state.grantDisabled)
        XCTAssertNil(state.hintText)
    }

    func testScreenRecordingRequestedShowsRelaunchHintUntilGranted() {
        let state = ComputerUsePermissionRowState.screenRecording(granted: false, requested: true)

        XCTAssertEqual(state.statusText, "Not granted")
        XCTAssertFalse(state.grantDisabled)
        XCTAssertEqual(state.hintText, "After granting Screen Recording, relaunch cmux for the permission to take effect.")
    }

    func testScreenRecordingGrantedDisablesGrantAndHidesHint() {
        let state = ComputerUsePermissionRowState.screenRecording(granted: true, requested: true)

        XCTAssertEqual(state.statusText, "Granted")
        XCTAssertTrue(state.grantDisabled)
        XCTAssertNil(state.hintText)
    }

    func testIdleDriverReadinessOffersTest() {
        let state = ComputerUseDriverRowState.readiness(
            driverState: .stopped,
            hasResolvedDriver: true
        )

        XCTAssertEqual(state.statusText, "Status: idle.")
        XCTAssertEqual(state.testButtonTitle, "Test")
        XCTAssertFalse(state.testDisabled)
    }

    func testRunningDriverReadinessIncludesHandshakeDetails() {
        let state = ComputerUseDriverRowState.readiness(
            driverState: .running(pid: 42, serverName: "cua", serverVersion: "1.2", toolCount: 7),
            hasResolvedDriver: true
        )

        XCTAssertEqual(state.statusText, "Status: running. cua 1.2, PID 42, 7 tools.")
        XCTAssertEqual(state.testButtonTitle, "Test")
        XCTAssertFalse(state.testDisabled)
    }

    func testStartingDriverReadinessDisablesTest() {
        let state = ComputerUseDriverRowState.readiness(
            driverState: .starting,
            hasResolvedDriver: true
        )

        XCTAssertEqual(state.statusText, "Status: checking readiness.")
        XCTAssertEqual(state.testButtonTitle, "Testing…")
        XCTAssertTrue(state.testDisabled)
    }
}
#endif
