import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Freeform reorder lift: the block under the pointer, the rows parting
/// around it, and the drag's own image once it leaves the list.
extension SidebarWorkspaceTableTests {
    @Test(arguments: [0, 1, 3])
    @MainActor
    func groupDragPreservesHeaderGrabOffset(memberCount: Int) async throws {
        let (controller, container, window) = makeLiftHost()
        defer { controller.dismantleContainerView(container) }
        _ = window
        let groupId = UUID()
        let header = makeLiftRow(groupId: groupId, isGroupHeader: true, height: 28)
        let members = (0..<memberCount).map { index in
            makeLiftRow(groupId: groupId, height: CGFloat(40 + index * 15))
        }
        let rows = [makeLiftRow(height: 80), header] + members + [makeLiftRow(height: 160)]
        let table = await applyLiftRows(rows, controller: controller, container: container)
        let sourceViews = try (1..<(2 + memberCount)).map { row in
            try #require(table.rowView(atRow: row, makeIfNecessary: true))
        }
        // Grab near the top of the header, far from an expanded block's
        // center. Pickup must not jump; each member must follow the header
        // by exactly the pointer's movement in both directions.
        let grab = NSPoint(x: 50, y: table.rect(ofRow: 1).minY + 5)
        for delta: CGFloat in [0, 24, -18, 0] {
            controller.updateReorderLift(
                windowPoint: table.convert(NSPoint(x: grab.x, y: grab.y + delta), to: nil),
                workspaceId: header.workspaceId
            )
            for rowView in sourceViews {
                let layer = try #require(rowView.layer)
                #expect(abs(layer.transform.m42 - delta) < 0.5)
            }
        }
    }

    @Test
    @MainActor
    func liveDragLiftIsRebuiltAcrossAStructuralUpdateWithoutBouncing() async throws {
        let (controller, container, window) = makeLiftHost()
        defer { controller.dismantleContainerView(container) }
        _ = window
        let closed = makeLiftRow(height: 40)
        let dragged = makeLiftRow(height: 40)
        let others = (0..<3).map { _ in makeLiftRow(height: 40) }
        let rows = [closed, dragged] + others
        let table = await applyLiftRows(rows, controller: controller, container: container)
        for row in rows.indices {
            _ = try #require(table.rowView(atRow: row, makeIfNecessary: true))
        }
        // Lift the second row and carry it two rows down, so rows part.
        let grab = NSPoint(x: 50, y: table.rect(ofRow: 1).minY + 10)
        for delta: CGFloat in [0, 90] {
            controller.updateReorderLift(
                windowPoint: table.convert(NSPoint(x: grab.x, y: grab.y + delta), to: nil),
                workspaceId: dragged.workspaceId
            )
        }
        // Let the parting glides finish, so on-screen and model agree.
        table.enumerateAvailableRowViews { rowView, _ in rowView.layer?.removeAllAnimations() }
        await flushStagedTableMutations()
        let visualTopsBefore = liftVisualTops(rows: rows, table: table)
        let snapshotBefore = controller.reorderLiftSnapshots.first?.layer

        // A workspace above the drag closes mid-drag.
        let remaining = Array(rows.dropFirst())
        _ = await applyLiftRows(remaining, controller: controller, container: container)

        // The lift survives against the new rows instead of ending.
        let session = try #require(controller.reorderLiftSession)
        #expect(session.workspaceId == dragged.workspaceId)
        #expect(session.sourceRange == 0..<1)
        if let snapshotBefore {
            #expect(controller.reorderLiftSnapshots.first?.layer === snapshotBefore)
        }
        // Every surviving row starts its motion exactly where it stood
        // before the update: no drop to its real frame, no bounce.
        for (index, row) in remaining.enumerated() {
            let rowView = try #require(table.rowView(atRow: index, makeIfNecessary: false))
            let layer = try #require(rowView.layer)
            let spring = layer.animation(forKey: "cmux.reorderShift") as? CABasicAnimation
            let start = (spring?.fromValue as? CGFloat) ?? layer.transform.m42
            let before = try #require(visualTopsBefore[row.workspaceId])
            #expect(abs(table.rect(ofRow: index).minY + start - before) < 0.5)
        }
    }

    @Test
    @MainActor
    func dragImageShowsOnlyAwayFromTheList() {
        let windowFrame = NSRect(x: 100, y: 100, width: 800, height: 600)
        let inside = NSPoint(x: 150, y: 400)
        typealias Controller = SidebarWorkspaceTableController
        // Over the list, or grazing its edges: the lift is the picture.
        for x: CGFloat in [-40, 0, 120, 260, 300] {
            #expect(!Controller.reorderDragShowsGhost(
                tablePointX: x, tableWidth: 260, windowFrame: windowFrame, screenPoint: inside
            ))
        }
        // Into the terminal beside it, or out to another window.
        #expect(Controller.reorderDragShowsGhost(
            tablePointX: 400, tableWidth: 260, windowFrame: windowFrame, screenPoint: inside
        ))
        #expect(Controller.reorderDragShowsGhost(
            tablePointX: 120, tableWidth: 260, windowFrame: windowFrame, screenPoint: NSPoint(x: 1200, y: 400)
        ))
    }

    // MARK: - Helpers

    @MainActor
    private func makeLiftHost() -> (SidebarWorkspaceTableController, SidebarWorkspaceTableContainerView, NSWindow) {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        return (controller, container, window)
    }

    @MainActor
    private func applyLiftRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        controller: SidebarWorkspaceTableController,
        container: SidebarWorkspaceTableContainerView
    ) async -> NSTableView {
        controller.apply(
            rows: rows,
            actions: makeTableActions(),
            workspaceIds: rows.map(\.workspaceId),
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        return container.tableView
    }

    /// Each row's on-screen top (frame plus lift translation), by workspace.
    @MainActor
    private func liftVisualTops(
        rows: [SidebarWorkspaceTableRowConfiguration],
        table: NSTableView
    ) -> [UUID: CGFloat] {
        var tops: [UUID: CGFloat] = [:]
        for (index, row) in rows.enumerated() {
            let shift = table.rowView(atRow: index, makeIfNecessary: false)?.layer?.transform.m42 ?? 0
            tops[row.workspaceId] = table.rect(ofRow: index).minY + shift
        }
        return tops
    }

    @MainActor
    private func makeLiftRow(
        groupId: UUID? = nil,
        isGroupHeader: Bool = false,
        height: CGFloat
    ) -> SidebarWorkspaceTableRowConfiguration {
        let workspaceId = UUID()
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let content = TestRowContent(token: 0, fixedHeight: height)
        return SidebarWorkspaceTableRowConfiguration(
            id: isGroupHeader ? .group(groupId ?? workspaceId) : .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: groupId,
            isGroupHeader: isGroupHeader,
            isPinned: false,
            environment: environment,
            equivalenceValue: content
        ) { _, _ in
            AnyView(content)
        }
    }
}
#endif
