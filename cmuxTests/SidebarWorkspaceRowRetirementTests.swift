import AppKit
import CmuxWorkspaces
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceRowRetirementTests {
    @Test
    func tableRetirementClosesStatusPopover() async throws {
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(manualTaskStatus: .working)
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let glyph = try #require(
            descendants(of: mounted.cell)
                .compactMap { $0 as? SidebarRowTaskStatusGlyphButton }
                .first { !$0.isHidden }
        )
        let existingWindowIds = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        #expect(glyph.accessibilityPerformPress())
        let popoverWindow = try #require(
            NSApplication.shared.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        await removeMountedRow(mounted)

        #expect(!popoverWindow.isVisible)
    }

    @Test
    func tableRetirementClosesChecklistPopover() async throws {
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(
            checklistItems: [WorkspaceChecklistItem(text: "Draft")],
            isChecklistPopoverPresented: true,
            checklistStyle: .popover
        )
        let existingWindowIds = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let popoverWindow = try #require(
            NSApplication.shared.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        await removeMountedRow(mounted)

        #expect(!popoverWindow.isVisible)
    }

    private func mount(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) async throws -> (
        controller: SidebarWorkspaceTableController,
        container: SidebarWorkspaceTableContainerView,
        window: NSWindow,
        tableActions: SidebarWorkspaceTableActions,
        cell: SidebarWorkspaceRowTableCellView
    ) {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let tableActions = makeTableActions()
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: actions,
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
        window.orderFront(nil)
        controller.apply(
            rows: [row],
            actions: tableActions,
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
        cell.layoutSubtreeIfNeeded()
        return (controller, container, window, tableActions, cell)
    }

    private func removeMountedRow(_ mounted: (
        controller: SidebarWorkspaceTableController,
        container: SidebarWorkspaceTableContainerView,
        window: NSWindow,
        tableActions: SidebarWorkspaceTableActions,
        cell: SidebarWorkspaceRowTableCellView
    )) async {
        mounted.controller.apply(
            rows: [],
            actions: mounted.tableActions,
            workspaceIds: [],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        mounted.container.tableView.layoutSubtreeIfNeeded()
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {}, beginWorkspaceDrag: { _ in }, endWorkspaceDrag: {},
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
#endif
