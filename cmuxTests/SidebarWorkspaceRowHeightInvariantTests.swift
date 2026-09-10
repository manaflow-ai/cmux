import AppKit
import CmuxWorkspaces
import Testing
@testable import cmux_DEV

/// Regression coverage for sidebar rows painting clipped after workspace
/// closes (https://github.com/manaflow-ai/cmux — "multiple closes leave rows
/// short of their content height"). The invariant under test is the one the
/// controller's DEBUG drift probe documents: for every row, the rect the
/// table lays out must equal the height its delegate answers, and closes must
/// never change a surviving row's height.
@Suite(.serialized)
@MainActor
struct SidebarWorkspaceRowHeightInvariantTests {
    private let tallDescription = Array(
        repeating: "wraps across several sidebar lines to exceed the estimate",
        count: 4
    ).joined(separator: " ")

    @Test
    func rapidClosesKeepSurvivingRowsAtFullContentHeight() async throws {
        let mounted = try await mount(rowCount: 6, width: 300)
        defer { mounted.window.close() }

        let initialHeights = rectHeightsById(mounted, appliedRows: mounted.rows)
        for (id, height) in initialHeights {
            #expect(
                height > estimatedHeightCeiling,
                "row \(id) must start taller than the single-line estimate"
            )
        }

        // Two closes in separate apply turns, then two coalesced into one
        // turn (rapid clicking collapses into a single staged apply).
        var surviving = mounted.rows
        surviving.remove(at: 0)
        applyRows(surviving, mounted)
        await flushStagedTableMutations()

        surviving.remove(at: 1)
        applyRows(surviving, mounted)
        var twiceSurviving = surviving
        twiceSurviving.remove(at: 2)
        applyRows(twiceSurviving, mounted)
        await flushStagedTableMutations()
        surviving = twiceSurviving
        mounted.container.tableView.layoutSubtreeIfNeeded()

        assertRectsMatchDelegate(mounted)
        let survivingHeights = rectHeightsById(mounted, appliedRows: surviving)
        #expect(survivingHeights.count == surviving.count)
        for (id, height) in survivingHeights {
            let initial = try #require(initialHeights[id])
            #expect(
                abs(height - initial) < 0.5,
                "closing other rows must not change row \(id): \(initial) -> \(height)"
            )
        }
    }

    @Test
    func closeDuringUnsettledWidthChangeSettlesToFullContentHeight() async throws {
        let mounted = try await mount(rowCount: 6, width: 300)
        defer { mounted.window.close() }

        // Narrow the sidebar and close two rows before the trailing width
        // settle can run — the historical clipped-row window (structural
        // reload while measured width and live width disagree).
        mounted.window.setContentSize(NSSize(width: 220, height: 900))
        mounted.container.layoutSubtreeIfNeeded()

        var surviving = mounted.rows
        surviving.remove(at: 0)
        applyRows(surviving, mounted)
        await flushStagedTableMutations()
        surviving.remove(at: 2)
        applyRows(surviving, mounted)
        await flushStagedTableMutations()

        mounted.controller.performWidthRemeasureNow()
        mounted.container.tableView.layoutSubtreeIfNeeded()

        assertRectsMatchDelegate(mounted)
        for (id, height) in rectHeightsById(mounted, appliedRows: surviving) {
            #expect(
                height > estimatedHeightCeiling,
                "row \(id) settled clipped after close during width change"
            )
        }
    }

    @Test
    func closingLastRowThenWidthSettleKeepsUnchangedRowsConsistent() async throws {
        let mounted = try await mount(rowCount: 6, width: 300)
        defer { mounted.window.close() }

        // Closing the trailing row leaves every surviving row content- and
        // index-identical, so no apply-time re-measure runs for them; the
        // width change then settles through the cache-diff path alone.
        mounted.window.setContentSize(NSSize(width: 240, height: 900))
        mounted.container.layoutSubtreeIfNeeded()

        var surviving = mounted.rows
        surviving.removeLast()
        applyRows(surviving, mounted)
        await flushStagedTableMutations()

        mounted.controller.performWidthRemeasureNow()
        mounted.container.tableView.layoutSubtreeIfNeeded()

        assertRectsMatchDelegate(mounted)
        for (id, height) in rectHeightsById(mounted, appliedRows: surviving) {
            #expect(
                height > estimatedHeightCeiling,
                "row \(id) stuck at the estimate after trailing close + settle"
            )
        }
    }

    // MARK: - Harness

    /// Ceiling for the 1-title-line / 0-auxiliary-line estimate every clipped
    /// row collapses to; the tall description keeps real rows well above it.
    private var estimatedHeightCeiling: CGFloat { 40 }

    private struct Mounted {
        let controller: SidebarWorkspaceTableController
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let tableActions: SidebarWorkspaceTableActions
        var rows: [SidebarWorkspaceTableRowConfiguration]
    }

    private func mount(rowCount: Int, width: CGFloat) async throws -> Mounted {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let tableActions = makeTableActions()
        let rows = (0..<rowCount).map { index in
            makeRowConfiguration(index: index, rowCount: rowCount)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded()
        let mounted = Mounted(
            controller: controller,
            container: container,
            window: window,
            tableActions: tableActions,
            rows: rows
        )
        applyRows(rows, mounted)
        await flushStagedTableMutations()
        container.tableView.layoutSubtreeIfNeeded()
        #expect(container.tableView.numberOfRows == rowCount)
        return mounted
    }

    private func applyRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        _ mounted: Mounted
    ) {
        mounted.controller.apply(
            rows: rows,
            actions: mounted.tableActions,
            workspaceIds: rows.map(\.workspaceId),
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
    }

    private func makeRowConfiguration(
        index: Int,
        rowCount: Int
    ) -> SidebarWorkspaceTableRowConfiguration {
        var model = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: tallDescription
        )
        model.index = index
        model.isFirstRow = index == 0
        return SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
    }

    /// The drift-probe invariant: the rect NSTableView laid out for each row
    /// equals the height its delegate currently answers.
    private func assertRectsMatchDelegate(_ mounted: Mounted) {
        let table = mounted.container.tableView
        let spacing = table.intercellSpacing.height
        for row in 0..<table.numberOfRows {
            let laidOut = table.rect(ofRow: row).height - spacing
            let served = mounted.controller.tableView(table, heightOfRow: row)
            #expect(
                abs(laidOut - served) < 0.5,
                "row \(row) rect \(laidOut) != delegate answer \(served)"
            )
        }
    }

    /// Heights keyed by workspace id; `appliedRows` is the row array most
    /// recently passed to `apply`, whose order is the table's row order.
    private func rectHeightsById(
        _ mounted: Mounted,
        appliedRows: [SidebarWorkspaceTableRowConfiguration]
    ) -> [UUID: CGFloat] {
        let table = mounted.container.tableView
        let spacing = table.intercellSpacing.height
        #expect(table.numberOfRows == appliedRows.count)
        var heights: [UUID: CGFloat] = [:]
        for row in 0..<min(table.numberOfRows, appliedRows.count) {
            heights[appliedRows[row].workspaceId] = table.rect(ofRow: row).height - spacing
        }
        return heights
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {}, beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true }, updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false }, commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil }, didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }
}
