import AppKit
import CmuxFoundation
import QuartzCore
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Issue #16253. Switching between a local and a Cloud workspace left no row
/// highlighted for about 200 ms and then two rows: each row's highlight
/// reached the screen in its own Core Animation commit, and reconciling the
/// click repainted rows from the selection they had before it. Every commit a
/// switch makes must show exactly one highlighted row, the committed one.
@Suite(.serialized)
@MainActor
struct SidebarWorkspaceSelectionCommitTests {
    @Test
    func clickingBetweenLocalAndCloudWorkspacesShowsOneHighlightedRowAtEveryCommit() async throws {
        let sidebar = try await Sidebar.make()
        defer { sidebar.close() }
        #expect(sidebar.highlightedOnScreen() == [sidebar.local.id])

        for target in [sidebar.cloud, sidebar.local, sidebar.cloud] {
            sidebar.click(target)
            #expect(sidebar.tabManager.selectedTabId == target.id, "the click commits the selection")
            #expect(sidebar.highlightedOnScreen() == [target.id], "the click's own commit")

            let duringReconcile = await sidebar.applyRowsAndInspectBeforeTurnEnds()
            #expect(duringReconcile == [target.id], "commits made while reconciling the rows")
            #expect(sidebar.highlightedOnScreen() == [target.id], "after the turn")
        }
    }

    @Test
    func keyboardSwitchShowsTheNewRowWithoutWaitingForTheRowRebuild() async throws {
        let sidebar = try await Sidebar.make()
        defer { sidebar.close() }

        CATransaction.flush()
        sidebar.tabManager.selectNextTab()
        #expect(sidebar.highlightedOnScreen() == [sidebar.cloud.id])

        sidebar.tabManager.selectPreviousTab()
        #expect(sidebar.highlightedOnScreen() == [sidebar.local.id])
    }
}

/// A windowed AppKit sidebar over a real TabManager, wired the way the
/// SwiftUI sidebar wires it: rows are rebuilt from the committed selection and
/// delivered through `apply`.
@MainActor
private final class Sidebar {
    let tabManager: TabManager
    let local: Workspace
    let cloud: Workspace
    private let controller = SidebarWorkspaceTableController()
    private let container: SidebarWorkspaceTableContainerView
    private let window: NSWindow
    private var multiSelection: Set<UUID>

    private init(tabManager: TabManager, local: Workspace, cloud: Workspace) {
        self.tabManager = tabManager
        self.local = local
        self.cloud = cloud
        multiSelection = [local.id]
        container = controller.makeContainerView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        controller.bindSelection(SidebarWorkspaceSelectionSource(
            owner: ObjectIdentifier(tabManager),
            selectedWorkspaceIds: tabManager.selectedTabIdPublisher.eraseToAnyPublisher(),
            multiSelectedWorkspaceIds: { [weak self] in self?.multiSelection ?? [] }
        ))
    }

    static func make() async throws -> Sidebar {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let local = try #require(tabManager.selectedWorkspace)
        let cloud = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
        cloud.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "clever-violet-python", isBase: false)
        let sidebar = Sidebar(tabManager: tabManager, local: local, cloud: cloud)
        sidebar.applyRows()
        await sidebar.runLoopTurn()
        sidebar.container.layoutSubtreeIfNeeded()
        sidebar.container.tableView.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return sidebar
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// A click through the table's own action, starting from a committed
    /// screen as every new event does.
    func click(_ workspace: Workspace) {
        let table = container.tableView
        guard let row = workspaceIds.firstIndex(of: workspace.id),
              let action = table.action,
              let target = table.target else {
            Issue.record("no row for \(workspace.id)")
            return
        }
        CATransaction.flush()
        table.setValue(row, forKey: "clickedRow")
        defer { table.setValue(-1, forKey: "clickedRow") }
        #expect(table.sendAction(action, to: target))
    }

    /// Delivers the rows SwiftUI rebuilds after a selection change and reads
    /// the screen in the same run-loop pass, before the turn's final commit,
    /// which is what a frame shows while a workspace switch still runs.
    func applyRowsAndInspectBeforeTurnEnds() async -> [UUID] {
        applyRows()
        return await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: self.highlightedOnScreen())
                }
            }
        }
    }

    /// Workspace ids whose selected fill is in the render tree.
    func highlightedOnScreen() -> [UUID] {
        let table = container.tableView
        return workspaceIds.indices.compactMap { row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SidebarWorkspaceRowTableCellView,
                  cell.isSelectionHighlightOnScreenForTesting else { return nil }
            return workspaceIds[row]
        }
    }

    private var workspaceIds: [UUID] { [local.id, cloud.id] }

    private func applyRows() {
        let rows = [local, cloud].map { workspace in
            let model = SidebarAppKitRowCellTests.makeModel(
                workspaceId: workspace.id,
                isActive: tabManager.selectedTabId == workspace.id
            )
            return SidebarWorkspaceTableRowConfiguration(
                workspaceRowModel: model,
                actions: SidebarAppKitRowCellTests.makeActions(model: model, tab: workspace, tabManager: tabManager),
                groupId: nil,
                isPinned: false,
                environment: SidebarWorkspaceTableEnvironmentSnapshot(
                    colorScheme: .dark,
                    globalFontMagnificationPercent: 100,
                    lazyContractProbe: SidebarLazyContractProbe()
                )
            )
        }
        controller.apply(
            rows: rows,
            actions: Self.tableActions(),
            workspaceIds: workspaceIds,
            selectedWorkspaceId: tabManager.selectedTabId,
            selectedScrollTargetWorkspaceId: tabManager.selectedTabId
        )
    }

    private func runLoopTurn() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private static func tableActions() -> SidebarWorkspaceTableActions {
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
            performPendingWorkspaceDrop: nil,
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
