import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Shortcut handler IME bypass precondition

/// Tests the precondition that the app-level shortcut handler (local event monitor)
/// checks: GhosttyNSView.hasMarkedText() must accurately reflect IME composition state.
/// The monitor uses this to bail out during active CJK composition.
final class CJKIMEShortcutBypassTests: XCTestCase {

    func testHasMarkedTextTracksCJKCompositionLifecycle() {
        let view = GhosttyNSView(frame: .zero)

        // No marked text -- shortcuts should be eligible to fire
        XCTAssertFalse(view.hasMarkedText())

        // Active Korean composition -- shortcuts must be bypassed
        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "hasMarkedText must return true during composition to enable shortcut bypass")

        // After unmarkText (commit or cancel) -- shortcuts should be eligible again
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "hasMarkedText must return false after commit to re-enable shortcuts")
    }

    func testHasMarkedTextTransitionsThroughChineseComposition() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.hasMarkedText())

        // Pinyin letters as marked text
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Candidate selection commits -> unmarkText
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    func testHasMarkedTextTransitionsThroughJapaneseComposition() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.hasMarkedText())

        // Hiragana composition
        view.setMarkedText("とうきょう", selectedRange: NSRange(location: 0, length: 5), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Kanji conversion (still marked)
        view.setMarkedText("東京", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Confirm -> unmarkText
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }
}

