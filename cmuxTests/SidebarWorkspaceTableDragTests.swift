import AppKit
import Bonsplit
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceTableDragTests {
    @Test
    @MainActor
    func groupHeaderBeginsAnchorDragAndWorkspaceRowBeginsOwnDragUnlessEditing() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = container
        let groupId = UUID()
        let anchorId = UUID()
        let workspaceId = UUID()
        var draggedWorkspaceIds: [UUID] = []
        let group = makeGroupConfiguration(groupId: groupId, anchorWorkspaceId: anchorId)
        let workspace = makeRowConfiguration(workspaceId: workspaceId)
        controller.apply(
            rows: [group, workspace],
            actions: makeTableActions(beginWorkspaceDrag: { draggedWorkspaceIds.append($0) }),
            workspaceIds: [anchorId, workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 0) != nil)
        #expect(draggedWorkspaceIds == [anchorId])
        let workspaceCell = try #require(
            container.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? SidebarWorkspaceRowTableCellView
        )
        workspaceCell.beginInlineRename()
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 1) == nil)
        #expect(draggedWorkspaceIds == [anchorId])
        _ = window.makeFirstResponder(container.tableView)
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 1) != nil)
        #expect(draggedWorkspaceIds == [anchorId, workspaceId])
    }

    @Test
    @MainActor
    func bonsplitDropsAtGroupedEdgesStayOutsideTheCompleteGroupRun() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let groupId = UUID()
        let beforeId = UUID()
        let anchorId = UUID()
        let firstMemberId = UUID()
        let secondMemberId = UUID()
        let afterId = UUID()
        let workspaceIds = [beforeId, anchorId, firstMemberId, secondMemberId, afterId]
        var receivedIndexes: [Int] = []
        let actions = makeTableActions(moveBonsplitToNewWorkspace: { index, _ in
            receivedIndexes.append(index)
            return UUID()
        })
        let transfer = try JSONDecoder().decode(
            BonsplitTabDragPayload.Transfer.self,
            from: Data(
                "{\"tab\":{\"id\":\"\(UUID())\"},\"sourcePaneId\":\"\(UUID())\",\"sourceProcessId\":0}".utf8
            )
        )

        controller.apply(
            rows: [
                makeRowConfiguration(workspaceId: beforeId),
                makeGroupConfiguration(
                    groupId: groupId,
                    anchorWorkspaceId: anchorId,
                    memberCount: 3
                ),
                makeRowConfiguration(workspaceId: firstMemberId, groupId: groupId),
                makeRowConfiguration(workspaceId: secondMemberId, groupId: groupId),
                makeRowConfiguration(workspaceId: afterId),
            ],
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()

        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0, SidebarDropIndicator(tabId: anchorId, edge: .bottom), transfer
        ))
        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            2, SidebarDropIndicator(tabId: firstMemberId, edge: .top), transfer
        ))
        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            2, SidebarDropIndicator(tabId: firstMemberId, edge: .bottom), transfer
        ))

        controller.apply(
            rows: [
                makeRowConfiguration(workspaceId: beforeId),
                makeGroupConfiguration(
                    groupId: groupId,
                    anchorWorkspaceId: anchorId,
                    memberCount: 3,
                    isCollapsed: true
                ),
                makeRowConfiguration(workspaceId: afterId),
            ],
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()

        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0, SidebarDropIndicator(tabId: anchorId, edge: .bottom), transfer
        ))
        #expect(receivedIndexes == [4, 1, 4, 4])
    }

    @Test
    @MainActor
    func reusedNativeCellClearsInlineRenameDragSuppression() {
        let cell = SidebarWorkspaceRowTableCellView()
        configure(cell, row: makeRowConfiguration())
        cell.beginInlineRename()
        #expect(cell.suppressesWorkspaceDrag)

        configure(cell, row: makeRowConfiguration())
        #expect(!cell.suppressesWorkspaceDrag)
    }

    @Test
    @MainActor
    func duplicateRenderItemIdsKeepTheFirstRowIndex() {
        let controller = SidebarWorkspaceTableController()
        _ = controller.makeContainerView()
        let workspaceId = UUID()
        controller.apply(
            rows: [
                makeRowConfiguration(workspaceId: workspaceId),
                makeRowConfiguration(workspaceId: workspaceId),
            ],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()

        #expect(controller.rowIndex(forWorkspaceId: workspaceId) == 0)
    }

    @Test
    @MainActor
    func workspaceTargetPrefersVisibleWorkspaceRowThenFallsBackToGroupHeader() {
        let controller = SidebarWorkspaceTableController()
        _ = controller.makeContainerView()
        let anchorId = UUID()
        let header = makeGroupConfiguration(groupId: UUID(), anchorWorkspaceId: anchorId)
        let workspace = makeRowConfiguration(workspaceId: anchorId)
        let actions = makeTableActions()

        controller.apply(
            rows: [header, workspace], actions: actions,
            workspaceIds: [anchorId], selectedWorkspaceId: anchorId,
            selectedScrollTargetWorkspaceId: anchorId
        )
        flushStagedTableMutations()
        #expect(controller.rowIndex(forWorkspaceId: anchorId) == 1)

        controller.apply(
            rows: [header], actions: actions,
            workspaceIds: [anchorId], selectedWorkspaceId: anchorId,
            selectedScrollTargetWorkspaceId: anchorId
        )
        flushStagedTableMutations()
        #expect(controller.rowIndex(forWorkspaceId: anchorId) == 0)
    }

    @Test
    @MainActor
    func dividerDragDefersRowRemeasureUntilSettledApply() {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        container.layoutSubtreeIfNeeded()
        let workspaceId = UUID()
        let row = makeRowConfiguration(
            workspaceId: workspaceId,
            title: String(repeating: "variable width title ", count: 5),
            wrapsTitle: true
        )
        let actions = makeTableActions()
        controller.apply(
            rows: [row], actions: actions, workspaceIds: [workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        let wideHeight = controller.tableView(container.tableView, heightOfRow: 0)

        container.frame.size.width = 120
        container.layoutSubtreeIfNeeded()
        controller.apply(
            rows: [row], actions: actions, workspaceIds: [workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil,
            isDividerDragActive: true
        )
        flushStagedTableMutations()
        #expect(controller.tableView(container.tableView, heightOfRow: 0) == wideHeight)

        controller.apply(
            rows: [row], actions: actions, workspaceIds: [workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil,
            isDividerDragActive: false
        )
        flushStagedTableMutations()
        let settledHeight = controller.tableView(container.tableView, heightOfRow: 0)
        #expect(settledHeight > wideHeight)

        controller.remeasureRowsIfWidthChanged()
        #expect(controller.tableView(container.tableView, heightOfRow: 0) == settledHeight)
    }

    @MainActor
    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        groupId: UUID? = nil,
        title: String = "workspace",
        wrapsTitle: Bool = false
    ) -> SidebarWorkspaceTableRowConfiguration {
        let defaultsSuiteName = "SidebarWorkspaceTableDragTests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.set(wrapsTitle, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
        let model = SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(title: title),
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 2,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 2,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: groupId != nil,
            isFirstRow: false,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: false,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0
        )
        return SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: makeRowActions(),
            groupId: groupId,
            isPinned: false,
            environment: environment
        )
    }

    @MainActor
    private func configure(
        _ cell: SidebarWorkspaceRowTableCellView,
        row: SidebarWorkspaceTableRowConfiguration
    ) {
        guard let model = row.appKitWorkspaceRowModel,
              let actions = row.appKitWorkspaceRowActions else {
            Issue.record("Expected a native workspace-row configuration")
            return
        }
        cell.configure(
            model: model,
            actions: actions,
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
    }

    @MainActor
    private func makeRowActions() -> SidebarAppKitRowActions {
        let workspace = Workspace(
            title: "Test",
            initialSurface: .browser,
            initialBrowserURL: URL(string: "about:blank")
        )
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: nil,
            notificationStore: nil,
            index: 0,
            contextMenuWorkspaceIds: [],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            commitRename: { _ in }
        )
    }

    @MainActor
    private func makeGroupConfiguration(
        groupId: UUID,
        anchorWorkspaceId: UUID,
        memberCount: Int = 1,
        isCollapsed: Bool = false
    ) -> SidebarWorkspaceTableRowConfiguration {
        let model = SidebarGroupHeaderRowModel(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            name: "Group",
            iconSymbol: "folder",
            tintHex: nil,
            isCollapsed: isCollapsed,
            isPinned: false,
            isAnchorActive: false,
            memberCount: memberCount,
            anchorUnreadCount: 0,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            globalFontMagnificationPercent: 100,
            cwdContextMenuItems: [],
            rowSpacing: 2,
            isFirstRow: true,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false
        )
        let actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: {}, onFocusAnchor: {}, onTapPlus: {},
            onRunResolvedItem: { _ in }, onRename: {}, onTogglePinned: {},
            onMarkRead: {}, onMarkUnread: {}, onClearLatestNotifications: {},
            onMarkAllRead: {}, onMarkAllUnread: {}, onUngroup: {}, onDelete: {},
            onEditConfig: {}, onOpenDocs: {}
        )
        return SidebarWorkspaceTableRowConfiguration(
            groupHeaderModel: model,
            actions: actions,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100
            )
        )
    }

    @MainActor
    private func flushStagedTableMutations() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    private func makeTableActions(
        beginWorkspaceDrag: @escaping (UUID) -> Void = { _ in },
        moveBonsplitToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID? = { _, _ in nil }
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            canCreateEmptyWorkspaceGroup: true,
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: beginWorkspaceDrag,
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _ in false },
            performWorkspaceDrop: { _, _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            setWorkspaceDropTargetCollectionActive: { _ in },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: moveBonsplitToNewWorkspace,
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }
}
