import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Persistence coverage for the workspace todo feature: the
/// `SessionWorkspaceSnapshot` status-override + checklist fields round-trip,
/// pre-feature manifests decode cleanly (and empty todo state does not bloat
/// new manifests), and the snapshot→live bridging drops garbage safely.
struct WorkspaceTodoSnapshotTests {
    private func makeSnapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
    }

    // MARK: - Codable round-trip

    @Test
    func todoFieldsRoundTrip() throws {
        var snapshot = makeSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = "working"
        let itemID = UUID()
        snapshot.checklist = [
            SessionChecklistItemSnapshot(id: itemID, text: "ship it", state: "in-progress", origin: "agent"),
        ]
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.taskStatusOverride == "review")
        #expect(decoded.taskStatusInferredAtOverride == "working")
        #expect(decoded.checklist == [
            SessionChecklistItemSnapshot(id: itemID, text: "ship it", state: "in-progress", origin: "agent"),
        ])
        #expect(decoded.restoredTaskStatusOverride == WorkspaceTaskStatusOverride(
            status: .review, inferredAtOverride: .working
        ))
        #expect(decoded.restoredChecklist == [
            WorkspaceChecklistItem(id: itemID, text: "ship it", state: .inProgress, origin: .agent),
        ])
    }

    /// A manifest written before this feature has none of the todo keys; it
    /// must decode cleanly, and empty todo state must not add keys to new
    /// manifests.
    @Test
    func todoFieldsAreOmittedWhenAbsentAndTolerated() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])
        #expect(object["taskStatusOverride"] == nil)
        #expect(object["taskStatusInferredAtOverride"] == nil)
        #expect(object["checklist"] == nil)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.taskStatusOverride == nil)
        #expect(decoded.taskStatusInferredAtOverride == nil)
        #expect(decoded.checklist == nil)
        #expect(decoded.restoredTaskStatusOverride == nil)
        #expect(decoded.restoredChecklist.isEmpty)
    }

    // MARK: - Restore bridging safety

    /// A partial or unparseable override is dropped whole: restoring a
    /// guessed `inferredAtOverride` would defeat anti-rot expiry.
    @Test
    func malformedOverrideRestoresToNil() {
        var snapshot = makeSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = nil
        #expect(snapshot.restoredTaskStatusOverride == nil)

        snapshot.taskStatusOverride = "not-a-lane"
        snapshot.taskStatusInferredAtOverride = "working"
        #expect(snapshot.restoredTaskStatusOverride == nil)
    }

    /// Unknown state/origin raw values degrade to pending/user instead of
    /// dropping the item; empty text drops the item.
    @Test
    func checklistRestoreDegradesUnknownRawValuesAndDropsEmptyText() {
        var snapshot = makeSnapshot()
        let keptID = UUID()
        snapshot.checklist = [
            SessionChecklistItemSnapshot(id: keptID, text: "  keep me  ", state: "someday", origin: "robot"),
            SessionChecklistItemSnapshot(id: UUID(), text: "   ", state: "pending", origin: "user"),
        ]
        let restored = snapshot.restoredChecklist
        #expect(restored == [
            WorkspaceChecklistItem(id: keptID, text: "keep me", state: .pending, origin: .user),
        ])
    }
}
