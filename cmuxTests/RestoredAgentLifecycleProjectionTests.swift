import Foundation
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Autosave must not turn a read of queued restore intent into an observable write.
@MainActor
struct RestoredAgentLifecycleProjectionTests {
    private func snapshot(_ session: String, directory: String = "/tmp/queued") -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(kind: .codex, sessionId: session, workingDirectory: directory)
    }

    @Test func projectionPreservesQueuedIdentityWithoutPublishingOrChangingMetadata() async {
        let panelID = UUID()
        let lifecycle = RestoredAgentLifecycleCoordinator()
        let queued = snapshot("queued")
        lifecycle.seedSessionRestore(
            panelId: panelID, snapshot: queued, manualResumeAvailable: true,
            willRunStartupCommand: false, willRunStartupInput: true,
            resumeWorkingDirectory: queued.workingDirectory
        )
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking {
                _ = lifecycle.snapshotsByPanelId
                _ = lifecycle.resumeStatesByPanelId
            } onChange: {
                changed()
            }
            for _ in 0..<128 {
                let refreshed = lifecycle.reconcileSnapshotWithQueuedRestoreIntent(
                    panelId: panelID, proposedSnapshot: snapshot("queued", directory: "/tmp/refreshed")
                )
                #expect(refreshed?.workingDirectory == "/tmp/refreshed")
                for proposed in [nil, snapshot("unrelated")] {
                    #expect(lifecycle.reconcileSnapshotWithQueuedRestoreIntent(
                        panelId: panelID, proposedSnapshot: proposed
                    )?.sessionId == "queued")
                }
            }
        }
        #expect(lifecycle.snapshotsByPanelId[panelID]?.workingDirectory == "/tmp/queued")
        #expect(lifecycle.resumeStatesByPanelId[panelID] == .awaitingAutoResumeCommand)
    }

    @Test func repeatedObservationPublishesOnlyAnActualChange() async {
        let panelID = UUID()
        let lifecycle = RestoredAgentLifecycleCoordinator()
        let initial = snapshot("queued")
        lifecycle.setSnapshot(initial, panelId: panelID)
        lifecycle.setResumeState(.manualResumeAvailable, panelId: panelID)
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking {
                _ = lifecycle.snapshotsByPanelId
                _ = lifecycle.resumeStatesByPanelId
            } onChange: {
                changed()
            }
            for _ in 0..<128 {
                lifecycle.setSnapshot(initial, panelId: panelID)
                lifecycle.setResumeState(.manualResumeAvailable, panelId: panelID)
            }
        }
        await confirmation(expectedCount: 1) { changed in
            withObservationTracking {
                _ = lifecycle.snapshotsByPanelId
            } onChange: {
                changed()
            }
            lifecycle.setSnapshot(snapshot("queued", directory: "/tmp/new"), panelId: panelID)
        }
        #expect(lifecycle.snapshotsByPanelId[panelID]?.workingDirectory == "/tmp/new")
    }

    @Test func commandAndCompletionTransitionsReleaseOnlyTheCompletedIntent() {
        let panelID = UUID()
        let lifecycle = RestoredAgentLifecycleCoordinator(dateProvider: { 100 })
        lifecycle.seedSessionRestore(
            panelId: panelID, snapshot: snapshot("queued"), manualResumeAvailable: true,
            willRunStartupCommand: false, willRunStartupInput: true, resumeWorkingDirectory: nil
        )
        lifecycle.setResumeState(.autoResumeCommandRunning, panelId: panelID)
        lifecycle.setSnapshot(snapshot("unrelated"), panelId: panelID)
        #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == "queued")
        lifecycle.setResumeState(.completedAgentExit, panelId: panelID)
        let projected = lifecycle.reconcileSnapshotWithQueuedRestoreIntent(
            panelId: panelID, proposedSnapshot: snapshot("next")
        )
        #expect(projected?.sessionId == "next")
        #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == "queued")
        #expect(lifecycle.completedGeneration(panelId: panelID)?.completedAt == 100)
        lifecycle.setResumeState(.observedAgentCommandRunning, panelId: panelID)
        lifecycle.setSnapshot(snapshot("next"), panelId: panelID)
        #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == "next")
        #expect(lifecycle.completedGeneration(panelId: panelID) == nil)
    }
}
