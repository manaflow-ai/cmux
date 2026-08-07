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
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "claude_code",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape from TextBox must reach the PTY while the focused agent turn is running"
        )
    }

    @Test
    func idleAgentDoesNotReceiveEscapeFromTextBox() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .idle
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "claude_code",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents,
            "Escape must retain TextBox focus behavior when the agent is not running"
        )
    }

    @Test
    func runningDockAgentReceivesEscapeFromTextBox() {
        let fixture = makeDockFixture()
        defer { fixture.dock.closeAllPanels() }

        fixture.dock.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape passthrough must follow a running agent into the Dock"
        )
    }

    @Test
    func manualDockActivityDoesNotReceiveEscapeFromTextBox() {
        let fixture = makeDockFixture()
        defer { fixture.dock.closeAllPanels() }

        fixture.dock.setAgentLifecycle(
            key: "manual:loader",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents,
            "Manual loading activity must not be treated as a running agent turn"
        )
    }

    private func makeWorkspaceFixture() throws -> (
        windowID: UUID,
        workspace: Workspace,
        panel: TerminalPanel
    ) {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        do {
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelID))

            panel.showTextBoxInputWhenAvailable()
            panel.surface.releaseSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func makeDockFixture() -> (
        dock: DockSplitStore,
        panel: TerminalPanel
    ) {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = TerminalPanel(
            workspaceId: dock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        dock.panels[panel.id] = panel
        panel.showTextBoxInputWhenAvailable()
        panel.surface.releaseSurfaceForTesting()
        return (dock, panel)
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
