import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent session retry event ordering", .serialized)
struct AgentSessionRetryOrderingTests {
    enum HookPublicationOrder: CaseIterable, Sendable, CustomTestStringConvertible {
        case bindingThenLifecycle
        case lifecycleThenBinding

        var testDescription: String {
            switch self {
            case .bindingThenLifecycle:
                "binding then lifecycle"
            case .lifecycleThenBinding:
                "lifecycle then binding"
            }
        }
    }

    @MainActor
    @Test(
        "hook-first managed starts retain ownership when the shell generation arrives",
        arguments: HookPublicationOrder.allCases
    )
    func hookFirstStartRetainsOwnership(order: HookPublicationOrder) throws {
        let fixture = try makeFixture(suffix: order.testDescription)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let binding = managedBinding(sessionId: "hook-first-\(order.testDescription)")

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        publishHooks(
            order: order,
            binding: binding,
            workspace: fixture.workspace,
            panelId: fixture.panelId
        )
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )

        endManagedRun(
            binding: binding,
            workspace: fixture.workspace,
            panelId: fixture.panelId
        )
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        #expect(fixture.workspace.statusEntries[fixture.statusKey]?.icon == "arrow.clockwise")
        fixture.workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("explicit input cancels a hook-first start before its shell generation")
    func explicitInputCancelsHookFirstStart() throws {
        let fixture = try makeFixture(suffix: "explicit-input")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let binding = managedBinding(sessionId: "hook-first-explicit-input")
        let panel = try #require(fixture.workspace.panels[fixture.panelId] as? TerminalPanel)

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        publishHooks(
            order: .bindingThenLifecycle,
            binding: binding,
            workspace: fixture.workspace,
            panelId: fixture.panelId
        )
        panel.surface.didReceiveExplicitInput()
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )

        endManagedRun(
            binding: binding,
            workspace: fixture.workspace,
            panelId: fixture.panelId
        )
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    @Test("backoff expiry waits for authoritative teardown and preserves the retry budget")
    func backoffExpiryWaitsForTeardown() throws {
        let fixture = try makeFixture(suffix: "late-teardown")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let binding = managedBinding(sessionId: "late-teardown")

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        #expect(fixture.workspace.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running
        )
        #expect(fixture.workspace.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            agentSessionEnded: true
        ))
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )

        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)
        #expect(fixture.workspace.statusEntries[fixture.statusKey]?.icon == "arrow.clockwise")
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .ready(attempt: 1, maximumAttempts: 3)
        )

        finishLifecycleTeardown(workspace: fixture.workspace, panelId: fixture.panelId)
        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .promptIdle
        )
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .awaitingLaunch(attempt: 1, maximumAttempts: 3)
        )

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        #expect(fixture.workspace.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running
        )
        endManagedRun(
            binding: binding,
            workspace: fixture.workspace,
            panelId: fixture.panelId
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
        #expect(fixture.workspace.statusEntries[fixture.statusKey]?.value == expectedStatus)
        fixture.workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("retry readiness deadline abandons a pane that never becomes idle")
    func readinessDeadlineAbandonsRetry() throws {
        let fixture = try makeFixture(suffix: "readiness-deadline")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let binding = managedBinding(sessionId: "readiness-deadline")

        fixture.workspace.updatePanelShellActivityState(
            panelId: fixture.panelId,
            state: .commandRunning
        )
        #expect(fixture.workspace.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running
        )
        #expect(fixture.workspace.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            agentSessionEnded: true
        ))
        fixture.workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: fixture.panelId,
            exitCode: 1
        )
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)
        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId]?.phase ==
                .ready(attempt: 1, maximumAttempts: 3)
        )

        fixture.workspace.agentSessionRetryCoordinator.retryReadinessDeadlineFired(
            panelId: fixture.panelId
        )

        #expect(
            fixture.workspace.agentSessionRetryCoordinator.statesByPanelId[fixture.panelId] == nil
        )
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    private func publishHooks(
        order: HookPublicationOrder,
        binding: SurfaceResumeBindingSnapshot,
        workspace: Workspace,
        panelId: UUID
    ) {
        switch order {
        case .bindingThenLifecycle:
            #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
            workspace.setAgentLifecycle(
                key: "claude_code",
                panelId: panelId,
                lifecycle: .running
            )
        case .lifecycleThenBinding:
            workspace.setAgentLifecycle(
                key: "claude_code",
                panelId: panelId,
                lifecycle: .running
            )
            #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        }
    }

    @MainActor
    private func endManagedRun(
        binding: SurfaceResumeBindingSnapshot,
        workspace: Workspace,
        panelId: UUID
    ) {
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == binding)
        #expect(workspace.clearSurfaceResumeBinding(
            panelId: panelId,
            agentSessionEnded: true
        ))
        finishLifecycleTeardown(workspace: workspace, panelId: panelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
    }

    @MainActor
    private func finishLifecycleTeardown(workspace: Workspace, panelId: UUID) {
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panelId,
            lifecycle: .idle
        )
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
    }

    @MainActor
    private func makeFixture(
        suffix: String
    ) throws -> (
        workspace: Workspace,
        defaults: UserDefaults,
        panelId: UUID,
        statusKey: String,
        suiteName: String
    ) {
        let normalizedSuffix = suffix.replacingOccurrences(of: " ", with: "-")
        let suiteName = "AgentSessionRetryOrderingTests.\(normalizedSuffix)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)
        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        return (
            workspace,
            defaults,
            panelId,
            "agent.auto_retry.\(panelId.uuidString.lowercased())",
            suiteName
        )
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
