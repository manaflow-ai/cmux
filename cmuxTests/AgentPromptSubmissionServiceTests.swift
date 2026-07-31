import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Atomic agent prompt submission")
struct AgentPromptSubmissionServiceTests {
    @Test func concurrentSubmissionsToOneWorkspaceStayIntactAndFIFO() async {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = await MainActor.run {
            AgentPromptSubmissionService()
        }
        let probe = AgentPromptFIFOProbe(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let first = Task { @MainActor in
            service.submit(
                workspaceID: workspaceID,
                delivery: {
                    probe.deliver("first", waitsForRelease: true)
                }
            )
        }
        await Task.detached {
            probe.waitUntilFirstStarted()
        }.value

        let second = Task { @MainActor in
            service.submit(
                workspaceID: workspaceID,
                delivery: {
                    probe.deliver("second", waitsForRelease: false)
                }
            )
        }

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
    @Test func sameWorkspaceReentrancyRejectsWithoutLateDelivery() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let service = AgentPromptSubmissionService()
        var delivered: [String] = []

        let outer = service.submit(
            workspaceID: workspaceID,
            delivery: {
                delivered.append("outer")
                let inner = service.submit(
                    workspaceID: workspaceID,
                    delivery: {
                        delivered.append("inner")
                        return .submitted(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID,
                            queued: false
                        )
                    }
                )
                #expect(inner == .serviceUnavailable(
                    workspaceID: workspaceID
                ))
                return .submitted(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    queued: false
                )
            }
        )

        #expect(outer == .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        ))
        #expect(delivered == ["outer"])
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
