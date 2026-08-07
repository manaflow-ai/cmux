import AppKit
import CmuxSettings
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceContextMenuRoutingTests {
    @Test
    func controlClickOnWorkspaceRowReturnsRenameMenu() async throws {
        let mounted = try await mountTable { workspaceId in
            SidebarWorkspaceRowSuspensionTests.makeModel(workspaceId: workspaceId)
        }
        defer { mounted.window.close() }
        let table = mounted.container.tableView
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(cell is SidebarWorkspaceRowTableCellView)
        let tablePoint = NSPoint(x: table.bounds.midX, y: table.rect(ofRow: 0).midY)
        let windowPoint = table.convert(tablePoint, to: nil)
        let event = try controlClickEvent(at: windowPoint, window: mounted.window)

        let menu = routedMenu(for: event, in: mounted)
        let renameTitle = String(
            localized: "contextMenu.renameWorkspace",
            defaultValue: "Rename Workspace…"
        )
        #expect(menu?.items.contains { $0.title == renameTitle } == true)
    }

    @Test
    func controlClickOnNestedChecklistItemReturnsItemMenu() throws {
        let item = WorkspaceChecklistItem(text: "Nested item")
        let workspace = Workspace()
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(
            checklistItems: [item],
            workspaceId: workspace.id
        )
        let cell = SidebarWorkspaceRowTableCellView(
            frame: NSRect(x: 180, y: 120, width: 320, height: 160)
        )
        let itemLine = SidebarRowChecklistItemLine(
            frame: NSRect(x: 16, y: 48, width: 288, height: 24)
        )
        cell.addSubview(itemLine)
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 360)
        )
        container.addSubview(cell)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            window.contentView = nil
            window.close()
        }
        itemLine.configure(
            item,
            model: model,
            primary: .labelColor,
            secondary: .secondaryLabelColor,
            isEditing: false,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: model,
                workspace: workspace
            )
        )
        let itemHeight = itemLine.measuredHeight(width: itemLine.bounds.width)
        try #require(itemHeight.isFinite && itemHeight > 0)
        itemLine.setFrameSize(NSSize(width: itemLine.bounds.width, height: itemHeight))
        itemLine.layoutSubtreeIfNeeded()
        let itemPoint = NSPoint(x: itemLine.bounds.midX, y: itemLine.bounds.midY)
        let windowPoint = itemLine.convert(itemPoint, to: nil)
        try #require(windowPoint.x.isFinite && windowPoint.y.isFinite)
        let event = try controlClickEvent(at: windowPoint, window: window)

        let menu = SidebarWorkspaceContextMenuResolver(rowView: cell).menu(for: event)
        #expect(menu?.items.map(\.title) == [
            String(localized: "sidebar.checklist.editItem", defaultValue: "Edit"),
            String(
                localized: "sidebar.checklist.markInProgress",
                defaultValue: "Mark In Progress"
            ),
            String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove"),
        ])
    }

    private struct MountedTable {
        let controller: SidebarWorkspaceTableController
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let tabManager: TabManager
    }

    private func mountTable(
        makeModel: (UUID) -> SidebarWorkspaceRowModel
    ) async throws -> MountedTable {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspace = Workspace()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let model = makeModel(workspace.id)
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                model: model,
                workspace: workspace,
                tabManager: tabManager
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
        _ = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        container.tableView.layoutSubtreeIfNeeded()

        return MountedTable(
            controller: controller,
            container: container,
            window: window,
            tabManager: tabManager
        )
    }

    private func controlClickEvent(at windowPoint: NSPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func routedMenu(for event: NSEvent, in mounted: MountedTable) -> NSMenu? {
        withExtendedLifetime(mounted.controller) {
            withExtendedLifetime(mounted.tabManager) {
                mounted.container.tableView.menu(for: event)
            }
        }
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
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
}
#endif
