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

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "retry-after-teardown")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        #expect(workspace.managedAgentRetryBinding(panelId: panelId) == binding)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        #expect(!workspace.hasActiveAgentLifecycleForRetry(panelId: panelId))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        let retryStatusKey = "agent.auto_retry.\(panelId.uuidString.lowercased())"
        let status = try #require(workspace.statusEntries[retryStatusKey])
        let expectedStatus = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.status.retrying",
                defaultValue: "Retrying agent (attempt %lld/%lld)…"
            ),
            Int64(1),
            Int64(3)
        )
        #expect(status.key == retryStatusKey)
        #expect(status.value == expectedStatus)
        #expect(status.icon == "arrow.clockwise")
        #expect(status.priority == 200)
        #expect(workspace.statusEntries.keys.filter { $0.hasPrefix("agent.auto_retry.") } == [retryStatusKey])
        workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("ordinary resume binding clears fail closed")
    func ordinaryBindingClearCancelsCandidate() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentSessionRetryCoordinatorTests.cleared"))
        defer { defaults.removePersistentDomain(forName: "AgentSessionRetryCoordinatorTests.cleared") }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
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

    @MainActor
    @Test("a later shell command invalidates an unclassified ended session")
    func laterCommandInvalidatesEndedSession() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentSessionRetryCoordinatorTests.laterCommand"))
        defer { defaults.removePersistentDomain(forName: "AgentSessionRetryCoordinatorTests.laterCommand") }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "ended-before-later-command")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(!workspace.statusEntries.keys.contains {
            $0.hasPrefix("agent.auto_retry.")
        })
    }

    @MainActor
    @Test("a replayed running state does not invalidate the command awaiting classification")
    func duplicateRunningStateRetainsEndedSession() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.duplicateRunning"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "ended-before-running-replay")
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        let retryStatusKey = "agent.auto_retry.\(panelId.uuidString.lowercased())"
        #expect(workspace.statusEntries[retryStatusKey]?.icon == "arrow.clockwise")
        workspace.agentSessionRetryCoordinator.cancelAll()
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
