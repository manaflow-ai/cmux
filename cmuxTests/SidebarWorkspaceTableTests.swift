import AppKit
import CmuxFoundation
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

        // Reorder drags resolve targets synchronously in validateDrop and
        // must never wake the bonsplit geometry gate.
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
    func reorderDragReplansFromStoredWindowPointOnViewportChange() async {
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
        var indicatorClears = 0
        let draggedId = ids[2]
        let actions = makeTableActions(
            updateWorkspaceDrag: { point, targets, _ in
                plannedPoints.append(point)
                plannedTargetCounts.append(targets.count)
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

        // Autoscroll moves content under a stationary pointer: same window
        // point, new viewport, so the stored point must re-plan and resolve
        // to a shifted table-space position.
        let originBefore = container.clipView.bounds.origin.y
        container.clipView.scroll(to: NSPoint(x: 0, y: originBefore + 100))
        container.scrollView.reflectScrolledClipView(container.clipView)
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(plannedPoints.count == 2)
        let scrolledBy = container.clipView.bounds.origin.y - originBefore
        #expect(abs((plannedPoints[1].y - plannedPoints[0].y) - scrolledBy) < 0.5)

        // Leaving the table retires the stored point: later viewport changes
        // must not keep planning a drag that is no longer over the sidebar.
        controller.reorderDropDragExited()
        #expect(indicatorClears == 1)
        controller.viewportDidChange()
        await flushStagedTableMutations()
        #expect(plannedPoints.count == 2)
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
        contentToken: Int = 0,
        fontMagnificationPercent: Int = 100,
        colorScheme: ColorScheme = .light
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

    @MainActor
    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
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
#endif

    private struct TestRowContent: View, Equatable {
        let token: Int

        var body: some View {
            EmptyView()
        }
    }
}
