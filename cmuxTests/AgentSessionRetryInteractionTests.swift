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
    @Test("a retry command start owns its generation before fresh hooks arrive")
    func retryStartBeforeHooksRetainsOwnership() throws {
        let fixture = try scheduledRetry(
            suiteName: "AgentSessionRetryInteractionTests.startBeforeHooks"
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: fixture.panelId
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .awaitingLaunch(attempt: 1, maximumAttempts: 3)
        )

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .running(attempt: 1, maximumAttempts: 3)
        )
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        let expectedStatus = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.status.retrying",
                defaultValue: "Retrying agent (attempt %lld/%lld)…"
            ),
            Int64(2),
            Int64(3)
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .waiting(attempt: 2, maximumAttempts: 3, exitCode: 1)
        )
        #expect(fixture.workspace.statusEntries[fixture.statusKey]?.value == expectedStatus)
        fixture.workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("a retry failure before start hooks advances the bounded retry budget")
    func retryFailureBeforeStartHooksAdvancesBudget() throws {
        let fixture = try scheduledRetry(
            suiteName: "AgentSessionRetryInteractionTests.failureBeforeStartHooks"
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: fixture.panelId
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .awaitingLaunch(attempt: 1, maximumAttempts: 3)
        )
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle
        )

        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        let expectedStatus = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.status.retrying",
                defaultValue: "Retrying agent (attempt %lld/%lld)…"
            ),
            Int64(2),
            Int64(3)
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .waiting(attempt: 2, maximumAttempts: 3, exitCode: 1)
        )
        #expect(fixture.workspace.statusEntries[fixture.statusKey]?.value == expectedStatus)
        fixture.workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("an unacknowledged retry launch expires and cannot claim a later command")
    func unacknowledgedLaunchExpires() throws {
        let fixture = try scheduledRetry(
            suiteName: "AgentSessionRetryInteractionTests.launchDeadline"
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: fixture.panelId
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .awaitingLaunch(attempt: 1, maximumAttempts: 3)
        )

        fixture.workspace.agentSessionRetryCoordinator.retryLaunchAcknowledgementDeadlineFired(
            panelId: fixture.panelId
        )
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        #expect(fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId] == nil)
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    @Test("explicit input cancels an accepted retry before launch acknowledgement")
    func explicitInputCancelsAwaitingLaunch() throws {
        let fixture = try scheduledRetry(
            suiteName: "AgentSessionRetryInteractionTests.awaitingInput"
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = try #require(fixture.workspace.panels[fixture.panelId] as? TerminalPanel)
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .awaitingLaunch(attempt: 1, maximumAttempts: 3)
        )

        panel.surface.didReceiveExplicitInput()

        #expect(fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId] == nil)
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    @Test("same-session hooks acknowledge a retry and clear its retrying status")
    func sameSessionHooksAcknowledgeLaunch() throws {
        let fixture = try scheduledRetry(
            suiteName: "AgentSessionRetryInteractionTests.hookAck"
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let binding = managedBinding(sessionId: "input-cancelled-retry")
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)

        #expect(fixture.workspace.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .running(attempt: 1, maximumAttempts: 3)
        )
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .unknown
        )

        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .running(attempt: 1, maximumAttempts: 3)
        )
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        #expect(fixture.workspace.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            agentSessionEnded: true
        ))
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle
        )
        #expect(fixture.workspace.clearAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId
        ))
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 0
        )

        #expect(fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId] == nil)
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    @Test("prompt-idle binding cleanup preserves the ended command for classification")
    func bindingOnlyCleanupPreservesEndedCandidate() throws {
        let suiteName = "AgentSessionRetryInteractionTests.bindingCleanup"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)
        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "binding-only-cleanup")
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .observedAgentCommandRunning

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)]?.icon == "arrow.clockwise")
        workspace.agentSessionRetryCoordinator.cancelAll()
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
