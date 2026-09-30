import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A hidden restore releases its old geometry contribution. Reveal must
/// reclaim the final pane size without waiting for focus or a keystroke.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudRestoreReplayGridTests {
    @Test(arguments: ["vt-state", "resized"])
    func replayWithoutSidecarPreservesAuthoredColors(event: String) async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 80, rows: 24)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        try await fixture.deliver(
            Data("AUTHORED".utf8), event: "vt-state", marker: "AUTHORED",
            colors: ["overrides": ["fg": "#123456", "bg": "#654321"]]
        )
        try await fixture.expectInputAfterPendingResponses(marker: "COLOR_APPLIED")
        let before = try #require(fixture.surface.mobileRenderGridFrame(
            stateSeq: 0, scrollbackLines: 0, includeTheme: true
        )?.frame)
        #expect(before.terminalForeground == "#123456")
        #expect(before.terminalBackground == "#654321")
        try await fixture.deliver(Data("REPLACEMENT".utf8), event: event, marker: "REPLACEMENT")
        try await fixture.expectInputAfterPendingResponses(marker: "REPLAY_APPLIED")
        let after = try #require(fixture.surface.mobileRenderGridFrame(
            stateSeq: 0, scrollbackLines: 0, includeTheme: true
        )?.frame)
        #expect(after.terminalForeground == before.terminalForeground)
        #expect(after.terminalBackground == before.terminalBackground)
    }

    /// The daemon snapshots while its parser is inside a sequence (here an SGR
    /// that has not reached its final byte). The replay ends at a boundary and
    /// the incomplete bytes arrive as `pending`, which the pane must write
    /// after its own color sidecar so the live output completes the sequence.
    @Test(arguments: ["vt-state", "resized"])
    func replayResumesTheSequenceTheDaemonParserIsInside(event: String) async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 80, rows: 24)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        try await fixture.deliver(
            Data("BEFORE ".utf8), event: event, marker: "BEFORE",
            colors: ["overrides": ["fg": "#123456"]],
            pending: Data("\u{1B}[1;3".utf8)
        )
        try await fixture.deliver(Data("1mRED\u{1B}[0m AFTER".utf8), event: "output", marker: "AFTER")

        let screen = try #require(fixture.surface.readText(region: .screen))
        #expect(screen.contains("BEFORE RED AFTER"), "screen=\(screen)")
        #expect(!screen.contains("1mRED"), "the sequence tail printed as text: \(screen)")
        try await fixture.expectInputAfterPendingResponses(marker: "RESUMED")
        let frame = try #require(fixture.surface.mobileRenderGridFrame(
            stateSeq: 0, scrollbackLines: 0, includeTheme: true
        )?.frame)
        #expect(frame.terminalForeground == "#123456")
    }

    /// The daemon owns the grid. A replay authored for 40×10 places text by
    /// absolute and edge-clamped cursor moves, so the pane must parse it at
    /// 40×10 even though its view holds more cells. The view's own grid stays
    /// what the pane reports, so it can still grow the shared grid later.
    @Test(arguments: ["vt-state", "resized"])
    func paneParsesTheReplayAtTheDaemonGridNotItsViewGrid(event: String) async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        // Cursor moves clamp at the grid edge: `X` lands in the last column
        // and `BOTTOM` on the last row of whatever grid parses them.
        let replay = "\u{1B}[H\u{1B}[2J\u{1B}[1;999HX\u{1B}[999;1HBOTTOM"
        try await fixture.deliver(Data(replay.utf8), event: event, marker: "BOTTOM", columns: 40, rows: 10)

        _ = try await fixture.waitForTerminalGrid(columns: 40, rows: 10)
        let rows = fixture.screenRows()
        #expect(rows.first == String(repeating: " ", count: 39) + "X", "rows=\(rows)")
        #expect(rows.count > 9 && rows[9] == "BOTTOM", "rows=\(rows)")
        let view = try #require(fixture.surface.naturalGridSize())
        #expect(view.columns > 40 && view.rows > 10, "the view grid collapsed onto the pinned grid: \(view)")
    }

    @Test
    func restoredSnapshotReplacesStaleLocalCells() async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 80, rows: 24)
        try await fixture.seedLocalOutput(Data("STALE_COMPOSER".utf8), marker: "STALE_COMPOSER")
        try await fixture.attach(replay: Data("FRESH_COMPOSER STATUS_READY".utf8))

        let screen = try #require(fixture.surface.readText(region: .screen))
        #expect(screen.contains("FRESH_COMPOSER"))
        #expect(!screen.contains("STALE_COMPOSER"))
    }

    @Test
    func hiddenRestoreReclaimsGeometryWithoutInput() async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 99, rows: 35)

        // The pane takes its normal visible -> hidden restoration edge before
        // the machine connects. No terminal focus or input follows the reveal.
        fixture.setVisible(true)
        fixture.setVisible(false)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        fixture.setVisible(true)

        let report = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(report.cmd == "resize-surface")
        #expect(report.surface == 17)
        #expect(report.columns == 99)
        #expect(report.rows == 35)
        // Legacy resize-surface replies use accepted=false for an applied
        // report; the first visible mirror must still promote itself.
        fixture.socket.send(["id": report.id, "ok": true, "data": ["accepted": false, "outcome": "applied"]])
        let claim = try #require(
            await fixture.socket.nextCommand(timeout: .seconds(5)),
            "A visible restored pane must claim its reported grid without requiring focus"
        )
        #expect(claim.cmd == "set-client-sizing")
        #expect(claim.surface == 17)
    }

    @Test
    func replayParsedAtAHiddenGridIsRefetchedOnceTheGridsMatch() async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 99, rows: 35)
        fixture.setVisible(true)
        fixture.setVisible(false)
        // A restored pane is laid out in a small bootstrap grid while hidden,
        // so the full-screen replay of the remote TUI lands on the wrong grid.
        try await fixture.setGrid(columns: 60, rows: 6)
        let authored = Self.fullScreenRows(status: "STATUS_READY")
        try await fixture.attach(replay: Self.cursorAddressedReplay(authored), columns: 99, rows: 35)
        try await fixture.setGrid(columns: 99, rows: 35)
        #expect(Array(fixture.screenRows().prefix(authored.count)) != authored)
        fixture.setVisible(true)

        // The remote PTY already has this grid, so the daemon acknowledges the
        // report without a `resized` replay. Nothing else repaints the pane.
        let report = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(report.cmd == "resize-surface")
        #expect(report.columns == 99)
        #expect(report.rows == 35)
        fixture.socket.send(["id": report.id, "ok": true, "data": ["accepted": true, "outcome": "applied"]])
        let claim = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(claim.cmd == "set-client-sizing")
        fixture.socket.send(["id": claim.id, "ok": true, "data": [:]])

        let reattach = try await fixture.answerHandshake()
        #expect(reattach.columns == 99)
        #expect(reattach.rows == 35)
        fixture.socket.send(["id": reattach.id, "ok": true, "data": [:]])
        let repaired = Self.fullScreenRows(status: "STATUS_REPAIRED")
        try await fixture.deliver(
            Self.cursorAddressedReplay(repaired), event: "vt-state", marker: "STATUS_REPAIRED",
            columns: 99, rows: 35
        )
        #expect(Array(fixture.screenRows().prefix(repaired.count)) == repaired)
        #expect(fixture.socket.connectionCount() == 2)
    }

    /// Thirty-five rows the way a full-screen TUI paints them: each one placed
    /// by absolute cursor address, so a shorter grid clamps and overwrites.
    private static func fullScreenRows(status: String) -> [String] {
        (1...34).map { String(format: "ROW%02d ", $0) + String(repeating: "abcdefghij", count: 4) }
            + [status.padding(toLength: 46, withPad: ".", startingAt: 0)]
    }

    private static func cursorAddressedReplay(_ rows: [String]) -> Data {
        Data(rows.enumerated().map { "\u{1B}[\($0.offset + 1);1H\($0.element)" }.joined().utf8)
    }

    @Test
    func intentionallyPassiveMirrorStillWaitsForExplicitFocus() async throws {
        let fixture = try CloudRestoreReplayFixture(initiallyClaimsGeometry: false)
        defer { fixture.close() }
        try await fixture.setGrid(columns: 99, rows: 35)
        fixture.setVisible(true)
        fixture.setVisible(false)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        fixture.setVisible(true)

        let report = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(report.cmd == "resize-surface")
        #expect(report.surface == 17)
        #expect(report.columns == 99)
        #expect(report.rows == 35)
        fixture.socket.send(["id": report.id, "ok": true, "data": ["outcome": "passive", "accepted": false]])
        try await fixture.expectInputAfterPendingResponses(marker: "PASSIVE_REPORT_APPLIED")
        fixture.focus()
        let claim = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(claim.cmd == "set-client-sizing")
        #expect(claim.surface == 17)
        fixture.socket.send([
            "event": "resized", "surface": 17, "cols": 99, "rows": 35,
            "replay": Data("CLAIMED_GRID".utf8).base64EncodedString()
        ])
        fixture.socket.send(["id": claim.id, "ok": true, "data": [:]])
        try await fixture.expectInputAfterPendingResponses(marker: "CLAIM_APPLIED")
    }

    @Test
    func typingIntoTheGeometryOwnerSendsOnlyOneWayInput() async throws {
        let fixture = try CloudRestoreReplayFixture()
        defer { fixture.close() }
        try await fixture.setGrid(columns: 99, rows: 35)
        fixture.setVisible(true)
        fixture.setVisible(false)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        fixture.setVisible(true)

        let report = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(report.cmd == "resize-surface")
        fixture.socket.send(["id": report.id, "ok": true, "data": ["accepted": true, "outcome": "applied"]])
        let claim = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(claim.cmd == "set-client-sizing")
        fixture.socket.send([
            "event": "resized", "surface": 17, "cols": 99, "rows": 35,
            "replay": Data("OWNER_GRID".utf8).base64EncodedString()
        ])
        fixture.socket.send(["id": claim.id, "ok": true, "data": [:]])
        try await fixture.expectInputAfterPendingResponses(marker: "OWNER_CONFIRMED")

        // Each keystroke used to re-claim geometry first, which put a
        // set-client-sizing round trip ahead of every key. The owner's keys
        // go out alone and ask for no reply, so a relay can send them as
        // compact one-way input.
        for key in ["l", "s", "\r"] {
            fixture.type(key)
            let input = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
            #expect(input.cmd == "send", "The confirmed owner re-claimed geometry for a keystroke")
            #expect(input.inputBytes == Data(key.utf8))
            #expect(input.noReply)
        }
    }

    @Test
    func typingIntoAPaneAnotherClientSizesReclaimsTheGridFirst() async throws {
        let fixture = try CloudRestoreReplayFixture(initiallyClaimsGeometry: false)
        defer { fixture.close() }
        try await fixture.setGrid(columns: 99, rows: 35)
        fixture.setVisible(true)
        fixture.setVisible(false)
        try await fixture.attach(replay: Data("STATUS_READY".utf8))
        fixture.setVisible(true)

        let report = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(report.cmd == "resize-surface")
        fixture.socket.send(["id": report.id, "ok": true, "data": ["outcome": "passive", "accepted": false]])
        try await fixture.expectInputAfterPendingResponses(marker: "PEER_OWNS_GRID")

        // Another client sizes the terminal. The pane the user types into
        // takes the grid back before its first key goes out.
        fixture.type("l")
        let claim = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(claim.cmd == "set-client-sizing", "A key went out before the pane reclaimed the grid")
        #expect(claim.surface == 17)
        fixture.socket.send([
            "event": "resized", "surface": 17, "cols": 99, "rows": 35,
            "replay": Data("RECLAIMED_GRID".utf8).base64EncodedString()
        ])
        fixture.socket.send(["id": claim.id, "ok": true, "data": [:]])
        let input = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(input.cmd == "send")
        #expect(input.inputBytes == Data("l".utf8))
        #expect(input.noReply)
    }
}
