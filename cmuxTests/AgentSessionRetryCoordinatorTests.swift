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
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
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
    @Test("classified failure remains scheduled across late lifecycle teardown")
    func classifiedFailureSurvivesLateLifecycleTeardown() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.lateTeardown"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "retry-before-late-teardown")
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)
        let retryStatusKey = "agent.auto_retry.\(panelId.uuidString.lowercased())"
        #expect(workspace.statusEntries[retryStatusKey]?.icon == "arrow.clockwise")

        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))

        #expect(workspace.statusEntries[retryStatusKey]?.icon == "arrow.clockwise")
        workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("a new shell command cancels a scheduled retry")
    func newShellCommandCancelsScheduledRetry() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.newCommandAfterFailure"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "retry-cancelled-by-new-command")
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)
        let retryStatusKey = "agent.auto_retry.\(panelId.uuidString.lowercased())"
        #expect(workspace.statusEntries[retryStatusKey]?.icon == "arrow.clockwise")

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        #expect(workspace.statusEntries[retryStatusKey] == nil)
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
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
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
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
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
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .idle)
        #expect(workspace.clearAgentLifecycle(key: "claude_code", panelId: panelId))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        let retryStatusKey = "agent.auto_retry.\(panelId.uuidString.lowercased())"
        #expect(workspace.statusEntries[retryStatusKey]?.icon == "arrow.clockwise")
        workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("active retry phases refresh matching bindings and reject replacement sessions")
    func activeRetryPhasesValidateManagedSessionIdentity() throws {
        let phases: [(name: String, phase: AgentSessionRetryPanelState.Phase)] = [
            ("awaitingLaunch", .awaitingLaunch(attempt: 1, maximumAttempts: 3)),
            ("running", .running(attempt: 1, maximumAttempts: 3)),
        ]

        for phaseCase in phases {
            let matchingWorkspace = Workspace()
            let matchingPanelId = try #require(matchingWorkspace.focusedPanelId)
            let originalBinding = managedBinding(sessionId: "\(phaseCase.name)-same")
            let refreshedBinding = managedBinding(
                sessionId: "\(phaseCase.name)-same",
                command: "claude --resume \(phaseCase.name)-same --updated",
                updatedAt: 1_888_888_888
            )
            let matchingCoordinator = matchingWorkspace.agentSessionRetryCoordinator
            matchingCoordinator.statesByPanelId[matchingPanelId] = .init(
                completedAttempts: 1,
                binding: originalBinding,
                commandGeneration: 7,
                phase: phaseCase.phase,
                timer: nil
            )

            #expect(matchingWorkspace.setSurfaceResumeBinding(
                refreshedBinding,
                panelId: matchingPanelId
            ))
            let refreshedState = try #require(
                matchingCoordinator.statesByPanelId[matchingPanelId],
                "Matching \(phaseCase.name) binding must preserve recovery"
            )
            #expect(refreshedState.binding == refreshedBinding)
            #expect(
                refreshedState.phase == .running(attempt: 1, maximumAttempts: 3),
                "Matching \(phaseCase.name) binding must acknowledge or preserve active recovery"
            )

            let replacementWorkspace = Workspace()
            let replacementPanelId = try #require(replacementWorkspace.focusedPanelId)
            let replacementCoordinator = replacementWorkspace.agentSessionRetryCoordinator
            replacementCoordinator.statesByPanelId[replacementPanelId] = .init(
                completedAttempts: 1,
                binding: originalBinding,
                commandGeneration: 7,
                phase: phaseCase.phase,
                timer: nil
            )
            let replacementBinding = managedBinding(sessionId: "\(phaseCase.name)-replacement")

            #expect(replacementWorkspace.setSurfaceResumeBinding(
                replacementBinding,
                panelId: replacementPanelId
            ))
            #expect(
                replacementCoordinator.statesByPanelId[replacementPanelId] == nil,
                "Mismatched \(phaseCase.name) binding must fail closed before retry acknowledgement"
            )
            #expect(replacementCoordinator.managedRunsByPanelId[replacementPanelId] == nil)
        }
    }

    @MainActor
    @Test("a delayed command completion cannot retry a replacement session")
    func replacementSessionInvalidatesEndedCandidate() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.replacementSession"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let endedBinding = managedBinding(sessionId: "ended-session")
        let replacementBinding = managedBinding(sessionId: "replacement-session")
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(endedBinding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))

        #expect(workspace.setSurfaceResumeBinding(replacementBinding, panelId: panelId))
        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.surfaceResumeBinding(panelId: panelId) == replacementBinding)
        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)] == nil)
    }

    @MainActor
    @Test("a binding observed outside the current command cannot authorize retry")
    func bindingWithoutCommandOwnershipFailsClosed() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.noEndedCandidate"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let currentBinding = managedBinding(sessionId: "still-current")
        #expect(workspace.setSurfaceResumeBinding(currentBinding, panelId: panelId))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.surfaceResumeBinding(panelId: panelId) == currentBinding)
        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)] == nil)
    }

    @MainActor
    @Test("a nonzero managed agent exit retries without a SessionEnd hook")
    func nonzeroManagedExitWithoutSessionEndRetries() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.hardExit"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        let binding = managedBinding(sessionId: "hard-nonzero-exit")
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 1)

        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)]?.icon == "arrow.clockwise")
        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId, agentSessionEnded: true))
        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)]?.icon == "arrow.clockwise")
        workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("an intentional signal exit never retries")
    func signalExitDoesNotRetry() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.signalExit"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoRetrySettings.autoRetryAgentSessionsKey)

        let workspace = Workspace(
            agentSessionAutoRetrySettings: AgentSessionAutoRetrySettings(defaults: defaults)
        )
        let panelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(
            managedBinding(sessionId: "ctrl-c-exit"),
            panelId: panelId
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        workspace.agentSessionRetryCoordinator.commandFinished(panelId: panelId, exitCode: 130)

        #expect(workspace.statusEntries[retryStatusKey(panelId: panelId)] == nil)
    }

    @MainActor
    @Test("timer fire invalidates replacement ownership but waits for delayed idle signals")
    func timerFireRevalidatesPaneOwnership() throws {
        let activeLifecycle = try scheduledRetry(
            suiteName: "AgentSessionRetryCoordinatorTests.timerActiveLifecycle",
            sessionId: "active-lifecycle"
        )
        defer {
            activeLifecycle.defaults.removePersistentDomain(
                forName: "AgentSessionRetryCoordinatorTests.timerActiveLifecycle"
            )
        }
        activeLifecycle.workspace.agentLifecycleStatesByPanelId[activeLifecycle.panelId] = [
            "claude_code": .running,
        ]
        activeLifecycle.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: activeLifecycle.panelId
        )
        #expect(
            activeLifecycle.workspace.statusEntries[activeLifecycle.statusKey]?.icon ==
                "arrow.clockwise"
        )

        let replacementBinding = try scheduledRetry(
            suiteName: "AgentSessionRetryCoordinatorTests.timerReplacementBinding",
            sessionId: "binding-owner"
        )
        defer {
            replacementBinding.defaults.removePersistentDomain(
                forName: "AgentSessionRetryCoordinatorTests.timerReplacementBinding"
            )
        }
        replacementBinding.workspace.surfaceResumeBindingsByPanelId[replacementBinding.panelId] =
            managedBinding(sessionId: "new-binding-owner")
        replacementBinding.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: replacementBinding.panelId
        )
        #expect(replacementBinding.workspace.statusEntries[replacementBinding.statusKey] == nil)

        let runningShell = try scheduledRetry(
            suiteName: "AgentSessionRetryCoordinatorTests.timerRunningShell",
            sessionId: "running-shell"
        )
        defer {
            runningShell.defaults.removePersistentDomain(
                forName: "AgentSessionRetryCoordinatorTests.timerRunningShell"
            )
        }
        runningShell.workspace.panelShellActivityStates[runningShell.panelId] = .commandRunning
        runningShell.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: runningShell.panelId
        )
        #expect(runningShell.workspace.statusEntries[runningShell.statusKey]?.icon == "arrow.clockwise")

        let unknownShell = try scheduledRetry(
            suiteName: "AgentSessionRetryCoordinatorTests.timerUnknownShell",
            sessionId: "unknown-shell"
        )
        defer {
            unknownShell.defaults.removePersistentDomain(
                forName: "AgentSessionRetryCoordinatorTests.timerUnknownShell"
            )
        }
        unknownShell.workspace.panelShellActivityStates[unknownShell.panelId] = .unknown
        unknownShell.workspace.agentSessionRetryCoordinator.retryTimerFired(
            panelId: unknownShell.panelId
        )
        #expect(unknownShell.workspace.statusEntries[unknownShell.statusKey]?.icon == "arrow.clockwise")

        activeLifecycle.workspace.agentSessionRetryCoordinator.cancelAll()
        replacementBinding.workspace.agentSessionRetryCoordinator.cancelAll()
        runningShell.workspace.agentSessionRetryCoordinator.cancelAll()
        unknownShell.workspace.agentSessionRetryCoordinator.cancelAll()
    }

    @MainActor
    @Test("disabling auto-retry immediately cancels scheduled recovery")
    func disablingCancelsScheduledRecovery() throws {
        let suiteName = "AgentSessionRetryCoordinatorTests.settingDisabled"
        let notificationCenter = NotificationCenter()
        let fixture = try scheduledRetry(
            suiteName: suiteName,
            sessionId: "disabled-while-waiting",
            notificationCenter: notificationCenter
        )
        defer { fixture.defaults.removePersistentDomain(forName: suiteName) }
        let settings = AgentSessionAutoRetrySettings(
            defaults: fixture.defaults,
            notificationCenter: notificationCenter
        )

        settings.setEnabled(false)

        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
        settings.setEnabled(true)
        fixture.workspace.agentSessionRetryCoordinator.retryTimerFired(panelId: fixture.panelId)
        #expect(fixture.workspace.statusEntries[fixture.statusKey] == nil)
    }

    @MainActor
    private func scheduledRetry(
        suiteName: String,
        sessionId: String,
        notificationCenter: NotificationCenter = .default
    ) throws -> (
        workspace: Workspace,
        defaults: UserDefaults,
        panelId: UUID,
        statusKey: String
    ) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AgentSessionAutoRetrySettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        settings.setEnabled(true)
        let workspace = Workspace(agentSessionAutoRetrySettings: settings)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.setSurfaceResumeBinding(
            managedBinding(sessionId: sessionId),
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
        return (workspace, defaults, panelId, statusKey)
    }

    private func retryStatusKey(panelId: UUID) -> String {
        "agent.auto_retry.\(panelId.uuidString.lowercased())"
    }

    private func managedBinding(
        sessionId: String,
        command: String? = nil,
        updatedAt: TimeInterval = 1_777_777_777
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Claude",
            kind: "claude",
            command: command ?? "claude --resume \(sessionId)",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: updatedAt
        )
    }
}
