import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Failed and skipped restore validation for recently-closed records
extension TabManagerSessionSnapshotTests {
    func testRightSidebarToolSnapshotTolerantlyDecodesObsoleteHistoryMode() throws {
        let json = #"{"mode":"history"}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: json)
        XCTAssertNil(snapshot.mode)
    }

    func testReopenSpecificRecentlyClosedRowRestoresOnlyThatRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        firstWorkspace.setPanelCustomTitle(panelId: closedPanelId, title: "Specific Tab")

        firstWorkspace.markCloseHistoryEligible(panelId: closedPanelId)
        XCTAssertTrue(firstWorkspace.closePanel(closedPanelId, force: true))
        drainMainQueue()

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Specific Workspace")
        manager.closeWorkspace(secondWorkspace)

        let snapshotBeforeRestore = ClosedItemHistoryStore.shared.menuSnapshot()
        let panelRow = try XCTUnwrap(snapshotBeforeRestore.items.first { $0.title == "Specific Tab" })
        let workspaceRow = try XCTUnwrap(snapshotBeforeRestore.items.first { $0.title == "Specific Workspace" })

        XCTAssertTrue(manager.reopenClosedHistoryItem(id: panelRow.id))
        XCTAssertNotNil(firstWorkspace.panelCustomTitles.first(where: { $0.value == "Specific Tab" }))

        let snapshotAfterRestore = ClosedItemHistoryStore.shared.menuSnapshot()
        XCTAssertEqual(snapshotAfterRestore.items.map(\.id), [workspaceRow.id])
        XCTAssertEqual(snapshotAfterRestore.items.map(\.title), ["Specific Workspace"])

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Specific Workspace")
    }

    func testFailedSpecificRecentlyClosedRestoreKeepsOriginalRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Unreachable Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        let row = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)

        XCTAssertFalse(manager.reopenClosedHistoryItem(id: row.id))
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.id), [row.id])
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Unreachable Tab"])
    }

    func testExplicitLastPanelCloseRecordsWorkspaceHistoryInsteadOfStalePanelHistory() throws {
        let manager = TabManager()
        let closingWorkspace = manager.addWorkspace(select: true)
        closingWorkspace.setCustomTitle("Closing Workspace")
        let panelId = try XCTUnwrap(closingWorkspace.focusedPanelId)
        let surfaceId = try XCTUnwrap(closingWorkspace.surfaceIdFromPanelId(panelId))

        closingWorkspace.markExplicitClose(surfaceId: surfaceId)
        XCTAssertFalse(closingWorkspace.closePanel(panelId))
        drainMainQueue()

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspace.id }))
        let rows = ClosedItemHistoryStore.shared.menuSnapshot().items
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Closing Workspace")
        XCTAssertEqual(
            rows.first?.detail,
            String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace")
        )

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(manager.tabs.contains { $0.customTitle == "Closing Workspace" })
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testReopenSkipsInvalidRecentRecordButKeepsItInHistory() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let restorablePanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: restorablePanelId, title: "Restorable Tab")
        workspace.markCloseHistoryEligible(panelId: restorablePanelId)
        XCTAssertTrue(workspace.closePanel(restorablePanelId, force: true))
        drainMainQueue()

        var invalidSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        invalidSnapshot.customTitle = "Invalid Newest Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: invalidSnapshot
        )))

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(workspace.panelCustomTitles.values.contains("Restorable Tab"))
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Invalid Newest Tab"])
    }

    func testSkippedClosedPanelIsRemappedWhenOlderWorkspaceRestores() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let sourceManager = TabManager()
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("Recovered Parent")
        let pane = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        sourceWorkspace.setPanelCustomTitle(panelId: panelId, title: "Remapped Skipped Tab")
        let workspaceSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(workspaceSnapshot.panels.first { $0.id == panelId })

        let restoreManager = TabManager()
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: sourceWorkspace.id,
            windowId: nil,
            workspaceIndex: 1,
            snapshot: workspaceSnapshot
        )))
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: sourceWorkspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        XCTAssertTrue(restoreManager.reopenMostRecentlyClosedItem())
        let restoredWorkspace = try XCTUnwrap(restoreManager.tabs.first { $0.customTitle == "Recovered Parent" })
        XCTAssertNotEqual(restoredWorkspace.id, sourceWorkspace.id)
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Remapped Skipped Tab"])

        XCTAssertTrue(restoreManager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(restoredWorkspace.panelCustomTitles.values.contains("Remapped Skipped Tab"))
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testNoOpClosedPanelRemapDoesNotAdvanceRevision() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        let store = ClosedItemHistoryStore(capacity: 10)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            paneAnchorPanelId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot,
            fallbackSplitPlacement: ClosedPanelSplitPlacement(
                orientation: .horizontal,
                insertFirst: false,
                anchorPanelId: UUID()
            )
        )))
        let revision = store.revision

        store.remapPanelWorkspaceIds(from: UUID(), to: UUID())
        store.remapPanelAnchorIds(from: UUID(), to: UUID())

        XCTAssertEqual(store.revision, revision)
    }

    func testFailedRestoreReinsertPreservesProtectedRecordWhenStoreIsAtCapacity() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var protectedSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        protectedSnapshot.customTitle = "Failed Restore"
        var firstNewSnapshot = protectedSnapshot
        firstNewSnapshot.customTitle = "First Newer"
        var secondNewSnapshot = protectedSnapshot
        secondNewSnapshot.customTitle = "Second Newer"
        let store = ClosedItemHistoryStore(capacity: 2)
        let protectedRecord = ClosedItemHistoryRecord(entry: .panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: protectedSnapshot
        )))

        store.push(protectedRecord)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: firstNewSnapshot
        )))
        let removed = try XCTUnwrap(store.removeRecord(id: protectedRecord.id))
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: secondNewSnapshot
        )))

        store.insert(removed.record, at: removed.index)

        let snapshot = store.menuSnapshot()
        XCTAssertEqual(snapshot.totalItemCount, 2)
        XCTAssertTrue(snapshot.items.contains { $0.id == protectedRecord.id })
        XCTAssertEqual(snapshot.items.map(\.title), ["Second Newer", "Failed Restore"])
    }

    func testRestoreFirstRestorableCanSkipRecordsThatAlreadyFailedThisCommand() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var oldSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        oldSnapshot.customTitle = "Old Failed"
        var newSnapshot = oldSnapshot
        newSnapshot.customTitle = "New Failed"
        let store = ClosedItemHistoryStore(capacity: 5)
        let oldRecord = ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: oldSnapshot
            ))
        )
        let newRecord = ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 2),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: newSnapshot
            ))
        )
        store.push(oldRecord)
        store.push(newRecord)
        var failedRecordIds: Set<UUID> = []
        var attemptedTitles: [String] = []

        XCTAssertFalse(store.restoreFirstRestorable(
            newerThan: Date(timeIntervalSince1970: 0),
            excluding: failedRecordIds,
            onFailure: { failedRecordIds.insert($0) },
            using: { entry in
                if case .panel(let panelEntry) = entry {
                    attemptedTitles.append(panelEntry.snapshot.customTitle ?? "")
                }
                return false
            }
        ))
        XCTAssertFalse(store.restoreFirstRestorable(
            newerThan: nil,
            excluding: failedRecordIds,
            onFailure: { failedRecordIds.insert($0) },
            using: { entry in
                if case .panel(let panelEntry) = entry {
                    attemptedTitles.append(panelEntry.snapshot.customTitle ?? "")
                }
                return false
            }
        ))

        XCTAssertEqual(attemptedTitles, ["New Failed", "Old Failed"])
        XCTAssertEqual(failedRecordIds, Set([newRecord.id, oldRecord.id]))
    }

    func testFailedClosedWorkspaceRestoreRemovesCreatedWorkspaceAndKeepsHistoryRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        var panelSnapshot = try XCTUnwrap(snapshot.panels.first)
        panelSnapshot.type = .markdown
        panelSnapshot.title = "Broken Markdown"
        panelSnapshot.customTitle = "Broken Workspace Tab"
        panelSnapshot.terminal = nil
        panelSnapshot.browser = nil
        panelSnapshot.markdown = nil
        panelSnapshot.filePreview = nil
        panelSnapshot.rightSidebarTool = nil
        snapshot.customTitle = "Broken Workspace"
        snapshot.panels = [panelSnapshot]
        snapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [panelSnapshot.id],
            selectedPanelId: panelSnapshot.id
        ))

        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: UUID(),
            windowId: nil,
            workspaceIndex: 1,
            snapshot: snapshot
        )))

        XCTAssertFalse(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Broken Workspace"])
    }

    func testClosedWindowRestoreValidationRejectsFailedRestorablePanelRestore() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        XCTAssertTrue(snapshot.hasRestorablePanels)
        XCTAssertFalse(ClosedWindowRestoreValidation.hasUsableRestoredContent(
            snapshot: snapshot,
            restoredPanelIdsByWorkspaceIndex: [[:]],
            hasLivePanels: true
        ))
        XCTAssertTrue(ClosedWindowRestoreValidation.hasUsableRestoredContent(
            snapshot: snapshot,
            restoredPanelIdsByWorkspaceIndex: [[UUID(): UUID()]],
            hasLivePanels: true
        ))
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

}
