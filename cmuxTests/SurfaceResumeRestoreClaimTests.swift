import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies the app-owned compare-and-claim boundary used by Codex restore.
@MainActor
@Suite(.serialized)
struct SurfaceResumeRestoreClaimTests {
    @Test
    func workspaceRestoreClaimRejectsReplacementAndPreservesParentBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            cwd: "/tmp/parent-cwd",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 10
        )
        let child = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume child-session",
            cwd: "/tmp/child-cwd",
            checkpointId: "child-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 11
        )

        #expect(workspace.setSurfaceResumeBinding(parent, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 10
        ))
        #expect(!workspace.setSurfaceResumeBinding(child, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == parent)
    }

    @Test
    func dockRestoreClaimConsumesOnSameSessionRefresh() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 20
        )
        let refresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            cwd: "/tmp/refreshed-cwd",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 21
        )

        #expect(store.setSurfaceResumeBinding(parent, panelId: panel.id))
        #expect(store.claimSurfaceResumeBinding(
            panelId: panel.id,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 20
        ))
        #expect(store.setSurfaceResumeBinding(refresh, panelId: panel.id))
        #expect(store.surfaceResumeBinding(panelId: panel.id) == refresh)
        #expect(store.surfaceResumeRestoreClaimsByPanelId[panel.id] == nil)
    }

    @Test
    func restoreClaimRequiresExactBindingGeneration() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 30
        )

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(!workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 31
        ))
        #expect(workspace.surfaceResumeRestoreClaimsByPanelId[panelID] == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == binding)
    }

    @Test
    func workspacePanelTeardownReleasesRestoreClaim() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume teardown-session",
            checkpointId: "teardown-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 40
        )

        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "teardown-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 40
        ))
        workspace.teardownAllPanels()

        #expect(workspace.surfaceResumeRestoreClaimsByPanelId.isEmpty)
    }

    @Test
    func workspaceReconciliationCannotReplaceClaimedCodexBinding() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let parent = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume parent-session",
            checkpointId: "parent-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui",
            updatedAt: 50
        )
        let detectedChild = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume child-session",
            checkpointId: "child-session",
            source: "process-detected",
            autoResume: true,
            updatedAt: 51
        )

        #expect(workspace.setSurfaceResumeBinding(parent, panelId: panelID))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: panelID,
            expectedCheckpointID: "parent-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: 50
        ))
        workspace.reconcileSurfaceResumeBindings(
            using: SurfaceResumeBindingIndex(bindingsByPanel: [
                .init(workspaceId: workspace.id, panelId: panelID): detectedChild,
            ]),
            restorableAgentIndex: .empty
        )

        #expect(workspace.surfaceResumeBinding(panelId: panelID) == parent)
    }
}
