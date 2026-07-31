import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Atomic agent prompt submission", .serialized)
struct AgentPromptSubmissionTests {
    @Test func concurrentSubmissionsToOneWorkspaceStayIntactAndFIFO() async {
        let controller = await MainActor.run { TerminalController.shared }
        let probe = await MainActor.run {
            let panel = TerminalPanel(workspaceId: UUID())
            panel.surface.releaseSurfaceForTesting()
            return AgentPromptTransactionProbe(surface: panel.surface)
        }
        let first = Task.detached {
            controller.v2MainSync {
                probe.deliver("first", waitsForRelease: true)
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
                _ = probe.deliver("second", waitsForRelease: false)
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
        #expect(
            await MainActor.run { probe.pendingPromptMessages }
                == ["first", "second"]
        )
        #expect(probe.maximumConcurrentDeliveries == 1)
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
    @Test func missingProcessIdentityCannotCarryComposerStateAcrossAgents() throws {
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
        panel.surface.recordHumanPromptInput(.unknown)
        #expect(panel.surface.currentPromptInputAgentScope != nil)
        #expect(panel.surface.hasUnconfirmedHumanPromptInput)

        workspace.recordAgentPID(
            key: agentKey,
            pid: pid_t.max - 1,
            panelId: panelID,
            refreshPorts: false
        )

        #expect(workspace.agentPromptInputScope(forPanelId: panelID) == nil)
        #expect(panel.surface.currentPromptInputAgentScope == nil)
        #expect(!panel.surface.hasUnconfirmedHumanPromptInput)

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
                == "agent_process_identity_available"
        )
    }

    @MainActor
    @Test func whitespaceOnlyPromptIsRejectedWithoutDelivery() {
        let result = TerminalController.shared.v2WorkspaceAgentSubmit(params: [
            "workspace_id": UUID().uuidString,
            "text": " \n\t ",
        ])

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
    }
}
