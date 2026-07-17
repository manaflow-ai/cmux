import AppKit
import Bonsplit
import CmuxFoundation
import Combine
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

    /// A hosted row can change height from cell-local SwiftUI state without a
    /// new table snapshot. The table must follow the rendered cell instead of
    /// leaving the old row rectangle in place while content paints over its
    /// neighbors.
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
        ) { _, _ in
            AnyView(ExpandingTestRow(model: model))
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
        canCreateEmptyWorkspaceGroup: Bool = true,
        createEmptyWorkspaceGroup: @escaping () -> Void = {},
        moveBonsplitToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID? = { _, _ in nil }
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            canCreateEmptyWorkspaceGroup: canCreateEmptyWorkspaceGroup,
            createEmptyWorkspaceGroup: createEmptyWorkspaceGroup,
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

    @MainActor
    private final class ExpandingTestRowModel: ObservableObject {
        @Published var isExpanded = false
    }

    @MainActor
    private struct ExpandingTestRow: View {
        @ObservedObject var model: ExpandingTestRowModel

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
