import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An account switch replaces the pane's shell, so a pane with no Claude
/// session must be refused before anything is respawned.
@MainActor
@Suite(.serialized)
struct WorkspaceClaudeAccountSwitchTests {
    @Test
    func paneWithoutClaudeIsRefusedAndKeepsItsShell() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let originalPanel = try #require(workspace.terminalPanel(for: panelId))

        let result = await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: "work",
            trigger: .manual
        )

        #expect(result == .notClaude)
        #expect(workspace.terminalPanel(for: panelId) === originalPanel)
        #expect(workspace.currentClaudeAccount(panelId: panelId) == nil)
    }
}
