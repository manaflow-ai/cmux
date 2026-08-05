import CmuxTerminal
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SessionPersistenceRuntimeTests {
    @Test
    func urgentLifecycleSaveUsesColdNonScanningPlanWithoutDiscardingLiveBinding() throws {
        let runtime = SessionPersistenceRuntime()
        let savePlan = runtime.urgentSavePlan()
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let storedBinding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach -t lifecycle-save",
            cwd: "/tmp/lifecycle-save",
            checkpointId: "lifecycle-save",
            source: "process-detected",
            autoResume: true,
            updatedAt: 10
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = storedBinding

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: savePlan.restorableAgentIndex,
            surfaceResumeBindingIndex: savePlan.surfaceResumeBindingIndex
        )

        #expect(savePlan.surfaceResumeBindingIndex == nil)
        #expect(
            savePlan.restorableAgentIndex.snapshot(
                workspaceId: workspace.id,
                panelId: panelID
            ) == nil
        )
        #expect(
            snapshot.panels.first(where: { $0.id == panelID })?.terminal?.resumeBinding
                == storedBinding
        )
    }

    @Test
    func urgentLifecycleSaveKeepsLastKnownIndexesWhileRefreshIsPending() async {
        let workspaceID = UUID()
        let panelID = UUID()
        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceID,
            panelId: panelID
        )
        let lastKnownBinding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t last-known",
            checkpointId: "last-known",
            source: "process-detected",
            updatedAt: 10
        )
        let refreshedBinding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t refreshed",
            checkpointId: "refreshed",
            source: "process-detected",
            updatedAt: 20
        )
        let runtime = SessionPersistenceRuntime(
            latest: ProcessDetectedResumeIndexes(
                restorableAgentIndex: .empty,
                surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                    bindingsByPanel: [key: lastKnownBinding]
                )
            )
        )
        let refreshStarted = SessionPersistenceLifecycleSaveGate()
        let allowRefreshToFinish = SessionPersistenceLifecycleSaveGate()
        let refreshTask = Task { @MainActor in
            await runtime.refresh {
                await refreshStarted.open()
                await allowRefreshToFinish.wait()
                return ProcessDetectedResumeIndexes(
                    restorableAgentIndex: .empty,
                    surfaceResumeBindingIndex: SurfaceResumeBindingIndex(
                        bindingsByPanel: [key: refreshedBinding]
                    )
                )
            }
        }
        await refreshStarted.wait()

        #expect(
            runtime.urgentSavePlan().surfaceResumeBindingIndex?.binding(
                workspaceId: workspaceID,
                panelId: panelID
            ) == lastKnownBinding
        )

        await allowRefreshToFinish.open()
        _ = await refreshTask.value
        #expect(
            runtime.urgentSavePlan().surfaceResumeBindingIndex?.binding(
                workspaceId: workspaceID,
                panelId: panelID
            ) == refreshedBinding
        )
    }

    @Test
    func repeatedAutosaveReusesLargeTextBoxDraftStorage() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelID))

        terminalPanel.textBoxContent = "before"
        terminalPanel.textBoxAttachments = (0..<1_000).map { index in
            TextBoxAttachment(
                displayName: "file-\(index).txt",
                submissionText: "/tmp/file-\(index).txt",
                submissionPath: "/tmp/file-\(index).txt",
                localURL: nil
            )
        }

        let first = try #require(terminalPanel.sessionTextBoxDraftSnapshot())
        let second = try #require(terminalPanel.sessionTextBoxDraftSnapshot())
        let firstStorage = first.parts.withUnsafeBufferPointer { $0.baseAddress }
        let secondStorage = second.parts.withUnsafeBufferPointer { $0.baseAddress }

        #expect(first.parts.count == 1_001)
        #expect(second.parts.count == 1_001)
        #expect(
            firstStorage == secondStorage,
            "Periodic autosave must reuse an unchanged large draft instead of rebuilding every attachment."
        )
    }
}
