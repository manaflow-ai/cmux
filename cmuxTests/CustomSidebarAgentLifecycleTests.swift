import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `agents[j].lifecycle` exposes the panel's journal lifecycle so a custom
/// sidebar can tell a finished turn with pending background work apart from
/// an idle one, which `agents[j].status` cannot express.
@MainActor
@Suite
struct CustomSidebarAgentLifecycleTests {
    @Test("background work pending is exposed while status stays backward compatible")
    func backgroundWorkPendingWireName() {
        let lifecycle = Workspace.customSidebarAgentLifecycle(
            state: .idle,
            agentSource: "claude",
            isCurrentPanelSession: true,
            panelLifecycles: ["claude_code": .backgroundWorkPending]
        )
        #expect(lifecycle == "background_work_pending")
    }

    @Test("every lifecycle phase maps to a snake_case wire name")
    func everyPhaseHasWireName() {
        let expected: [AgentHibernationLifecycleState: String] = [
            .unknown: "unknown",
            .running: "running",
            .backgroundWorkPending: "background_work_pending",
            .needsInput: "needs_input",
            .idle: "idle",
        ]
        for phase in AgentHibernationLifecycleState.allCases {
            let lifecycle = Workspace.customSidebarAgentLifecycle(
                state: .working(since: Date(timeIntervalSince1970: 1)),
                agentSource: "codex",
                isCurrentPanelSession: true,
                panelLifecycles: ["codex": phase]
            )
            #expect(lifecycle == expected[phase])
        }
    }

    @Test("lifecycle is read under the agent's own status key")
    func readsAgentStatusKey() {
        let panelLifecycles: [String: AgentHibernationLifecycleState] = [
            "claude_code": .needsInput,
            "codex": .running,
        ]
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "claude", isCurrentPanelSession: true, panelLifecycles: panelLifecycles
        ) == "needs_input")
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "codex", isCurrentPanelSession: true, panelLifecycles: panelLifecycles
        ) == "running")
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "opencode", isCurrentPanelSession: true, panelLifecycles: panelLifecycles
        ) == nil)
    }

    @Test("ended sessions and unbound panels report no lifecycle")
    func endedOrUnboundOmitted() {
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .ended, agentSource: "claude", isCurrentPanelSession: true, panelLifecycles: ["claude_code": .running]
        ) == nil)
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "claude", isCurrentPanelSession: true, panelLifecycles: nil
        ) == nil)
    }

    @Test("the lifecycle the journal sets on a panel is the one projected")
    func projectsWorkspacePanelLifecycle() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.customSidebarWorkspaceSnapshot(
            index: 0, selectedId: workspace.id, unreadCount: 0
        ).surfaces.first?.panelId)

        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .backgroundWorkPending)

        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle,
            agentSource: "claude",
            isCurrentPanelSession: true,
            panelLifecycles: workspace.agentLifecycleStatesByPanelId[panelId]
        ) == "background_work_pending")
    }

    @Test("a record that is not its panel's current session reports no lifecycle")
    func nonCurrentSessionOmitted() {
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle,
            agentSource: "claude",
            isCurrentPanelSession: false,
            panelLifecycles: ["claude_code": .backgroundWorkPending]
        ) == nil)
    }

    @Test("two live sessions of one agent on a panel: only the current one gets the lifecycle")
    func olderSessionOnSamePanelDoesNotBorrowLifecycle() throws {
        let registry = AgentChatSessionRegistry()
        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let olderID = UUID().uuidString
        let newerID = UUID().uuidString
        for (sessionID, offset) in [(olderID, 0.0), (newerID, 10.0)] {
            _ = registry.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .sessionStart,
                source: "codex",
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset)
            ))
        }
        let older = try #require(registry.record(sessionID: olderID))
        let newer = try #require(registry.record(sessionID: newerID))
        #expect(older.state != .ended)
        #expect(newer.state != .ended)
        let liveSessionID = try #require(registry.liveSession(surfaceID: surfaceID)?.sessionID)
        #expect(liveSessionID == newerID)

        let panelLifecycles: [String: AgentHibernationLifecycleState] = ["codex": .backgroundWorkPending]
        let lifecycles = [older, newer].map { record in
            Workspace.customSidebarAgentLifecycle(
                state: record.state,
                agentSource: record.agentKind.sourceName,
                isCurrentPanelSession: record.sessionID == liveSessionID,
                panelLifecycles: panelLifecycles
            )
        }
        #expect(lifecycles == [nil, "background_work_pending"])
    }
}
