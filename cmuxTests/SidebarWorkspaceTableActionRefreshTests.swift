import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceTableActionRefreshTests {
    @Test
    @MainActor
    func equivalentVisibleGroupHeaderRefreshesItsActions() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let groupId = UUID()
        let anchorWorkspaceId = UUID()
        var initialToggleCount = 0
        var refreshedToggleCount = 0
        let initial = makeGroupConfiguration(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            onToggleCollapsed: { initialToggleCount += 1 }
        )
        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = container

        controller.apply(
            rows: [initial],
            actions: makeTableActions(),
            workspaceIds: [anchorWorkspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let initialCell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SidebarGroupHeaderTableCellView
        )
        let chevronButton = try #require(
            initialCell.subviews.compactMap { $0 as? SidebarHeaderGlyphButton }.first
        )
        chevronButton.performClick(nil)
        #expect(initialToggleCount == 1)

        let refreshed = makeGroupConfiguration(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            onToggleCollapsed: { refreshedToggleCount += 1 }
        )
        controller.apply(
            rows: [refreshed],
            actions: makeTableActions(),
            workspaceIds: [anchorWorkspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()

        let refreshedCell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarGroupHeaderTableCellView
        )
        #expect(refreshedCell === initialCell)
        chevronButton.performClick(nil)
        #expect(initialToggleCount == 1)
        #expect(refreshedToggleCount == 1)
    }

    @MainActor
    private func makeGroupConfiguration(
        groupId: UUID,
        anchorWorkspaceId: UUID,
        onToggleCollapsed: @escaping () -> Void
    ) -> SidebarWorkspaceTableRowConfiguration {
        let model = SidebarGroupHeaderRowModel(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            name: "Group",
            iconSymbol: "folder",
            tintHex: nil,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: false,
            memberCount: 1,
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
            onToggleCollapsed: onToggleCollapsed,
            onFocusAnchor: {},
            onTapPlus: {},
            onRunResolvedItem: { _ in },
            onRename: {},
            onTogglePinned: {},
            onMarkRead: {},
            onMarkUnread: {},
            onClearLatestNotifications: {},
            onMarkAllRead: {},
            onMarkAllUnread: {},
            onUngroup: {},
            onDelete: {},
            onEditConfig: {},
            onOpenDocs: {}
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
    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            canCreateEmptyWorkspaceGroup: true,
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
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
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    @MainActor
    private func flushStagedTableMutations() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}
