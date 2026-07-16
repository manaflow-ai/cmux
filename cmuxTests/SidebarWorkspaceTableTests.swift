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

        #expect(container.tableView.style == .fullWidth)
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

        let initialChanges = cache.prepare(
            rows: [row],
            columnWidth: 200,
            measurableRange: 0..<1
        ) { _, _ in
            measurementCount += 1
            return 44
        }
        let repeatedChanges = cache.prepare(
            rows: [row],
            columnWidth: 200,
            measurableRange: 0..<1
        ) { _, _ in
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

        _ = cache.prepare(rows: [row], columnWidth: 200, measurableRange: 0..<1, measure: measure)
        let changed = cache.prepare(rows: [row], columnWidth: 240, measurableRange: 0..<1, measure: measure)

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

        _ = cache.prepare(rows: [original], columnWidth: 200, measurableRange: 0..<1, measure: measure)
        _ = cache.prepare(rows: [changedContent], columnWidth: 200, measurableRange: 0..<1, measure: measure)
        _ = cache.prepare(rows: [changedFont], columnWidth: 200, measurableRange: 0..<1, measure: measure)
        _ = cache.prepare(rows: [changedAppearance], columnWidth: 200, measurableRange: 0..<1, measure: measure)

        #expect(measurementCount == 4)
        #expect(cache.height(for: changedAppearance, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func cachedHeightQueriesDuringScrollNeverMeasure() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        _ = cache.prepare(rows: [row], columnWidth: 200, measurableRange: 0..<1) { _, _ in
            measurementCount += 1
            return 44
        }

        for _ in 0..<500 {
            #expect(
                cache.prepareHostedRowsForViewportChange(
                    [row],
                    columnWidth: 200,
                    measurableRange: 0..<1,
                    visibleRange: 0..<1
                ) == nil
            )
            #expect(cache.height(for: row, columnWidth: 200) == 44)
        }

        #expect(measurementCount == 1)
    }

    /// One width change or bulk content update must never measure the whole
    /// list: rows outside the near-viewport window keep (or fall back to)
    /// their estimates until they scroll in.
    @Test
    @MainActor
    func rowHeightCacheMeasuresOnlyTheMeasurableRange() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let rows = (0..<10).map { _ in makeRowConfiguration() }
        var measured = 0
        let changed = cache.prepare(
            rows: rows,
            columnWidth: 200,
            measurableRange: 2..<5
        ) { _, _ in
            measured += 1
            return 44
        }

        #expect(measured == 3)
        #expect(changed == IndexSet(integersIn: 2..<5))
        #expect(cache.height(for: rows[2], columnWidth: 200) == 44)
        #expect(cache.height(for: rows[0], columnWidth: 200) == nil)

        // Scrolling the window forward measures the newly approaching rows
        // and keeps the still-valid earlier measurements.
        let scrolled = cache.prepare(
            rows: rows,
            columnWidth: 200,
            measurableRange: 4..<7
        ) { _, _ in
            measured += 1
            return 44
        }
        #expect(measured == 5)
        #expect(scrolled == IndexSet(integersIn: 5..<7))
        #expect(cache.height(for: rows[3], columnWidth: 200) == 44)
        #expect(cache.height(for: rows[6], columnWidth: 200) == 44)
    }

#if DEBUG
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
    func dropTargetGeometryIsIdleDuringScrollAndTracksDragLifecycle() {
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
        flushStagedApplies()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        var computations = 0
        controller.dropTargetComputationProbe = { computations += 1 }

        controller.viewportDidChange()
        controller.viewportDidChange()
        #expect(computations == 0)

        controller.workspaceDragSessionDidBegin()
        #expect(computations == 1)
        #expect(container.reorderDropView.targets.map(\.workspaceId) == [workspaceId])

        controller.viewportDidChange()
        #expect(computations == 2)

        controller.workspaceDragSessionDidEnd()
        #expect(container.reorderDropView.targets.isEmpty)
        controller.viewportDidChange()
        #expect(computations == 2)
    }

    @Test
    @MainActor
    func contextMenuTransitionsReconfigureTheHoveredRow() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = makeRowConfiguration()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        controller.apply(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedApplies()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let rowRect = container.tableView.rect(ofRow: 0)
        let windowPoint = container.tableView.convert(
            NSPoint(x: rowRect.midX, y: rowRect.midY),
            to: nil
        )
        container.tableView.setPointerWindowLocation(windowPoint)
        let realized = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SidebarWorkspaceTableCellView
        )
        container.tableView.layoutSubtreeIfNeeded()
        // The reconfigure path resolves cells with makeIfNecessary: false, so
        // prove the realized cell is installed in the live table hierarchy
        // before asserting on the transitions.
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceTableCellView,
            "the table did not keep the realized cell in its live hierarchy"
        )
        #expect(cell === realized)
        #expect(cell.representedRowId == row.id)

        // configure(cell:at:) rebinds the cell probe from the controller on
        // every pass, so observe reconfigures at the controller level.
        var renders = 0
        controller.reconfigurationProbe = { renders += 1 }

        // Opening drops the hovered flag on the menu's row immediately instead
        // of leaving it stale until the next unrelated apply().
        controller.contextMenuDidOpen(rowId: row.id)
        #expect(renders == 1)

        // Closing with a stationary pointer restores the hovered flag even
        // though recomputeHoveredRow() resolves the unchanged row id.
        controller.contextMenuDidClose(rowId: row.id)
        #expect(renders == 2)
    }

    /// The drop planner's `.newWorkspace(insertionIndex:)` is positional
    /// within the visible-row target subset, so the controller must translate
    /// through the indicator's row identity to the full workspace ordering
    /// before performing the move.
    @Test
    @MainActor
    func bonsplitNewWorkspaceDropTranslatesIndicatorToGlobalInsertionIndex() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceIds = (0..<4).map { _ in UUID() }
        var receivedInsertionIndex: Int?
        controller.apply(
            rows: workspaceIds.map { makeRowConfiguration(workspaceId: $0) },
            actions: makeTableActions(moveBonsplitToNewWorkspace: { insertionIndex, _ in
                receivedInsertionIndex = insertionIndex
                return UUID()
            }),
            workspaceIds: workspaceIds,
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedApplies()
        // Transfer only has its Decodable initializer (the explicit
        // init(from:) suppresses the memberwise one), so build it the way
        // production does: from a pasteboard JSON payload.
        let transfer = try JSONDecoder().decode(
            BonsplitTabDragPayload.Transfer.self,
            from: Data("""
            {"tab":{"id":"\(UUID().uuidString)"},"sourcePaneId":"\(UUID().uuidString)","sourceProcessId":0}
            """.utf8)
        )

        // A subset-relative index of 0 with the indicator anchored at the
        // third workspace must land at global index 2, not 0.
        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0,
            SidebarDropIndicator(tabId: workspaceIds[2], edge: .top),
            transfer
        ))
        #expect(receivedInsertionIndex == 2)

        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0,
            SidebarDropIndicator(tabId: workspaceIds[2], edge: .bottom),
            transfer
        ))
        #expect(receivedInsertionIndex == 3)

        // An end-of-list indicator appends after the full ordering.
        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0,
            SidebarDropIndicator(tabId: nil, edge: .bottom),
            transfer
        ))
        #expect(receivedInsertionIndex == 4)
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

#if DEBUG
    /// apply() stages its input and flushes table mutations on the next
    /// main-run-loop turn (outside SwiftUI render passes); pump one turn so
    /// tests observe post-flush state through the production timing.
    @MainActor
    private func flushStagedApplies() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

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
        moveBonsplitToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID? = { _, _ in nil }
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
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
            moveBonsplitToNewWorkspace: moveBonsplitToNewWorkspace,
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
