import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct ProcessDetectedResumeIndexPersistenceFallbackTests {
    @Test
    func unavailableProcessIndexesProduceACoreSessionSavePlan() {
        let plan = ProcessDetectedResumeIndexSavePlan.resolve(nil)

        #expect(plan.usesCoreSnapshotFallback)
        #expect(plan.surfaceResumeBindingIndex == nil)
        #expect(
            plan.restorableAgentIndex.snapshot(workspaceId: UUID(), panelId: UUID()) == nil,
            "The fallback must explicitly suppress a second process-index load."
        )
    }

    @Test
    func coreFallbackFingerprintTracksStoredResumeBindings() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            Self.resumeBinding(checkpointId: "first"),
            panelId: panelId
        ))
        let firstFingerprint = manager.sessionAutosaveFingerprint(
            surfaceResumeBindingIndex: nil
        )

        #expect(workspace.setSurfaceResumeBinding(
            Self.resumeBinding(checkpointId: "second"),
            panelId: panelId
        ))

        #expect(
            firstFingerprint != manager.sessionAutosaveFingerprint(
                surfaceResumeBindingIndex: nil
            )
        )
    }

    private static func resumeBinding(checkpointId: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach -t \(checkpointId)",
            cwd: "/tmp/\(checkpointId)",
            checkpointId: checkpointId,
            source: "process-detected",
            updatedAt: 42
        )
    }
}
