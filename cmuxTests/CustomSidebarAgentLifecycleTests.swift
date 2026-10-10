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
            state: .idle, agentSource: "claude", panelLifecycles: panelLifecycles
        ) == "needs_input")
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "codex", panelLifecycles: panelLifecycles
        ) == "running")
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "opencode", panelLifecycles: panelLifecycles
        ) == nil)
    }

    @Test("ended sessions and unbound panels report no lifecycle")
    func endedOrUnboundOmitted() {
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .ended, agentSource: "claude", panelLifecycles: ["claude_code": .running]
        ) == nil)
        #expect(Workspace.customSidebarAgentLifecycle(
            state: .idle, agentSource: "claude", panelLifecycles: nil
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
            panelLifecycles: workspace.agentLifecycleStatesByPanelId[panelId]
        ) == "background_work_pending")
    }
}
