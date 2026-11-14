import AppKit
import CMUXMobileCore
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A viewing Mac's mirror learns the host program's mouse modes only from the
/// attach replay. Claude Code's fullscreen TUI asks for any-motion tracking
/// with SGR reports; a mirror left on X10 typed `[MCVL` into the host's prompt.
/// https://github.com/manaflow-ai/cmux/issues/21775
@MainActor
@Suite("Devices: mirror mouse format after attach replay", .serialized)
struct DeviceTerminalMirrorMouseFormatTests {
    @Test(arguments: [
        [1003, 1006],                   // Claude Code fullscreen
        [1000, 1002, 1003, 1015, 1006], // crossterm EnableMouseCapture
    ])
    func mirrorSendsSGRMouseReportsAfterReplay(enabled: [Int]) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal(ioMode: .manualMirror)
            defer { terminal.close() }
            try await terminal.launch()
            try terminal.output(Self.replay(enabling: Set(enabled)))
            _ = try await terminal.inputBytesBeforeBarrier()

            let runtime = try #require(terminal.surface.surface)
            ghostty_surface_mouse_pos(runtime, 200, 120, GHOSTTY_MODS_NONE)
            let input = try await terminal.inputBeforeBarrier()

            #expect(input.hasPrefix("\u{1B}[<"), "\(input.debugDescription)")
            #expect(input.hasSuffix("M"), "\(input.debugDescription)")
            #expect(!input.contains("\u{1B}[M"), "\(input.debugDescription)")
        }
    }

    /// The host's render grid lists every DEC mode, on or off, by number.
    private static func replay(enabling enabled: Set<Int>) throws -> Data {
        let defaultsOn: Set<Int> = [7, 1007, 1035, 1036]
        let codes = [1, 4, 5, 6, 7, 8, 9, 40, 45, 66, 67, 69, 1000, 1002, 1003, 1004,
                     1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 2004, 2027]
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "mirror",
            stateSeq: 1,
            columns: 80,
            rows: 24,
            cursor: .init(row: 0, column: 2),
            rowSpans: [.init(row: 0, column: 0, text: "> ")],
            activeScreen: .alternate,
            modes: codes.map { .init(code: $0, ansi: false, on: enabled.contains($0) || defaultsOn.contains($0)) }
        )
        return MobileTerminalRenderGridReplay(frame).patchBytes()
    }
}
