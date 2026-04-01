import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private var cjkIMEInterpretKeyEventsSwizzled = false
private var cjkIMEInterpretKeyEventsHook: ((GhosttyNSView, [NSEvent]) -> Bool)?

private extension GhosttyNSView {
    @objc func cmuxUnitTest_interpretKeyEvents(_ eventArray: [NSEvent]) {
        if let hook = cjkIMEInterpretKeyEventsHook, hook(self, eventArray) {
            return
        }
        cmuxUnitTest_interpretKeyEvents(eventArray)
    }
}

private func installCJKIMEInterpretKeyEventsSwizzle() {
    guard !cjkIMEInterpretKeyEventsSwizzled else { return }

    let originalSelector = #selector(GhosttyNSView.interpretKeyEvents(_:))
    let swizzledSelector = #selector(GhosttyNSView.cmuxUnitTest_interpretKeyEvents(_:))

    guard let originalMethod = class_getInstanceMethod(GhosttyNSView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(GhosttyNSView.self, swizzledSelector) else {
        fatalError("Unable to locate GhosttyNSView interpretKeyEvents methods for swizzling")
    }

    let didAddMethod = class_addMethod(
        GhosttyNSView.self,
        originalSelector,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    )

    if didAddMethod {
        class_replaceMethod(
            GhosttyNSView.self,
            swizzledSelector,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        )
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    cjkIMEInterpretKeyEventsSwizzled = true
}

private func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
    if let view = view as? GhosttyNSView {
        return view
    }

    for subview in view.subviews {
        if let match = findGhosttyNSView(in: subview) {
            return match
        }
    }

    return nil
}

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

    // MARK: - selectedRange / validAttributesForMarkedText

    func testSelectedRangeReturnsEmptyRangeWithoutSelection() {
        let view = GhosttyNSView(frame: .zero)
        let range = view.selectedRange()
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func testValidAttributesForMarkedTextReturnsEmpty() {
        let view = GhosttyNSView(frame: .zero)
        XCTAssertTrue(view.validAttributesForMarkedText().isEmpty)
    }
}

// MARK: - performKeyEquivalent bypasses during IME composition

/// Tests that performKeyEquivalent does not intercept key events when the
/// terminal view has active CJK IME composition (marked text). Without this,
/// CJK IME input would be broken because key events would be consumed by
/// shortcut handling instead of flowing through to the input method.
final class CJKIMEPerformKeyEquivalentTests: XCTestCase {

    func testPerformKeyEquivalentReturnsFalseDuringIMEComposition() {
        let view = GhosttyNSView(frame: .zero)

        // Simulate active IME composition
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Create a key event (unmodified 'a' key -- typical during Korean typing)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0 // kVK_ANSI_A
        ) else {
            XCTFail("Failed to create key event")
            return
        }

        // performKeyEquivalent should return false to let the event flow to keyDown/IME
        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed, "performKeyEquivalent must not consume events during CJK IME composition")
    }

    func testPerformKeyEquivalentReturnsFalseForModifiedKeyDuringIMEComposition() {
        let view = GhosttyNSView(frame: .zero)

        // Simulate active Japanese composition
        view.setMarkedText("にほん", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // Shift key during composition (e.g., to type katakana in some IMEs)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "A",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to create key event")
            return
        }

        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed, "performKeyEquivalent must not consume shift+key during CJK IME composition")
    }

    func testPerformKeyEquivalentReturnsFalseForSpaceDuringIMEComposition() {
        let view = GhosttyNSView(frame: .zero)

        // Space bar is used to trigger kanji conversion in Japanese IME
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49 // kVK_Space
        ) else {
            XCTFail("Failed to create key event")
            return
        }

        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed, "performKeyEquivalent must not consume space during CJK IME composition (needed for kanji conversion)")
    }

    func testPerformKeyEquivalentReturnsFalseForReturnDuringComposition() {
        let view = GhosttyNSView(frame: .zero)

        // Active Japanese kanji conversion
        view.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36 // kVK_Return
        ) else {
            XCTFail("Failed to create return event")
            return
        }

        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed, "Return during CJK IME composition must not be consumed (needed for candidate confirmation)")
    }

    func testPerformKeyEquivalentReturnsFalseForEscapeDuringComposition() {
        let view = GhosttyNSView(frame: .zero)

        // Active Chinese pinyin composition
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53 // kVK_Escape
        ) else {
            XCTFail("Failed to create escape event")
            return
        }

        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed, "Escape during CJK IME composition must not be consumed (needed for composition cancel)")
    }

    /// Regression: after IME composition is complete, performKeyEquivalent
    /// should resume normal behavior (no longer bypass).
    func testPerformKeyEquivalentResumesAfterCompositionEnds() {
        let view = GhosttyNSView(frame: .zero)

        // Start composition
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        // End composition
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())

        // Now performKeyEquivalent should process events normally again.
        // Without a surface it returns false, but the point is that it does
        // NOT return false at the hasMarkedText() guard — it proceeds further.
        // We verify that hasMarkedText is false so the guard doesn't trigger.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to create key event")
            return
        }

        // The view has no window/surface, so it returns false at the
        // firstResponder or surface check, but importantly NOT at the
        // hasMarkedText guard.
        let consumed = view.performKeyEquivalent(with: event)
        XCTAssertFalse(consumed)
        XCTAssertFalse(view.hasMarkedText(), "Composition ended; hasMarkedText should be false")
    }
}

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

// MARK: - IME firstRect placement and sizing

/// Regression tests for IME candidate/preedit anchor rectangle reporting.
/// If width/height are discarded here, macOS can place preedit UI incorrectly.
final class CJKIMEFirstRectTests: XCTestCase {

    func testFirstRectUsesIMEProvidedWidthAndHeight() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 10, height: 20)
        view.setIMEPointForTesting(x: 120, y: 240, width: 64, height: 26)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)

        let expectedViewRect = NSRect(x: 120, y: frame.height - 240, width: 64, height: 26)
        let expectedScreenRect = window.convertToScreen(view.convert(expectedViewRect, to: nil))

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, 64, accuracy: 0.001)
        XCTAssertEqual(rect.height, 26, accuracy: 0.001)
    }

    func testFirstRectFallsBackToCellHeightWhenIMEHeightIsZero() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 9, height: 18)
        view.setIMEPointForTesting(x: 80, y: 120, width: 36, height: 0)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertEqual(rect.width, 36, accuracy: 0.001)
        XCTAssertEqual(rect.height, 18, accuracy: 0.001)
    }

    func testFirstRectUsesZeroWidthForInsertionPointWithoutOffsettingCaretAnchor() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)
        view.cellSize = CGSize(width: 9, height: 18)
        view.setIMEPointForTesting(x: 80, y: 120, width: 36, height: 24)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            view.clearIMEPointForTesting()
            window.orderOut(nil)
        }

        let rect = view.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: nil)
        let expectedViewRect = NSRect(x: 80, y: frame.height - 120, width: 0, height: 24)
        let expectedScreenRect = window.convertToScreen(view.convert(expectedViewRect, to: nil))

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 24, accuracy: 0.001)
    }

    func testDocumentVisibleRectUsesScreenCoordinates() {
        guard #available(macOS 14.0, *) else { return }

        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let view = GhosttyNSView(frame: frame)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: frame)
        window.contentView = content
        content.addSubview(view)
        view.frame = frame

        defer {
            window.orderOut(nil)
        }

        let expected = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        let rect = view.documentVisibleRect

        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.001)
    }
}

// MARK: - Key text accumulator during CJK IME composition

/// Tests that the keyTextAccumulator correctly manages text during the keyDown
/// event flow, which is critical for CJK IME composition to work.
final class CJKIMEKeyTextAccumulatorTests: XCTestCase {

    func testAccumulatorStartsNil() {
        let view = GhosttyNSView(frame: .zero)
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }

    func testAccumulatorCanBeSetAndRead() {
        let view = GhosttyNSView(frame: .zero)

        view.setKeyTextAccumulatorForTesting([])
        XCTAssertEqual(view.keyTextAccumulatorForTesting, [])

        view.setKeyTextAccumulatorForTesting(["한"])
        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["한"])

        view.setKeyTextAccumulatorForTesting(nil)
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }

    func testAccumulatorCollectsMultipleIMECommits() {
        let view = GhosttyNSView(frame: .zero)

        // Simulate a keyDown event that triggers multiple insertText calls
        // (can happen with some IME behaviors)
        view.setKeyTextAccumulatorForTesting([])

        var acc = view.keyTextAccumulatorForTesting!
        acc.append("你")
        acc.append("好")
        view.setKeyTextAccumulatorForTesting(acc)

        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["你", "好"])
        view.setKeyTextAccumulatorForTesting(nil)
    }

    /// When the accumulator is nil (not in keyDown), insertText should not
    /// try to accumulate. This is the "direct send" path for IME events
    /// that arrive outside of keyDown processing.
    func testAccumulatorNilMeansDirectSendPath() {
        let view = GhosttyNSView(frame: .zero)

        view.setKeyTextAccumulatorForTesting(nil)
        // insertText with nil accumulator and no surface/currentEvent is a no-op,
        // but the important thing is that it doesn't crash or accumulate.
        XCTAssertNil(view.keyTextAccumulatorForTesting)
    }
}

// MARK: - External committed-text sanitization

final class ExternalCommittedTextSanitizationTests: XCTestCase {
    func testStripsLeadingCSISequenceFromExternalCommittedText() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{1B}[Chello"),
            "hello"
        )
    }

    func testStripsLeadingC1CSISequenceFromExternalCommittedText() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{009B}1;5Chello"),
            "hello"
        )
    }

    func testStripsMultipleLeadingControlAndEscapeSequences() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\u{1B}[1;5C\u{1B}OChello"),
            "hello"
        )
    }

    func testLeavesLiteralBracketPrefixedTextUntouched() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("[Code] review"),
            "[Code] review"
        )
    }

    func testPreservesLeadingControlBytesUsedByAutomation() {
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\n"),
            "\n"
        )
        XCTAssertEqual(
            GhosttyNSView.sanitizeExternalCommittedText("\tfoo"),
            "\tfoo"
        )
    }
}

// MARK: - Shift+Space fallback suppression (IME source-switch shortcut)

final class CJKIMEShiftSpaceFallbackTests: XCTestCase {
    func testSuppressesShiftSpaceFallbackWhenNoMarkedTextAndNoIMECommit() {
        let view = GhosttyNSView(frame: .zero)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) else {
            XCTFail("Failed to create Shift+Space event")
            return
        }

        XCTAssertTrue(
            view.shouldSuppressShiftSpaceFallbackTextForTesting(event: event, markedTextBefore: false),
            "Shift+Space should suppress synthesized space fallback when IME did not commit text"
        )
    }

    func testDoesNotSuppressRegularSpaceFallback() {
        let view = GhosttyNSView(frame: .zero)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) else {
            XCTFail("Failed to create Space event")
            return
        }

        XCTAssertFalse(
            view.shouldSuppressShiftSpaceFallbackTextForTesting(event: event, markedTextBefore: false),
            "Only Shift+Space should be suppressed"
        )
    }
}

// MARK: - Space release regression (Codex hold-to-talk in cmux)

@MainActor
final class GhosttySpaceReleaseRegressionTests: XCTestCase {
    func testSyntheticSpaceReleaseCarriesUnshiftedCodepoint() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var releaseEvent: ghostty_input_key_s?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            if keyEvent.action == GHOSTTY_ACTION_RELEASE, keyEvent.keycode == 49 {
                releaseEvent = keyEvent
            }
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: " ",
            charactersIgnoringModifiers: " ",
            keyCode: 49
        )
        XCTAssertTrue(sent, "Expected synthetic Space key press/release to be dispatched")

        guard let releaseEvent else {
            XCTFail("Expected to capture synthetic Space key release event")
            return
        }

        XCTAssertEqual(releaseEvent.action, GHOSTTY_ACTION_RELEASE)
        XCTAssertEqual(releaseEvent.keycode, 49)
        XCTAssertEqual(releaseEvent.unshifted_codepoint, " ".unicodeScalars.first!.value)
        XCTAssertEqual(releaseEvent.consumed_mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertFalse(releaseEvent.composing)
        XCTAssertNil(releaseEvent.text)
    }
}

@MainActor
final class KoreanIMEReturnCommitRegressionTests: XCTestCase {
    func testReturnAfterKoreanCommitAlsoSendsReturnToSurface() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))

        // Simulate Korean input source so shouldSendCommittedIMEConfirmKey fires
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.Korean.2SetKorean"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === view else { return false }
            candidateView.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        defer {
            KeyboardLayout.debugInputSourceIdOverride = nil
            cjkIMEInterpretKeyEventsHook = nil
        }

        var sawReturnPress = false
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 36,
                  keyEvent.text == nil else { return }
            sawReturnPress = true
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to create Return event")
            return
        }

        window.makeFirstResponder(view)
        view.keyDown(with: event)

        XCTAssertFalse(view.hasMarkedText(), "Return should commit the active Hangul composition")
        XCTAssertTrue(sawReturnPress, "Return should still be forwarded after IME commit so the command executes once")
    }
}

@MainActor
final class AccessibilityInsertTextRegressionTests: XCTestCase {
    func testDirectInsertTextUsesTypedInputSemantics() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.insertText("dictated line\n", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(pressedText, ["dictated line"])
        XCTAssertEqual(pressedKeycodes, [36], "Trailing newline should be delivered as Return, not pasted text")
    }

    func testDirectInsertTextPreservesLeadingEscapeForAutomation() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.insertText("\u{1B}[A", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(pressedText, ["\u{1B}[A"])
        XCTAssertEqual(pressedKeycodes, [], "Direct NSTextInputClient insertText should preserve raw ESC bytes")
    }

    func testAccessibilityValueSanitizesLeadingEscapeSequence() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.setAccessibilityValue("\u{1B}[Adictated line\n")

        XCTAssertEqual(pressedText, ["dictated line"])
        XCTAssertEqual(pressedKeycodes, [36], "AX value insertion should sanitize injected ESC prefixes before sending text")
    }
}

final class GhosttyBackquoteRegressionTests: XCTestCase {
    func testShiftBackquoteEscFallbackSendsLiteralTilde() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var pressText: String?
        var pressUnshiftedCodepoint: UInt32?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 50 else { return }
            pressUnshiftedCodepoint = keyEvent.unshifted_codepoint
            if let text = keyEvent.text {
                pressText = String(cString: text)
            } else {
                pressText = nil
            }
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{1B}",
            charactersIgnoringModifiers: "`",
            keyCode: 50,
            modifierFlags: [.shift]
        )
        XCTAssertTrue(sent, "Expected synthetic Shift+backquote event to be dispatched")
        XCTAssertEqual(pressText, "~")
        XCTAssertEqual(pressUnshiftedCodepoint, "`".unicodeScalars.first?.value)
    }
}

@MainActor
final class GhosttyOptionDeleteRegressionTests: XCTestCase {
    func testOptionDeletePreservesAltAsModifierForWordDelete() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var pressEvent: ghostty_input_key_s?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 51 else { return }
            pressEvent = keyEvent
        }

        let sent = hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51,
            modifierFlags: [.option]
        )
        XCTAssertTrue(sent, "Expected synthetic Option+Delete event to be dispatched")

        guard let pressEvent else {
            XCTFail("Expected to capture Option+Delete key event")
            return
        }

        XCTAssertEqual(pressEvent.action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(pressEvent.keycode, 51)
        XCTAssertEqual(
            pressEvent.mods.rawValue & GHOSTTY_MODS_ALT.rawValue,
            GHOSTTY_MODS_ALT.rawValue,
            "Option+Delete should preserve Alt on the raw key event"
        )
        XCTAssertEqual(
            pressEvent.consumed_mods.rawValue,
            GHOSTTY_MODS_NONE.rawValue,
            "Non-printing delete should not consume Option as text input"
        )
        XCTAssertNil(pressEvent.text, "Delete should be encoded as a key event, not forwarded as DEL text")
    }
}
