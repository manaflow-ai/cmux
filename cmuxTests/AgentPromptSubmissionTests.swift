import Darwin
import CMUXAgentLaunch
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class AgentPromptDeliveryGate {
    var isReady = false
}

@Suite("Atomic agent prompt submission", .serialized)
struct AgentPromptSubmissionTests {
    @MainActor
    @Test func addressedAdmissionReturnsMessageIDsAndDrainsFIFO() {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let gate = AgentPromptDeliveryGate()

        func delivery(_ text: String) -> AgentPromptSubmissionResult {
            if !gate.isReady {
                return .rejectedComposerBusy(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            }
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: false
            )
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: { delivery("first") }
        )
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: { delivery("second") }
        )

        #expect(first.messageID != second.messageID)
        #expect(first.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "human_composer_busy"
        ))
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "workspace_fifo"
        ))

        gate.isReady = true
        let firstDrain = service.drain(workspaceID: workspaceID)
        #expect(firstDrain.map(\.messageID) == [first.messageID])
        #expect(service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            message: "first"
        ) == first.messageID)
        let secondDrain = service.drain(workspaceID: workspaceID)
        let drained = firstDrain + secondDrain
        #expect(drained.map(\.messageID) == [first.messageID, second.messageID])
        #expect(drained.allSatisfy {
            if case .submitted = $0.result { return true }
            return false
        })
    }

    @MainActor
    @Test func unconfirmedAcceptedPromptStopsBlockingTheWorkspaceFIFO() throws {
        let service = AgentPromptSubmissionService(maximumPendingRequests: 8)
        let workspaceID = UUID()
        let surfaceID = UUID()

        func accepting() -> AgentPromptSubmissionResult {
            .submitted(workspaceID: workspaceID, surfaceID: surfaceID, queued: false)
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: accepting
        )
        guard case .submitted = first.result else {
            Issue.record("Expected the first prompt to be accepted")
            return
        }

        // The agent never emits a matching hook: no confirm() arrives.
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: accepting
        )
        #expect(second.result == .queued(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: "prior_prompt_in_flight"
        ))
        // Inside the confirmation window the barrier holds.
        #expect(service.drain(workspaceID: workspaceID).isEmpty)

        // Past the window the barrier expires and drain advances the FIFO.
        let expired = service.expireStaleInFlight(
            workspaceID: workspaceID,
            now: Date().addingTimeInterval(service.confirmationTimeout + 1)
        )
        #expect(expired == first.messageID)
        let drained = service.drain(workspaceID: workspaceID)
        #expect(drained.map(\.messageID) == [second.messageID])

        // A late hook still matches the first accepted message.
        #expect(service.confirm(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            message: "first"
        ) == first.messageID)
    }

    @MainActor
    @Test func zeroConfirmationWindowNeverWedgesLaterSubmissions() throws {
        let service = AgentPromptSubmissionService(
            maximumPendingRequests: 8,
            confirmationTimeout: 0
        )
        let workspaceID = UUID()
        let surfaceID = UUID()

        func accepting() -> AgentPromptSubmissionResult {
            .submitted(workspaceID: workspaceID, surfaceID: surfaceID, queued: false)
        }

        let first = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "first",
            delivery: accepting
        )
        guard case .submitted = first.result else {
            Issue.record("Expected the first prompt to be accepted")
            return
        }
        // The stale barrier expires during admission, so the second prompt
        // delivers instead of queueing behind a hook that never comes.
        let second = service.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: "second",
            delivery: accepting
        )
        guard case .submitted = second.result else {
            Issue.record("Expected the second prompt to be accepted")
            return
        }
        #expect(first.messageID != second.messageID)
    }

    @MainActor
    @Test func addressedDeliveryDoesNotSelectOrFocusTargetWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var target: Workspace?
        defer {
            target?.panels.values.forEach { ($0 as? TerminalPanel)?.surface.releaseSurfaceForTesting() }
            if let target, tabManager.tabs.contains(where: { $0.id == target.id }) {
                tabManager.closeWorkspace(target)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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

    @Test func concurrentSubmissionsAcrossWorkspacesStayIntactAndGloballyFIFO() async {
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

        // The first synchronous socket hop is holding the same serial main
        // boundary. async returns only after the second complete transaction
        // has been accepted behind it, so releasing the first cannot degrade
        // this into two sequential caller starts.
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
        let pending = panel.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
    }

    @MainActor
    @Test func hookObservedTurnGatesDeliveryInsteadOfShellActivity() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
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
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
        }

        func makeAgentWorkspace() throws -> (Workspace, UUID) {
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
            panel.surface.releaseSurfaceForTesting()
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
        let (busyWorkspace, busySurface) = try makeAgentWorkspace()
        busyWorkspace.recordAgentTurnStart(panelId: busySurface)
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
        busyWorkspace.recordAgentTurnStart(panelId: busySurface)
        busyWorkspace.recordAgentTurnEnd(panelId: nil)
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
    }

    @MainActor
    @Test func rawMobileDraftBlocksExactMobileAndAgentSubmissions() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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

        let pending = panel.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.inputTextItems == 1)
        #expect(pending.promptSubmissionItems == 0)
    }

    @MainActor
    @Test func exactMobileSendPreservesDeliveryBeforeAgentScopeBinding() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        let pending = panel.surface.pendingSocketInputSnapshotForTests
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
        #expect(
            panel.surface.pendingSocketInputSnapshotForTests.items == 2
        )
    }

    @MainActor
    @Test func surfaceLessHookConfirmsUniqueAgentTerminalDraft() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
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
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
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

        let pending = panel.surface.pendingSocketInputSnapshotForTests
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

        let pending = panel.surface.pendingSocketInputSnapshotForTests
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

        let pending = panel.surface.pendingSocketInputSnapshotForTests
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)

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
            panel.surface.pendingSocketInputSnapshotForTests
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

    @MainActor
    @Test func identityGapReturnsRetryableScopeErrorWithoutTerminalWrite() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
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
        #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
        #expect(payload["surface_id"] as? String == panelID.uuidString)
        let pending = panel.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.promptSubmissionItems == 1)
        #expect(pending.inputTextItems == 0)
        #expect(pending.keyEvents == 0)
    }

    @MainActor
    @Test func hooklessAgentRemainsNotFoundWithoutTerminalWrite() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
    }

    @MainActor
    @Test func whitespaceOnlyPromptIsRejectedWithoutDelivery() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        defer {
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
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
        #expect(panel.surface.pendingSocketInputSnapshotForTests.items == 0)
    }
}
