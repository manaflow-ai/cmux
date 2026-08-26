import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationTerminationFailureTests {
    @Test(arguments: [Int32?.none, Int32(EPERM)])
    func escalationFailureOrPostKillDeadlineFailsClosed(signalError: Int32?) async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let processExit = AsyncStream<Void>.makeStream()

        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitAfterEscalation(
                [.init(processID: 101, processIdentity: identity, processGroupID: 1)],
                gracePeriod: .zero,
                postKillExitPeriod: .zero,
                waitForExit: { _ in
                    for await _ in processExit.stream { return true }
                    return false
                },
                sleepUntilDeadline: { _ in true },
                processIdentityProvider: { _ in identity },
                signalErrorProvider: { _, _ in signalError }
            )

        #expect(didExit == false)
        processExit.continuation.finish()
    }

    @Test
    func emptyRefreshDoesNotProveOriginalGenerationExited() async {
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let processExit = AsyncStream<Void>.makeStream()

        let didExit = await AgentHibernationController
            .waitForScopedProcessGenerationsToExitAfterEscalation(
                [
                    .init(
                        processID: 101,
                        processIdentity: identity,
                        processGroupID: 101,
                        ttyDevice: 123
                    ),
                ],
                gracePeriod: .zero,
                waitForExit: { _ in
                    for await _ in processExit.stream { return true }
                    return false
                },
                sleepUntilDeadline: { _ in true },
                processIdentityProvider: { _ in identity },
                processGroupProvider: { _ in 101 },
                nextEpochProvider: { processGroupLeaders, _, _, _ in
                    AgentHibernationProcessExitEpoch(
                        terminations: [],
                        processGroupLeaders: processGroupLeaders
                    )
                }
            )

        #expect(didExit == false)
        processExit.continuation.finish()
    }

    @MainActor
    @Test
    func failedCommittedTerminationRecoversAfterExactExit() async {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("test-agent"),
            sessionId: "failed-termination",
            workingDirectory: "/tmp",
            launchCommand: nil
        )
        panel.beginAgentHibernationTermination(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let recoveryExit = AsyncStream<Void>.makeStream()
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [],
            waitForExit: { _ in false },
            waitForRecoveryExit: { _ in
                for await _ in recoveryExit.stream { return true }
                return false
            },
            onExit: { true },
            onFailure: {
                panel.beginAgentHibernationTerminationRecovery()
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            }
        )
        let observation = controller.committedTerminationObservationsByPanelID[panel.id]?.task

        await observation?.value

        #expect(panel.agentHibernationTerminationFailed == false)
        #expect(panel.isAgentHibernationCommitPending)
        #expect(panel.prepareAgentHibernationResume() == .unavailable)
        let recovery = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        #expect(recovery != nil)

        recoveryExit.continuation.yield()
        recoveryExit.continuation.finish()
        await recovery?.value

        #expect(panel.agentHibernationTerminationFailed == false)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
    }

    @MainActor
    @Test
    func failedTerminationKeepsRecoveryUntilNativeTeardownCompletes() async {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.beginAgentHibernationTermination(
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "delayed-native-teardown",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let nativeTeardownCompleted = AsyncStream<Void>.makeStream()
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [],
            waitForExit: { _ in false },
            waitForRecoveryExit: { _ in true },
            waitForRecoveryReadiness: {
                for await _ in nativeTeardownCompleted.stream { return true }
                return false
            },
            onExit: { true },
            onFailure: {
                panel.beginAgentHibernationTerminationRecovery()
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            }
        )
        let initialObservation =
            controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await initialObservation?.value

        #expect(panel.agentHibernationTerminationFailed == false)
        #expect(panel.isAgentHibernationCommitPending)
        let recovery = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        #expect(recovery != nil)

        nativeTeardownCompleted.continuation.yield()
        nativeTeardownCompleted.continuation.finish()
        await recovery?.value

        #expect(panel.isAgentHibernated)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
    }

    @MainActor
    @Test
    func failedNoProcessRecoveryRetrySkipsExitWaitAndSucceeds() async {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.beginAgentHibernationTermination(
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "retryable-recovery",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let readinessAttempts = OSAllocatedUnfairLock(initialState: 0)
        let terminationRetryCount = OSAllocatedUnfairLock(initialState: 0)
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [],
            waitForExit: { _ in false },
            waitForRecoveryExit: { _ in true },
            retryTermination: {
                terminationRetryCount.withLock { $0 += 1 }
                return .exited
            },
            waitForRecoveryReadiness: {
                readinessAttempts.withLock {
                    $0 += 1
                    return $0 > 1
                }
            },
            onExit: { true },
            onFailure: {
                panel.beginAgentHibernationTerminationRecovery()
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            },
            onRecoveryFailure: {
                panel.failAgentHibernationTermination()
            },
            onRecoveryRetry: {
                panel.beginAgentHibernationTerminationRecovery()
            }
        )
        let initial = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await initial?.value
        let failedRecovery =
            controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await failedRecovery?.value

        #expect(panel.agentHibernationTerminationFailed)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] != nil)

        controller.retryCommittedTerminationRecovery(panelID: panel.id)
        let retry = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await retry?.value

        #expect(panel.isAgentHibernated)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
        #expect(terminationRetryCount.withLock { $0 } == 1)
    }

    @MainActor
    @Test
    func recoveryDeadlineExposesRetryableFailure() async {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.beginAgentHibernationTermination(
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "recovery-deadline",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let readiness = AsyncStream<Void>.makeStream()
        controller.observeCommittedTermination(
            panelID: panel.id,
            terminations: [],
            waitForExit: { _ in false },
            waitForRecoveryReadiness: {
                for await _ in readiness.stream { return true }
                return false
            },
            recoveryDeadline: .zero,
            sleepUntilRecoveryDeadline: { _ in true },
            onExit: { true },
            onFailure: {
                panel.beginAgentHibernationTerminationRecovery()
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            },
            onRecoveryFailure: {
                panel.failAgentHibernationTermination()
            }
        )
        let initial = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await initial?.value
        let recovery = controller.committedTerminationObservationsByPanelID[panel.id]?.task
        await recovery?.value

        #expect(panel.agentHibernationTerminationFailed)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] != nil)
        readiness.continuation.finish()
    }

    @MainActor
    @Test
    func recoveredFailureRunsWorkspaceHibernationCommit() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        defer { panel.close() }
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "recovered-workspace-commit",
            workingDirectory: "/tmp",
            launchCommand: nil
        )
        try #require(agent.resumeCommand != nil)
        panel.beginAgentHibernationTermination(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        panel.beginAgentHibernationTerminationRecovery()
        panel.failAgentHibernationTermination()
        workspace.restoredAgentLifecycle.setResumeState(.completedAgentExit, panelId: panelID)

        workspace.enterAgentHibernation(
            panelId: panelID,
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )

        #expect(panel.agentHibernationTerminationFailed == false)
        #expect(panel.isAgentHibernated)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId == agent.sessionId)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelID] == .manualResumeAvailable)
    }

    @MainActor
    @Test
    func unknownProcessAbsenceIsUnsafeForPressureTeardown() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let record = AgentHibernationRecord(
            key: .init(workspaceId: workspace.id, panelId: panelID),
            workspace: workspace,
            terminalPanel: panel,
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "unknown-process-evidence",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: false,
            containsUnrelatedProcess: false,
            panelProcessIDs: [],
            processIDs: [],
            processIdentities: [:]
        )

        #expect(record.hasPressureSafeProcessEvidence == false)
        #expect(record.processSafetyAllowsHibernation(for: .systemMemoryPressure))
    }
}
