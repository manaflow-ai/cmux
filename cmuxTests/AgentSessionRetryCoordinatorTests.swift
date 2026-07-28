import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent session retry coordinator", .serialized)
struct AgentSessionRetryCoordinatorTests {
    @MainActor
    @Test("managed session teardown and idle retain the retry candidate until exit classification")
    func managedSessionTeardownRetainsCandidate() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentSessionRetryCoordinatorTests.retained"))
        defer { defaults.removePersistentDomain(forName: "AgentSessionRetryCoordinatorTests.retained") }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "retry-after-teardown")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        #expect(!workspace.hasActiveAgentLifecycleForRetry(panelId: panelId))
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.statusEntries.keys.contains {
            $0.hasPrefix("agent.auto_retry.")
        })
        workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("ordinary resume binding clears fail closed")
    func ordinaryBindingClearCancelsCandidate() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentSessionRetryCoordinatorTests.cleared"))
        defer { defaults.removePersistentDomain(forName: "AgentSessionRetryCoordinatorTests.cleared") }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            managedBinding(sessionId: "manual-clear"),
            panelId: panelId
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId))
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(!workspace.statusEntries.keys.contains {
            $0.hasPrefix("agent.auto_retry.")
        })
    }

    private func managedBinding(sessionId: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Claude",
            kind: "claude",
            command: "claude --resume \(sessionId)",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_777
        )
    }
}
