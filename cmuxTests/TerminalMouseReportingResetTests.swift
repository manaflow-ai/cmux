import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6668:
/// after returning from sleep, a terminal whose foreground program (e.g. an
/// SSH session dropped while the Mac was asleep) left mouse reporting enabled
/// would print mouse-movement escape sequences at the shell prompt. cmux clears
/// the stuck modes when a command finishes while mouse reporting is still
/// active.
@Suite("Terminal mouse reporting reset")
struct TerminalMouseReportingResetTests {
    @Test func returnsDisableSequenceWhenMouseReportingStillActive() {
        // A command finished but mouse reporting is still on -> the just-finished
        // program left it stuck, so cmux must emit the disable sequences.
        #expect(
            TerminalMouseReportingReset(mouseReportingActive: true).disableSequence
                == TerminalMouseReportingReset.allMouseModesDisableSequence
        )
    }

    @Test func returnsNilWhenMouseReportingNotActive() {
        // Nothing to clear when mouse reporting is already off; cmux must not
        // touch the terminal.
        #expect(TerminalMouseReportingReset(mouseReportingActive: false).disableSequence == nil)
    }

    @Test func disableSequenceClearsEveryMouseTrackingAndEncodingMode() {
        let sequence = TerminalMouseReportingReset.allMouseModesDisableSequence
        // Every disable must be a DECRST ("\u{1b}[?<n>l").
        for mode in [9, 1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016] {
            #expect(
                sequence.contains("\u{1b}[?\(mode)l"),
                "disableSequence is missing DECRST for mode \(mode)"
            )
        }
        // The any-event motion mode (1003) is the one that makes the terminal
        // report bare mouse movement, which is the exact issue #6668 symptom.
        #expect(sequence.contains("\u{1b}[?1003l"))
    }
}
