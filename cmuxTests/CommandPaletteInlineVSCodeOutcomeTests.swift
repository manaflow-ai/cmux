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
@Suite("Command palette inline VS Code outcome")
struct CommandPaletteInlineVSCodeOutcomeTests {
    @Test func acceptedAsynchronousOpenReportsQueued() {
        #expect(ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: true) == .queued)
    }

    @Test func rejectedOpenReportsFailure() {
        #expect(
            ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: false)
                == .failed(
                    code: "open_failed",
                    message: String(
                        localized: "action.error.inlineVSCodeOpenFailed",
                        defaultValue: "VS Code (Inline) could not open the directory."
                    )
                )
        )
    }
}
