import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct CustomSidebarAgentSurfaceIdTests {
    @Test("an agent's surfaceId is its hosting tab's focusable surfaceId")
    func agentSurfaceIdMatchesHostingTab() throws {
        let previousTranscriptService = TerminalController.shared.agentChatTranscriptService
        let registry = AgentChatSessionRegistry()
        TerminalController.shared.agentChatTranscriptService = AgentChatTranscriptService(
            registry: registry,
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.agentChatTranscriptService = previousTranscriptService
        }
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: "custom-sidebar-agent-surface",
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelId.uuidString,
            receivedAt: Date(timeIntervalSince1970: 1)
        ))

        let snapshot = workspace.customSidebarWorkspaceSnapshot(
            index: 0, selectedId: workspace.id, unreadCount: 0
        )
        let tab = try #require(snapshot.surfaces.first { $0.panelId == panelId })
        let agent = try #require(snapshot.agents.first)
        #expect(agent.panelId == panelId)
        #expect(agent.surfaceId == tab.surfaceId)
        // surface.focus looks the id up in the workspace's panels.
        let surfaceId = try #require(agent.surfaceId)
        #expect(workspace.panels[surfaceId] != nil)
    }
}
