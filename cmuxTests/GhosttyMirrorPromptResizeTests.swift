import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Cloud terminal mirrors a shell that runs on the VM. Resizing the mirror
/// must keep the prompt that shell drew: the shell's own redraw arrives a
/// network round trip later, so clearing the prompt for it blanks the pane
/// until then. A local terminal's shell redraws at once, so it never shows.
/// https://github.com/manaflow-ai/cmux/issues/21301
@MainActor
@Suite("Mirrored prompt survives a local resize", .serialized)
struct GhosttyMirrorPromptResizeTests {
    @Test func resizeKeepsTheRemotePrompt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal(ioMode: .manualMirror)
            defer { terminal.close() }
            try await terminal.launch()
            let runtime = try #require(terminal.surface.surface)

            // A Cloud replay begins with a full reset; zsh's Ghostty shell
            // integration marks its prompt without a redraw option.
            try terminal.output("\u{1b}c\u{1b}]133;A;cl=line\u{07}cloud$ \u{1b}]133;B\u{07}")
            #expect(terminal.surface.visibleText()?.contains("cloud$") == true)

            // The manual backend applies the resize inline.
            let before = ghostty_surface_size(runtime)
            ghostty_surface_set_size(
                runtime,
                before.width_px + 10 * before.cell_width_px,
                before.height_px
            )
            #expect(ghostty_surface_size(runtime).columns > before.columns)

            let text = terminal.surface.visibleText()
            #expect(
                text?.contains("cloud$") == true,
                "The resize cleared the mirrored prompt: \(String(describing: text))"
            )
        }
    }
}
