import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentHibernationPlannerSwiftTests {
    @MainActor
    @Test
    func agentPIDMutationInvalidatesPendingHibernationTeardown() throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let baselineEpoch = controller.teardownValidationEpochByPanel[panelKey] ?? 0

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )
        let recordEpoch = try #require(controller.teardownValidationEpochByPanel[panelKey])
        #expect(recordEpoch == baselineEpoch + 1)

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.clearAgentPID(
            key: "codex.live-session",
            panelId: panelId,
            clearStatus: true,
            refreshPorts: false
        )
        #expect(controller.teardownValidationEpochByPanel[panelKey] == recordEpoch + 1)
    }

    @Test
    func liveScopedProcessCreatesPressureButIsNotSelected() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let runningAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let exitedAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(
                    key: runningAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    hasLiveProcess: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 300
                ),
                .init(
                    key: exitedAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 200
                ),
            ],
            settings: settings,
            now: now
        )

        #expect(selected == Set([exitedAgent]))
    }
}
