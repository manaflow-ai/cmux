import CMUXMobileCore
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ghostty writes the binary render-grid frame field by field in Zig; the
/// JSON export of the same capture is the reference. Any layout drift between
/// `writeRenderGridBinary` and `MobileTerminalRenderGridFrame.decodeBinary`
/// shows up as a decode failure or an unequal frame here.
@MainActor
@Suite(.serialized)
struct MobileRenderGridBinaryExportParityTests {
    @Test func binaryExportDecodesToTheSameFrameAsTheJSONExport() async throws {
        let terminal = try ScrollbackTestTerminal()
        defer { terminal.close() }
        try await terminal.launch()
        try terminal.output(
            "\u{1b}c"
                + (1...60).map { "history \($0)\r\n" }.joined()
                + "\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[38;5;214mpalette\u{1b}[0m "
                + "\u{1b}[38;2;18;52;86;48;2;200;100;50mrgb\u{1b}[0m\r\n"
                + "\u{1b}[3;4;9mitalic under strike\u{1b}[0m 界 🌍 e\u{301}\r\n"
                + "\u{1b}]10;#123456\u{1b}\\\u{1b}]12;#ABCDEF\u{1b}\\"
                + "\u{1b}[?2004h\u{1b}[?1h\u{1b}[5 q"
        )
        let runtime = try #require(terminal.surface.surface)
        let surfaceID = terminal.surface.id.uuidString
        for includeTheme in [false, true] {
            for anchorActive in [false, true] {
                for scrollbackLines in [0, 20] {
                    let json = export(runtime, surfaceID) {
                        ghostty_surface_render_grid_json_v2(
                            runtime, $0, $1, 7, UInt(scrollbackLines), includeTheme, anchorActive
                        )
                    }
                    let binary = export(runtime, surfaceID) {
                        ghostty_surface_render_grid_binary(
                            runtime, $0, $1, 7, UInt(scrollbackLines), includeTheme, anchorActive
                        )
                    }
                    let expected = try MobileTerminalRenderGridFrame.decode(try #require(json))
                    let actual = try MobileTerminalRenderGridFrame.decodeBinary(try #require(binary))
                    #expect(
                        actual == expected,
                        "theme=\(includeTheme) screen=\(anchorActive) scrollback=\(scrollbackLines)"
                    )
                    #expect(actual.rowSpans.contains { $0.text.contains("界") })
                }
            }
        }
    }

    private func export(
        _ runtime: ghostty_surface_t,
        _ surfaceID: String,
        _ call: (UnsafePointer<CChar>, UInt) -> ghostty_string_s
    ) -> Data? {
        let exported = surfaceID.withCString { call($0, UInt(surfaceID.utf8.count)) }
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr, exported.len > 0 else { return nil }
        return Data(bytes: pointer, count: Int(exported.len))
    }
}
