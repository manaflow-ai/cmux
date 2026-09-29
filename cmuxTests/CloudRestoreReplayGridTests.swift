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
