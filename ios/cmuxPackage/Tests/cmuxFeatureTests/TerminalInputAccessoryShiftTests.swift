#if canImport(UIKit)
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Behavioral tests for the ⇧ accessory modifier on the terminal input bar.
///
/// ⇧ has the same armed/sticky machinery as ⌃/⌥/⌘ but was never surfaced as a bar
/// button. Now that it is, these lock the functional contract a user expects:
/// arming ⇧ and tapping Tab sends back-tab (CSI Z) — the sequence agents and TUIs
/// read to cycle backward — and a one-shot ⇧ applies to exactly one key.
///
/// Drives the view directly through its `simulate*ForTesting` hooks so no live
/// keyboard / first-responder is required.
@MainActor
@Suite("Terminal input accessory ⇧ modifier")
struct TerminalInputAccessoryShiftTests {
    private let backTab = Data([0x1B, 0x5B, 0x5A]) // ESC [ Z
    private let tab = Data([0x09])

    @Test("⇧ armed then Tab sends back-tab (CSI Z)")
    func shiftTabSendsBackTab() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.simulateAccessoryActionForTesting(.shift) // arm ⇧
        view.simulateAccessoryActionForTesting(.tab) // ⇧ + Tab

        #expect(sequences == [backTab])
    }

    @Test("a one-shot ⇧ applies to a single key only")
    func shiftIsConsumedAfterOneKey() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.simulateAccessoryActionForTesting(.shift) // arm ⇧ (one-shot)
        view.simulateAccessoryActionForTesting(.tab) // consumes ⇧ → back-tab
        view.simulateAccessoryActionForTesting(.tab) // ⇧ already spent → plain Tab

        #expect(sequences == [backTab, tab])
    }

    @Test("⇧ armed then a typed character commits uppercased text")
    func shiftUppercasesCommittedText() {
        let view = TerminalInputTextView()
        var text: [String] = []
        var sequences: [Data] = []
        view.onText = { text.append($0) }
        view.onEscapeSequence = { sequences.append($0) }

        view.simulateAccessoryActionForTesting(.shift) // arm ⇧
        view.insertText("a") // commit a typed character with ⇧ armed

        #expect(text == ["A"])
        #expect(sequences.isEmpty)

        // ⇧ was one-shot: the next character is unmodified.
        view.insertText("b")
        #expect(text == ["A", "b"])
    }

    @Test("tapping ⇧ twice toggles it off so the next key is unmodified")
    func tappingShiftTwiceDisarms() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.simulateAccessoryActionForTesting(.shift) // arm ⇧
        view.simulateAccessoryActionForTesting(.shift) // tap again → off
        view.simulateAccessoryActionForTesting(.tab) // no modifier → plain Tab

        #expect(sequences == [tab])
    }

    @Test("a one-shot ⇧ is consumed by Backspace and does not leak to the next key")
    func shiftConsumedByBackspace() {
        let view = TerminalInputTextView()
        var backspaces = 0
        var text: [String] = []
        view.onBackspace = { backspaces += 1 }
        view.onText = { text.append($0) }

        view.simulateAccessoryActionForTesting(.shift) // arm ⇧ (one-shot)
        view.deleteBackward() // Backspace consumes ⇧, sends a normal backspace
        view.insertText("a") // ⇧ already spent → lowercase, not "A"

        #expect(backspaces == 1)
        #expect(text == ["a"])
    }
}
#endif
