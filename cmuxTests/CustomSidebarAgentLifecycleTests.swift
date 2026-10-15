import CmuxAgentChat
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class CustomSidebarDockTestPanel: Panel {
    let objectWillChange = ObservableObjectPublisher()
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Custom sidebar lifecycle"

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

/// Covers the lifecycle projection that lets custom sidebars distinguish
/// pending background work from an idle agent session.
@MainActor
@Suite
struct CustomSidebarAgentLifecycleTests {
    @Test("background work pending has a stable wire name")
    func backgroundWorkPendingWireName() {
        let lifecycle = Workspace.customSidebarAgentLifecycle(
            sessionID: "session",
            currentSessionID: "session",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: ["claude_code": .backgroundWorkPending],
            lifecycleSessionIDs: ["claude_code": "session"]
        )
        #expect(lifecycle == "background_work_pending")
    }

    @Test("all lifecycle phases map to their custom-sidebar wire names")
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
                sessionID: "session",
                currentSessionID: "session",
                state: .working(since: Date(timeIntervalSince1970: 1)),
                agentSource: "codex",
                panelLifecycles: ["codex": phase],
                lifecycleSessionIDs: ["codex": "session"]
            )
            #expect(lifecycle == expected[phase])
        }
    }

    @Test("lifecycle lookup uses the same provider key as the built-in sidebar")
    func readsAgentStatusKey() {
        let panelLifecycles: [String: AgentHibernationLifecycleState] = [
            "claude_code": .needsInput,
            "codex": .running,
        ]

        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "session",
            currentSessionID: "session",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: panelLifecycles,
            lifecycleSessionIDs: ["claude_code": "session"]
        ) == "needs_input")
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "session",
            currentSessionID: "session",
            state: .idle,
            agentSource: "codex",
            panelLifecycles: panelLifecycles,
            lifecycleSessionIDs: ["codex": "session"]
        ) == "running")
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "session",
            currentSessionID: "session",
            state: .idle,
            agentSource: "opencode",
            panelLifecycles: panelLifecycles
        ) == nil)
    }

    @Test("ended sessions and unbound panels omit lifecycle")
    func endedOrUnboundOmitted() {
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "ended",
            currentSessionID: "ended",
            state: .ended,
            agentSource: "claude",
            panelLifecycles: ["claude_code": .running],
            lifecycleSessionIDs: ["claude_code": "ended"]
        ) == nil)
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "unbound",
            currentSessionID: "unbound",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: nil,
            lifecycleSessionIDs: nil
        ) == nil)
    }

    @Test("panel lifecycle set by the workspace is projected")
    func projectsWorkspacePanelLifecycle() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panelId,
            lifecycle: .backgroundWorkPending,
            sessionID: "session"
        )

        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "session",
            currentSessionID: "session",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: workspace.agentLifecycleStatesByPanelId[panelId],
            lifecycleSessionIDs: workspace.agentLifecycleSessionIDsByPanelId[panelId]
        ) == "background_work_pending")
    }

    @Test("an older live record does not inherit the newer session lifecycle")
    func olderSessionDoesNotInheritLifecycle() {
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "old-session",
            currentSessionID: "new-session",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: ["claude_code": .backgroundWorkPending]
        ) == nil)
    }

    @Test("a current session does not inherit an older lifecycle entry")
    func currentSessionDoesNotInheritOlderLifecycle() {
        #expect(Workspace.customSidebarAgentLifecycle(
            sessionID: "new-session",
            currentSessionID: "new-session",
            state: .idle,
            agentSource: "claude",
            panelLifecycles: ["claude_code": .backgroundWorkPending],
            lifecycleSessionIDs: ["claude_code": "old-session"]
        ) == nil)
    }

    @Test("Dock lifecycle ownership survives the panel owner routing")
    func dockOwnerPreservesSessionID() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = CustomSidebarDockTestPanel()
        dock.panels[panel.id] = panel

        ControlSidebarPanelOwner.dock(dock).setAgentLifecycle(
            key: "claude_code",
            panelId: panel.id,
            lifecycle: .backgroundWorkPending,
            sessionID: "session"
        )

        let runtime = try #require(dock.agentRuntimeByPanelId[panel.id])
        #expect(runtime.agentLifecycleStates["claude_code"] == .backgroundWorkPending)
        #expect(runtime.agentLifecycleSessionIDs["claude_code"] == "session")
    }
}
