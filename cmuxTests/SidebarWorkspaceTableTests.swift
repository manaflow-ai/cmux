import AppKit
import CmuxFoundation
import CmuxNotifications
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceTableTests {
    @Test
    @MainActor
    func reorderDropDestinationIsOverlayNotTable() throws {
        let container = SidebarWorkspaceTableController().makeContainerView()
        let pasteboardType = SidebarWorkspaceReorderDropOverlay.pasteboardType

        #expect(!container.tableView.registeredDraggedTypes.contains(pasteboardType))
        let reorderDropView = try #require(
            container.subviews.lazy.compactMap { $0 as? SidebarWorkspaceReorderDropView }.first
        )
        #expect(reorderDropView.registeredDraggedTypes.contains(pasteboardType))
    }

    @Test
    @MainActor
    func containerHasNoStructuralHorizontalRowInsetAndAlwaysActiveHoverTracking() throws {
        let container = SidebarWorkspaceTableController().makeContainerView()
        let column = try #require(container.tableView.tableColumns.first)
        container.tableView.updateTrackingAreas()
        let hoverTrackingArea = try #require(container.tableView.trackingAreas.first { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.mouseMoved)
                && area.options.contains(.inVisibleRect)
        })

        // .plain intentionally: fullWidth insets cell frames ~6pt per side
        // (see makeContainerView); stale .fullWidth expectation slipped in
        // while PR CI was disabled.
        #expect(container.tableView.style == .plain)
        #expect(container.scrollView.contentInsets.left == 0)
        #expect(container.scrollView.contentInsets.right == 0)
        #expect(container.tableView.intercellSpacing.width == 0)
        #expect(!container.tableView.usesAutomaticRowHeights)
        #expect(container.tableView.columnAutoresizingStyle == .uniformColumnAutoresizingStyle)
        #expect(column.resizingMask.contains(.autoresizingMask))
        #expect(hoverTrackingArea.options.contains(.activeAlways))
        #expect(!hoverTrackingArea.options.contains(.activeInKeyWindow))
    }

    @Test
    func rowHeightEstimateAccountsForScaleWrappingAndDetails() {
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        let compact = calculator.estimatedWorkspaceHeight(
            fontScale: 1,
            titleLineCount: 1,
            auxiliaryLineCount: 0
        )
        let detailed = calculator.estimatedWorkspaceHeight(
            fontScale: 1.2,
            titleLineCount: 3,
            auxiliaryLineCount: 4
        )

        #expect(compact == 31)
        #expect(detailed == 144)
        #expect(calculator.estimatedGroupHeaderHeight(fontScale: 1) == 36)
        #expect(detailed > compact)
    }

    @Test
    @MainActor
    func rowHeightCacheMeasuresOnceForEquivalentRepeatedQueries() {
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
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesWhenColumnWidthChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, width in
            measurementCount += 1
            return width / 4
        }

        _ = cache.prepare(rows: [row], columnWidth: 200, measure: measure)
        let changed = cache.prepare(rows: [row], columnWidth: 240, measure: measure)

        #expect(measurementCount == 2)
        #expect(changed == IndexSet(integer: 0))
        #expect(cache.height(for: row, columnWidth: 200) == nil)
        #expect(cache.height(for: row, columnWidth: 240) == 60)
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesContentFontAndAppearanceChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let workspaceId = UUID()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, _ in
            measurementCount += 1
            return CGFloat(40 + measurementCount)
        }
        let original = makeRowConfiguration(workspaceId: workspaceId)
        let changedContent = makeRowConfiguration(workspaceId: workspaceId, contentToken: 1)
        let changedFont = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120
        )
        let changedAppearance = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120,
            colorScheme: .dark
        )

        _ = cache.prepare(rows: [original], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedContent], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedFont], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedAppearance], columnWidth: 200, measure: measure)

        #expect(measurementCount == 4)
        #expect(cache.height(for: changedAppearance, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func cachedHeightQueriesDuringScrollNeverMeasure() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        _ = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }

        for _ in 0..<500 {
            #expect(cache.prepareHostedRowsIfWidthChanged([row], columnWidth: 200) == nil)
            #expect(cache.height(for: row, columnWidth: 200) == 44)
        }

        #expect(measurementCount == 1)
    }

#if DEBUG
    @Test
    @MainActor
    func tableApplyCoalescesAndMutatesOnlyAfterTheCurrentCallbackReturns() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let actions = makeTableActions()

        controller.apply(
            rows: [first],
            actions: actions,
            workspaceIds: [first.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )

        #expect(
            container.tableView.numberOfRows == 0,
            "Representable updates must not mutate NSTableView before the originating callback returns."
        )
        await flushStagedTableMutations()
        #expect(
            container.tableView.numberOfRows == 2,
            "The deferred boundary must coalesce repeated inputs and apply the newest table snapshot."
        )
    }

    @Test
    @MainActor
    func equivalentCellConfigurationDoesNotRenderAgain() {
        let cell = SidebarWorkspaceTableCellView()
        let workspaceId = UUID()
        var renders = 0
        cell.reconfigurationProbe = { renders += 1 }

        configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))
        configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))

        #expect(renders == 1)
    }

    @Test
    @MainActor
    func hoverFlipRendersOnlyTheAffectedCell() {
        let firstCell = SidebarWorkspaceTableCellView()
        let secondCell = SidebarWorkspaceTableCellView()
        let firstRow = makeRowConfiguration()
        let secondRow = makeRowConfiguration()
        var firstRenders = 0
        var secondRenders = 0
        firstCell.reconfigurationProbe = { firstRenders += 1 }
        secondCell.reconfigurationProbe = { secondRenders += 1 }

        configure(firstCell, row: firstRow)
        configure(secondCell, row: secondRow)
        configure(firstCell, row: firstRow, isPointerHovering: true)
        configure(firstCell, row: firstRow, isPointerHovering: true)

        #expect(firstRenders == 2)
        #expect(secondRenders == 1)
    }

    @Test
    @MainActor
    func cellReusePreservesOneHostingViewAndStableRootIdentity() {
        let cell = SidebarWorkspaceTableCellView()
        let hostingIdentity = cell.hostingViewIdentity
        let rootIdentity = cell.hostedRootIdentity
        let reusedWorkspaceId = UUID()

        configure(cell, row: makeRowConfiguration())
        configure(cell, row: makeRowConfiguration(workspaceId: reusedWorkspaceId))

        #expect(cell.subviews.count == 1)
        #expect(cell.hostingViewIdentity == hostingIdentity)
        #expect(cell.hostedRootIdentity == rootIdentity)
        #expect(cell.representedRowId == .workspace(reusedWorkspaceId))
    }

    @Test
    @MainActor
    func dropTargetGeometryIsIdleOutsideBonsplitTargetCollection() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        controller.apply(
            rows: [makeRowConfiguration(workspaceId: workspaceId)],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        var computations = 0
        controller.dropTargetComputationProbe = { computations += 1 }

        controller.viewportDidChange()
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(computations == 0)

        // Starting a reorder at the table must not wake the bonsplit-only
        // geometry gate. The destination overlay resolves its own targets.
        controller.workspaceDragSessionDidBegin()
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(computations == 0)
        controller.workspaceDragSessionDidEnd()

        container.bonsplitDropView.setWorkspaceDropTargetCollectionActive(true)
        #expect(computations == 1)

        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(computations == 2)

        container.bonsplitDropView.setWorkspaceDropTargetCollectionActive(false)
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(computations == 2)
    }

    @Test
    @MainActor
    func bonsplitTargetsExcludeVisualDividerRows() {
        let first = makeRowConfiguration()
        let dividerId = UUID()
        let divider = makeRowConfiguration(
            workspaceId: dividerId,
            renderItemId: .divider(dividerId)
        )
        let second = makeRowConfiguration()
        let rows = [first, divider, second]

        let targets = SidebarWorkspaceTableDropTargetGeometryGate.makeBonsplitTargets(
            rows: rows,
            rowRange: rows.indices,
            frameForRow: { row in
                CGRect(x: 0, y: CGFloat(row * 20), width: 200, height: 18)
            }
        )

        #expect(targets.map(\.workspaceId) == [first.workspaceId, second.workspaceId])
    }

    @Test
    @MainActor
    func emptyAreaMenuUsesAuthoritativeDividerAvailability() async throws {
        let controller = SidebarWorkspaceTableController()
        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let container = controller.makeContainerView()

        controller.apply(
            rows: [first, second],
            actions: makeTableActions(canCreateDivider: false),
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()

        let dividerItem = try #require(controller.emptyAreaMenu().items.last)
        #expect(dividerItem.title == String(localized: "sidebar.divider.add", defaultValue: "Add Divider"))
        #expect(!dividerItem.isEnabled)
        _ = container
    }

    @Test
    @MainActor
    func reorderDragReplansFromStoredWindowPointOnViewportChange() async throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let ids = (0..<30).map { _ in UUID() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        var plannedPoints: [CGPoint] = []
        var plannedTargetCounts: [Int] = []
        var plannedTargetY: [CGFloat?] = []
        var indicatorClears = 0
        let draggedId = ids[2]
        let actions = makeTableActions(
            updateWorkspaceDrag: { point, targets, _ in
                plannedPoints.append(point)
                plannedTargetCounts.append(targets.count)
                plannedTargetY.append(targets.first { $0.workspaceId == ids[5] }?.frame.minY)
                return SidebarWorkspaceTableReorderDropUpdate(
                    indicator: SidebarDropIndicator(tabId: ids[5], edge: .top),
                    scope: .raw,
                    draggedWorkspaceId: draggedId,
                    indicatorRowIds: ids,
                    plan: nil
                )
            },
            clearWorkspaceDropIndicator: { indicatorClears += 1 }
        )
        controller.apply(
            rows: ids.map { makeRowConfiguration(workspaceId: $0) },
            actions: actions,
            workspaceIds: ids,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let windowPoint = NSPoint(x: 40, y: 120)
        #expect(controller.updateReorderDrag(windowPoint: windowPoint))
        #expect(plannedPoints.count == 1)
        // Targets are the visible rows only, not the full 30-row model.
        #expect(plannedTargetCounts == [container.tableView.rows(in: container.tableView.visibleRect).length])

        // Autoscroll moves overlay-space targets under a stationary pointer.
        // The stored window point re-plans with a stable overlay point and
        // freshly converted target frames.
        let originBefore = container.clipView.bounds.origin.y
        container.clipView.scroll(to: NSPoint(x: 0, y: originBefore + 100))
        container.scrollView.reflectScrolledClipView(container.clipView)
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(plannedPoints.count == 2)
        let scrolledBy = container.clipView.bounds.origin.y - originBefore
        #expect(plannedPoints[1] == plannedPoints[0])
        let targetYBefore = try #require(plannedTargetY[0])
        let targetYAfter = try #require(plannedTargetY[1])
        #expect(abs((targetYAfter - targetYBefore) + scrolledBy) < 0.5)

        // Leaving the table retires the stored point: later viewport changes
        // must not keep planning a drag that is no longer over the sidebar.
        controller.reorderDropDragExited()
        #expect(indicatorClears == 1)
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(plannedPoints.count == 2)
    }

    @Test
    @MainActor
    func heightChangingReorderPreservesVisibleRowOffset() async throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let ids = (0..<40).map { _ in UUID() }
        let initialRows = ids.map {
            makeRowConfiguration(workspaceId: $0, fixedHeight: 30)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        controller.apply(
            rows: initialRows,
            actions: makeTableActions(),
            workspaceIds: ids,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let table = container.tableView
        let anchorIndex = 10
        let anchorId = initialRows[anchorIndex].id
        let requestedOrigin = table.rect(ofRow: anchorIndex).minY + 7
        container.clipView.scroll(to: NSPoint(x: 0, y: requestedOrigin))
        container.scrollView.reflectScrolledClipView(container.clipView)
        let offsetBefore = table.rect(ofRow: anchorIndex).minY - table.visibleRect.minY

        var reorderedIds = ids
        let movedId = reorderedIds.remove(at: 5)
        reorderedIds.insert(movedId, at: 20)
        let nextRows = reorderedIds.map { id in
            makeRowConfiguration(
                workspaceId: id,
                contentToken: id == movedId ? 1 : 0,
                fixedHeight: id == movedId ? 80 : 30
            )
        }
        controller.apply(
            rows: nextRows,
            actions: makeTableActions(),
            workspaceIds: reorderedIds,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()

        let nextAnchorIndex = try #require(nextRows.firstIndex { $0.id == anchorId })
        let offsetAfter = table.rect(ofRow: nextAnchorIndex).minY - table.visibleRect.minY
        #expect(abs(offsetAfter - offsetBefore) < 0.5)
    }

    @Test
    @MainActor
    func unreadRefreshKeepsTableHeightInLockstepWithTheReconfiguredCell() async throws {
        let workspace = Workspace()
        let baseModel = SidebarWorkspaceRowSuspensionTests.makeModel(workspaceId: workspace.id)
        var pumpModel = baseModel
        pumpModel.latestNotificationText = "metadata refresh"
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .dark,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: baseModel,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: baseModel,
                workspace: workspace
            ),
            groupId: nil,
            isPinned: false,
            environment: environment,
            workspace: workspace,
            rebuild: { pumpModel },
            unreadRebuild: { snapshot in
                var fresh = baseModel
                let summary = snapshot.summary(forWorkspaceId: workspace.id)
                fresh.unreadCount = summary.unreadCount
                fresh.latestNotificationText = summary.latestNotificationText
                return fresh
            }
        )
        let cache = SidebarWorkspaceTableRowHeightCache()
        _ = cache.prepareRows(at: [0], in: [row], columnWidth: 320)
        let cacheSnapshot = SidebarUnreadSnapshot(
            summaryByWorkspaceId: [workspace.id: SidebarWorkspaceUnreadSummary(
                unreadCount: 1,
                latestNotificationText: "cache fingerprint notification"
            )]
        )
        let cacheUpdatedRow = row.applyingUnreadSnapshot(cacheSnapshot)
        let cacheChanges = cache.prepareRows(
            at: [0],
            in: [cacheUpdatedRow],
            columnWidth: 320
        )
        #expect(cacheChanges == IndexSet(integer: 0))
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer { window.close() }

        let unread = SidebarUnreadModel()
        controller.setUnreadSource(unread)
        controller.apply(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [workspace.id],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SidebarWorkspaceRowTableCellView
        )

        // The initial pump replay installs a height override for the shorter
        // live model. The unread update below must retire that override before
        // the cell is painted with its taller notification preview.
        let pumpHeight = controller.tableView(container.tableView, heightOfRow: 0)
        let baseHeight = ceil(
            cell.layoutContent(model: baseModel, width: cell.bounds.width, apply: false)
        )
        #expect(pumpHeight > baseHeight)

        let latestText = String(repeating: "latest agent message ", count: 30)
        unread.applyWorkspaceSummaryProjection(
            forWorkspaceId: workspace.id,
            summary: SidebarWorkspaceUnreadSummary(
                unreadCount: 1,
                latestNotificationText: latestText
            ),
            totalUnreadCount: 1
        )
        await flushUntil { cell.currentModelForMeasurement?.latestNotificationText == latestText }
        #expect(cell.currentModelForMeasurement?.latestNotificationText == latestText)
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let installedModel = try #require(cell.currentModelForMeasurement)
        let expectedHeight = ceil(
            cell.layoutContent(model: installedModel, width: cell.bounds.width, apply: false)
        )
        let servedHeight = controller.tableView(container.tableView, heightOfRow: 0)
        let tableHeight = container.tableView.rect(ofRow: 0).height
            - container.tableView.intercellSpacing.height
        #expect(abs(servedHeight - expectedHeight) < 0.5)
        #expect(abs(tableHeight - expectedHeight) < 0.5)
    }

    @Test
    func reorderIndicatorPainterMatchesPredicateAndSuppressesDraggedRow() {
        let ids = (0..<5).map { _ in UUID() }

        let topEdge = SidebarWorkspaceTableReorderIndicatorPainter(
            indicator: SidebarDropIndicator(tabId: ids[3], edge: .top),
            scope: .raw,
            draggedWorkspaceId: ids[1],
            indicatorRowIds: ids
        )
        let targetPaint = topEdge.paint(forRowWorkspaceId: ids[3])
        #expect(targetPaint.top)
        #expect(!targetPaint.bottom)
        let bystanderPaint = topEdge.paint(forRowWorkspaceId: ids[2])
        #expect(!bystanderPaint.top)
        #expect(!bystanderPaint.bottom)

        // A bottom-edge indicator canonicalizes to the top of the row after
        // the gap, same as the SwiftUI sidebar's predicate.
        let bottomEdge = SidebarWorkspaceTableReorderIndicatorPainter(
            indicator: SidebarDropIndicator(tabId: ids[2], edge: .bottom),
            scope: .raw,
            draggedWorkspaceId: ids[1],
            indicatorRowIds: ids
        )
        let canonicalPaint = bottomEdge.paint(forRowWorkspaceId: ids[3])
        #expect(canonicalPaint.top)

        // The dragged row never paints: AppKit snapshots it as the drag image
        // lazily, and a painted line would be baked into the ghost.
        let selfTargeting = SidebarWorkspaceTableReorderIndicatorPainter(
            indicator: SidebarDropIndicator(tabId: ids[1], edge: .top),
            scope: .raw,
            draggedWorkspaceId: ids[1],
            indicatorRowIds: ids
        )
        let draggedPaint = selfTargeting.paint(forRowWorkspaceId: ids[1])
        #expect(!draggedPaint.top)
        #expect(!draggedPaint.bottom)
    }
#endif

    @Test
    func hoverRecomputesFromStationaryWindowPointAfterScrollAndReorder() throws {
        let resolver = SidebarWorkspaceTableHoverResolver()
        let pointer = NSPoint(x: 20, y: 15)
        var scrollOffset: CGFloat = 0
        var orderedIds = ["a", "b", "c", "d"]

        func resolvedId() -> String? {
            let row = resolver.hoveredRow(
                windowPoint: pointer,
                convertToTable: { NSPoint(x: $0.x, y: $0.y + scrollOffset) },
                rowAtPoint: { Int(floor($0.y / 20)) },
                rowCount: orderedIds.count
            )
            return row.map { orderedIds[$0] }
        }

        #expect(resolvedId() == "a")
        scrollOffset = 20
        #expect(resolvedId() == "b")
        orderedIds = ["a", "c", "b", "d"]
        #expect(resolvedId() == "c")
    }

    @MainActor
    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        renderItemId: SidebarWorkspaceRenderItemID? = nil,
        contentToken: Int = 0,
        fontMagnificationPercent: Int = 100,
        colorScheme: ColorScheme = .light,
        fixedHeight: CGFloat? = nil
    ) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: colorScheme,
            globalFontMagnificationPercent: fontMagnificationPercent,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: colorScheme,
            globalFontMagnificationPercent: fontMagnificationPercent
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: renderItemId ?? .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent(token: contentToken, fixedHeight: fixedHeight)
        ) { _, _ in
            AnyView(TestRowContent(token: contentToken, fixedHeight: fixedHeight))
        }
    }

    @MainActor
    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func flushUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<32 {
            if predicate() { return }
            await flushStagedTableMutations()
            await Task.yield()
        }
    }

#if DEBUG
    @MainActor
    private func configure(
        _ cell: SidebarWorkspaceTableCellView,
        row: SidebarWorkspaceTableRowConfiguration,
        isPointerHovering: Bool = false
    ) {
        cell.configure(
            row: row,
            isPointerHovering: isPointerHovering,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
    }

    @MainActor
    private func makeTableActions(
        updateWorkspaceDrag: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> SidebarWorkspaceTableReorderDropUpdate? = { _, _, _ in nil },
        clearWorkspaceDropIndicator: @escaping () -> Void = {},
        canCreateDivider: Bool = true
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            createDivider: {},
            canCreateDivider: canCreateDivider,
            beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 },
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
#endif

    private struct TestRowContent: View, Equatable {
        let token: Int
        let fixedHeight: CGFloat?

        @ViewBuilder
        var body: some View {
            if let fixedHeight {
                Color.clear.frame(height: fixedHeight)
            } else {
                EmptyView()
            }
        }
    }
}

#if DEBUG
@Suite
struct SidebarWorkspaceTableResizeLifecycleTests {
    @Test
    @MainActor
    func appliedRowsStayStableUntilInteractiveResizeEnds() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer { window.close() }

        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let third = makeRowConfiguration()
        let actions = makeTableActions()
        controller.apply(
            rows: [first],
            actions: actions,
            workspaceIds: [first.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 1)

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: window)
        var resizeIsActive = true
        defer {
            if resizeIsActive {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
            }
        }
        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()

        #expect(
            container.tableView.numberOfRows == 1,
            "A live resize must keep the controller's previously applied row graph stable."
        )

        controller.apply(
            rows: [first, second, third],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId, third.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(
            container.tableView.numberOfRows == 1,
            "A newer resize-time snapshot must not replace the applied row graph."
        )

        TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
        resizeIsActive = false
        await flushStagedTableMutations()
        #expect(
            container.tableView.numberOfRows == 3,
            "Resize completion must reconcile the newest deferred row graph."
        )
    }

    @MainActor
    private func makeRowConfiguration() -> SidebarWorkspaceTableRowConfiguration {
        let workspaceId = UUID()
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
            equivalenceValue: TestRowContent()
        ) { _, _ in
            AnyView(TestRowContent())
        }
    }

    @MainActor
    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            createDivider: {},
            canCreateDivider: true,
            beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},
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

    private struct TestRowContent: View, Equatable {
        var body: some View {
            EmptyView()
        }
    }
}
#endif
