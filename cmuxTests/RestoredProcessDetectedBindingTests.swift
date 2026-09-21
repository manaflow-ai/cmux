import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RestoredProcessDetectedBindingTests {
    @Test(arguments: ["tmux", "ssh"])
    func workspaceSnapshotsPreservePendingRestoreAcrossEmptyScans(kind: String) throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let binding = binding(kind: kind)
        snapshot.panels[0].terminal?.resumeBinding = binding
        workspace.restoreSessionSnapshot(snapshot)
        let panelID = try #require(workspace.focusedPanelId)

        // Restore completion, timer, and lifecycle saves can all arrive before
        // the login shell has executed its queued restore command.
        for pass in 0..<8 {
            let saved = workspace.sessionSnapshot(
                includeScrollback: pass.isMultiple(of: 2),
                surfaceResumeBindingIndex: .empty
            )
            #expect(saved.panels.first?.terminal?.resumeBinding?.command == binding.command)
        }
        let detected = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: workspace.id, panelId: panelID): binding
        ])
        _ = workspace.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: detected)
        _ = workspace.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: .empty)
        let exited = workspace.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: .empty)
        #expect(exited.panels.first?.terminal?.resumeBinding == nil)
    }

    @Test(arguments: [DockScope.workspace, .global], ["tmux", "ssh"])
    func dockSnapshotsPreservePendingRestoreAcrossEmptyScans(scope: DockScope, kind: String) throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        var panel = try #require(source.sessionSnapshot(includeScrollback: false).panels.first)
        let binding = binding(kind: kind)
        panel.terminal?.resumeBinding = binding
        let dock = DockSplitStore(workspaceId: UUID(), scope: scope, baseDirectoryProvider: { "/tmp" })
        defer { dock.closeAllPanels() }
        let mapping = dock.restoreSessionSnapshot(SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel]
        ))
        let panelID = try #require(mapping[panel.id])

        for pass in 0..<8 {
            let saved = dock.sessionSnapshot(
                includeScrollback: pass.isMultiple(of: 2),
                surfaceResumeBindingIndex: pass.isMultiple(of: 2) ? .empty : nil
            )
            #expect(saved.panels.first?.terminal?.resumeBinding?.command == binding.command)
        }
        let detected = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: dock.workspaceId, panelId: panelID): binding
        ])
        _ = dock.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: detected)
        let exited = dock.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: .empty)
        #expect(exited.panels.first?.terminal?.resumeBinding == nil)
    }

    @Test func restoredBindingObservationStaysArmedUntilEvidence() throws {
        var pending = binding(kind: "tmux")
        pending.armRestoredProcessDetectionObservation()
        #expect(pending.preservesRestoredProcessDetection())
        pending.clearRestoredProcessDetectionObservation()
        #expect(!pending.preservesRestoredProcessDetection())
    }

    @Test func aFinishedCommandReleasesTheWorkspaceRestoreIntent() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.panels[0].terminal?.resumeBinding = binding(kind: "tmux")
        workspace.restoreSessionSnapshot(snapshot)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
        let saved = workspace.sessionSnapshot(includeScrollback: false, surfaceResumeBindingIndex: .empty)
        #expect(saved.panels.first?.terminal?.resumeBinding == nil)
    }

    private func binding(kind: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            kind: kind,
            command: kind == "tmux" ? "tmux attach -t restore-test" : "ssh restore-test.invalid",
            cwd: "/tmp",
            checkpointId: "restore-test",
            source: "process-detected",
            autoResume: true,
            updatedAt: 100
        )
    }
}
