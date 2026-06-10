import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Closed item history persistence, async load, remap, and recently-closed menu snapshots
extension TabManagerSessionSnapshotTests {
    func testRestoreSessionSnapshotPrunesClosedPanelsForReplacedWorkspaces() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Stale Replaced Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.customTitle = "Preserved Closed Workspace"
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount, 2)

        manager.restoreSessionSnapshot(manager.sessionSnapshot(includeScrollback: false))

        let menuSnapshot = ClosedItemHistoryStore.shared.menuSnapshot()
        XCTAssertEqual(menuSnapshot.items.map(\.title), ["Preserved Closed Workspace"])
    }

    func testRecentlyClosedMenuSnapshotListsPanelWorkspaceAndWindowRowsNewestFirst() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.setCustomTitle("Workspace Row")

        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Panel Row"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        let windowSnapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspaceSnapshot, workspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(snapshot: windowSnapshot)))

        let snapshot = ClosedItemHistoryStore.shared.menuSnapshot()

        XCTAssertEqual(snapshot.totalItemCount, 3)
        XCTAssertFalse(snapshot.isLimited)
        XCTAssertEqual(snapshot.items.map(\.title), ["Window", "Workspace Row", "Panel Row"])
        XCTAssertEqual(snapshot.items.map(\.detail), ["2 workspaces", "Workspace", "Tab"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.menuTitle.contains("\n") })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.menuSubtitle.contains("Closed") })
    }

    func testClosedItemHistoryPersistsRecordsWithoutSharedCapacityLimit() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.json", isDirectory: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let store = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )

        for index in 0..<3 {
            var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
            workspaceSnapshot.customTitle = "Closed Workspace \(index)"
            store.push(ClosedItemHistoryRecord(
                closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entry: .workspace(ClosedWorkspaceHistoryEntry(
                    workspaceId: UUID(),
                    windowId: nil,
                    workspaceIndex: index,
                    snapshot: workspaceSnapshot
                ))
            ))
        }

        let restoredStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        let snapshot = restoredStore.menuSnapshot()

        XCTAssertEqual(snapshot.totalItemCount, 3)
        XCTAssertFalse(snapshot.isLimited)
        XCTAssertEqual(snapshot.items.map(\.title), [
            "Closed Workspace 2",
            "Closed Workspace 1",
            "Closed Workspace 0"
        ])

        restoredStore.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testClosedItemHistoryAsyncLoadMergesEarlyMutation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.json", isDirectory: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let seedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        var persistedSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        persistedSnapshot.customTitle = "Persisted Workspace"
        seedStore.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: 0,
                snapshot: persistedSnapshot
            ))
        ))

        let loadingStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: false,
            persistsRecordsSynchronously: true
        )
        var earlySnapshot = workspace.sessionSnapshot(includeScrollback: false)
        earlySnapshot.customTitle = "Early Workspace"
        loadingStore.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 2),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: 1,
                snapshot: earlySnapshot
            ))
        ))

        waitForClosedHistoryCount(2, in: loadingStore)

        XCTAssertEqual(loadingStore.menuSnapshot().items.map(\.title), [
            "Early Workspace",
            "Persisted Workspace"
        ])
    }

    func testClosedItemHistoryFlushPendingSavesPersistsLatestRecords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.json", isDirectory: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let store = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadPersisted: false
        )
        var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.customTitle = "Flushed Workspace"
        store.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: nil,
                workspaceIndex: 0,
                snapshot: workspaceSnapshot
            ))
        ))

        store.flushPendingSaves()

        let restoredStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        XCTAssertEqual(restoredStore.menuSnapshot().items.map(\.title), ["Flushed Workspace"])
    }

    func testClosedItemHistoryAsyncLoadReplaysQueuedPanelWorkspaceRemap() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-remap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.json", isDirectory: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Persisted Closed Tab"
        let oldWorkspaceId = workspace.id
        let newWorkspaceId = UUID()
        let oldPanelId = panelSnapshot.id
        let newPanelId = UUID()
        let recordId = UUID()
        let seedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        seedStore.push(ClosedItemHistoryRecord(
            id: recordId,
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: oldWorkspaceId,
                paneId: UUID(),
                paneAnchorPanelId: oldPanelId,
                tabIndex: 0,
                snapshot: panelSnapshot,
                fallbackSplitPlacement: ClosedPanelSplitPlacement(
                    orientation: .horizontal,
                    insertFirst: false,
                    anchorPanelId: oldPanelId
                )
            ))
        ))

        let loadingStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: false,
            persistsRecordsSynchronously: true
        )
        loadingStore.remapPanelWorkspaceIds(
            from: oldWorkspaceId,
            to: newWorkspaceId,
            panelIdMap: [oldPanelId: newPanelId]
        )

        waitForClosedHistoryCount(1, in: loadingStore)

        let remappedRecord = try XCTUnwrap(loadingStore.removeRecord(id: recordId)?.record)
        guard case .panel(let entry) = remappedRecord.entry else {
            return XCTFail("Expected persisted panel record")
        }
        XCTAssertEqual(entry.workspaceId, newWorkspaceId)
        XCTAssertEqual(entry.paneAnchorPanelId, newPanelId)
        XCTAssertEqual(entry.fallbackSplitPlacement?.anchorPanelId, newPanelId)
        XCTAssertFalse(entry.restoreInOriginalPane)
    }

    func testSessionRestoreRemapsPersistedClosedPanelWorkspaceIds() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let sourceManager = TabManager()
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("Restored Parent")
        let pane = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        sourceWorkspace.setPanelCustomTitle(panelId: panelId, title: "Persisted Closed Tab")
        let sourceSnapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(
            sourceWorkspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )

        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: sourceWorkspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        let restoreManager = TabManager()
        _ = restoreManager.restoreSessionSnapshot(sourceSnapshot)
        let restoredWorkspace = try XCTUnwrap(restoreManager.tabs.first { $0.customTitle == "Restored Parent" })
        XCTAssertNotEqual(restoredWorkspace.id, sourceWorkspace.id)

        XCTAssertTrue(restoreManager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(restoredWorkspace.panelCustomTitles.values.contains("Persisted Closed Tab"))
    }

    func testRecentlyClosedWorkspaceTitleIgnoresDotDirectoryFallback() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.customTitle = nil
        workspaceSnapshot.processTitle = ""
        workspaceSnapshot.currentDirectory = "."

        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.first?.title,
            String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
        )
    }

    func testRecentlyClosedMenuSnapshotLimitsPreviewButKeepsFullCount() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)

        for index in 0..<12 {
            var snapshot = panelSnapshot
            snapshot.customTitle = "Panel \(index)"
            ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: index,
                snapshot: snapshot
            )))
        }

        let limitedSnapshot = ClosedItemHistoryStore.shared.menuSnapshot(maxItemCount: 10)

        XCTAssertEqual(limitedSnapshot.totalItemCount, 12)
        XCTAssertTrue(limitedSnapshot.isLimited)
        XCTAssertEqual(limitedSnapshot.items.count, 10)
        XCTAssertEqual(limitedSnapshot.items.first?.title, "Panel 11")
        XCTAssertEqual(limitedSnapshot.items.last?.title, "Panel 2")
    }

    func testRecentlyClosedMenuSnapshotCarriesClosedTimestamp() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Timed Panel"
        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)

        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            closedAt: closedAt,
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: panelSnapshot
            ))
        ))

        let item = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        XCTAssertEqual(item.title, "Timed Panel")
        XCTAssertEqual(item.closedAt, closedAt)
        XCTAssertTrue(item.menuTitle.contains("\n"))
        XCTAssertTrue(item.menuSubtitle.contains(String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab")))
    }

    private func waitForClosedHistoryCount(
        _ expectedCount: Int,
        in store: ClosedItemHistoryStore,
        timeout: TimeInterval = 2
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if store.menuSnapshot().totalItemCount == expectedCount {
                return
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertEqual(store.menuSnapshot().totalItemCount, expectedCount)
    }

}
