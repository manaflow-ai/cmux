import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox Escape passthrough", .serialized)
struct TextBoxEscapePassthroughTests {
    @Test
    func runningAgentReceivesEscapeFromTextBox() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        defer { closeWindow(windowID) }

        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))

        panel.showTextBoxInputWhenAvailable()
        panel.surface.releaseSurfaceForTesting()
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panel.id,
            lifecycle: .running
        )
        defer {
            _ = workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id)
        }
        let before = panel.surface.debugPendingSocketInputForTesting()

        panel.handleTextBoxEscape()

        let after = panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape from TextBox must reach the PTY while the focused agent turn is running"
        )
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
