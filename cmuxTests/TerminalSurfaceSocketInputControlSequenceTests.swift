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
    /// A DSR *query* — `ESC[6n` / `ESC[?6n` (cursor position) or `ESC[5n`
    /// (status) — is the sequence #5763 needs the emulator to consume and answer,
    /// so it is queued as one terminal-output payload rather than split into Escape
    /// + literal text.
    @Test
    func coldSocketInputQueuesDSRCursorQueryAsRawTerminalBytes() {
        for sequence in ["\u{1B}[6n", "\u{1B}[?6n", "\u{1B}[5n"] {
            let panel = TerminalPanel(workspaceId: UUID())

            panel.surface.releaseSurfaceForTesting()
            #expect(panel.surface.sendInput(sequence))

            let pending = panel.surface.debugPendingSocketInputForTesting()
            #expect(
                pending.keyEvents == 0,
                "DSR queries must not be split into Escape key events plus literal text."
            )
            #expect(
                pending.inputTextItems == 0,
                "DSR queries must bypass committed text input so Ghostty consumes them as terminal control sequences."
            )
            #expect(
                pending.pasteTextItems == 0,
                "DSR queries must bypass paste input so they are not echoed by the shell."
            )
            #expect(
                pending.processOutputItems == 1,
                "DSR queries must be queued as one terminal output payload."
            )
            #expect(pending.bytes == sequence.utf8.count)
        }
    }

    /// A CPR *response* (`ESC[50;36R`) is a terminal-to-application reply, not a
    /// query the emulator answers. Routing it to the display parser would swallow
    /// bytes the foreground PTY program is waiting for, so it stays on the input
    /// path (Escape key + literal tail) instead of `process_output`.
    @Test
    func coldSocketInputDoesNotRouteCPRResponseToTerminalParser() {
        let sequence = "\u{1B}[50;36R"
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput(sequence))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.processOutputItems == 0,
            "A CPR response must not reach the terminal output parser; it is destined for the foreground PTY program."
        )
        #expect(
            pending.keyEvents == 1 && pending.inputTextItems == 1,
            "A CPR response must stay on the input path so its bytes reach the program."
        )
    }

    /// A function-key CSI (`ESC[15~`, F5) is interactive input, not a DSR query,
    /// so it is *not* routed to the display parser. The positive assertion guards
    /// that its bytes still reach the input path rather than being silently
    /// dropped.
    @Test
    func coldSocketInputDoesNotRouteFunctionKeyCSIToTerminalParser() {
        let sequence = "\u{1B}[15~"
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput(sequence))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.processOutputItems == 0,
            "Function-key CSI must not reach the terminal output parser, which would consume it as a display-only control sequence instead of PTY input."
        )
        #expect(
            pending.keyEvents == 1 && pending.inputTextItems == 1,
            "Function-key CSI bytes must stay on the input path (Escape + literal tail), not be dropped."
        )
    }

    /// A modified function key that shares the CPR `R` final (xterm Shift+F3 is
    /// `ESC[1;2R`) is interactive input, not a cursor report, so it must also stay
    /// on the input path and reach the foreground program.
    @Test
    func coldSocketInputDoesNotRouteModifiedFunctionKeyToTerminalParser() {
        let sequence = "\u{1B}[1;2R"
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput(sequence))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.processOutputItems == 0,
            "Modified function keys ending in R must not be routed to the terminal output parser as a CPR report."
        )
        #expect(
            pending.keyEvents == 1 && pending.inputTextItems == 1,
            "Modified function-key bytes must stay on the input path so they reach the program."
        )
    }

    /// Navigation keys cmux clients actually send (an up arrow here) are re-issued
    /// as key events, not routed to the terminal parser, so interactive navigation
    /// still reaches the PTY through libghostty's cursor-key encoding.
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

    /// Shift+Tab (`ESC[Z`, back-tab) is re-issued as a single key event rather than
    /// routed to the terminal output parser, so reverse-tab reaches the PTY
    /// (libghostty encodes `ESC[Z`) instead of a display-only cursor-backward-tab.
    /// It is the one interactive CSI key the iOS client actually sends over the
    /// socket (a hardware Shift+Tab and the on-screen ⇧+Tab accessory), so TUIs
    /// such as Claude Code keep reverse-focus.
    @Test
    func coldSocketInputRoutesShiftTabAsKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        #expect(panel.surface.sendInput("\u{1B}[Z"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            pending.keyEvents == 1,
            "Shift+Tab must stay a single key event so libghostty encodes ESC[Z for the PTY."
        )
        #expect(
            pending.processOutputItems == 0,
            "Shift+Tab must not be routed to the terminal output parser (which would consume it as cursor-backward-tab)."
        )
        #expect(pending.inputTextItems == 0)
        #expect(pending.pasteTextItems == 0)
    }
}
