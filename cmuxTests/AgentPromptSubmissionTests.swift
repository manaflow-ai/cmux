import Darwin
import CMUXAgentLaunch
@testable import CmuxTerminal
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class TemporaryAppEnvironment {
    let appDelegate: AppDelegate
    let tabManager: TabManager
    private let previousAppDelegate: AppDelegate?
    private let previousTabManager: TabManager?

    init() {
        previousAppDelegate = AppDelegate.shared
        appDelegate = previousAppDelegate ?? AppDelegate()
        previousTabManager = appDelegate.tabManager
        tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
    }

    func restore() {
        appDelegate.tabManager = previousTabManager
        AppDelegate.shared = previousAppDelegate
    }
}

@Suite("Atomic agent prompt submission", .serialized)
struct AgentPromptSubmissionTests {
    private struct LiveSurfaceTimeout: Error {}

    @MainActor
    private func waitForLiveSurface(_ surface: TerminalSurface) async throws {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        let readiness = AsyncStream<Void>.makeStream()
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        surface.onRuntimeReady = {
            previousOnRuntimeReady?()
            readiness.continuation.yield()
            readiness.continuation.finish()
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        if surface.hasLiveSurface { return }
        try await withThrowingTaskGroup(of: Bool.self, returning: Bool.self) {
            group in
            group.addTask {
                for await _ in readiness.stream {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            let becameReady = try await group.next() ?? false
            group.cancelAll()
            guard becameReady, surface.hasLiveSurface else {
                throw LiveSurfaceTimeout()
            }
            return true
        }
    }

    @MainActor
    @Test func addressedDeliveryDoesNotSelectOrFocusTargetWorkspace() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var target: Workspace?
        defer {
            target?.panels.values.forEach { ($0 as? TerminalPanel)?.surface.releaseSurfaceForTesting() }
            if let target, tabManager.tabs.contains(where: { $0.id == target.id }) {
                tabManager.closeWorkspace(target)
            }
            environment.restore()
        }

        let selected = tabManager.addWorkspace(select: true)
        target = tabManager.addWorkspace(select: false)
        let targetWorkspace = try #require(target)
        let targetSurface = try #require(targetWorkspace.focusedPanelId)
        guard let panel = targetWorkspace.terminalInputTarget(forPanelID: targetSurface)?.panel else {
            Issue.record("Target terminal was not created")
            return
        }
        targetWorkspace.recordAgentPID(
            key: "codex.focus-safety",
            pid: getpid(),
            panelId: targetSurface,
            refreshPorts: false
        )
        panel.surface.releaseSurfaceForTesting()

        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": targetWorkspace.id.uuidString,
            "surface_id": targetSurface.uuidString,
            "text": "focus must stay put",
        ])
        guard case .ok = result else {
            Issue.record("Expected addressed delivery admission")
            return
        }
        #expect(tabManager.selectedTabId == selected.id)
    }

    @Test func mainHopKeepsConcurrentDeliveryCallbacksSerialized() async {
        let controller = await MainActor.run { TerminalController.shared }
        let probe = await MainActor.run {
            let firstPanel = TerminalPanel(workspaceId: UUID())
            let secondPanel = TerminalPanel(workspaceId: UUID())
            firstPanel.surface.releaseSurfaceForTesting()
            secondPanel.surface.releaseSurfaceForTesting()
            return AgentPromptTransactionProbe(
                firstSurface: firstPanel.surface,
                secondSurface: secondPanel.surface
            )
        }
        let first = Task.detached {
            controller.v2MainSync {
                probe.deliver(
                    "first",
                    to: .first,
                    waitsForRelease: true
                )
            }
        }
        let firstStarted = await Task.detached {
            probe.waitUntilFirstStarted()
        }.value
        #expect(firstStarted)

        // This probe intentionally covers only the synchronous main-hop
        // serialization contract. The package-level service tests cover the
        // actual workspace FIFO and re-entrant admission path.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = probe.deliver(
                    "second",
                    to: .second,
                    waitsForRelease: false
                )
            }
        }
        #expect(probe.startedMessages == ["first"])
        probe.releaseFirst()

        #expect(await first.value == .queued)
        let bothCompleted = await Task.detached {
            probe.waitUntilCompletedMessages(2)
        }.value
        #expect(bothCompleted)
        #expect(probe.startedMessages == ["first", "second"])
        #expect(probe.completedMessages == ["first", "second"])
        let pendingMessages = await MainActor.run {
            (
                first: probe.pendingPromptMessages(for: .first),
                second: probe.pendingPromptMessages(for: .second)
            )
        }
        #expect(pendingMessages.first == ["first"])
        #expect(pendingMessages.second == ["second"])
        #expect(probe.maximumConcurrentDeliveries == 1)
        await MainActor.run { probe.releaseSurfacesForTesting() }
    }

    @MainActor
    @Test func hibernatedPromptSurvivesShellIdleBeforeAgentRebind() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer {
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }

        panel.surface.releaseSurfaceForTesting()
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "hibernated-agent",
            workingDirectory: nil,
            launchCommand: nil
        )
        panel.agentHibernationPhase = .hibernated(
            AgentHibernationPanelState(
                agent: agent,
                hibernatedAt: .now,
                lastActivityAt: .now
            )
        )

        let first = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelID.uuidString,
            "text": "preserve across resume",
        ])
        guard case .ok(let firstPayload) = first,
              let firstData = firstPayload as? [String: Any] else {
            Issue.record("Expected the hibernated prompt to be queued")
            return
        }
        #expect(firstData["queued"] as? Bool == true)
        #expect(firstData["queue_reason"] as? String == "agent_not_ready")

        // The replacement shell can report prompt-idle before its agent PID
        // and hook scope are rebound. That notification must not consume the
        // retained request as agent_not_found.
        workspace.updatePanelShellActivityState(
            panelId: panelID,
            state: .promptIdle
        )

        let second = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelID.uuidString,
            "text": "stay behind the first prompt",
        ])
        guard case .ok(let secondPayload) = second,
              let secondData = secondPayload as? [String: Any] else {
            Issue.record("Expected the retained prompt to remain in the FIFO")
            return
        }
        #expect(secondData["queued"] as? Bool == true)
        #expect(secondData["queue_reason"] as? String == "workspace_fifo")
    }

    @MainActor
    @Test func nativeHumanDraftIsPreservedAsASeparateFutureSubmission() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        panel.textBoxContent = "human draft"

        let result = panel.sendPromptSubmissionResult(
            "supervisor message",
            submitKey: "return",
            agentInputScope: "agentPIDKey:codex.session",
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit"
        )

        #expect(result == .queued)
        #expect(panel.textBoxContent == "human draft")
        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
    }

    @MainActor
    @Test func hookObservedTurnGatesDeliveryInsteadOfShellActivity() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var created: [Workspace] = []
        defer {
            for workspace in created {
                workspace.panels.values.forEach {
                    ($0 as? TerminalPanel)?.surface.releaseSurfaceForTesting()
                }
                if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                    tabManager.closeWorkspace(workspace)
                }
            }
            environment.restore()
        }

        func makeAgentWorkspace(
            releaseSurface: Bool = true
        ) throws -> (Workspace, UUID) {
            let workspace = tabManager.addWorkspace(select: false)
            created.append(workspace)
            let surfaceID = try #require(workspace.focusedPanelId)
            let panel = try #require(
                workspace.terminalInputTarget(forPanelID: surfaceID)?.panel
            )
            workspace.recordAgentPID(
                key: "codex.turn-gate",
                pid: getpid(),
                panelId: surfaceID,
                refreshPorts: false
            )
            if releaseSurface {
                panel.surface.releaseSurfaceForTesting()
            }
            // A TUI agent keeps the shell in commandRunning even while its
            // composer is idle; that alone must not gate addressed delivery.
            workspace.panelShellActivityStates[surfaceID] = .commandRunning
            return (workspace, surfaceID)
        }

        func firstSubmissionReason(
            workspace: Workspace,
            surfaceID: UUID,
            text: String
        ) throws -> String? {
            let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "text": text,
            ])
            guard case .ok(let payloadAny) = result,
                  let payload = payloadAny as? [String: Any] else {
                Issue.record("Expected admission for \(text)")
                return nil
            }
            #expect(payload["delivery_state"] as? String == "queued")
            return payload["queue_reason"] as? String
        }

        // Idle composer under a running TUI: queued only because the test
        // surface is cold, never because of shell activity.
        let (idleWorkspace, idleSurface) = try makeAgentWorkspace()
        #expect(try firstSubmissionReason(
            workspace: idleWorkspace,
            surfaceID: idleSurface,
            text: "deliver while composer is idle"
        ) == "agent_not_ready")

        // A hook-observed turn owns the composer and takes precedence.
        let (busyWorkspace, busySurface) = try makeAgentWorkspace(
            releaseSurface: false
        )
        let busyPanel = try #require(
            busyWorkspace.terminalInputTarget(forPanelID: busySurface)?.panel
        )
        try await waitForLiveSurface(busyPanel.surface)
        let busySessionID = "busy-session"
        busyWorkspace.recordAgentTurnStart(
            panelId: busySurface,
            sessionID: busySessionID
        )
        #expect(try firstSubmissionReason(
            workspace: busyWorkspace,
            surfaceID: busySurface,
            text: "queued behind the active turn"
        ) == "agent_turn_active")

        // A stale hook-observed turn expires so one missed stop hook cannot
        // wedge addressed delivery; a stop hook clears it explicitly.
        let past = Date().addingTimeInterval(
            Workspace.activeAgentTurnMaximumAge + 1
        )
        #expect(!busyWorkspace.hasActiveAgentTurn(panelId: busySurface, now: past))
        #expect(!busyWorkspace.hasActiveAgentTurn(panelId: busySurface))
        let replacementSessionID = "replacement-session"
        busyWorkspace.recordAgentTurnStart(
            panelId: busySurface,
            sessionID: replacementSessionID
        )
        #expect(!busyWorkspace.recordAgentTurnEnd(
            panelId: busySurface,
            sessionID: busySessionID
        ))
        #expect(busyWorkspace.hasActiveAgentTurn(panelId: busySurface))
        #expect(busyWorkspace.recordAgentTurnEnd(
            panelId: busySurface,
            sessionID: replacementSessionID
        ))
        #expect(!busyWorkspace.hasActiveAgentTurn(panelId: busySurface))
    }

    @MainActor
    @Test func nativeHumanDraftDoesNotMakeTerminalComposerBusy() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        panel.textBoxContent = "human draft"

        let isBusy = panel.terminalComposerIsBusy(
            agentInputScope: "agentPIDKey:codex.session"
        )

        #expect(!isBusy)
        #expect(panel.textBoxContent == "human draft")
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func stopHookCompletesBeforeFollowingPromptSubmit() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        let controller = TerminalController.shared
        let service = controller.agentPromptSubmissionService
        let workspaceID = workspace.id
        let targetSurfaceID = panelID
        defer {
            controller.cancelAgentPromptConfirmationFallback(
                workspaceID: workspaceID
            )
            _ = service.remove(workspaceID: workspaceID)
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        try await waitForLiveSurface(panel.surface)

        let agentKey = "codex.session-a"
        workspace.recordAgentPID(
            key: agentKey,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        workspace.recordAgentTurnStart(
            panelId: panelID,
            sessionID: "session-a"
        )
        var deliveryAttempts = 0
        let queued = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: targetSurfaceID,
            text: "queued between turns",
            delivery: { _ in
                deliveryAttempts += 1
                return deliveryAttempts == 1
                    ? .agentBusy(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID
                    )
                    : .submitted(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID,
                        queued: true
                    )
            }
        )
        #expect(queued.result == .queued(
            workspaceID: workspaceID,
            surfaceID: targetSurfaceID,
            reason: "agent_turn_active"
        ))

        // Both events are delivered on one main-actor turn. A deferred stop
        // transition would therefore run after B starts and fail its session
        // check, leaving the queued request behind the wrong turn.
        controller.v2ApplyIMessageModeSideEffects(for: WorkstreamEvent(
            sessionId: "session-a",
            hookEventName: .stop,
            source: "codex",
            workspaceId: workspaceID.uuidString,
            surfaceId: targetSurfaceID.uuidString,
            ppid: Int(getpid())
        ))
        controller.v2ApplyIMessageModeSideEffects(for: WorkstreamEvent(
            sessionId: "session-b",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspaceID.uuidString,
            surfaceId: targetSurfaceID.uuidString,
            toolInputJSON: #"{"prompt":"next prompt"}"#,
            ppid: Int(getpid())
        ))
        // Let the old unstructured stop task (on pre-fix code) run before the
        // assertions; this is a scheduler turn, not a production delay.
        for _ in 0..<3 { await Task.yield() }

        #expect(
            workspace.activeAgentTurnStartsByPanelId[panelID]?.sessionID
                == "session-b"
        )
        #expect(deliveryAttempts == 2)
        #expect(service.remove(surfaceID: targetSurfaceID).isEmpty)
    }

    @MainActor
    @Test func activeTurnSchedulesADeadlineRetry() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        let controller = TerminalController.shared
        let workspaceID = workspace.id
        let targetSurfaceID = panelID
        defer {
            controller.cancelAgentPromptConfirmationFallback(
                workspaceID: workspaceID
            )
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        try await waitForLiveSurface(panel.surface)

        workspace.recordAgentPID(
            key: "codex.expiry-scheduler",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        workspace.activeAgentTurnStartsByPanelId[panelID] =
            Workspace.AgentTurnStartRecord(
                sessionID: "expiring-session",
                startedAt: Date()
            )

        let result = controller.deliverAgentPromptSubmission(
            workspaceID: workspaceID,
            requestedSurfaceID: targetSurfaceID,
            text: "wait for the turn deadline",
            messageID: UUID()
        )
        #expect(result == .agentBusy(
            workspaceID: workspaceID,
            surfaceID: targetSurfaceID
        ))
        #expect(
            controller.agentPromptConfirmationFallbackSchedulers[workspaceID]?
                .isScheduled == true
        )
    }

    @MainActor
    @Test func expiredActiveTurnReleasesTheGuardedQueue() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        let service = TerminalController.shared.agentPromptSubmissionService
        let workspaceID = workspace.id
        let targetSurfaceID = panelID
        defer {
            _ = service.remove(workspaceID: workspaceID)
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        try await waitForLiveSurface(panel.surface)

        workspace.recordAgentPID(
            key: "codex.expiry-drain",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        workspace.activeAgentTurnStartsByPanelId[panelID] =
            Workspace.AgentTurnStartRecord(
                sessionID: "expired-session",
                startedAt: Date().addingTimeInterval(
                    -(Workspace.activeAgentTurnMaximumAge + 1)
                )
            )
        var deliveryAttempts = 0
        let receipt = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: targetSurfaceID,
            text: "retry after expiry",
            delivery: { _ in
                deliveryAttempts += 1
                return deliveryAttempts == 1
                    ? .agentBusy(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID
                    )
                    : .submitted(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID,
                        queued: true
                    )
            }
        )
        #expect(receipt.result == .queued(
            workspaceID: workspaceID,
            surfaceID: targetSurfaceID,
            reason: "agent_turn_active"
        ))

        workspace.drainAgentPromptQueueIfReady(panelId: panelID)

        #expect(workspace.activeAgentTurnStartsByPanelId[panelID] == nil)
        #expect(deliveryAttempts == 2)
        #expect(service.remove(surfaceID: targetSurfaceID).isEmpty)
    }

    @MainActor
    @Test func delayedStopFromAReusedPIDCannotMatchTheCurrentGeneration() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let key = "codex.generation-session"
        defer { workspace.teardownAllPanels() }

        workspace.recordAgentPID(
            key: key,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPromptHookMatchesSession(
            panelId: panelID,
            hookSource: "codex",
            sessionID: "generation-session",
            hookProcessID: Int(getpid())
        ))
        let current = try #require(
            Workspace.agentPIDProcessIdentity(pid: getpid())
        )
        workspace.agentPIDProcessIdentitiesByKey[key] = AgentPIDProcessIdentity(
            pid: getpid(),
            startSeconds: current.startSeconds &- 1,
            startMicroseconds: current.startMicroseconds
        )
        #expect(!workspace.agentPromptHookMatchesSession(
            panelId: panelID,
            hookSource: "codex",
            sessionID: "generation-session",
            hookProcessID: Int(getpid())
        ))
        #expect(!workspace.agentPromptHookMatchesSession(
            panelId: panelID,
            hookSource: "codex",
            sessionID: "generation-session",
            hookProcessID: nil
        ))
    }

    @MainActor
    @Test func replacingAnAgentBindingDoesNotDiscardItsQueuedPrompt() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        let service = TerminalController.shared.agentPromptSubmissionService
        let workspaceID = workspace.id
        let targetSurfaceID = panelID
        defer {
            _ = service.remove(workspaceID: workspaceID)
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        try await waitForLiveSurface(panel.surface)

        workspace.recordAgentPID(
            key: "codex.replaced-old",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        workspace.activeAgentTurnStartsByPanelId[panelID] =
            Workspace.AgentTurnStartRecord(
                sessionID: "old-turn",
                startedAt: Date()
            )
        var attempts = 0
        let receipt = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: targetSurfaceID,
            text: "survive process replacement",
            delivery: { _ in
                attempts += 1
                return .agentBusy(
                    workspaceID: workspaceID,
                    surfaceID: targetSurfaceID
                )
            }
        )
        #expect(receipt.result == .queued(
            workspaceID: workspaceID,
            surfaceID: targetSurfaceID,
            reason: "agent_turn_active"
        ))

        // The stale structured key is removed before the replacement key is
        // installed. Scope synchronization must be deferred across that
        // transient empty-binding state, or it will discard this request.
        workspace.recordAgentPID(
            key: "codex.replaced-new",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )

        #expect(service.remove(surfaceID: targetSurfaceID).count == 1)
        #expect(attempts == 1)
    }

    @MainActor
    @Test func restoringAReusedPIDDoesNotDrainBeforeSavedIdentityIsInstalled() async throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        let service = TerminalController.shared.agentPromptSubmissionService
        let workspaceID = workspace.id
        let targetSurfaceID = panelID
        defer {
            _ = service.remove(workspaceID: workspaceID)
            panel.surface.releaseSurfaceForTesting()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        try await waitForLiveSurface(panel.surface)

        var attempts = 0
        let receipt = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: targetSurfaceID,
            text: "wait for restored process identity",
            delivery: { _ in
                attempts += 1
                return attempts == 1
                    ? .agentScopeUnavailable(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID
                    )
                    : .submitted(
                        workspaceID: workspaceID,
                        surfaceID: targetSurfaceID,
                        queued: true
                    )
            }
        )
        #expect(receipt.result == .queued(
            workspaceID: workspaceID,
            surfaceID: targetSurfaceID,
            reason: "agent_not_ready"
        ))

        let pid = getpid()
        let currentIdentity = try #require(
            Workspace.agentPIDProcessIdentity(pid: pid)
        )
        let savedIdentity = AgentPIDProcessIdentity(
            pid: pid,
            startSeconds: currentIdentity.startSeconds &- 1,
            startMicroseconds: currentIdentity.startMicroseconds
        )
        workspace.adoptDetachedAgentRuntimeState(
            Workspace.DetachedAgentRuntimeState(
                panelId: panelID,
                statusEntries: [:],
                agentPIDs: ["codex.restored-reused": pid],
                agentPIDProcessIdentities: [
                    "codex.restored-reused": savedIdentity,
                ],
                agentPIDKeys: ["codex.restored-reused"]
            )
        )

        #expect(attempts == 1)
        #expect(service.remove(surfaceID: targetSurfaceID).count == 1)
    }

    @MainActor
    @Test func exactMobileChatSubmissionRejectsWithoutChangingHumanDraft() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        let agentScope = "agentPIDKey:codex.session"
        panel.surface.synchronizePromptInputAgentScope(agentScope)
        panel.surface.recordHumanPromptInput(.unknown)

        let result = panel.sendPromptSubmissionResult(
            "mobile message",
            submitKey: "return",
            agentInputScope: agentScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.prompt_submit"
        )

        #expect(result == .composerBusy)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func rawMobileDraftBlocksExactMobileAndAgentSubmissions() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel

        workspace.recordAgentPID(
            key: "codex.mobile-draft",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.releaseSurfaceForTesting()
        let inputResult = TerminalController.shared.v2MobileTerminalInput(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "phone draft",
            ]
        )
        guard case .ok = inputResult else {
            Issue.record("Expected raw mobile draft to be accepted")
            return
        }

        let mobileResult = TerminalController.shared.v2MobileTerminalPaste(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "mobile message",
            ],
            rejectIfHumanComposerBusy: true
        )
        guard case .err(let mobileCode, _, _) = mobileResult else {
            Issue.record("Expected exact mobile submission to reject the draft")
            return
        }
        #expect(mobileCode == "rejected_composer_busy")

        let agentResult = TerminalController.shared.v2WorkspaceAgentSubmit(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "supervisor message",
            ]
        )
        guard case .ok(let agentPayload) = agentResult else {
            Issue.record("Expected agent submission to queue behind the draft")
            return
        }
        let agentResponse = try #require(agentPayload as? [String: Any])
        #expect(agentResponse["message_id"] is String)
        #expect(agentResponse["queued"] as? Bool == true)
        #expect(agentResponse["delivery_state"] as? String == "queued")

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.inputTextItems == 1)
        #expect(pending.promptSubmissionItems == 0)
    }

    @MainActor
    @Test func exactMobileSendPreservesDeliveryBeforeAgentScopeBinding() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)
        panel.surface.releaseSurfaceForTesting()
        let result = TerminalController.shared.v2MobileTerminalPaste(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "mobile message",
            ],
            rejectIfHumanComposerBusy: true
        )

        guard case .ok(let payload) = result else {
            Issue.record("Expected pre-binding mobile send to remain available")
            return
        }
        let response = try #require(payload as? [String: Any])
        #expect(response["submitted"] as? Bool == true)
        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.keyEvents == 0)
        #expect(pending.promptSubmissionItems == 1)
        #expect(
            panel.surface.pendingPromptPreparationKeyLabelsForTests
                == [["ctrl+a", "ctrl+k", "ctrl+u"]]
        )

        workspace.recordAgentPID(
            key: "codex.prebinding-mobile",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)

        let agentResult = TerminalController.shared.v2WorkspaceAgentSubmit(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "supervisor message",
            ]
        )
        guard case .ok(let agentPayload) = agentResult else {
            Issue.record(
                "Expected agent submission after initial binding to remain available"
            )
            return
        }
        let agentResponse = try #require(agentPayload as? [String: Any])
        #expect(agentResponse["submitted"] as? Bool == true)
        #expect(agentResponse["queued"] as? Bool == true)
        #expect(agentResponse["queue_reason"] as? String == "agent_not_ready")
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 1)
        #expect(
            TerminalController.shared.agentPromptSubmissionService
                .pendingCount == 1
        )
    }

    @MainActor
    @Test func surfaceLessHookConfirmsUniqueAgentTerminalDraft() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel

        workspace.recordAgentPID(
            key: "codex.surface-less-hook",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        let event = WorkstreamEvent(
            sessionId: "surface-less-hook",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: nil,
            toolInputJSON: #"{"prompt":"human prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func staleExplicitSurfaceHookDoesNotConfirmAnotherTerminal() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel

        workspace.recordAgentPID(
            key: "codex.stale-surface-hook",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        let event = WorkstreamEvent(
            sessionId: "stale-surface-hook",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: UUID().uuidString,
            toolInputJSON: #"{"prompt":"other prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func surfaceLessHookUsesExactSessionInMultiAgentWorkspace() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let otherPanel = TerminalPanel(workspaceId: workspace.id)
        workspace.panels[otherPanel.id] = otherPanel
        defer {
            workspace.panels.values.forEach {
                ($0 as? TerminalPanel)?.surface.releaseSurfaceForTesting()
            }
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }
        let targetPanelID = try #require(workspace.focusedPanelId)
        let targetPanel = try #require(
            workspace.terminalInputTarget(
                forPanelID: targetPanelID
            )?.panel
        )

        workspace.recordAgentPID(
            key: "codex.target-session",
            pid: getpid(),
            panelId: targetPanelID,
            refreshPorts: false
        )
        workspace.recordAgentPID(
            key: "codex.other-session",
            pid: getpid(),
            panelId: otherPanel.id,
            refreshPorts: false
        )
        for panel in [targetPanel, otherPanel] {
            panel.surface.recordHumanPromptInput(.unknown)
            panel.surface.recordHumanPromptInput(.submissionBoundary)
            #expect(panel.surface.hasUnconfirmedHumanPromptInput)
        }

        let event = WorkstreamEvent(
            sessionId: "target-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: nil,
            toolInputJSON: #"{"prompt":"target prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(!targetPanel.surface.hasUnconfirmedHumanPromptInput)
        #expect(otherPanel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func preBindingHumanInputRejectsGuardedAgentSubmission() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        let agentScope = "agentPIDKey:codex.session"
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.synchronizePromptInputAgentScope(agentScope)

        let result = panel.sendPromptSubmissionResult(
            "supervisor message",
            submitKey: "return",
            agentInputScope: agentScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit"
        )

        #expect(result == .composerBusy)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func simpleTextBoxSubmissionUsesOneCompoundTerminalItem() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()

        var completion: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.send(
            "review this change",
            via: panel.surface,
            terminalAgentContext: "agentPIDKey:codex.session"
        ) {
            completion = $0
        }

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(pending.pasteTextItems == 0)
        #expect(pending.keyEvents == 0)
        #expect(completion?.didSubmit == true)
    }

    @MainActor
    @Test func humanTextBoxSubmissionIsNotWedgedByPhysicalInputLedger() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        panel.surface.synchronizePromptInputAgentScope(
            "agentPIDKey:codex.session"
        )
        panel.surface.recordHumanPromptInput(.unknown)

        var completion: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.send(
            "must stay intact",
            via: panel.surface,
            terminalAgentContext: "agentPIDKey:codex.session"
        ) {
            completion = $0
        }

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(completion?.didSubmit == true)
    }

    @MainActor
    @Test func shellTextBoxSubmissionIgnoresShellInputLedger() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.surface.releaseSurfaceForTesting()
        panel.surface.recordHumanPromptInput(.unknown)

        var completion: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.send(
            "echo intact",
            via: panel.surface,
            terminalAgentContext: ""
        ) {
            completion = $0
        }

        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(completion?.didSubmit == true)
    }

    @MainActor
    @Test func unrelatedSupportedPIDDoesNotResetComposerOwnership() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer { panel.surface.releaseSurfaceForTesting() }

        workspace.recordAgentPID(
            key: "codex.primary",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        let originalScope = panel.surface.currentPromptInputAgentScope

        workspace.recordAgentPID(
            key: "ollama.unrelated",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )

        #expect(panel.surface.currentPromptInputAgentScope == originalScope)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func hooklessAgentDoesNotOwnRecoverableComposerState() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer { panel.surface.releaseSurfaceForTesting() }

        workspace.recordAgentPID(
            key: "ollama",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)
        #expect(panel.surface.currentPromptInputAgentScope == nil)
    }

    @MainActor
    @Test func temporaryProcessIdentityGapPreservesComposerState() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer { panel.surface.releaseSurfaceForTesting() }
        let agentKey = "codex.identity-unavailable"

        workspace.recordAgentPID(
            key: agentKey,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        let originalScope = try #require(
            panel.surface.currentPromptInputAgentScope
        )
        panel.surface.recordHumanPromptInput(.unknown)
        #expect(panel.surface.currentPromptInputAgentScope == originalScope)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        workspace.recordAgentPID(
            key: agentKey,
            pid: pid_t.max - 1,
            panelId: panelID,
            refreshPorts: false
        )

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)
        #expect(panel.surface.currentPromptInputAgentScope == nil)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        panel.surface.releaseSurfaceForTesting()
        let result = panel.sendPromptSubmissionResult(
            "must not reach an identity-less composer",
            submitKey: "return",
            agentInputScope: nil,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit"
        )
        #expect(result == .agentScopeUnavailable)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)

        workspace.recordAgentPID(
            key: agentKey,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == originalScope)
        #expect(panel.surface.currentPromptInputAgentScope == originalScope)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        let busyResult = panel.sendPromptSubmissionResult(
            "must wait for the preserved human draft",
            submitKey: "return",
            agentInputScope: originalScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit"
        )
        #expect(busyResult == .composerBusy)

        panel.surface.recordHumanPromptInput(.submissionBoundary)
        #expect(
            panel.surface.confirmPromptSubmission(message: "human draft")
                == .human
        )
        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)

        let recoveredResult = panel.sendPromptSubmissionResult(
            "automation resumes after confirmation",
            submitKey: "return",
            agentInputScope: originalScope,
            rejectIfHumanComposerBusy: true,
            hookRecordingSource: "workspace.agent_submit"
        )
        #expect(recoveredResult == .queued)
        #expect(
            panel.surface.debugPendingSocketInputForTesting()
                .promptSubmissionItems == 1
        )
    }

    @MainActor
    @Test func claudeScopeTreatsControlReturnAsPromptBoundary() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer { panel.surface.releaseSurfaceForTesting() }

        workspace.recordAgentPID(
            key: "claude_code",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        let agentScope = try #require(
            panel.surface.currentPromptInputAgentScope
        )
        #expect(agentScope.hasPrefix("agentPIDKey:claude_code|"))
        panel.surface.releaseSurfaceForTesting()
        #expect(panel.sendText("first line\nsecond line"))
        #expect(panel.sendNamedKey("ctrl+enter"))
        #expect(
            panel.surface.confirmPromptSubmission(
                message: "first line second line"
            ) == .human
        )
        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func rejectedMobileAttachmentBatchCleansEarlierFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = TerminalPasteboardService(
            temporaryDirectory: directory
        )
        let oversizedPayload = Data(
            repeating: 0,
            count: TerminalPasteboardService.maximumImageDataByteCount + 1
        ).base64EncodedString()

        let result = await TerminalController.prepareMobileChatAttachments(
            [
                MobileChatAttachmentPayload(
                    encodedData: Data([0x01]).base64EncodedString(),
                    fileExtension: "png"
                ),
                MobileChatAttachmentPayload(
                    encodedData: oversizedPayload,
                    fileExtension: "png"
                )
            ],
            pasteboard: pasteboard
        )

        #expect(result == nil)
        let materializedFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(materializedFiles.isEmpty)
    }

    @Test func mobileAttachmentBatchRejectsTooManyItemsBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = TerminalPasteboardService(
            temporaryDirectory: directory
        )
        let attachments = (0..<11).map { index in
            MobileChatAttachmentPayload(
                encodedData: Data([UInt8(index)]).base64EncodedString(),
                fileExtension: "png"
            )
        }

        let result = await TerminalController.prepareMobileChatAttachments(
            attachments,
            pasteboard: pasteboard
        )

        #expect(result == nil)
        let materializedFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(materializedFiles.isEmpty)
    }

    @MainActor
    @Test func mobileChatRejectsMalformedAttachmentsBeforeBindingLookup() async {
        let controller = TerminalController.shared
        let previousService = controller.agentChatTranscriptService
        controller.agentChatTranscriptService = nil
        defer { controller.agentChatTranscriptService = previousService }

        let result = await controller.v2MobileChatSend(params: [
            "session_id": "missing-session",
            "text": "keep this prompt",
            "attachments": "not-an-array",
        ])

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected malformed attachments to be rejected")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test func composerBusyMapsToDistinctRetryableSocketError() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()

        let result = TerminalController.agentPromptSocketResult(
            .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        )

        guard case .err(let code, _, let rawData) = result else {
            Issue.record("Expected rejected_composer_busy")
            return
        }
        let data = try #require(rawData as? [String: Any])
        #expect(code == "rejected_composer_busy")
        #expect(data["workspace_id"] as? String == workspaceID.uuidString)
        #expect(data["surface_id"] as? String == surfaceID.uuidString)
        #expect(data["retryable"] as? Bool == true)
        #expect(
            data["retry_after"] as? String
                == "human_prompt_submit_or_agent_restart"
        )
    }

    @Test func unavailableAgentScopeMapsToDistinctRetryableSocketError() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()

        let result = TerminalController.agentPromptSocketResult(
            .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        )

        guard case .err(let code, _, let rawData) = result else {
            Issue.record("Expected agent_scope_unavailable")
            return
        }
        let data = try #require(rawData as? [String: Any])
        #expect(code == "agent_scope_unavailable")
        #expect(data["workspace_id"] as? String == workspaceID.uuidString)
        #expect(data["surface_id"] as? String == surfaceID.uuidString)
        #expect(data["retryable"] as? Bool == true)
        #expect(
            data["retry_after"] as? String
                == "agent_terminal_ready"
        )
    }

    @Test func acceptedSocketResultUsesAcceptedDeliveryState() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let result = TerminalController.agentPromptSocketResult(
            .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: false
            ),
            messageID: UUID()
        )

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("Expected an accepted submission payload")
            return
        }
        #expect(payload["queued"] as? Bool == false)
        #expect(payload["delivery_state"] as? String == "accepted")
    }

    @MainActor
    @Test func identityGapReturnsRetryableScopeErrorWithoutTerminalWrite() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }

        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel
        let agentKey = "codex.socket-identity-gap"

        workspace.recordAgentPID(
            key: agentKey,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        let originalScope = try #require(
            workspace.agentPromptInputScope(forPanelId: panelID)
        )
        panel.surface.recordHumanPromptInput(.unknown)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
        workspace.recordAgentPID(
            key: agentKey,
            pid: pid_t.max - 1,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)

        panel.surface.releaseSurfaceForTesting()
        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelID.uuidString,
            "text": "must wait for a stable agent identity",
        ])

        guard case .ok(let rawPayload) = result else {
            Issue.record("Expected agent submission to queue during identity gap")
            return
        }
        let data = try #require(rawPayload as? [String: Any])
        #expect(data["message_id"] is String)
        #expect(data["queued"] as? Bool == true)
        #expect(data["delivery_state"] as? String == "queued")
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        workspace.recordAgentPID(
            key: agentKey,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        #expect(
            workspace.agentPromptInputScope(forPanelId: panelID)
                == originalScope
        )

        let busyResult = TerminalController.shared.v2WorkspaceAgentSubmit(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "must preserve the guarded human draft",
            ]
        )
        guard case .ok(let busyPayload) = busyResult else {
            Issue.record("Expected the second prompt to remain queued")
            return
        }
        let busyResponse = try #require(busyPayload as? [String: Any])
        #expect(busyResponse["message_id"] is String)
        #expect(busyResponse["queued"] as? Bool == true)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        panel.surface.recordHumanPromptInput(.submissionBoundary)
        #expect(
            panel.surface.confirmPromptSubmission(message: "human draft")
                == .human
        )
        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)

        let retryResult = TerminalController.shared.v2WorkspaceAgentSubmit(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelID.uuidString,
                "text": "safe after the human prompt boundary",
            ]
        )
        guard case .ok(let rawPayload) = retryResult else {
            Issue.record("Expected recovered agent submission to queue")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["submitted"] as? Bool == true)
        #expect(payload["queued"] as? Bool == true)
        #expect(payload["queue_reason"] as? String == "prior_prompt_in_flight")
        #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
        #expect(payload["surface_id"] as? String == panelID.uuidString)
        let pending = panel.surface.debugPendingSocketInputForTesting()
        #expect(pending.items == 0)
        #expect(pending.promptSubmissionItems == 0)
        #expect(pending.inputTextItems == 0)
        #expect(pending.keyEvents == 0)
        #expect(
            TerminalController.shared.agentPromptSubmissionService
                .pendingCount == 1
        )
    }

    @MainActor
    @Test func hooklessAgentRemainsNotFoundWithoutTerminalWrite() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }

        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel
        workspace.recordAgentPID(
            key: "ollama",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)

        panel.surface.releaseSurfaceForTesting()
        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelID.uuidString,
            "text": "must not target a hookless agent",
        ])

        guard case .err(let code, _, let rawData) = result else {
            Issue.record("Expected agent_not_found")
            return
        }
        let data = try #require(rawData as? [String: Any])
        #expect(code == "agent_not_found")
        #expect(data["workspace_id"] as? String == workspace.id.uuidString)
        #expect(data["surface_id"] as? String == panelID.uuidString)
        #expect(data["retryable"] == nil)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func whitespaceOnlyPromptIsRejectedWithoutDelivery() throws {
        let environment = TemporaryAppEnvironment()
        let tabManager = environment.tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            environment.restore()
        }

        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel
        panel.surface.releaseSurfaceForTesting()

        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelID.uuidString,
            "text": " \n\t ",
        ])

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }
}
