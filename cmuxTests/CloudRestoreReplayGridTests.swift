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
        fixture.socket.send(["id": report.id, "ok": true, "data": ["outcome": "passive"]])
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
        fixture.socket.send(["id": report.id, "ok": true, "data": ["outcome": "passive"]])
        #expect(await fixture.socket.nextCommand(timeout: .milliseconds(200)) == nil)
        fixture.focus()
        let claim = try #require(await fixture.socket.nextCommand(timeout: .seconds(5)))
        #expect(claim.cmd == "set-client-sizing")
    }
}
