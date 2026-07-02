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

    /// Verifies a complete function-key CSI (`ESC[15~`, F5) is *not* routed to
    /// the terminal output parser. Unlike the DSR/CPR reports above, a function
    /// key is interactive input for the foreground program; feeding it to the
    /// display parser (`process_output`) would consume it as an unknown output
    /// control sequence and never deliver it to the PTY. Only cursor
    /// reports/queries (`ESC[…n` / `ESC[…R`) — the sequences #5763 needs the
    /// emulator to answer — are parser-routed; every other complete CSI stays on
    /// the input path.
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

    /// Verifies Shift+Tab (`ESC[Z`, back-tab) is re-issued as a single key event
    /// rather than routed to the terminal output parser, so reverse-tab reaches
    /// the PTY (libghostty encodes `ESC[Z`) instead of being consumed as a
    /// display-only cursor-backward-tab move. This is the one interactive CSI key
    /// the iOS client actually sends over the socket — a hardware Shift+Tab and
    /// the on-screen ⇧+Tab accessory both forward `ESC[Z` through
    /// `terminal.input` — so it must not be swallowed like the report/function-key
    /// CSI above (TUIs such as Claude Code use back-tab for reverse-focus).
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
