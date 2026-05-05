import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CJKIMEMarkedSelectionTests: XCTestCase {
    func testSelectedRangeReturnsEmptyRangeWithoutSelectionOrMarkedText() {
        let view = GhosttyNSView(frame: .zero)
        let range = view.selectedRange()
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func testSelectedRangeTracksMarkedTextSelection() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 2, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(
            view.selectedRange(),
            NSRange(location: 2, length: 1),
            "selectedRange should mirror the IME caret/selection inside marked text"
        )
    }

    func testSelectedRangeReturnsEmptyRangeAfterCompositionEnds() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText(
            "東京",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        view.unmarkText()

        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testAttributedSubstringReturnsMarkedTextSegment() {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "とうきょう",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 2, length: 2),
            actualRange: &actualRange
        )

        XCTAssertEqual(actualRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(substring?.string, "きょ")
    }

    func testTraditionalChineseZhuyinMarkedTextSelectionAndSubstring() {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 2),
            actualRange: &actualRange
        )

        XCTAssertEqual(actualRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(substring?.string, "ㄓㄨ")
    }
}
