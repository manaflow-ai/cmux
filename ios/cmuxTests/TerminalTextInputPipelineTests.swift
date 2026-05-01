import XCTest
@testable import cmux_DEV

final class TerminalTextInputPipelineTests: XCTestCase {
    func testComposingTextStaysBufferedUntilCommit() {
        let result = TerminalTextInputPipeline.process(text: "nihon", isComposing: true)

        XCTAssertNil(result.committedText)
        XCTAssertEqual(result.nextBufferText, "nihon")
    }

    func testCommittedUnicodeTextEmitsAndClearsBuffer() {
        let result = TerminalTextInputPipeline.process(text: "日本", isComposing: false)

        XCTAssertEqual(result.committedText, "日本")
        XCTAssertEqual(result.nextBufferText, "")
    }

    func testCursorBlinkStateTogglesOnInterval() {
        var state = TerminalCursorBlinkState()

        state.start(now: 10)

        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.advance(now: 10.49))
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.advance(now: 10.5))
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.advance(now: 11.0))
        XCTAssertTrue(state.isVisible)
    }

    func testCursorBlinkStateResetMakesCursorVisible() {
        var state = TerminalCursorBlinkState()

        state.start(now: 10)
        _ = state.advance(now: 10.5)
        state.reset(now: 12)

        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.advance(now: 12.49))
        XCTAssertTrue(state.isVisible)
    }

    func testTerminalFontZoomDirectionUsesGhosttyBindingActions() {
        XCTAssertEqual(TerminalFontZoomDirection.decrease.bindingAction, "decrease_font_size:1")
        XCTAssertEqual(TerminalFontZoomDirection.increase.bindingAction, "increase_font_size:1")
    }
}
