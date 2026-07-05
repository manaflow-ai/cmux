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
}
#endif
