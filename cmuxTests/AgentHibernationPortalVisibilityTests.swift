import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct AgentHibernationPortalVisibilityTests {
    @Test func showingAutoResumePresentationDoesNotRestoreNonHibernatedTerminalPortal() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))

        #expect(!panel.isAgentHibernated)
        panel.hostedView.setVisibleInUI(false)
        #expect(!panel.hostedView.debugPortalVisibleInUI)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        #expect(!panel.hostedView.debugPortalVisibleInUI)
    }
}
