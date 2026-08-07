import AppKit
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
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspace = Workspace()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(workspaceId: workspace.id)
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

        let table = container.tableView
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(cell is SidebarWorkspaceRowTableCellView)
        let tablePoint = NSPoint(x: table.bounds.midX, y: table.rect(ofRow: 0).midY)
        let windowPoint = table.convert(tablePoint, to: nil)
        let event = try #require(NSEvent.mouseEvent(
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

        let menu = withExtendedLifetime(window) {
            withExtendedLifetime(tabManager) {
                table.menu(for: event)
            }
        }
        let renameTitle = String(
            localized: "contextMenu.renameWorkspace",
            defaultValue: "Rename Workspace…"
        )
        #expect(menu?.items.contains { $0.title == renameTitle } == true)
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
