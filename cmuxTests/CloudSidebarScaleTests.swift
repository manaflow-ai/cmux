import AppKit
import Bonsplit
import Foundation
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Repro for #12481: the same accepted state and one changed row at 20/50/100 workspaces.
@MainActor
@Suite("Cloud sidebar scale", .serialized)
struct CloudSidebarScaleTests {
    @Test(arguments: [20, 50, 100])
    func notificationReplayDoesNotWritePreferences(workspaceCount: Int) async throws {
        let suite = "CloudSidebarScaleTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        let sync = CloudNotificationSync(
            machineID: "scale", clientID: "mac-scale", store: store,
            resolveTarget: { _ in nil }, deliver: { _, _ in true }, send: { _ in }
        )
        defer { sync.retire() }
        // Each workspace emits a catalog delta that does not change notifications.
        for _ in 0..<workspaceCount { sync.apply(rows: []) }
        await store.flush()
        let writes = defaults.writes
        print("CLOUD_SIDEBAR_SCALE workspaces=\(workspaceCount) replay_writes=\(writes.total) main_thread_writes=\(writes.main)")
        #expect(writes.total == 0, "Unchanged notification state must not write preferences.")
    }

    @Test
    func notificationTransitionDoesNotWriteOnMainThread() async throws {
        let suite = "CloudSidebarScaleTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudNotificationSyncStore(defaults: defaults)
        let sync = CloudNotificationSync(
            machineID: "scale", clientID: "mac-scale",
            store: store,
            resolveTarget: { _ in .init(workspaceID: UUID(), panelID: nil) },
            deliver: { _, _ in true }, send: { _ in }
        )
        defer { sync.retire() }
        sync.apply(rows: [CloudVMNotificationRow(
            id: "notification-1", title: "Done", subtitle: nil, body: "", level: "info",
            createdAtMs: 1, terminalID: "terminal-1", readBy: []
        )])
        #expect(sync.state.delivered == ["notification-1"])
        await store.flush()
        #expect(defaults.writes.total == 1)
        #expect(defaults.writes.main == 0, "Encoding and preference writes cannot run on the UI actor.")
    }

    @Test(arguments: [20, 50, 100])
    func oneChangedRowDoesNotReconfigureOtherWorkspaces(workspaceCount: Int) throws {
        let suite = "CloudSidebarScaleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tabDragTransferRegistry = TabDragTransferRegistry()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions, nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            tabDragTransferRegistry: { tabDragTransferRegistry }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        container.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(workspaceCount + 1) * 36)
        let outline = try #require(coordinator.outlineView)
        let delegate = RecordingDelegate()
        outline.delegate = delegate
        let ids = (0..<workspaceCount).map { _ in UUID() }
        let initial = Self.nodes(ids: ids)
        coordinator.apply(nodes: initial)
        outline.expandItem(initial[0], expandChildren: true)
        Self.realizeRows(outline, container: container)
        #expect(outline.numberOfRows == workspaceCount + 1)
        #expect(delegate.configuredIDs.count == workspaceCount + 1, "The fixture must actually realize all rows.")
        let selectedRow = 2
        outline.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        let selectedNode = try #require(outline.item(atRow: selectedRow) as? CloudTreeNode)

        delegate.configuredIDs = []
        coordinator.apply(nodes: Self.nodes(ids: ids))
        Self.realizeRows(outline, container: container)
        #expect(delegate.configuredIDs.isEmpty, "An equal snapshot must leave all cells alone.")

        let changedID = ids[0].uuidString
        delegate.configuredIDs = []
        coordinator.apply(nodes: Self.nodes(ids: ids, renamed: ids[0]))
        Self.realizeRows(outline, container: container)
        print("CLOUD_SIDEBAR_SCALE workspaces=\(workspaceCount) changed_rows=1 configured_rows=\(delegate.configuredIDs.count)")
        #expect(delegate.configuredIDs == [changedID], "One workspace rename must reconfigure exactly that row.")
        #expect(outline.item(atRow: selectedRow) as? CloudTreeNode === selectedNode)
        #expect(outline.selectedRow == selectedRow)
        #expect(outline.isItemExpanded(initial[0]))
        #expect((outline.item(atRow: 1) as? CloudTreeNode)?.searchableTitle == "Renamed")

        let clock = ContinuousClock()
        let replacement = Self.nodes(ids: ids, renamed: ids[0])
        let duration = clock.measure {
            for _ in 0..<100 { coordinator.apply(nodes: replacement) }
        }
        print("CLOUD_SIDEBAR_SCALE workspaces=\(workspaceCount) equal_applies=100 duration=\(duration)")
    }

    private static func nodes(ids: [UUID], renamed: UUID? = nil) -> [CloudTreeNode] {
        [CloudTreeNode(
            id: "local", kind: .localMachine(.init(name: "This Mac", terminalCount: ids.count, browserCount: 0)),
            children: ids.map { id in
                CloudTreeNode(id: id.uuidString, kind: .localWorkspace(.init(
                    workspaceID: id, title: id == renamed ? "Renamed" : "Workspace \(id)",
                    terminalCount: 1, isSelected: false
                )))
            }
        )]
    }

    private static func realizeRows(_ outline: NSOutlineView, container: NSView) {
        container.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    private final class RecordingDelegate: NSObject, NSOutlineViewDelegate {
        var configuredIDs: [String] = []
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? CloudTreeNode else { return nil }
            configuredIDs.append(node.id)
            return NSTextField(labelWithString: node.searchableTitle)
        }
    }

    // Foundation invokes this synchronous override from either executor. The lock
    // protects only the test's recorder, never production persistence or UI state.
    private final class RecordingDefaults: UserDefaults {
        private let recorded = OSAllocatedUnfairLock(initialState: (total: 0, main: 0))
        var writes: (total: Int, main: Int) { recorded.withLock { $0 } }
        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName.hasPrefix("cloud.notifications.sync.") {
                recorded.withLock {
                    $0.total += 1
                    if Thread.isMainThread { $0.main += 1 }
                }
            }
            super.set(value, forKey: defaultName)
        }
    }

    private static let machineActions = MachineRowActions(
        setupVPN: { _ in }, openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
        confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {}
    )
    private static let nodeActions = CloudTreeNodeActions(
        project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in }, projectInLocalWorkspace: { _, _ in },
        projectRemoteViewInLocalWorkspace: { _, _, _ in }, newTerminal: { _, _ in }, openGroup: { _, _, _, _ in },
        openGroupAsWorkspace: { _, _, _ in }, newWorkspace: { _ in }, closeTerminal: { _ in },
        closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in }, renameTerminal: { _, _ in },
        selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}
    )
}
