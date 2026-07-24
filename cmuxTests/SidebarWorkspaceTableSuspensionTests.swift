import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceTableSuspensionTests {
    @Test
    func rowHeightCacheMeasuresAgainAfterPayloadSuspension() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0

        let initialChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }
        let repeatedChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 99
        }

        #expect(measurementCount == 1)
        #expect(initialChanges == IndexSet(integer: 0))
        #expect(repeatedChanges.isEmpty)
        #expect(cache.height(for: row, columnWidth: 200) == 44)

        cache.suspendPresentation(retaining: [row.id])
        let changedRow = makeRowConfiguration(workspaceId: row.workspaceId, contentToken: 1)
        let revealChanges = cache.prepare(rows: [changedRow], columnWidth: 200) { candidate, _ in
            candidate.estimatedHeight
        }
        #expect(revealChanges == IndexSet(integer: 0))
    }

    @Test
    func rowHeightCachePrunesRowsRemovedDuringSuspension() {
        let retainedRow = makeRowConfiguration()
        let removedRow = makeRowConfiguration()
        let cache = SidebarWorkspaceTableRowHeightCache()
        _ = cache.prepare(rows: [retainedRow, removedRow], columnWidth: 200) { row, _ in
            row.id == retainedRow.id ? 44 : 55
        }

        cache.suspendPresentation(retaining: [retainedRow.id])

        #expect(cache.height(for: retainedRow.presentationSnapshot(), columnWidth: 200) == 44)
        #expect(cache.height(for: removedRow.presentationSnapshot(), columnWidth: 200) == nil)
    }

    @Test
    func hiddenTableRejectsQueuedWorkAndReconcilesOnReveal() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let actions = makeTableActions()
        var viewportComputations = 0
        controller.dropTargetComputationProbe = { viewportComputations += 1 }

        controller.apply(
            rows: [first],
            actions: actions,
            workspaceIds: [first.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        controller.setPresentationActive(false, workspaceIds: [first.workspaceId])
        controller.viewportDidChange()
        controller.performWidthRemeasureNow()
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 0)
        #expect(viewportComputations == 0)

        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 0)

        controller.setPresentationActive(
            true,
            workspaceIds: [first.workspaceId, second.workspaceId]
        )
        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 2)
    }

    @Test
    func hidingRetiresNativeReorderSession() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceIds = (0..<6).map { _ in UUID() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            window.contentView = nil
            window.close()
        }
        var indicatorClears = 0
        let actions = makeTableActions(
            updateWorkspaceDrag: { _, _, _ in
                SidebarWorkspaceTableReorderDropUpdate(
                    indicator: SidebarDropIndicator(tabId: workspaceIds[4], edge: .top),
                    scope: .raw,
                    draggedWorkspaceId: workspaceIds[1],
                    indicatorRowIds: workspaceIds,
                    plan: nil
                )
            },
            clearWorkspaceDropIndicator: { indicatorClears += 1 }
        )
        controller.apply(
            rows: workspaceIds.map { makeRowConfiguration(workspaceId: $0) },
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        #expect(controller.updateReorderDrag(windowPoint: NSPoint(x: 40, y: 120)))
        #expect(controller.isReorderDropSessionActive)

        controller.setPresentationActive(false, workspaceIds: workspaceIds)

        #expect(!controller.isReorderDropSessionActive)
        #expect(indicatorClears == 1)
    }

    @Test
    func cellDetachmentDefersInlineEditCommitThroughControllerScheduler() async throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let model = SidebarWorkspaceRowSuspensionTests.makeModel()
        var committedTitle: String?
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: model,
                onCommitRename: { committedTitle = $0 }
            ),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer { window.close() }
        controller.apply(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [model.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView
        )
        cell.beginInlineRename()
        let field = try #require(
            Self.descendants(of: cell).compactMap { $0 as? SidebarRowInlineRenameField }.first
        )
        field.stringValue = "Detached rename"

        controller.dismantleContainerView(container)

        #expect(committedTitle == nil)
        await flushStagedTableMutations()
        #expect(committedTitle == "Detached rename")
    }

    @Test
    func transientWindowReparentingKeepsRowActionsAttached() async throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let model = SidebarWorkspaceRowSuspensionTests.makeModel()
        var committedTitle: String?
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: model,
                onCommitRename: { committedTitle = $0 }
            ),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
        let firstRoot = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        container.frame = firstRoot.bounds
        firstRoot.addSubview(container)
        let window = NSWindow(
            contentRect: firstRoot.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = firstRoot
        defer { window.close() }
        controller.apply(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [model.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        firstRoot.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView
        )

        let replacementRoot = NSView(frame: firstRoot.frame)
        window.contentView = replacementRoot
        replacementRoot.addSubview(firstRoot)

        cell.beginInlineRename()
        let field = try #require(
            Self.descendants(of: cell).compactMap { $0 as? SidebarRowInlineRenameField }.first
        )
        field.onCommit?("Reparented rename")
        #expect(
            committedTitle == "Reparented rename",
            "A transient content-view reparent must not detach live row actions."
        )
    }

    @Test
    func transientWindowReparentingKeepsGroupHeaderActionsAttached() {
        let cell = SidebarGroupHeaderTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 44)
        )
        var collapseToggles = 0
        cell.configure(
            model: makeGroupHeaderModel(),
            actions: makeGroupHeaderActions { collapseToggles += 1 },
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let firstRoot = NSView(frame: cell.frame)
        firstRoot.addSubview(cell)
        let window = NSWindow(
            contentRect: firstRoot.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = firstRoot
        defer { window.close() }

        let replacementRoot = NSView(frame: firstRoot.frame)
        window.contentView = replacementRoot
        replacementRoot.addSubview(firstRoot)

        let chevron = Self.descendants(of: cell).compactMap { $0 as? SidebarHeaderGlyphButton }.first
        chevron?.performClick(nil)
        #expect(collapseToggles == 1, "A transient reparent must not detach group-header actions.")
    }

    @Test
    func mutationSchedulerCancelsHiddenWorkAndFlushesRevealOnce() async {
        var appliedInputs = 0
        var viewportFlushes = 0
        var postUpdateActions = 0
        var reloads = 0
        let scheduler = SidebarWorkspaceTableMutationScheduler(
            applyFlush: { _ in appliedInputs += 1 },
            viewportChangeFlush: { viewportFlushes += 1 },
            reloadFlush: { reloads += 1 }
        )
        let row = makeRowConfiguration()
        let input = SidebarWorkspaceTableApplyInput(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )

        scheduler.stageApply(input)
        scheduler.stageViewportChange()
        scheduler.stageTableReload()
        scheduler.cancelPendingApplyAndViewport()
        await flushStagedTableMutations()
        #expect(appliedInputs == 0)
        #expect(viewportFlushes == 0)
        #expect(reloads == 1)

        scheduler.stageApply(input)
        scheduler.stageViewportChange()
        scheduler.stageTableReload()
        scheduler.stageTableReload()
        scheduler.stagePostUpdateActions([{ postUpdateActions += 1 }])
        #expect(postUpdateActions == 0)
        await flushStagedTableMutations()
        #expect(appliedInputs == 1)
        #expect(viewportFlushes == 1)
        #expect(postUpdateActions == 1)
        #expect(reloads == 2)
    }

    @Test
    func mutationSchedulerKeepsDeferredActionsAliveUntilFlush() async {
        var postUpdateActions = 0
        var scheduler: SidebarWorkspaceTableMutationScheduler? =
            SidebarWorkspaceTableMutationScheduler(
                applyFlush: { _ in },
                viewportChangeFlush: {},
                reloadFlush: {}
            )
        weak var scheduledOwner = scheduler

        scheduler?.stagePostUpdateActions([{ postUpdateActions += 1 }])
        scheduler = nil

        #expect(scheduledOwner != nil, "The scheduled flush must retain its queued actions.")
        await flushStagedTableMutations()
        #expect(postUpdateActions == 1)
        #expect(scheduledOwner == nil)
    }

    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        contentToken: Int = 0
    ) -> SidebarWorkspaceTableRowConfiguration {
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent(token: contentToken)
        ) { _, _ in
            AnyView(TestRowContent(token: contentToken))
        }
    }

    private func makeGroupHeaderModel() -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(), anchorWorkspaceId: UUID(), name: "Group", iconSymbol: "folder",
            tintHex: nil, isCollapsed: false, isPinned: false, isAnchorActive: false,
            memberCount: 1, anchorUnreadCount: 0, canMarkRead: false, canMarkUnread: true,
            hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: true,
            shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0,
            fontScale: 1, globalFontMagnificationPercent: 100, cwdContextMenuItems: [],
            rowSpacing: 2, isFirstRow: true, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false
        )
    }

    private func makeGroupHeaderActions(
        onToggleCollapsed: @escaping () -> Void
    ) -> SidebarGroupHeaderRowActions {
        SidebarGroupHeaderRowActions(
            onToggleCollapsed: onToggleCollapsed, onFocusAnchor: {}, onTapPlus: {},
            onRunResolvedItem: { _ in }, onRename: {}, onTogglePinned: {}, onMarkRead: {},
            onMarkUnread: {}, onClearLatestNotifications: {}, onMarkAllRead: {},
            onMarkAllUnread: {}, onUngroup: {}, onDelete: {}, onEditConfig: {}, onOpenDocs: {}
        )
    }

    private func makeTableActions(
        updateWorkspaceDrag: @escaping (
            CGPoint,
            [SidebarWorkspaceReorderDropOverlay.Target],
            UUID?
        ) -> SidebarWorkspaceTableReorderDropUpdate? = { _, _, _ in nil },
        clearWorkspaceDropIndicator: @escaping () -> Void = {}
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: updateWorkspaceDrag,
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: clearWorkspaceDropIndicator,
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private struct TestRowContent: View, Equatable {
        let token: Int

        var body: some View { EmptyView() }
    }
}
#endif
