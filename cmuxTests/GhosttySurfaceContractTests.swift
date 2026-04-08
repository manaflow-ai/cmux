import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for Ghostty surface edge cases: nil surface handling, empty text input,
/// and sendText guards.
@MainActor
final class GhosttySurfaceContractTests: XCTestCase {

    // MARK: - Empty text input

    /// insertText("") via NSTextInputClient should not crash and should not
    /// attempt to send data to the surface.
    func testEmptyTextInputViaInsertTextIsIgnored() {
        let view = GhosttyNSView(frame: .zero)
        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// The single-argument insertText override (responder chain) should also
    /// handle empty strings gracefully.
    func testEmptyTextInputViaSingleArgInsertTextIsIgnored() {
        let view = GhosttyNSView(frame: .zero)
        view.insertText("")
    }

    /// NSAttributedString with empty content should also be handled.
    func testEmptyAttributedStringInputIsIgnored() {
        let view = GhosttyNSView(frame: .zero)
        view.insertText(NSAttributedString(string: ""), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Marked text state with nil surface

    /// Setting and clearing marked text when no surface exists should not crash.
    /// This can happen when a view is being torn down while the IME is composing.
    func testMarkedTextLifecycleWithNilSurface() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText("a", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - insertText clears marked text even for empty payload

    /// IME flush: insertText("") should still clear any active marked text,
    /// even though no text is sent to the terminal.
    func testInsertEmptyTextClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(view.hasMarkedText(), "insertText(\"\") should still clear marked text via unmarkText")
    }
}
