import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A restored hidden mirror must interpret the replay at the daemon's grid.
/// The final pane can have that same grid, so the daemon owes no resize replay
/// to repair cursor drift introduced while the pane was still bootstrapping.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudRestoreReplayGridTests {
    @Test
    func hiddenRestoreMatchesFreshAttachAfterSameSizeReveal() async throws {
        let fresh = try CloudRestoreReplayFixture()
        let restored = try CloudRestoreReplayFixture()
        defer { fresh.close(); restored.close() }

        try await fresh.setGrid(columns: 80, rows: 24)
        try await restored.setGrid(columns: 99, rows: 35)
        try await fresh.attach(replay: replay)
        try await restored.attach(replay: replay)

        // The real pane settles to the daemon's existing 80x24 size. A
        // same-size resize succeeds without a `resized` replacement event.
        try await restored.setGrid(columns: 80, rows: 24)
        let turn = Data("\r\n4\r\nSTATUS_AFTER".utf8)
        try await fresh.deliver(turn, event: "output", marker: "STATUS_AFTER")
        try await restored.deliver(turn, event: "output", marker: "STATUS_AFTER")

        let expected = try #require(fresh.surface.readText(region: .screen))
        let actual = try #require(restored.surface.readText(region: .screen))
        #expect(expected.contains("> Ask Codex to do anything\n4\nSTATUS_AFTER"))
        #expect(actual == expected, "Restoration changed the cursor or screen before the next TUI diff")
    }

    /// Recorded from the bundled cmux-tui's byte attach, after an 80x24
    /// primary-screen TUI writes a wrapped paragraph and a composer band.
    /// Like a real snapshot, it restores the cursor by absolute coordinates
    /// after reconstructing wrapped rows; following output is incremental.
    private var replay: Data {
        Data((
            "\u{1B}[?12hAttach specimen\r\n\r\n\r\n"
            + String(repeating: "A", count: 80)
            + String(repeating: "B", count: 80)
            + String(repeating: "C", count: 20)
            + "\r\n\r\n\r\n\r\n> 2+2\r\n\r\n\r\n4\r\n\r\n"
            + "\u{1B}[0m\u{1B}[48;2;60;64;72m> Ask Codex to do anything"
            + String(repeating: " ", count: 54)
            + "\u{1B}[0m\r\n\r\nSTATUS_READY\u{1B}[0m\u{1B}[15;3H"
            + "\u{1B}[3g\u{1B}[9G\u{1B}H\u{1B}[17G\u{1B}H\u{1B}[25G\u{1B}H"
            + "\u{1B}[33G\u{1B}H\u{1B}[41G\u{1B}H\u{1B}[49G\u{1B}H"
            + "\u{1B}[57G\u{1B}H\u{1B}[65G\u{1B}H\u{1B}[73G\u{1B}H"
            + "\u{1B}[15;3H\u{1B}[15;3H"
        ).utf8)
    }
}
