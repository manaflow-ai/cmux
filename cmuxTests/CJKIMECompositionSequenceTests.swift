import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Multi-character composition sequences

/// Tests more complex IME scenarios involving multiple composition steps.
final class CJKIMECompositionSequenceTests: XCTestCase {

    /// Korean: type multiple syllable blocks, each going through
    /// composition -> commit -> next block.
    func testKoreanMultiSyllableSequence() {
        let view = GhosttyNSView(frame: .zero)

        // First syllable: 안 (an)
        view.setMarkedText("ㅇ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("아", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("안", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // When next syllable starts, current syllable is committed via unmarkText
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())

        // Second syllable: 녕 (nyeong)
        view.setMarkedText("ㄴ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("녀", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.setMarkedText("녕", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    /// Japanese: romaji -> hiragana composition -> kanji conversion -> commit.
    func testJapaneseRomajiToKanjiFullSequence() {
        let view = GhosttyNSView(frame: .zero)

        // 1. Romaji input "t" -> still composing
        view.setMarkedText("t", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // 2. Romaji input "to" -> hiragana と
        view.setMarkedText("と", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // 3. Continue "kyo" -> ときょ
        view.setMarkedText("とk", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.setMarkedText("ときょ", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // 4. Complete: とうきょう (Tokyo in hiragana)
        view.setMarkedText("とうきょう", selectedRange: NSRange(location: 0, length: 5), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // 5. Space triggers kanji conversion -> 東京
        view.setMarkedText("東京", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "Kanji candidates are still marked text")

        // 6. Enter confirms -> unmarkText (insertText calls this internally)
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    /// Chinese: partial pinyin with backspace to correct.
    func testChinesePinyinWithCorrection() {
        let view = GhosttyNSView(frame: .zero)

        // Type "zho" (partial for 中)
        view.setMarkedText("z", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("zho", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Backspace corrects to "zh"
        view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "Backspace during composition should keep marked text")
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))

        // Re-type correctly "zhong"
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Select candidate 中 -> commit
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    /// Canceling composition via Escape: unmarkText should be called.
    func testCancelCompositionClearsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        // Start composition
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Cancel via Escape (IME calls unmarkText or setMarkedText with empty string)
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))
    }

    /// Verify that canceling composition via setMarkedText with empty string works.
    /// Some IMEs cancel composition this way instead of calling unmarkText.
    func testCancelCompositionViaEmptySetMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        // Start composition
        view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Cancel by setting empty marked text
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText(), "Empty setMarkedText should clear composition state")
    }

    /// Verify rapid composition transitions (e.g., switching between IMEs
    /// or quickly typing multiple characters).
    func testRapidCompositionTransitions() {
        let view = GhosttyNSView(frame: .zero)

        // Rapidly cycle: compose -> commit -> compose -> commit
        for char in ["ㅎ", "하", "한"] {
            view.setMarkedText(char, selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
        }

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())

        for char in ["ㄱ", "구", "글"] {
            view.setMarkedText(char, selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
        }

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }
}

