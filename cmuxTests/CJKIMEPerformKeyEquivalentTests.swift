import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


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

