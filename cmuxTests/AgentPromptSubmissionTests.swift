import Darwin
import CMUXAgentLaunch
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Atomic agent prompt submission", .serialized)
struct AgentPromptSubmissionTests {
    @Test func deliveryLaneTimesOutAndReleasesItsTurn() async {
        let lane = AgentPromptSubmissionDeliveryLane(
            deliveryTimeout: .milliseconds(1),
            maximumWaitingTurns: 1
        )
        let workspaceID = UUID()
        let surfaceID = UUID()
        let timedOut = await lane.perform { _ in
            .admitted(
                .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: true
                )
            )
        }
        #expect(
            timedOut == .admitted(
                .surfaceUnavailable(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            )
        )

        let recovered = await lane.perform { receipt in
            receipt.finish(.sent)
            return .admitted(
                .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            )
        }
        #expect(
            recovered == .admitted(
                .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            )
        )
    }

    @Test func compatibilityTurnSharesTheGlobalAdmissionGate() async {
        let lane = AgentPromptSubmissionDeliveryLane(
            deliveryTimeout: .milliseconds(10),
            maximumWaitingTurns: 1
        )
        #expect(lane.tryBeginSynchronousTurn())

        let blocked = await lane.perform { _ in
            .admitted(
                .submitted(
                    workspaceID: UUID(),
                    surfaceID: UUID(),
                    queued: false
                )
            )
        }
        #expect(blocked == .laneBusy)

        lane.completeSynchronousTurn()
        let recovered = await lane.perform { receipt in
            receipt.finish(.sent)
            return .admitted(
                .submitted(
                    workspaceID: UUID(),
                    surfaceID: UUID(),
                    queued: false
                )
            )
        }
        if case .admitted(.submitted) = recovered {
            // The shared gate is available again after the compatibility turn.
        } else {
            Issue.record("Expected the async admission lane to recover")
        }
    }

    @Test func deliveryLaneWaitsForActualDeliveryBeforeStartingNext() async {
        let lane = AgentPromptSubmissionDeliveryLane()
        let probe = AgentPromptDeliveryLaneProbe()
        let firstWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondWorkspaceID = UUID()
        let secondSurfaceID = UUID()

        let first = Task.detached {
            await lane.perform { receipt in
                probe.started("first", receipt: receipt)
                return .admitted(
                    .submitted(
                        workspaceID: firstWorkspaceID,
                        surfaceID: firstSurfaceID,
                        queued: true
                    )
                )
            }
        }
        #expect(probe.waitUntilStarted(count: 1))

        let second = Task.detached {
            await lane.perform { receipt in
                probe.started("second", receipt: receipt)
                return .admitted(
                    .submitted(
                        workspaceID: secondWorkspaceID,
                        surfaceID: secondSurfaceID,
                        queued: true
                    )
                )
            }
        }

        #expect(probe.waitUntilStarted(count: 1))
        #expect(probe.startedMessages == ["first"])
        probe.finishFirst(.sent)

        #expect(
            await first.value == .admitted(
                .submitted(
                    workspaceID: firstWorkspaceID,
                    surfaceID: firstSurfaceID,
                    queued: true
                )
            )
        )
        #expect(probe.waitUntilStarted(count: 2))
        #expect(probe.startedMessages == ["first", "second"])
        probe.finishSecond(.sent)
        #expect(
            await second.value == .admitted(
                .submitted(
                    workspaceID: secondWorkspaceID,
                    surfaceID: secondSurfaceID,
                    queued: true
                )
            )
        )
    }

    @Test func cancelledWaitingSubmissionReleasesItsTurnAndReservation() async {
        let lane = AgentPromptSubmissionDeliveryLane(
            deliveryTimeout: .seconds(5),
            maximumWaitingTurns: 1
        )
        let probe = AgentPromptDeliveryLaneProbe()
        let first = Task {
            await lane.perform { receipt in
                probe.started("first", receipt: receipt)
                return .admitted(
                    .submitted(
                        workspaceID: UUID(),
                        surfaceID: UUID(),
                        queued: true
                    )
                )
            }
        }
        #expect(probe.waitUntilStarted(count: 1))

        let waiting = Task {
            await lane.perform { receipt in
                probe.started("cancelled", receipt: receipt)
                return .admitted(
                    .submitted(
                        workspaceID: UUID(),
                        surfaceID: UUID(),
                        queued: true
                    )
                )
            }
        }
        waiting.cancel()
        #expect(await waiting.value == .laneBusy)
        #expect(probe.startedMessages == ["first"])

        probe.finishFirst(.sent)
        let firstResult = await first.value
        if case .admitted(.submitted) = firstResult {
            // The original turn completed normally.
        } else {
            Issue.record("Expected the original lane turn to complete")
        }

        let recovered = await lane.perform { receipt in
            receipt.finish(.sent)
            return .admitted(
                .submitted(
                    workspaceID: UUID(),
                    surfaceID: UUID(),
                    queued: false
                )
            )
        }
        if case .admitted(.submitted) = recovered {
            // Cancellation released both the waiting turn and its gate slot.
        } else {
            Issue.record("Expected the lane to recover after cancellation")
        }
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
    @Test func normalMobileTerminalPasteClaimsHumanPromptOwnership() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        let agentScope = "agentPIDKey:codex.mobile-paste"
        panel.surface.synchronizePromptInputAgentScope(agentScope)

        let result = panel.sendPromptSubmissionResult(
            "mobile draft",
            submitKey: "return",
            agentInputScope: agentScope,
            rejectIfHumanComposerBusy: false,
            hookRecordingSource: nil,
            recordHumanPromptInput: true
        )

        #expect(result.accepted)
        if result == .queued {
            #expect(
                panel.surface.pendingSocketInputQueue.first?.isHumanInput == true
            )
        } else {
            #expect(panel.surface.hasUnconfirmedHumanPromptInput)
            #expect(
                panel.surface.confirmPromptSubmission(message: "mobile draft")
                    == .human
            )
        }
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
        guard case .err(let agentCode, _, _) = agentResult else {
            Issue.record("Expected agent submission to reject the draft")
            return
        }
        #expect(agentCode == "rejected_composer_busy")

        let pending = panel.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 1)
        #expect(pending.inputTextItems == 1)
        #expect(pending.promptSubmissionItems == 0)
    }

    @MainActor
    @Test func exactMobileSendFailsClosedBeforeAgentScopeBinding() throws {
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

        guard case .err(let code, _, let rawData) = result else {
            Issue.record("Expected pre-binding mobile send to fail closed")
            return
        }
        #expect(code == "agent_scope_unavailable")
        let response = try #require(rawData as? [String: Any])
        #expect(response["retryable"] as? Bool == true)
        let pending = panel.surface.pendingSocketInputSnapshotForTests
        #expect(pending.items == 0)
    }

    @MainActor
    @Test func surfaceLessHookWithoutExactSessionDoesNotGuessUniqueAgent() throws {
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
            sessionId: "unrelated-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: nil,
            toolInputJSON: #"{"prompt":"human prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func unverifiedHookDoesNotRecordWhileAnAppPromptIsPending() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let previousTabManager = appDelegate.tabManager
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        var workspaceForCleanup: Workspace?
        var panelForCleanup: TerminalPanel?
        let defaults = UserDefaults.standard
        let previousIMessageMode = defaults.object(forKey: IMessageModeSettings.key)
        defer {
            if let previousIMessageMode {
                defaults.set(previousIMessageMode, forKey: IMessageModeSettings.key)
            } else {
                defaults.removeObject(forKey: IMessageModeSettings.key)
            }
            panelForCleanup?.surface.releaseSurfaceForTesting()
            if let workspace = workspaceForCleanup,
               tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
        }
        defaults.set(true, forKey: IMessageModeSettings.key)

        let workspace = tabManager.addWorkspace(select: true)
        workspaceForCleanup = workspace
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        panelForCleanup = panel
        workspace.recordAgentPID(
            key: "codex.unverified-prompt",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        let submission = panel.surface.sendPromptSubmission(
            "app-owned prompt",
            submitKey: "return",
            hookRecordingSource: "workspace.agent_submit"
        )
        #expect(submission.accepted)
        #expect(workspace.latestSubmittedMessage == nil)

        let event = WorkstreamEvent(
            sessionId: "unverified-prompt",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            ppid: Int(getpid()),
            toolInputJSON: #"{"prompt":"foreign human hook"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(
            workspace.latestSubmittedMessage == nil,
            "An unverified hook must not fall through to generic workspace prompt recording"
        )
    }

    @MainActor
    @Test func hookWithoutPIDCannotUseGenericPromptRouting() throws {
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
            key: "codex.missing-hook-pid",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)

        let event = WorkstreamEvent(
            sessionId: "missing-hook-pid",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            ppid: nil,
            toolInputJSON: #"{"prompt":"human prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
        #expect(workspace.latestSubmittedMessage == nil)
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
    @Test func explicitSurfaceHookMustMatchTheAgentSession() throws {
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
            key: "codex.real-session",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)

        let event = WorkstreamEvent(
            sessionId: "different-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            toolInputJSON: #"{"prompt":"wrong session"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func explicitSurfaceHookAcceptsSourcePrefixedSession() throws {
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
            key: "codex.real-session",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)

        let event = WorkstreamEvent(
            sessionId: "codex-real-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            ppid: Int(getpid()),
            toolInputJSON: #"{"prompt":"real prompt"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @MainActor
    @Test func legacyClaudeHookRequiresTheCurrentProcessBinding() throws {
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
            key: "claude_code",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.recordHumanPromptInput(.unknown)
        panel.surface.recordHumanPromptInput(.submissionBoundary)

        let event = WorkstreamEvent(
            sessionId: "restarted-claude-session",
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            ppid: Int(getpid()) + 1,
            toolInputJSON: #"{"prompt":"stale hook"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: event)

        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        let currentEvent = WorkstreamEvent(
            sessionId: "restarted-claude-session",
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            ppid: Int(getpid()),
            toolInputJSON: #"{"prompt":"current hook"}"#
        )
        TerminalController.shared.v2ApplyIMessageModeSideEffects(for: currentEvent)

        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)
    }

    @Test func livePromptScopeOverridesStaleLaunchHintsForSubmitKey() {
        let submitKey = TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: true,
            context: "initialCommand:claude\nagentPIDKey:codex.current",
            agentInputScope:
                "agentPIDKey:codex.current|pid:123|start:1.0"
        )

        #expect(submitKey == "return")
    }

    @MainActor
    @Test func staleCachedAgentIdentityCannotProvidePromptScope() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(
            workspace.terminalInputTarget(forPanelID: panelID)?.panel
        )
        defer { panel.surface.releaseSurfaceForTesting() }

        let key = "codex.stale-session"
        workspace.recordAgentPID(
            key: key,
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        var pids = workspace.agentPIDs
        pids[key] = pid_t.max - 1
        workspace.agentPIDs = pids

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)
    }

    @MainActor
    @Test func agentSubmitAcceptsWorkspaceAndSurfaceRefs() throws {
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
            key: "codex.ref-session",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        panel.surface.releaseSurfaceForTesting()

        let workspaceRef = try #require(
            TerminalController.shared.v2Ref(
                kind: .workspace,
                uuid: workspace.id
            ) as? String
        )
        let surfaceRef = try #require(
            TerminalController.shared.v2Ref(
                kind: .surface,
                uuid: panelID
            ) as? String
        )
        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": workspaceRef,
            "surface_id": surfaceRef,
            "text": "prompt through refs",
        ])

        guard case .ok(let rawPayload) = result else {
            Issue.record("Expected workspace and surface refs to resolve")
            return
        }
        let payload = try #require(rawPayload as? [String: Any])
        #expect(payload["submitted"] as? Bool == true)
        #expect(payload["queued"] as? Bool == true)
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
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            otherPanel.surface.releaseSurfaceForTesting()
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
            ppid: Int(getpid()),
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
        let oversizedPayload = String(
            repeating: "A",
            count:
                TerminalPasteboardService.maximumBase64ImageByteCount + 1
        )

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

    @MainActor
    @Test func mobileChatAttachmentsCleanUpAfterPromptHookConsumption() {
        var cleanedURLs: [URL] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            cleanupMobileChatAttachments: { urls in
                cleanedURLs.append(contentsOf: urls)
            }
        )
        let firstAttachmentURL = URL(fileURLWithPath: "/tmp/cmux-mobile-chat-1.png")
        let secondAttachmentURL = URL(fileURLWithPath: "/tmp/cmux-mobile-chat-2.png")
        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(
            service.registerMobileChatAttachmentFiles(
                [firstAttachmentURL],
                sessionID: "mobile-chat-session",
                surfaceID: "surface-mobile-chat",
                fileCount: 1,
                prompt: "/tmp/cmux-mobile-chat-1.png"
            )
        )
        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(
            service.registerMobileChatAttachmentFiles(
                [secondAttachmentURL],
                sessionID: "mobile-chat-session",
                surfaceID: "surface-mobile-chat",
                fileCount: 1,
                prompt: "/tmp/cmux-mobile-chat-2.png"
            )
        )

        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: "mobile-chat-session",
                hookEventName: .userPromptSubmit,
                source: "codex",
                surfaceId: "surface-mobile-chat",
                toolInputJSON: #"{"prompt":"/tmp/cmux-mobile-chat-1.png"}"#
            )
        )
        #expect(cleanedURLs.isEmpty)

        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: "mobile-chat-session",
                hookEventName: .stop,
                source: "codex",
                surfaceId: "surface-mobile-chat"
            )
        )

        #expect(cleanedURLs == [firstAttachmentURL])

        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: "mobile-chat-session",
                hookEventName: .userPromptSubmit,
                source: "codex",
                surfaceId: "surface-mobile-chat",
                toolInputJSON: #"{"prompt":"/tmp/cmux-mobile-chat-2.png"}"#
            )
        )
        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: "mobile-chat-session",
                hookEventName: .stop,
                source: "codex",
                surfaceId: "surface-mobile-chat"
            )
        )
        #expect(cleanedURLs == [firstAttachmentURL, secondAttachmentURL])
    }

    @MainActor
    @Test func mobileChatAttachmentDiscardRemovesOnlyExactBatch() {
        var cleanedURLs: [URL] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            cleanupMobileChatAttachments: { urls in
                cleanedURLs.append(contentsOf: urls)
            }
        )
        let firstURL = URL(fileURLWithPath: "/tmp/cmux-mobile-chat-discard-1.png")
        let secondURL = URL(fileURLWithPath: "/tmp/cmux-mobile-chat-discard-2.png")
        let sessionID = "mobile-chat-discard-session"
        let surfaceID = "surface-mobile-chat-discard"

        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(
            service.registerMobileChatAttachmentFiles(
                [firstURL],
                sessionID: sessionID,
                surfaceID: surfaceID,
                fileCount: 1,
                prompt: firstURL.path
            )
        )
        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(
            service.registerMobileChatAttachmentFiles(
                [secondURL],
                sessionID: sessionID,
                surfaceID: surfaceID,
                fileCount: 1,
                prompt: secondURL.path
            )
        )

        #expect(
            !service.discardMobileChatAttachmentBatch(
                [URL(fileURLWithPath: "/tmp/cmux-mobile-chat-wrong.png")],
                sessionID: sessionID,
                surfaceID: surfaceID
            )
        )
        #expect(cleanedURLs.isEmpty)
        #expect(
            service.discardMobileChatAttachmentBatch(
                [firstURL],
                sessionID: sessionID,
                surfaceID: surfaceID
            )
        )
        #expect(cleanedURLs == [firstURL])

        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .userPromptSubmit,
                source: "codex",
                surfaceId: surfaceID,
                toolInputJSON: #"{"prompt":"/tmp/cmux-mobile-chat-discard-2.png"}"#
            )
        )
        service.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .stop,
                source: "codex",
                surfaceId: surfaceID
            )
        )
        #expect(cleanedURLs == [firstURL, secondURL])
    }

    @MainActor
    @Test func mobileChatAttachmentReservationExpiresBeforeNewAdmission() {
        var now = Date(timeIntervalSince1970: 10)
        var cleanedURLs: [URL] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            cleanupMobileChatAttachments: { urls in
                cleanedURLs.append(contentsOf: urls)
            },
            now: { now }
        )
        let expiredURL = URL(fileURLWithPath: "/tmp/cmux-expiring-mobile-chat.png")
        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(
            service.registerMobileChatAttachmentFiles(
                [expiredURL],
                sessionID: "expiring-session",
                surfaceID: "expiring-surface",
                fileCount: 1,
                prompt: "/tmp/cmux-expiring-mobile-chat.png"
            )
        )

        now = now.addingTimeInterval(31 * 60)
        #expect(service.reserveMobileChatAttachmentBatch(fileCount: 1))
        #expect(cleanedURLs == [expiredURL])
        service.releaseMobileChatAttachmentBatchReservation(fileCount: 1)
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

        guard case .err(let code, _, let rawData) = result else {
            Issue.record("Expected agent_scope_unavailable")
            return
        }
        let data = try #require(rawData as? [String: Any])
        #expect(code == "agent_scope_unavailable")
        #expect(data["workspace_id"] as? String == workspace.id.uuidString)
        #expect(data["surface_id"] as? String == panelID.uuidString)
        #expect(data["retryable"] as? Bool == true)
        #expect(data["retry_after"] as? String == "agent_terminal_ready")
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
        guard case .err(let busyCode, _, _) = busyResult else {
            Issue.record("Expected rejected_composer_busy")
            return
        }
        #expect(busyCode == "rejected_composer_busy")
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
