#if canImport(UIKit)
import CmuxMobileTerminalKit
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
/// Drives the REAL accessory/nub handlers (`handleAccessoryAction` /
/// `handleNubArrow`) via `@testable import` — through the `tapAccessory` /
/// `tapNub` test-target helpers below — so no live keyboard / first-responder
/// and no production test seam is required.
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

        view.tapAccessory(.shift) // arm ⇧
        view.tapAccessory(.tab) // ⇧ + Tab

        #expect(sequences == [backTab])
    }

    @Test("a one-shot ⇧ applies to a single key only")
    func shiftIsConsumedAfterOneKey() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.tapAccessory(.shift) // arm ⇧ (one-shot)
        view.tapAccessory(.tab) // consumes ⇧ → back-tab
        view.tapAccessory(.tab) // ⇧ already spent → plain Tab

        #expect(sequences == [backTab, tab])
    }

    @Test("⇧ armed then a typed character commits uppercased text")
    func shiftUppercasesCommittedText() {
        let view = TerminalInputTextView()
        var text: [String] = []
        var sequences: [Data] = []
        view.onText = { text.append($0) }
        view.onEscapeSequence = { sequences.append($0) }

        view.tapAccessory(.shift) // arm ⇧
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

        view.tapAccessory(.shift) // arm ⇧
        view.tapAccessory(.shift) // tap again → off
        view.tapAccessory(.tab) // no modifier → plain Tab

        #expect(sequences == [tab])
    }

    @Test("a one-shot ⇧ is consumed by Backspace and does not leak to the next key")
    func shiftConsumedByBackspace() {
        let view = TerminalInputTextView()
        var backspaces = 0
        var text: [String] = []
        view.onBackspace = { backspaces += 1 }
        view.onText = { text.append($0) }

        view.tapAccessory(.shift) // arm ⇧ (one-shot)
        view.deleteBackward() // Backspace consumes ⇧, sends a normal backspace
        view.insertText("a") // ⇧ already spent → lowercase, not "A"

        #expect(backspaces == 1)
        #expect(text == ["a"])
    }

    @Test("a one-shot ⇧ is consumed by the arrow nub and does not leak to the next key")
    func shiftConsumedByArrowNub() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        var text: [String] = []
        view.onEscapeSequence = { sequences.append($0) }
        view.onText = { text.append($0) }

        let up = Data([0x1B, 0x5B, 0x41]) // ESC [ A
        view.tapAccessory(.shift) // arm ⇧ (one-shot)
        view.tapNub(.upArrow) // nub sends a raw arrow, consumes ⇧
        view.insertText("a") // ⇧ already spent → lowercase, not "A"

        #expect(sequences == [up]) // arrow forwarded unmodified
        #expect(text == ["a"]) // ⇧ did not leak
    }

    @Test("a one-shot ⌥ is applied to the arrow nub before it is consumed")
    func alternateAppliesToArrowNub() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.tapAccessory(.alternate) // arm ⌥ (one-shot)
        view.tapNub(.leftArrow) // ⌥ + ← = word-left
        view.tapNub(.leftArrow) // ⌥ already spent → plain ←

        #expect(sequences == [
            Data([0x1B, 0x62]), // ESC b
            Data([0x1B, 0x5B, 0x44]), // ESC [ D
        ])
    }

    @Test("a one-shot ⌘ is applied to the arrow nub before it is consumed")
    func commandAppliesToArrowNub() {
        let view = TerminalInputTextView()
        var sequences: [Data] = []
        view.onEscapeSequence = { sequences.append($0) }

        view.tapAccessory(.command) // arm ⌘ (one-shot)
        view.tapNub(.leftArrow) // ⌘ + ← = start of line
        view.tapNub(.leftArrow) // ⌘ already spent → plain ←

        #expect(sequences == [
            Data([0x01]), // Ctrl+A
            Data([0x1B, 0x5B, 0x44]), // ESC [ D
        ])
    }
}

private extension TerminalInputTextView {
    /// Test-target stand-in for a toolbar accessory tap.
    ///
    /// Clears the sticky double-tap window first: synthesized taps land
    /// microseconds apart and would otherwise read as the sticky-promotion
    /// double-tap (real taps are seconds apart). Then drives the REAL
    /// ``TerminalInputTextView/handleAccessoryAction(_:)`` path via
    /// `@testable import`. Lives in the test target so production source ships
    /// no test seam.
    func tapAccessory(_ action: TerminalInputAccessoryAction) {
        modifierState.clearDoubleTapWindow()
        handleAccessoryAction(action)
    }

    /// Test-target stand-in for an arrow-nub press: drives the REAL
    /// ``TerminalInputTextView/handleNubArrow(_:)`` path the production nub
    /// callback uses.
    func tapNub(_ action: TerminalInputAccessoryAction) {
        handleNubArrow(action)
    }
}
#endif
