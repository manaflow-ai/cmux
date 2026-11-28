import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux agent hibernate` skips the idle delay, the live-terminal limit and the
/// confirmation window, and keeps every other safety check.
@MainActor
@Suite(.serialized)
struct AgentHibernationManualRequestTests {
    @Test
    func aVisibleAgentIsRefused() throws {
        #expect(try refusal(isProtected: true) == .visible)
    }

    @Test
    func aWorkingAgentIsRefused() throws {
        #expect(try refusal(lifecycle: .running) == .agentBusy)
        #expect(try refusal(lifecycle: .needsInput) == .agentBusy)
    }

    @Test
    func anAgentWithoutLifecycleReportsIsRefused() throws {
        #expect(try refusal(lifecycle: .unknown) == .lifecycleUnknown)
    }

    @Test
    func anAgentActiveMomentsAgoIsRefused() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let record = makeRecord(workspace: workspace, panel: panel, lastActivityAt: 1_000)
        #expect(AgentHibernationController.manualHibernationRefusal(for: record, teardownInFlight: false, now: 1_002) == .recentlyActive)
        #expect(AgentHibernationController.manualHibernationRefusal(for: record, teardownInFlight: false, now: 1_010) == .notRunning)
    }

    @Test
    func unconfirmedInputIsRefused() throws {
        #expect(try refusal(hasUnconfirmedTerminalInput: true) == .unconfirmedInput)
    }

    @Test
    func unrelatedProcessesAreRefused() throws {
        #expect(try refusal(containsUnrelatedProcess: true, liveness: .running) == .processScopeUnsafe)
        #expect(try refusal(liveness: .unknown) == .processScopeUnsafe)
    }

    @Test
    func aTeardownAlreadyInFlightIsReported() throws {
        #expect(try refusal(teardownInFlight: true) == .teardownInProgress)
    }

    @Test
    func anAlreadyHibernatedAgentIsReported() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.agentHibernationPhase = .hibernated(AgentHibernationPanelState(
            agent: agent(),
            hibernatedAt: Date(),
            lastActivityAt: Date()
        ))
        let record = makeRecord(workspace: workspace, panel: panel)
        #expect(AgentHibernationController.manualHibernationRefusal(for: record, teardownInFlight: false) == .alreadyHibernated)
    }

    @Test
    func anIdleOffscreenAgentPassesEverySafetyCheck() throws {
        // A unit-test terminal never starts its surface, so the last check
        // (a live terminal to free) is the one that answers here.
        #expect(try refusal() == .notRunning)
    }

    /// A manual request waits for its committed termination's exit
    /// observation, and answers hibernated once the pane settles there.
    @Test
    func aManualRequestWhoseExitObservationSucceedsReportsTheHibernation() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.beginAgentHibernationTermination(
            agent: agent(),
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        let requestID = controller.registerCommittedTerminationObservation(
            panelID: panel.id,
            processExitCompletion: processExitCompletion
        )
        controller.observeCommittedTermination(
            panelID: panel.id,
            requestID: requestID,
            terminations: [],
            processExitCompletion: processExitCompletion,
            waitForExit: { _ in true },
            onExit: {
                panel.completeAgentHibernationTermination()
                return true
            },
            onRecovery: {
                panel.completeAgentHibernationTermination()
            }
        )

        let hibernated = await controller.committedTerminationOutcome(
            trigger: .manual,
            panelID: panel.id,
            requestID: requestID,
            terminalPanel: panel
        )

        #expect(hibernated)
        #expect(panel.isAgentHibernated)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
    }

    /// When the first exit observation fails, recovery takes over the same
    /// request and can still hibernate the pane. The manual request waits for
    /// it and answers with the pane's settled phase, not with the handover.
    @Test
    func aManualRequestWaitsForRecoveryToSettleThePane() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.beginAgentHibernationTermination(
            agent: agent(),
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let controller = AgentHibernationController.shared
        let processExitCompletion = AgentHibernationProcessExitCompletion()
        let requestID = controller.registerCommittedTerminationObservation(
            panelID: panel.id,
            processExitCompletion: processExitCompletion
        )
        let recoveryExit = AsyncStream<Void>.makeStream()
        controller.observeCommittedTermination(
            panelID: panel.id,
            requestID: requestID,
            terminations: [],
            processExitCompletion: processExitCompletion,
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
            },
            onRecoveryFailure: {
                panel.failAgentHibernationTermination()
            }
        )
        let initialObservation =
            controller.committedTerminationObservationsByPanelID[panel.id]?.task
        let outcome = Task { @MainActor in
            await controller.committedTerminationOutcome(
                trigger: .manual,
                panelID: panel.id,
                requestID: requestID,
                terminalPanel: panel
            )
        }
        // The process exits only after the first observation has failed and
        // handed the request over to recovery.
        await initialObservation?.value
        recoveryExit.continuation.yield()
        recoveryExit.continuation.finish()

        #expect(await outcome.value)
        #expect(panel.isAgentHibernated)
        #expect(panel.agentHibernationTerminationFailed == false)
        #expect(controller.committedTerminationObservationsByPanelID[panel.id] == nil)
    }

    @Test
    func theManualTriggerNeverSelectsThroughThePlanner() {
        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let ordered = AgentHibernationPlanner.orderedPanelKeys(
            inputs: [
                .init(
                    key: key,
                    hasRestorableAgent: true,
                    isLive: true,
                    processSafetyAllowsHibernation: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: 0
                ),
            ],
            settings: AgentHibernationSettings.Values(
                enabled: true,
                idleSeconds: 5,
                maxLiveTerminals: 0,
                confirmationSeconds: 5
            ),
            now: 1_000,
            trigger: .manual
        )
        #expect(ordered.isEmpty)
        #expect(!AgentHibernationReclaimTrigger.manual.isMemoryPressure)
    }

    private func refusal(
        isProtected: Bool = false,
        lifecycle: AgentHibernationLifecycleState = .idle,
        hasUnconfirmedTerminalInput: Bool = false,
        containsUnrelatedProcess: Bool = false,
        liveness: RestorableAgentProcessLiveness = .exited,
        teardownInFlight: Bool = false
    ) throws -> AgentHibernationManualRefusal? {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let record = makeRecord(
            workspace: workspace,
            panel: panel,
            isProtected: isProtected,
            lifecycle: lifecycle,
            hasUnconfirmedTerminalInput: hasUnconfirmedTerminalInput,
            containsUnrelatedProcess: containsUnrelatedProcess,
            liveness: liveness
        )
        return AgentHibernationController.manualHibernationRefusal(for: record, teardownInFlight: teardownInFlight)
    }

    private func makeRecord(
        workspace: Workspace,
        panel: TerminalPanel,
        isProtected: Bool = false,
        lifecycle: AgentHibernationLifecycleState = .idle,
        hasUnconfirmedTerminalInput: Bool = false,
        containsUnrelatedProcess: Bool = false,
        liveness: RestorableAgentProcessLiveness = .exited,
        lastActivityAt: TimeInterval = 0
    ) -> AgentHibernationRecord {
        AgentHibernationRecord(
            key: AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panel.id),
            workspace: workspace,
            terminalPanel: panel,
            agent: agent(),
            lifecycle: lifecycle,
            hasUnconfirmedTerminalInput: hasUnconfirmedTerminalInput,
            lastActivityAt: lastActivityAt,
            isProtected: isProtected,
            hasLiveProcess: false,
            containsUnrelatedProcess: containsUnrelatedProcess,
            panelProcessIDs: [],
            processIDs: [],
            processIdentities: [:],
            processLiveness: liveness
        )
    }

    private func agent() -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "manual-\(UUID().uuidString)",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: nil
        )
    }
}
