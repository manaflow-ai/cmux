import Testing
@testable import CnxTerminal

/// User report 2026-10-14: a reset and its replay lay out once, at the end.
@Suite struct TerminalReplayGateTests {
    @Test func aReplayFedOverSeveralFramesIsOneStep() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true)
        #expect(gate.isReplaying)
        // The reset's own batch is parsed: still replaying.
        var done = gate.parsed(2); #expect(!done)
        gate.received(900_000, isReset: false)
        done = gate.parsed(256_000); #expect(!done)
        done = gate.parsed(256_000); #expect(!done)
        #expect(gate.isReplaying)
        done = gate.parsed(388_000); #expect(done)
        #expect(!gate.isReplaying)
        // Live output after it is not gated.
        gate.received(40, isReset: false)
        #expect(!gate.isReplaying)
        done = gate.parsed(40); #expect(!done)
    }

    @Test func theCapEndsAStuckReplay() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true)
        gate.expire()
        #expect(!gate.isReplaying)
    }
}
