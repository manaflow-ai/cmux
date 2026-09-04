import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationPlannerSwiftTests {
    @Test
    func idleAntigravityLifecycleIsEligibleForHibernation() {
        #expect(AgentHibernationLifecycleStatusKeys.isAllowed("antigravity"))
        #expect(AgentHibernationLifecycleState.idle.allowsHibernation)

        let workspaceId = UUID()
        let antigravityKey = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let runningKey = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 5,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                AgentHibernationPlannerInput(
                    key: antigravityKey,
                    hasRestorableAgent: true,
                    isLive: true,
                    hasLiveProcess: true,
                    processSafetyAllowsHibernation: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: 0
                ),
                AgentHibernationPlannerInput(
                    key: runningKey,
                    hasRestorableAgent: true,
                    isLive: true,
                    hasLiveProcess: true,
                    processSafetyAllowsHibernation: true,
                    isProtected: false,
                    lifecycle: .running,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: 0
                ),
            ],
            settings: settings,
            now: 100
        )
        #expect(selected == Set([antigravityKey]))
    }
}
