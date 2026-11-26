import Foundation
import Testing
@testable import CMUXMobileCore

@Test func themePatchPreservesCellRelativeCursorColor() throws {
    var theme = TerminalTheme.monokai
    theme.cursor = "#123456"
    theme.cursorColorSemantic = .foreground
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: theme,
        terminalConfigTheme: theme
    )

    let patch = try #require(String(
        data: MobileTerminalRenderGridReplay(frame).themePatchBytes(),
        encoding: .utf8
    ))
    #expect(patch.contains("\u{1B}]112\u{1B}\\"))
    #expect(!patch.contains("\u{1B}]12;rgb:12/34/56\u{1B}\\"))
}

@Test func themePatchDoesNotMutateSynchronizedOutputMode() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        rowSpans: [],
        terminalTheme: .monokai,
        terminalConfigTheme: .monokai
    )

    let patch = try #require(String(
        data: MobileTerminalRenderGridReplay(frame).themePatchBytes(),
        encoding: .utf8
    ))
    #expect(!patch.contains("\u{1B}[?2026h"))
    #expect(!patch.contains("\u{1B}[?2026l"))
}
