import AppKit
import Bonsplit
import CmuxFoundation
import Combine
import Observation
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
    @MainActor
    func tableApplyCoalescesAndMutatesOnlyAfterTheCurrentCallbackReturns() {
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
        #expect(container.tableView.numberOfRows == 0)
        flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 2)
    }

    @Test
    @MainActor
    func liveCellHeightChangeUpdatesTheTableRowGeometry() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let model = ExpandingTestRowModel()
        let row = makeExpandingRowConfiguration(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
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
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        _ = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SidebarWorkspaceTableCellView
        )
        let collapsedHeight = container.tableView.rect(ofRow: 0).height
        model.isExpanded = true
        for _ in 0..<3 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            container.layoutSubtreeIfNeeded()
            container.tableView.layoutSubtreeIfNeeded()
        }
        #expect(container.tableView.rect(ofRow: 0).height > collapsedHeight + 40)
    }

    @Test
    @MainActor
    func equivalentCellConfigurationDoesNotChangeCellStateAgain() {
        let cell = SidebarWorkspaceTableCellView()
        let workspaceId = UUID()
        let firstChanged = configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))
        let equivalentChanged = configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))
        #expect(firstChanged)
        #expect(!equivalentChanged)
        #expect(cell.model.state?.row.id == .workspace(workspaceId))
    }

    @Test
    @MainActor
    func hoverFlipChangesOnlyTheAffectedCellState() {
        let firstCell = SidebarWorkspaceTableCellView()
        let secondCell = SidebarWorkspaceTableCellView()
        let firstRow = makeRowConfiguration()
        let secondRow = makeRowConfiguration()
        #expect(configure(firstCell, row: firstRow))
        #expect(configure(secondCell, row: secondRow))
        #expect(configure(firstCell, row: firstRow, isPointerHovering: true))
        #expect(!configure(firstCell, row: firstRow, isPointerHovering: true))
        #expect(firstCell.model.state?.isPointerHovering == true)
        #expect(secondCell.model.state?.isPointerHovering == false)
    }

    @Test
    @MainActor
    func cellReusePreservesOneHostingView() {
        let cell = SidebarWorkspaceTableCellView()
        let hostingView = cell.subviews.first
        let reusedWorkspaceId = UUID()
        configure(cell, row: makeRowConfiguration())
        configure(cell, row: makeRowConfiguration(workspaceId: reusedWorkspaceId))
        #expect(cell.subviews.count == 1)
        #expect(cell.subviews.first === hostingView)
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
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        controller.viewportDidChange()
        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(container.reorderDropView.targets.isEmpty)
        controller.workspaceDragSessionDidBegin()
        #expect(container.reorderDropView.targets.map(\.workspaceId) == [workspaceId])
        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(container.reorderDropView.targets.map(\.workspaceId) == [workspaceId])
        controller.workspaceDragSessionDidEnd()
        #expect(container.reorderDropView.targets.isEmpty)
        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(container.reorderDropView.targets.isEmpty)
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
        flushStagedTableMutations()
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
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceTableCellView,
            "the table did not keep the realized cell in its live hierarchy"
        )
        #expect(cell === realized)
        #expect(cell.representedRowId == row.id)
        #expect(cell.model.state?.isPointerHovering == true)
        // Opening drops the hovered flag immediately.
        controller.contextMenuDidOpen(rowId: row.id)
        #expect(cell.model.state?.isPointerHovering == false)

        // Closing with a stationary pointer restores the hovered flag even
        // though recomputeHoveredRow() resolves the unchanged row id.
        controller.contextMenuDidClose(rowId: row.id)
        #expect(cell.model.state?.isPointerHovering == true)
    }

    @Test
    @MainActor
    func emptyAreaGroupCreationRespectsCapability() throws {
        let controller = SidebarWorkspaceTableController()
        _ = controller.makeContainerView()
        var creations = 0
        controller.apply(
            rows: [],
            actions: makeTableActions(
                canCreateEmptyWorkspaceGroup: false,
                createEmptyWorkspaceGroup: { creations += 1 }
            ),
            workspaceIds: [],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        let item = try #require(controller.emptyAreaMenu().items.first)
        #expect(!item.isEnabled)
        controller.createEmptyWorkspaceGroup()
        #expect(creations == 0)
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
        flushStagedTableMutations()
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
        id: SidebarWorkspaceRenderItemID? = nil,
        workspaceId: UUID = UUID(),
        groupId: UUID? = nil,
        isGroupHeader: Bool = false,
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
            id: id ?? .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: groupId,
            isGroupHeader: isGroupHeader,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent(token: contentToken)
        ) { _, _, _ in
            AnyView(TestRowContent(token: contentToken))
        }
    }

    @MainActor
    private func makeExpandingRowConfiguration(
        model: ExpandingTestRowModel
    ) -> SidebarWorkspaceTableRowConfiguration {
        let workspaceId = UUID()
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: 0
        ) { _, _, _ in
            AnyView(ExpandingTestRow(model: model))
        }
    }

    @MainActor
    @discardableResult
    private func configure(
        _ cell: SidebarWorkspaceTableCellView,
        row: SidebarWorkspaceTableRowConfiguration,
        isPointerHovering: Bool = false
    ) -> Bool {
        cell.configure(
            row: row,
            isPointerHovering: isPointerHovering,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
    }

    @MainActor
    private func flushStagedTableMutations() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    private func makeTableActions(
        canCreateEmptyWorkspaceGroup: Bool = true,
        createEmptyWorkspaceGroup: @escaping () -> Void = {},
        beginWorkspaceDrag: @escaping (UUID) -> Void = { _ in },
        moveBonsplitToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID? = { _, _ in nil }
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            canCreateEmptyWorkspaceGroup: canCreateEmptyWorkspaceGroup,
            createEmptyWorkspaceGroup: createEmptyWorkspaceGroup,
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
    private struct TestRowContent: View, Equatable {
        let token: Int
        var body: some View {
            EmptyView()
        }
    }

    @MainActor
    @Observable
    private final class ExpandingTestRowModel {
        var isExpanded = false
    }

    @MainActor
    private struct ExpandingTestRow: View {
        let model: ExpandingTestRowModel

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 30)
                if model.isExpanded {
                    Color.clear.frame(height: 100)
                }
            }
        }
    }
}
