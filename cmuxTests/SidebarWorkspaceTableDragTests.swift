import AppKit
import Bonsplit
import Foundation
import SwiftUI
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
        let group = makeRowConfiguration(
            id: .group(groupId),
            workspaceId: anchorId,
            groupId: groupId,
            isGroupHeader: true
        )
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
                as? SidebarWorkspaceTableCellView
        )
        workspaceCell.model.state?.editingDidChange(true)
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 1) == nil)
        #expect(draggedWorkspaceIds == [anchorId])
        workspaceCell.model.state?.editingDidChange(false)
        #expect(controller.tableView(container.tableView, pasteboardWriterForRow: 1) != nil)
        #expect(draggedWorkspaceIds == [anchorId, workspaceId])
    }

    @Test
    @MainActor
    func reusedCellClearsSuppressionAndRejectsStaleEditingCallbacks() {
        let cell = SidebarWorkspaceTableCellView()
        configure(cell, row: makeRowConfiguration())
        let staleEditingDidChange = cell.model.state?.editingDidChange
        staleEditingDidChange?(true)
        #expect(cell.suppressesWorkspaceDrag)

        configure(cell, row: makeRowConfiguration())
        staleEditingDidChange?(true)
        #expect(!cell.suppressesWorkspaceDrag)
    }

    @MainActor
    private func makeRowConfiguration(
        id: SidebarWorkspaceRenderItemID? = nil,
        workspaceId: UUID = UUID(),
        groupId: UUID? = nil,
        isGroupHeader: Bool = false
    ) -> SidebarWorkspaceTableRowConfiguration {
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
            id: id ?? .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: groupId,
            isGroupHeader: isGroupHeader,
            isPinned: false,
            environment: environment,
            equivalenceValue: workspaceId
        ) { _, _, _ in AnyView(EmptyView()) }
    }

    @MainActor
    private func configure(
        _ cell: SidebarWorkspaceTableCellView,
        row: SidebarWorkspaceTableRowConfiguration
    ) {
        cell.configure(
            row: row,
            isPointerHovering: false,
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
        beginWorkspaceDrag: @escaping (UUID) -> Void
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
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }
}
