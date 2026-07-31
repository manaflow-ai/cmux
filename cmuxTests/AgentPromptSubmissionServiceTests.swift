import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Atomic agent prompt submission")
struct AgentPromptSubmissionServiceTests {
    @MainActor
    @Test func concurrentSubmissionsToOneWorkspaceStayIntactAndFIFO() async {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService()
        let probe = AgentPromptFIFOProbe(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let results = AsyncStream<AgentPromptSubmissionResult>.makeStream()
        defer { results.continuation.finish() }

        service.enqueue(
            workspaceID: workspaceID,
            delivery: {
                await probe.deliver("first", waitsForRelease: true)
            },
            completion: { result in
                results.continuation.yield(result)
            }
        )
        await probe.waitUntilFirstStarted()

        service.enqueue(
            workspaceID: workspaceID,
            delivery: {
                await probe.deliver("second", waitsForRelease: false)
            },
            completion: { result in
                results.continuation.yield(result)
            }
        )

        let startedBeforeRelease = await probe.startedMessages
        #expect(startedBeforeRelease == ["first"])
        await probe.releaseFirst()

        var resultIterator = results.stream.makeAsyncIterator()
        #expect(await resultIterator.next() == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(await resultIterator.next() == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        let startedMessages = await probe.startedMessages
        let completedMessages = await probe.completedMessages
        let submittedWireMessages = await probe.submittedWireMessages
        let maximumConcurrentDeliveries =
            await probe.maximumConcurrentDeliveries
        #expect(startedMessages == ["first", "second"])
        #expect(completedMessages == ["first", "second"])
        #expect(submittedWireMessages == ["first", "second"])
        #expect(maximumConcurrentDeliveries == 1)
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
            hookRecording: .alreadyRecorded
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
    @Test func rejectedTextBoxSubmissionNeverFallsBackToSplitWrites() {
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
        #expect(pending.items == 0)
        #expect(completion?.failure == .terminalWriteRejected)
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
