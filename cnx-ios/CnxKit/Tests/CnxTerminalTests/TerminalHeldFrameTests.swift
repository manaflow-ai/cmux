import Foundation
import Testing
@testable import CnxTerminal

/// design/terminal R3-2 / round 5: hold the last frame until a TUI repaints.
@Suite struct TerminalHeldFrameTests {
    let rule = TerminalHeldFrame()

    @Test func anEmptyTUIScreenKeepsTheFrame() {
        #expect(!rule.shouldRelease(isAlternate: true, nonBlankRows: 0, rows: 24, elapsed: 0.6))
        // A header line alone is not a repaint yet.
        #expect(!rule.shouldRelease(isAlternate: true, nonBlankRows: 2, rows: 24, elapsed: 0.9))
    }

    @Test func aRepaintedTUIReleasesIt() {
        #expect(rule.shouldRelease(isAlternate: true, nonBlankRows: 8, rows: 24, elapsed: 1.0))
    }

    @Test func theCapLongerThanTopsTickStillEndsIt() {
        #expect(TerminalHeldFrame.cap > 1.0)
        #expect(rule.shouldRelease(isAlternate: true, nonBlankRows: 0, rows: 24, elapsed: 1.5))
    }

    @Test func aShellReplayReleasesOnAnyText() {
        #expect(rule.shouldRelease(isAlternate: false, nonBlankRows: 1, rows: 41, elapsed: 0.05))
        #expect(!rule.shouldRelease(isAlternate: false, nonBlankRows: 0, rows: 41, elapsed: 0.05))
    }

    @Test func countsRowsWithText() {
        #expect(TerminalHeldFrame.nonBlankRows(in: "Processes: 1\n\n   \nPID COMMAND\n", limit: 24) == 2)
        #expect(TerminalHeldFrame.nonBlankRows(in: "a\nb\nc", limit: 2) == 2)
    }
}
