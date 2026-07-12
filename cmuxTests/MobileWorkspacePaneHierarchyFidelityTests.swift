import AppKit
import Bonsplit
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileWorkspacePaneHierarchyFidelityTests {
    private func makeWorkspaceWithTabTerminals() throws -> (Workspace, [UUID]) {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        return (workspace, [first, second.id])
    }

    private func makeWorkspaceWithSplitTerminals() throws -> (Workspace, [UUID]) {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(
            workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false)
        )
        return (workspace, [first, second.id])
    }

    @Test func focusingAnotherPaneChangesOnlyScopedFocusSignature() throws {
        let (workspace, ordered) = try makeWorkspaceWithSplitTerminals()
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        let focusedBefore = MobileWorkspaceListObserver.focusedHierarchySignatureForTesting(
            workspace: workspace
        )

        workspace.focusPanel(ordered[1])

        #expect(workspace.focusedPanelId == ordered[1])
        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        let focusedAfter = MobileWorkspaceListObserver.focusedHierarchySignatureForTesting(
            workspace: workspace
        )
        #expect(before == after, "generic list updates must not duplicate scoped focus events")
        #expect(focusedBefore != focusedAfter, "focus events recompute only the affected workspace")
    }

    @Test func movingTerminalAcrossPanesChangesHashWhenFlatOrderDoesNot() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals()
        let split = try #require(
            workspace.newTerminalSplit(from: ordered[1], orientation: .horizontal, focus: false)
        )
        let initialFlatOrder = workspace.orderedPanelIds
        let panes = workspace.bonsplitController.allPaneIds
        #expect(panes.count == 2)
        let movedTabID = try #require(workspace.surfaceIdFromPanelId(ordered[1]))
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        #expect(workspace.bonsplitController.moveTab(movedTabID, toPane: panes[1], atIndex: 0))

        #expect(workspace.orderedPanelIds == initialFlatOrder)
        #expect(workspace.orderedPanelIds.last == split.id)
        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "pane membership is mobile payload state")
    }
}
