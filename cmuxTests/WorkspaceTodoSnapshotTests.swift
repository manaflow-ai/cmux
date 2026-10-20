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
        let attachment = WorkspaceChecklistAttachment(
            displayName: "screenshot.png",
            filePath: "/tmp/screenshot.png",
            byteCount: 512,
            contentTypeIdentifier: "public.png",
            pixelWidth: 320,
            pixelHeight: 200
        )
        snapshot.checklist = [
            SessionChecklistItemSnapshot(
                id: itemID,
                text: "ship it",
                state: "in-progress",
                origin: "agent",
                attachments: [attachment]
            ),
        ]
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.taskStatusOverride == "review")
        #expect(decoded.taskStatusInferredAtOverride == "working")
        #expect(decoded.checklist == [
            SessionChecklistItemSnapshot(
                id: itemID,
                text: "ship it",
                state: "in-progress",
                origin: "agent",
                attachments: [attachment]
            ),
        ])
        #expect(decoded.restoredTaskStatusOverride == WorkspaceTaskStatusOverride(
            status: .review, inferredAtOverride: .working
        ))
        #expect(decoded.restoredChecklist == [
            WorkspaceChecklistItem(
                id: itemID,
                text: "ship it",
                state: .inProgress,
                origin: .agent,
                attachments: [attachment]
            ),
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

    /// Fresh workspaces opt out of status glyphs by default, while
    /// pre-existing manifests that lack the field still restore to the
    /// historical Auto/visible state.
    @MainActor
    @Test
    func newWorkspaceDefaultsToHiddenStatusWithoutChangingLegacyRestore() {
        let workspace = Workspace()
        #expect(workspace.todoState.statusHidden)

        let snapshot = makeSnapshot()
        workspace.restoreTodoState(from: snapshot)
        #expect(!workspace.todoState.statusHidden)
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
        let attachment = WorkspaceChecklistAttachment(displayName: "image.png", filePath: "/tmp/image.png")
        snapshot.checklist = [
            SessionChecklistItemSnapshot(
                id: keptID,
                text: "  keep me  ",
                state: "someday",
                origin: "robot",
                attachments: [attachment]
            ),
            SessionChecklistItemSnapshot(id: UUID(), text: "   ", state: "pending", origin: "user"),
        ]
        let restored = snapshot.restoredChecklist
        #expect(restored == [
            WorkspaceChecklistItem(
                id: keptID,
                text: "keep me",
                state: .pending,
                origin: .user,
                attachments: [attachment]
            ),
        ])
    }

    @Test
    func checklistRestoreIgnoresOrDegradesMalformedAttachments() throws {
        let itemID = UUID()
        let validAttachmentID = UUID()
        let snapshotData = try JSONEncoder().encode(makeSnapshot())
        let raw = try JSONSerialization.jsonObject(with: snapshotData)
        var object = try #require(raw as? [String: Any])
        object["checklist"] = [
            [
                "id": itemID.uuidString,
                "text": "inspect image",
                "state": "pending",
                "origin": "user",
                "attachments": [
                    [
                        "id": validAttachmentID.uuidString,
                        "displayName": " image.png ",
                        "filePath": "/tmp/image.png",
                        "byteCount": 256,
                        "contentTypeIdentifier": " public.png ",
                        "pixelWidth": 100,
                        "pixelHeight": 80,
                    ],
                    [
                        "displayName": "",
                        "filePath": "/tmp/fallback.jpg",
                        "byteCount": -10,
                        "contentTypeIdentifier": " ",
                        "pixelWidth": 0,
                        "pixelHeight": -1,
                    ],
                    [
                        "displayName": "missing-path.png",
                    ],
                    99,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        let restored = decoded.restoredChecklist
        let item = try #require(restored.first)
        #expect(restored.count == 1)
        #expect(item.id == itemID)
        #expect(item.attachments.count == 2)
        #expect(item.attachments[0] == WorkspaceChecklistAttachment(
            id: validAttachmentID,
            displayName: "image.png",
            filePath: "/tmp/image.png",
            byteCount: 256,
            contentTypeIdentifier: "public.png",
            pixelWidth: 100,
            pixelHeight: 80
        ))
        #expect(item.attachments[1].displayName == "fallback.jpg")
        #expect(item.attachments[1].filePath == "/tmp/fallback.jpg")
        #expect(item.attachments[1].byteCount == nil)
        #expect(item.attachments[1].contentTypeIdentifier == nil)
        #expect(item.attachments[1].pixelWidth == nil)
        #expect(item.attachments[1].pixelHeight == nil)
    }
}
