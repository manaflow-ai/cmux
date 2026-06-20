#if canImport(UIKit)
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Behavioral tests for hold-to-repeat Backspace on the iOS terminal input view.
///
/// The iOS terminal input is a `UITextView` that keeps a perpetually-empty
/// document: every committed keystroke is forwarded to the Mac and the local
/// buffer is cleared. The software keyboard's auto-repeat timer for Backspace
/// only keeps firing `deleteBackward()` while the first responder reports
/// `hasText == true`. With the inherited empty-document `hasText`, that reads
/// `false`, so holding Backspace deleted exactly one character and then stopped.
///
/// These lock the contract that makes hold-to-repeat work (iSH's technique):
/// `hasText` is a forced constant `true`, and `deleteBackward()` keeps emitting a
/// real backspace to the Mac on every repeat tick when no IME composition is
/// active. They drive the view directly so no live keyboard is required.
@MainActor
@Suite("Terminal input hold-to-repeat Backspace")
struct TerminalInputBackspaceRepeatTests {
    /// The keyboard's repeat gate. If this is `false`, the system stops
    /// auto-repeating `deleteBackward()` after the first delete and hold-to-repeat
    /// Backspace is dead. It must be a constant `true`.
    @Test("hasText is always true so the keyboard auto-repeats Backspace")
    func hasTextIsAlwaysTrue() {
        let view = TerminalInputTextView()
        #expect(view.hasText)
    }

    /// Simulates the keyboard's auto-repeat firing `deleteBackward()` repeatedly
    /// while Backspace is held: every tick on an empty document (no IME marked
    /// text) must reach the Mac as a backspace, not be swallowed after the first.
    @Test("each held-Backspace repeat tick sends a backspace to the Mac")
    func heldBackspaceRepeatsToTheMac() {
        let view = TerminalInputTextView()
        var backspaces = 0
        view.onBackspace = { backspaces += 1 }

        // No IME composition is active, so each repeat tick is a real backspace.
        for _ in 0 ..< 5 {
            view.deleteBackward()
        }

        #expect(backspaces == 5)
    }
}
#endif
