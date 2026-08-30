import Darwin
import Foundation
import os
import Testing
import CmuxWorkspaces

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
        #expect(record.processSafetyAllowsHibernation == false)
    }

    @Test
    func pressureTeardownRequiresFreshProcessEntry() {
        #expect(
            AgentHibernationController.memoryPressureTeardownAllowsProcessEntry(nil) == false
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("test-agent"),
            sessionId: "pressure-entry-evidence",
            workingDirectory: "/tmp",
            launchCommand: nil
        )
        func makeEntry(
            processLiveness: RestorableAgentProcessLiveness = .exited,
            processIDs: Set<Int> = [],
            terminationProcessIDs: Set<Int> = [],
            terminationProcessIdentities: [Int: AgentPIDProcessIdentity] = [:],
            containsUnrelatedProcess: Bool
        ) -> RestorableAgentSessionIndex.Entry {
            RestorableAgentSessionIndex.Entry(
                snapshot: snapshot,
                lifecycle: .idle,
                updatedAt: 0,
                provenance: .exactProcessBinding,
                processLiveness: processLiveness,
                processIDs: processIDs,
                processIdentities: terminationProcessIdentities,
                agentProcessIDs: processIDs,
                agentProcessIdentities: terminationProcessIdentities,
                hibernationPanelProcessIDs: processIDs,
                terminationProcessIDs: terminationProcessIDs,
                terminationProcessIdentities: terminationProcessIdentities,
                containsUnrelatedProcess: containsUnrelatedProcess
            )
        }

        #expect(
            AgentHibernationController.memoryPressureTeardownAllowsProcessEntry(
                makeEntry(containsUnrelatedProcess: false)
            )
        )
        #expect(
            AgentHibernationController.memoryPressureTeardownAllowsProcessEntry(
                makeEntry(
                    processLiveness: .unknown,
                    containsUnrelatedProcess: false
                )
            ) == false
        )
        let identity = AgentPIDProcessIdentity(pid: 101, startSeconds: 1, startMicroseconds: 0)
        #expect(
            AgentHibernationController.memoryPressureTeardownAllowsProcessEntry(
                makeEntry(
                    processLiveness: .running,
                    processIDs: [101],
                    terminationProcessIDs: [101],
                    terminationProcessIdentities: [101: identity],
                    containsUnrelatedProcess: false
                )
            )
        )
        #expect(
            AgentHibernationController.memoryPressureTeardownAllowsProcessEntry(
                makeEntry(containsUnrelatedProcess: true)
            ) == false
        )
    }

    @MainActor
    @Test
    func hibernationRecordsDoNotReusePanelIDFallbackForMovedLiveProcess() throws {
        let appDelegate = AppDelegate()
        let manager = TabManager()
        appDelegate.tabManager = manager
        defer { appDelegate.tabManager = nil }

        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "moved-live-process",
            workingDirectory: "/tmp",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        workspace.restoredAgentLifecycle.setSnapshot(snapshot, panelId: panelID)
        workspace.restoredAgentLifecycle.setResumeState(
            .manualResumeAvailable,
            panelId: panelID
        )

        let sourceWorkspaceID = UUID()
        let sourceKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: sourceWorkspaceID,
            panelId: panelID
        )
        let processID = 7_101
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: 42,
            startMicroseconds: 1
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                sourceKey: (
                    snapshot: snapshot,
                    updatedAt: 42,
                    processIDs: [processID],
                    agentProcessIDs: [processID],
                    sessionIDSource: .explicit
                ),
            ],
            hibernationProcessScopes: [
                sourceKey: (
                    panelProcessIDs: [processID],
                    terminationProcessIDs: [processID],
                    containsUnrelatedProcess: false
                ),
            ],
            processIdentityProvider: { requestedProcessID in
                requestedProcessID == processID ? identity : nil
            }
        )

        let record = try #require(
            appDelegate.agentHibernationRecords(
                index: index,
                activityByPanel: [:],
                terminalInputByPanel: [:],
                lifecycleChangeByPanel: [:]
            ).first { $0.key.panelId == panelID }
        )

        #expect(record.processSafetyAllowsHibernation == false)
    }

    @MainActor
    @Test
    func oversizedLiveProcessScopeIsNotEligibleForHibernation() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let processIDs = Set(
            1...(AgentHibernationController.maximumScopedProcessTerminationCount + 1)
        )
        let processIdentities = Dictionary(uniqueKeysWithValues: processIDs.map { processID in
            (
                processID,
                AgentPIDProcessIdentity(
                    pid: pid_t(processID),
                    startSeconds: Int64(processID),
                    startMicroseconds: 0
                )
            )
        })
        let record = AgentHibernationRecord(
            key: .init(workspaceId: workspace.id, panelId: panelID),
            workspace: workspace,
            terminalPanel: panel,
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "oversized-process-scope",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: true,
            containsUnrelatedProcess: false,
            panelProcessIDs: processIDs,
            processIDs: processIDs,
            processIdentities: processIdentities
        )

        #expect(record.hasPressureSafeProcessEvidence == false)
        #expect(!record.processSafetyAllowsHibernation)
    }

    @MainActor
    @Test
    func mismatchedProcessIdentityKeysAreNotEligibleForHibernation() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let processIDs: Set<Int> = [101, 102]
        let mismatchedIdentities = [
            101: AgentPIDProcessIdentity(pid: 101, startSeconds: 1, startMicroseconds: 0),
            999: AgentPIDProcessIdentity(pid: 999, startSeconds: 2, startMicroseconds: 0),
        ]
        let record = AgentHibernationRecord(
            key: .init(workspaceId: workspace.id, panelId: panelID),
            workspace: workspace,
            terminalPanel: panel,
            agent: .init(
                kind: .custom("test-agent"),
                sessionId: "mismatched-process-identities",
                workingDirectory: "/tmp",
                launchCommand: nil
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: true,
            containsUnrelatedProcess: false,
            panelProcessIDs: processIDs,
            processIDs: processIDs,
            processIdentities: mismatchedIdentities
        )
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: record.agent,
            lifecycle: .idle,
            updatedAt: 0,
            provenance: .exactProcessBinding,
            processLiveness: .running,
            processIDs: processIDs,
            processIdentities: mismatchedIdentities,
            agentProcessIDs: processIDs,
            agentProcessIdentities: mismatchedIdentities,
            hibernationPanelProcessIDs: processIDs,
            terminationProcessIDs: processIDs,
            terminationProcessIdentities: mismatchedIdentities,
            containsUnrelatedProcess: false
        )

        #expect(record.hasPressureSafeProcessEvidence == false)
        #expect(!record.processSafetyAllowsHibernation)
        #expect(!entry.processSafetyAllowsScheduledHibernation)
    }
}
