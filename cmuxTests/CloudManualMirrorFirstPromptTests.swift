import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A new `cmux ssh` or Cloud split can receive its attach replay before the
/// pane's native runtime exists or before the pane is bound (#16184). The
/// replay addresses the daemon's grid and ends on the shell's OSC 133 prompt.
/// The pane must parse it at that grid; resizing afterwards reflows it and,
/// with no shell behind the mirror, used to erase the prompt for good while
/// the cursor stayed at the prompt's end.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudManualMirrorFirstPromptTests {
    /// `X` clamps to the last column of whatever grid parses it, and the
    /// prompt is the zsh shape Ghostty's shell integration marks.
    private static let replay = Data(
        "\u{1B}[H\u{1B}[2J\u{1B}[1;999HX\r\n\u{1B}]133;A\u{07}host ~ % \u{1B}]133;B\u{07}".utf8
    )

    @Test
    func replayBufferedBeforeTheRuntimeKeepsItsGridAndPrompt() async throws {
        let fixture = try CloudRestoreReplayFixture(runtimeSpawnPolicy: .heldForStartupRestoreAdmission)
        defer { fixture.close() }
        #expect(!fixture.surface.hasLiveSurface)

        try await fixture.attachBeforeSurfaceBinding(replay: Self.replay, columns: 40, rows: 10)
        #expect(!fixture.surface.hasLiveSurface, "the replay must arrive before the runtime")
        fixture.surface.admitStartupRestoreRuntime()
        try await fixture.waitForText("host ~ %")
        // The pane's later geometry passes re-apply the pin. They must find
        // the grid already pinned instead of resizing the parsed prompt.
        fixture.surface.reapplyAssignedGrid()

        _ = try await fixture.waitForTerminalGrid(columns: 40, rows: 10)
        let rows = fixture.screenRows()
        #expect(rows.first == String(repeating: " ", count: 39) + "X", "rows=\(rows)")
        #expect(rows.count > 1 && rows[1] == "host ~ %", "rows=\(rows)")
    }

    @Test
    func replayReceivedBeforeBindingIsParsedAtTheDaemonGrid() async throws {
        let fixture = try CloudRestoreReplayFixture(bindSurface: false)
        defer { fixture.close() }

        try await fixture.attachBeforeSurfaceBinding(replay: Self.replay, columns: 40, rows: 10)
        fixture.bindSurface()
        try await fixture.waitForText("host ~ %")

        _ = try await fixture.waitForTerminalGrid(columns: 40, rows: 10)
        let rows = fixture.screenRows()
        #expect(rows.first == String(repeating: " ", count: 39) + "X", "rows=\(rows)")
        #expect(rows.count > 1 && rows[1] == "host ~ %", "rows=\(rows)")
    }
}
