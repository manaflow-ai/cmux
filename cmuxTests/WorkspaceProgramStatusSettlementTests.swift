import CMUXAgentLaunch
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace program-status settlement", .serialized)
struct WorkspaceProgramStatusSettlementTests {
    /// An Esc interrupt sends no Stop. The workspace settles the pane from
    /// the program status going idle, and custom sidebars read
    /// `agents[].status` from the agent chat registry, so the registry has
    /// to end the same turn.
    @MainActor
    @Test func settlingFromProgramStatusEndsTheAgentChatTurn() throws {
        let previousService = TerminalController.shared.agentChatTranscriptService
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        TerminalController.shared.agentChatTranscriptService = service
        defer { TerminalController.shared.agentChatTranscriptService = previousService }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let turnStart = Date(timeIntervalSince1970: 1_000)
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelId.uuidString,
            ppid: 123,
            receivedAt: turnStart
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        workspace.setStatusEntry(
            SidebarStatusEntry(key: "claude_code", value: "Running", timestamp: turnStart, workState: .running),
            key: "claude_code",
            panelId: panelId
        )
        #expect(service.sessionRecord(sessionID: sessionID)?.state == .working(since: turnStart))

        workspace.settleAgentTurnFromProgramStatus(
            key: "claude_code",
            panelId: panelId,
            edge: Date(timeIntervalSince1970: 1_010)
        )

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["claude_code"] == .idle)
        #expect(service.sessionRecord(sessionID: sessionID)?.state == .idle)
    }
}
