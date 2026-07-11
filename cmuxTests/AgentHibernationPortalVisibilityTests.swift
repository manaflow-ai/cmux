import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct AgentHibernationPortalVisibilityTests {
    @Test func workspacePresentationRemainsVisibleUntilEveryHostDisappears() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let firstHost = UUID()
        let replacementHost = UUID()

        workspace.setContentViewPresentationVisibility(
            isVisible: true,
            isInputActive: true,
            hostId: firstHost
        )
        workspace.setContentViewPresentationVisibility(
            isVisible: true,
            isInputActive: true,
            hostId: replacementHost
        )
        workspace.setContentViewPresentationVisibility(
            isVisible: false,
            isInputActive: false,
            hostId: firstHost
        )

        #expect(workspace.portalPresentationVisible)
        #expect(workspace.agentHibernationVisiblePanelIdsForCurrentLayout().contains(panelId))

        workspace.setContentViewPresentationVisibility(
            isVisible: false,
            isInputActive: false,
            hostId: replacementHost
        )

        #expect(!workspace.portalPresentationVisible)
        #expect(workspace.agentHibernationVisiblePanelIdsForCurrentLayout().isEmpty)
    }

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
