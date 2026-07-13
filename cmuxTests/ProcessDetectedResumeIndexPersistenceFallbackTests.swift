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

    @Test
    func unavailableIndexesRejectStaleProcessBindingAndPreserveDurableBinding() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            Self.resumeBinding(checkpointId: "stale"),
            panelId: panelId
        ))

        let plan = ProcessDetectedResumeIndexSavePlan.resolve(.completed(nil))
        let snapshot = try #require(app.debugBuildSessionSnapshotForTesting(
            includeScrollback: false,
            surfaceResumeBindingIndex: plan.surfaceResumeBindingIndex
        ))
        let savedWorkspace = try #require(snapshot.windows.first?.tabManager.workspaces.first)

        #expect(plan.usesCoreSnapshotFallback)
        #expect(savedWorkspace.workspaceId == workspace.id)
        #expect(savedWorkspace.panels.first(where: { $0.id == panelId })?
            .terminal?.resumeBinding == nil)

        #expect(workspace.setSurfaceResumeBinding(
            Self.resumeBinding(checkpointId: "durable", source: "cli"),
            panelId: panelId
        ))
        let durableSnapshot = try #require(app.debugBuildSessionSnapshotForTesting(
            includeScrollback: false,
            surfaceResumeBindingIndex: plan.surfaceResumeBindingIndex
        ))
        let durableWorkspace = try #require(durableSnapshot.windows.first?.tabManager.workspaces.first)

        #expect(durableWorkspace.panels.first(where: { $0.id == panelId })?
            .terminal?.resumeBinding?.checkpointId == "durable")
    }

    private static func resumeBinding(
        checkpointId: String,
        source: String = "process-detected"
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach -t \(checkpointId)",
            cwd: "/tmp/\(checkpointId)",
            checkpointId: checkpointId,
            source: source,
            updatedAt: 42
        )
    }
}
