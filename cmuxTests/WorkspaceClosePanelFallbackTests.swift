import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `Workspace.closePanel` falls back to the focused pane's selected tab when the
/// target panel has lost its tab mapping. That fallback must never close a tab
/// owned by a different panel (https://github.com/manaflow-ai/cmux/issues/12524).
@MainActor
@Suite("closePanel unmapped fallback", .serialized)
struct WorkspaceClosePanelFallbackTests {
    @Test func fallbackRefusesToCloseSelectedTabOwnedByAnotherPanel() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let otherPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        let otherTabId = try #require(workspace.surfaceIdFromPanelId(otherPanel.id))
        workspace.bonsplitController.selectTab(otherTabId)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == otherTabId)

        // A target with no tab mapping that still owns first responder.
        let unmappedPanelId = UUID()
        #expect(workspace.surfaceIdFromPanelId(unmappedPanelId) == nil)

        #expect(!workspace.closeUnmappedPanelViaSelectedTab(
            unmappedPanelId,
            firstResponderPanelId: unmappedPanelId,
            force: true
        ))

        #expect(workspace.bonsplitController.tabs(inPane: paneId).count == 2)
        #expect(workspace.panels[otherPanel.id] != nil)
        #expect(workspace.panels[firstPanelId] != nil)
        #expect(workspace.surfaceIdFromPanelId(otherPanel.id) == otherTabId)
    }

    @Test func fallbackStillClosesSelectedTabWithNoPanelMapping() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let targetPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        let targetTabId = try #require(workspace.surfaceIdFromPanelId(targetPanel.id))
        workspace.bonsplitController.selectTab(targetTabId)

        // The target lost its mapping but its tab is still selected.
        workspace.removeSurfaceMapping(forSurfaceId: targetTabId)
        #expect(workspace.surfaceIdFromPanelId(targetPanel.id) == nil)
        #expect(workspace.panelIdFromSurfaceId(targetTabId) == nil)

        #expect(workspace.closeUnmappedPanelViaSelectedTab(
            targetPanel.id,
            firstResponderPanelId: targetPanel.id,
            force: true
        ))

        let remainingTabIds = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        #expect(!remainingTabIds.contains(targetTabId))
        #expect(remainingTabIds.count == 1)
        #expect(workspace.surfaceIdFromPanelId(firstPanelId) != nil)
    }
}
