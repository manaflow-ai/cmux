import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux textbox` / `surface.textbox.*` show and hide a terminal's TextBox
/// Input without taking keyboard focus unless the caller asks for it.
@MainActor
@Suite("TerminalPanel TextBox socket control", .serialized)
struct TerminalPanelTextBoxControlTests {
    @Test
    func showWithoutFocusLeavesTheTerminalAsTheFocusTarget() {
        let panel = makePanel()

        #expect(panel.setTextBoxInputVisible(true, focus: false))
        #expect(panel.isTextBoxActive)
        #expect(panel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))
    }

    @Test
    func showWithFocusMakesTheTextBoxTheFocusTarget() {
        let panel = makePanel()

        #expect(panel.setTextBoxInputVisible(true, focus: true))
        #expect(panel.isTextBoxActive)
        #expect(panel.preferredFocusIntentForActivation() == .terminal(.textBoxInput))
    }

    @Test
    func showingAShownTextBoxReportsNoChange() {
        let panel = makePanel()
        panel.setTextBoxInputVisible(true, focus: false)

        #expect(!panel.setTextBoxInputVisible(true, focus: false))
        #expect(panel.isTextBoxActive)
        // Asking for focus on an already shown TextBox still moves focus there.
        #expect(!panel.setTextBoxInputVisible(true, focus: true))
        #expect(panel.preferredFocusIntentForActivation() == .terminal(.textBoxInput))
    }

    @Test
    func hideKeepsTheDraftAndReportsChangeOnce() {
        let panel = makePanel()
        panel.setTextBoxInputVisible(true, focus: false)
        panel.textBoxContent = "half-written prompt"

        #expect(panel.setTextBoxInputVisible(false, focus: false))
        #expect(!panel.isTextBoxActive)
        #expect(panel.textBoxContent == "half-written prompt")
        #expect(!panel.setTextBoxInputVisible(false, focus: false))
    }

    private func makePanel() -> TerminalPanel {
        let panel = TerminalPanel(workspaceId: UUID(), runtimeSpawnPolicy: .pacedSessionRestore)
        panel.surface.releaseHostedSurfaceForTesting()
        return panel
    }
}
