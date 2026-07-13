import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Model/persistence-layer coverage for the kanban board's Stage 1 foundation:
/// the `KanbanColumn` config value type and the `SessionWorkspaceSnapshot`
/// fields that carry a workspace's column assignment across restarts.
@Suite struct KanbanColumnAssignmentTests {
    // MARK: - SessionWorkspaceSnapshot round-trip

    @Test
    func kanbanFieldsRoundTripThroughSnapshotEncoding() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            kanbanColumnId: "in-progress",
            kanbanOrder: 12.5
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.kanbanColumnId == "in-progress")
        #expect(decoded.kanbanOrder == 12.5)
    }

    /// A manifest written before the kanban board has no `kanbanColumnId` /
    /// `kanbanOrder` keys at all; it must decode with both fields nil (and a
    /// nil pair must not bloat new manifests) so a card with no assignment
    /// lands in the default column.
    @Test
    func absentKanbanFieldsDecodeAsNilForBackCompat() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
        let data = try JSONEncoder().encode(snapshot)
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])
        #expect(object["kanbanColumnId"] == nil, "nil kanbanColumnId should be omitted from the manifest")
        #expect(object["kanbanOrder"] == nil, "nil kanbanOrder should be omitted from the manifest")

        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.kanbanColumnId == nil)
        #expect(decoded.kanbanOrder == nil)
    }

    // MARK: - KanbanColumn.defaults

    @Test
    func defaultsSeedExactlyOneArchiveColumn() {
        let archiveColumns = KanbanColumn.defaults.filter(\.isArchive)
        #expect(archiveColumns.count == 1)
        #expect(archiveColumns.first?.id == "archive")
    }

    @Test
    func defaultsHaveExpectedIdsTitlesAndOrder() {
        let defaults = KanbanColumn.defaults
        #expect(defaults.map(\.id) == ["todo", "in-progress", "done", "archive"])
        #expect(defaults.map(\.title) == ["To Do", "In Progress", "Done", "Archive"])
        #expect(defaults.map(\.order) == [0, 1, 2, 3])
        #expect(defaults.last?.isCollapsed == true)
        #expect(defaults.dropLast().allSatisfy { !$0.isArchive && !$0.isCollapsed })
    }

    @Test
    func columnRoundTripsThroughSettingCodable() {
        let column = KanbanColumn(
            id: "review",
            title: "Review",
            order: 5,
            colorHex: "#C0392B",
            isArchive: false,
            isCollapsed: true
        )
        #expect(KanbanColumn.decodeFromJSON(column.encodeForJSON()) == column)
    }
}
