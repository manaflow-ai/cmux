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
///   4. Composing (`setMarkedText`) suppresses the anchor and a delete cancels the
///      composition instead of forwarding a stray backspace to the Mac.
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

    @Test("composing suppresses the anchor and delete cancels composition without forwarding a backspace")
    func composingSuppressesAnchorAndDelete() {
        let view = TerminalInputTextView()
        var backspaces = 0
        view.onBackspace = { backspaces += 1 }

        // While an IME composition is active the document is the marked text, not
        // the anchor.
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.markedTextRange != nil)
        #expect(documentText(of: view) == "한")

        // A delete during composition must cancel the composition, NOT forward a
        // stray backspace to the Mac.
        view.deleteBackward()
        #expect(backspaces == 0)
        #expect(view.markedTextRange == nil)

        // After the composition is gone the anchor is restored and a real delete
        // forwards a backspace again.
        view.deleteBackward()
        #expect(backspaces == 1)
        #expect(documentText(of: view).isEmpty == false)
    }
}
#endif
