import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct TerminalSurfaceSocketInputControlSequenceTests {
    /// Verifies CPR/DSR CSI sequences are queued as terminal output bytes instead of literal shell input.
    @Test
    func coldSocketInputQueuesCSIReportsAsRawTerminalBytes() {
        for sequence in ["\u{1B}[6n", "\u{1B}[50;36R"] {
            let panel = TerminalPanel(workspaceId: UUID())

            panel.surface.releaseSurfaceForTesting()
            #expect(panel.surface.sendInput(sequence))

            let pending = panel.surface.debugPendingSocketInputForTesting()
            #expect(
                pending.keyEvents == 0,
                "CSI reports must not be split into Escape key events plus literal text."
            )
            #expect(
                pending.inputTextItems == 0,
                "CSI reports must bypass committed text input so Ghostty consumes them as terminal control sequences."
            )
            #expect(
                pending.pasteTextItems == 0,
                "CSI reports must bypass paste input so they are not echoed by the shell."
            )
            #expect(
                pending.processOutputItems == 1,
                "CSI reports must be queued as one terminal output payload."
            )
            #expect(pending.bytes == sequence.utf8.count)
        }
    }

    /// Verifies a complete function-key CSI (`ESC[15~`, F5) is queued as one
    /// terminal-output payload — the same handling as the CPR/DSR reports above
    /// and consistent with the #5763 fix. No cmux client sends function keys as
    /// raw socket input, and the navigation keys clients do send are re-issued as
    /// key events before this routing (see
    /// `coldSocketInputRoutesNavigationArrowAsKeyEvent`), so this breadth does
    /// not regress interactive input.
    @Test
    func coldSocketInputQueuesFunctionKeyCSIAsRawTerminalBytes() {
        let sequence = "\u{1B}[15~"
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput(sequence))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.keyEvents == 0,
            "Function-key CSI must not be split into Escape key events plus literal text."
        )
        #expect(
            pending.inputTextItems == 0,
            "Function-key CSI must bypass committed text input so Ghostty consumes it as a terminal control sequence."
        )
        #expect(
            pending.pasteTextItems == 0,
            "Function-key CSI must bypass paste input so it is not echoed by the shell."
        )
        #expect(
            pending.processOutputItems == 1,
            "Function-key CSI must be queued as one terminal output payload."
        )
        #expect(pending.bytes == sequence.utf8.count)
    }

    /// Verifies the navigation keys cmux clients actually send (an up arrow here)
    /// are re-issued as key events, not routed to the terminal parser, so
    /// interactive navigation still reaches the PTY through libghostty's
    /// cursor-key encoding.
    @Test
    func coldSocketInputRoutesNavigationArrowAsKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput("\u{1B}[A"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.keyEvents == 1,
            "Navigation arrows must stay a single key event so libghostty encodes them for the cursor-key mode."
        )
        #expect(
            pending.processOutputItems == 0,
            "Navigation arrows must not be routed to the terminal output parser."
        )
        #expect(pending.inputTextItems == 0)
        #expect(pending.pasteTextItems == 0)
    }
}
