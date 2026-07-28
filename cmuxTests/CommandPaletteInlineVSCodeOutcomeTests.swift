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

    @Test func terminalDirectoryCandidateDoesNotRequireFilesystemAvailability() {
        let unavailableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-unavailable-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: unavailableURL.path))

        let candidate = ContentView.commandPaletteTerminalDirectoryCandidateURL(
            "  \(unavailableURL.path)  "
        )

        #expect(candidate?.path == unavailableURL.path)
    }
}
