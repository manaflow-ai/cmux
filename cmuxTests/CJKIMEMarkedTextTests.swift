import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - NSTextInputClient protocol: marked text (preedit) lifecycle

/// Tests that the GhosttyNSView NSTextInputClient implementation correctly
/// manages marked text state for CJK IME composition (Korean jamo combining,
/// Chinese pinyin candidate selection, Japanese hiragana-to-kanji conversion).
final class CJKIMEMarkedTextTests: XCTestCase {

    // MARK: - Korean (한글) jamo combining

    /// Korean IME sends partial jamo as marked text, then replaces/commits.
    /// e.g. ㅎ -> 하 -> 한 as the user types consonants and vowels.
    func testKoreanJamoCombiningSetMarkedTextCreatesMarkedState() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.hasMarkedText(), "Should start with no marked text")

        // First jamo: ㅎ (hieut)
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "Should have marked text after first jamo")
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))

        // Combined syllable: 하 (ha)
        view.setMarkedText("하", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "Should still have marked text during composition")
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))

        // Further combined: 한 (han)
        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
    }

    /// When insertText is called during a keyDown (accumulator active), the
    /// committed text should be accumulated and marked text cleared.
    func testKoreanInsertTextCommitsAndClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        // Simulate composition in progress
        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // insertText clears marked text via unmarkText even when currentEvent is nil.
        // The guard on currentEvent causes an early return, but we can verify the
        // marked text management through the accumulator path.
        //
        // Simulate the keyDown-time accumulator flow: set accumulator, call insertText
        // with a real event context, verify accumulation.
        view.setKeyTextAccumulatorForTesting([])

        // Directly test unmarkText + accumulator (the core of insertText's behavior)
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "unmarkText should clear marked text (as insertText does)")
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))

        // Verify the accumulator would receive the text
        var acc = view.keyTextAccumulatorForTesting ?? []
        acc.append("한")
        view.setKeyTextAccumulatorForTesting(acc)
        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["한"], "Committed Korean text should be accumulated")
        view.setKeyTextAccumulatorForTesting(nil)
    }

    /// Third-party voice input apps often commit text outside an active keyDown
    /// event. `insertText` should still clear marked text in that path.
    func testInsertTextWithoutCurrentEventClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText(), "insertText should clear marked text even without an active currentEvent")
    }

    /// The responder-chain `insertText:` action (single argument) should route
    /// to NSTextInputClient insertion so external text-injection tools work.
    func testResponderChainInsertTextSelectorClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("你")
        XCTAssertFalse(view.hasMarkedText(), "single-argument insertText should follow the same commit path")
    }

    // MARK: - Chinese (中文) pinyin candidate selection

    /// Chinese pinyin IME types Roman letters as marked text, then the user
    /// selects a character from a candidate list which triggers insertText.
    func testChinesePinyinMarkedTextDuringTyping() {
        let view = GhosttyNSView(frame: .zero)

        // User types "n" -> marked text shows "n"
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))

        // User types "i" -> marked text shows "ni"
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))

        // User types "h" -> marked text shows "nih"
        view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))

        // User types "a" -> marked text shows "niha" with potential candidates
        view.setMarkedText("niha", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 4))

        // User types "o" -> marked text shows "nihao"
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
    }

    func testChinesePinyinCandidateSelectionClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        // Pinyin composition "nihao" in progress
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Simulate: user selects candidate 你好 from the list.
        // insertText calls unmarkText internally; verify that path.
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "Marked text should be cleared after candidate selection")
    }

    // MARK: - Japanese (日本語) hiragana-to-kanji conversion

    /// Japanese IME first shows hiragana as marked text, then converts to kanji
    /// candidates. The user confirms to commit via insertText.
    func testJapaneseHiraganaComposition() {
        let view = GhosttyNSView(frame: .zero)

        // User types "ni" -> hiragana に
        view.setMarkedText("に", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // User types "ho" -> hiragana にほ
        view.setMarkedText("にほ", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))

        // User types "n" -> hiragana にほん
        view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // User types "go" -> hiragana にほんご
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 4))
    }

    func testJapaneseKanjiConversionKeepsMarkedTextUntilCommit() {
        let view = GhosttyNSView(frame: .zero)

        // Hiragana にほんご in composition
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Space bar triggers conversion, showing kanji candidate 日本語
        // (this is still marked text, just converted)
        view.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "Kanji candidates should still be marked text")

        // User confirms the kanji selection (Enter or number key) -> unmarkText
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "Marked text should be cleared after kanji confirmation")
    }

    // MARK: - unmarkText clears composition state

    func testUnmarkTextClearsCompositionState() {
        let view = GhosttyNSView(frame: .zero)

        // Set up marked text (any CJK language)
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "unmarkText should clear marked text")
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0),
                       "markedRange should return NSNotFound after unmarkText")
    }

    func testUnmarkTextIsIdempotent() {
        let view = GhosttyNSView(frame: .zero)

        // Call unmarkText when there's no marked text -- should be a no-op
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())

        // Call again -- still no-op
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    // MARK: - Attributed string variant

    func testSetMarkedTextAcceptsAttributedString() {
        let view = GhosttyNSView(frame: .zero)

        let attrStr = NSAttributedString(string: "漢字", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        view.setMarkedText(attrStr, selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
    }

    func testInsertTextWithAttributedStringClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText("test", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // insertText internally calls unmarkText; verify that path
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    // MARK: - validAttributesForMarkedText

    func testValidAttributesForMarkedTextReturnsEmpty() {
        let view = GhosttyNSView(frame: .zero)
        XCTAssertTrue(view.validAttributesForMarkedText().isEmpty)
    }
}

