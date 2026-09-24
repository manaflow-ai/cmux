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
}
