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
        let workspaceID = UUID()
        let surfaceID = UUID()
        let controller = await MainActor.run { TerminalController.shared }
        let probe = AgentPromptTransactionProbe(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let first = Task.detached {
            controller.v2MainSync {
                probe.deliver("first", waitsForRelease: true)
            }
        }
        await Task.detached {
            probe.waitUntilFirstStarted()
        }.value

        let second = Task.detached {
            probe.noteSecondCallerReady()
            controller.v2MainSync {
                probe.deliver("second", waitsForRelease: false)
            }
        }
        await Task.detached {
            probe.waitUntilSecondCallerReady()
        }.value

        #expect(probe.startedMessages == ["first"])
        probe.releaseFirst()

        #expect(await first.value == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(await second.value == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(probe.startedMessages == ["first", "second"])
        #expect(probe.completedMessages == ["first", "second"])
        #expect(probe.submittedWireMessages == ["first", "second"])
        #expect(probe.maximumConcurrentDeliveries == 1)
    }

    @MainActor
    @Test func nativeHumanDraftIsUnchangedAndNoPromptIsQueued() {
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

        #expect(result == .composerBusy)
        #expect(panel.textBoxContent == "human draft")
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
        panel.surface.recordHumanPromptInput(maySubmitPrompt: false)

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
        panel.surface.recordHumanPromptInput(maySubmitPrompt: false)

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
    }
}
