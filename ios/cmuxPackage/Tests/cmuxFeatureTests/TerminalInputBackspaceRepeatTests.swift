#if canImport(UIKit)
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Regression coverage for hold-to-repeat Backspace on the iOS soft keyboard.
///
/// Device-confirmed root cause: a bare `UIKeyInput`/`UITextInput` responder with
/// an EMPTY virtual document gets its software-keyboard delete no-oped by UIKit —
/// `deleteBackward()` fires zero times when the key is held, so backspace never
/// reaches the Mac. Forcing `hasText == true` alone does NOT fix it.
///
/// The fix gives the view a non-empty ONE-CHARACTER virtual document (a hidden
/// zero-width "delete-repeat anchor") whenever it is not composing, and re-arms
/// that anchor inside `inputDelegate.textWillChange`/`textDidChange` on every
/// empty-buffer delete. That re-arm is what makes UIKit's document-driven repeat
/// timer fire `deleteBackward()` again on the next auto-repeat tick.
///
/// These tests assert the observable invariants that SUSTAIN the repeat, so a
/// regression (reverting to a `UITextView`, dropping the anchor, or removing the
/// `textWillChange/textDidChange` re-arm) makes them fail:
///   1. Not composing → the virtual document is non-empty (length 1, the anchor),
///      so UIKit always has something to delete.
///   2. N held `deleteBackward()` calls forward N backspaces AND leave the
///      document non-empty after each (the anchor is restored / re-armed), so the
///      repeat can keep going.
///   3. Each delete re-arms the document via the `UITextInputDelegate`
///      (`textWillChange`/`textDidChange`), the signal UIKit's repeat timer reads.
///   4. Composing (`setMarkedText`) suppresses the anchor and a delete shortens the
///      marked composition by one grapheme (instead of forwarding a stray backspace
///      to the Mac), clearing the composition only when the last unit is removed.
///
/// Drives the view directly; no live keyboard / first responder required.
@MainActor
@Suite("Terminal input Backspace hold-to-repeat")
struct TerminalInputBackspaceRepeatTests {
    /// Reads the view's full virtual document through the public `UITextInput`
    /// surface (`beginningOfDocument`..`endOfDocument`), the same way UIKit walks
    /// it to decide whether a delete has anything to remove.
    private func documentText(of view: TerminalInputTextView) -> String {
        guard let range = view.textRange(
            from: view.beginningOfDocument,
            to: view.endOfDocument
        ) else {
            return ""
        }
        return view.text(in: range) ?? ""
    }

    /// Counts `textWillChange`/`textDidChange` pairs so a test can prove the
    /// anchor re-arm (the document-driven repeat signal) actually fired.
    private final class ChangeCountingInputDelegate: NSObject, UITextInputDelegate {
        var willChange = 0
        var didChange = 0
        func selectionWillChange(_ textInput: (any UITextInput)?) {}
        func selectionDidChange(_ textInput: (any UITextInput)?) {}
        func textWillChange(_ textInput: (any UITextInput)?) { willChange += 1 }
        func textDidChange(_ textInput: (any UITextInput)?) { didChange += 1 }
        // Required by `UITextInputDelegate` as of the iOS 18.4 SDK (Writing Tools
        // conversation context). Unused by these tests.
        @available(iOS 18.4, *)
        func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    }

    @Test("when not composing the virtual document is a single non-empty anchor char")
    func nonEmptyDocumentWhenIdle() {
        let view = TerminalInputTextView()

        // `hasText` must be true so the keyboard arms its delete auto-repeat, AND
        // the document UIKit walks must actually be non-empty (length 1) so the
        // delete has a target. An empty-document view (the broken state) would
        // report length 0 here even with `hasText == true`.
        #expect(view.hasText == true)

        let document = documentText(of: view)
        #expect(document.isEmpty == false)
        #expect((document as NSString).length == 1)

        // The end position is offset 1 (one char to the left of the caret), which
        // is exactly the deletable character UIKit needs to keep repeating.
        let end = view.offset(from: view.beginningOfDocument, to: view.endOfDocument)
        #expect(end == 1)
    }

    @Test("N held deletes forward N backspaces and the document stays non-empty after each")
    func repeatedDeletesForwardAndReArm() {
        let view = TerminalInputTextView()
        var backspaces = 0
        view.onBackspace = { backspaces += 1 }

        // Simulate the keyboard auto-repeat firing deleteBackward() repeatedly
        // while the key is held. Each tick must forward a real backspace, and the
        // virtual document must remain non-empty afterward so the NEXT tick still
        // has something to delete (the repeat cannot continue otherwise).
        let ticks = 5
        for i in 1...ticks {
            view.deleteBackward()
            #expect(backspaces == i)
            let document = documentText(of: view)
            #expect(document.isEmpty == false, "document must stay non-empty after delete \(i) so repeat continues")
            #expect((document as NSString).length == 1)
        }

        #expect(backspaces == ticks)
    }

    @Test("each delete re-arms the document via the input delegate (the repeat signal)")
    func deleteRearmsViaInputDelegate() {
        let view = TerminalInputTextView()
        let delegate = ChangeCountingInputDelegate()
        view.inputDelegate = delegate
        view.onBackspace = {}

        // UIKit's document-driven key-repeat timer re-reads the document only when
        // told it changed via textWillChange/textDidChange. Each empty-buffer
        // delete must bracket the anchor toggle in that pair, or the repeat stalls
        // after the first delete even with a non-empty document.
        view.deleteBackward()
        #expect(delegate.willChange == 1)
        #expect(delegate.didChange == 1)

        view.deleteBackward()
        #expect(delegate.willChange == 2)
        #expect(delegate.didChange == 2)
    }

    @Test("the anchor character changes on each delete so UIKit sees a real document change")
    func anchorTogglesBetweenDeletes() {
        let view = TerminalInputTextView()
        view.onBackspace = {}

        // The re-arm toggles the anchor between two distinct zero-width chars so
        // the document's *contents* change, not just its length. If it always
        // toggled back to the same string UIKit could short-circuit the repeat.
        let first = documentText(of: view)
        view.deleteBackward()
        let second = documentText(of: view)
        view.deleteBackward()
        let third = documentText(of: view)

        #expect(first != second)
        #expect(second != third)
        #expect(first == third) // alternates between exactly two values
    }

    @Test("composing-delete shortens the marked text by one grapheme, then clears, without forwarding a backspace")
    func composingDeleteShortensThenClears() {
        let view = TerminalInputTextView()
        var backspaces = 0
        view.onBackspace = { backspaces += 1 }
        var committed: [String] = []
        view.onText = { committed.append($0) }

        // While an IME composition is active the document is the marked text, not
        // the anchor. Start a multi-character Korean composition (each syllable is
        // one Swift `Character`/grapheme).
        view.setMarkedText("안녕하", selectedRange: NSRange(location: 3, length: 0))
        #expect(view.markedTextRange != nil)
        #expect(documentText(of: view) == "안녕하")

        // A delete mid-composition must remove exactly ONE composing unit (the last
        // grapheme), re-present the shortened composition, and forward NOTHING to
        // the Mac (the candidate is uncommitted).
        view.deleteBackward()
        #expect(backspaces == 0)
        #expect(committed.isEmpty)
        #expect(view.markedTextRange != nil, "still composing after one shortening delete")
        #expect(documentText(of: view) == "안녕")

        view.deleteBackward()
        #expect(backspaces == 0)
        #expect(documentText(of: view) == "안")
        #expect(view.markedTextRange != nil)

        // Removing the LAST remaining composing character clears/unmarks the
        // composition (it becomes empty), still without any backspace.
        view.deleteBackward()
        #expect(backspaces == 0)
        #expect(committed.isEmpty)
        #expect(view.markedTextRange == nil, "composition cleared when the last unit is removed")

        // After the composition is gone the anchor is restored and a real,
        // non-composing delete forwards a backspace to the Mac again.
        view.deleteBackward()
        #expect(backspaces == 1)
        #expect(documentText(of: view).isEmpty == false)
    }

    @Test("composing-delete on a multi-scalar grapheme removes the whole glyph, never a partial codepoint")
    func composingDeleteRespectsGraphemeBoundaries() {
        let view = TerminalInputTextView()
        var backspaces = 0
        view.onBackspace = { backspaces += 1 }

        // A flag emoji is two Unicode scalars (regional indicators) but ONE
        // grapheme, and several UTF-16 code units. Deleting by grapheme must drop
        // the entire flag, leaving the preceding ASCII character intact rather than
        // splitting the glyph mid-scalar.
        let composing = "a🇰🇷"
        view.setMarkedText(composing, selectedRange: NSRange(location: (composing as NSString).length, length: 0))
        #expect(documentText(of: view) == composing)

        view.deleteBackward()
        #expect(backspaces == 0)
        #expect(documentText(of: view) == "a", "the whole flag grapheme is removed in one delete")
        #expect(view.markedTextRange != nil)
    }
}
#endif
