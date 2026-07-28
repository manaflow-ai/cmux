import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent session retry interactions", .serialized)
struct AgentSessionRetryInteractionTests {
    @MainActor
    @Test("explicit terminal input cancels a retry before it can share the prompt")
    func explicitInputCancelsScheduledRetry() throws {
        let fixture = try scheduledRetry(suiteName: "AgentSessionRetryInteractionTests.input")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = try #require(fixture.workspace.panels[fixture.panelId] as? TerminalPanel)

        panel.surface.didReceiveExplicitInput()

        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    @Test("explicit input at an ended prompt invalidates unclassified retry ownership")
    func explicitInputInvalidatesEndedRunBeforeClassification() throws {
        let suiteName = "AgentSessionRetryInteractionTests.unclassifiedInput"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)
        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(
            managedBinding(sessionId: "ended-before-input"),
            panelId: panelId
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        panel.surface.didReceiveExplicitInput()
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)] == nil)
    }

    @MainActor
    @Test("moving an active managed run preserves retry ownership")
    func activeRunTransferPreservesRetryOwnership() throws {
        let suiteName = "AgentSessionRetryInteractionTests.transfer"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)
        let source = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let destination = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(source.focusedPanelId)
        let binding = managedBinding(sessionId: "moved-active-run")
        source.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(source.setSurfaceResumeBinding(binding, panelId: panelId))
        source.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let transfer = try #require(source.detachSurface(panelId: panelId))
        #expect(transfer.agentSessionRetryCompletedAttempts == 0)
        let destinationPaneId = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(
            transfer,
            inPane: destinationPaneId,
            focus: false
        ) == panelId)

        destination.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        destination.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(destination.statusEntries[retryStatusKey(panelId: panelId)]?.icon == "arrow.clockwise")
        destination.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    private func scheduledRetry(
        suiteName: String
    ) throws -> (
        workspace: Workspace,
        defaults: UserDefaults,
        panelId: UUID,
        statusKey: String,
        suiteName: String
    ) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)
        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(
            managedBinding(sessionId: "input-cancelled-retry"),
            panelId: panelId
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)
        let statusKey = retryStatusKey(panelId: panelId)
        #expect(workspace.statusEntries[statusKey]?.icon == "arrow.clockwise")
        return (workspace, defaults, panelId, statusKey, suiteName)
    }

    private func retryStatusKey(panelId: UUID) -> String {
        "agent.auto_retry.\(panelId.uuidString.lowercased())"
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
