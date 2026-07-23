import AppKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette terminal input outcomes")
struct CommandPaletteTerminalInputOutcomeTests {
    @Test func sentInputReportsCompleted() {
        #expect(ContentView.commandPaletteTerminalInputResult(.sent) == .completed)
    }

    @Test func coldSurfaceInputReportsQueued() {
        #expect(ContentView.commandPaletteTerminalInputResult(.queued) == .queued)
    }

    @Test(
        "Rejected input reports failure",
        arguments: [
            TerminalSurface.NamedKeySendResult.unknownKey,
            .inputQueueFull,
            .surfaceUnavailable,
            .processExited,
        ]
    )
    func rejectedInputReportsFailure(_ result: TerminalSurface.NamedKeySendResult) {
        #expect(
            ContentView.commandPaletteTerminalInputResult(result)
                == .failed(
                    code: "terminal_input_rejected",
                    message: String(
                        localized: "action.error.terminalInputRejected",
                        defaultValue: "The terminal did not accept the input."
                    )
                )
        )
    }
}
