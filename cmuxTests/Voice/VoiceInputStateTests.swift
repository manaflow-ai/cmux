import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceInputStateTests: XCTestCase {
    func testInitialStateIsIdle() {
        let state = VoiceInputState()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.transcript, "")
    }

    func testSetActivityUpdatesValue() {
        let state = VoiceInputState()
        state.activity = .listening
        XCTAssertEqual(state.activity, .listening)
    }

    func testIsActiveReflectsNonIdleConnectedState() {
        let state = VoiceInputState()
        state.isActive = true
        XCTAssertTrue(state.isActive)
    }
}
