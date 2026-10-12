import AppKit
import Bonsplit
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Previous/Next (Leo 2026-10-12, Chrome tab keys) move between sidebar workspaces, what
/// Chrome calls tabs, wrapping at the ends, even from a pane with two or more tabs.
@MainActor
@Suite(.serialized)
struct RapidSwitchTests {
    @Test
    func aSingleTabPaneMovesToTheNextAndPreviousWorkspaceAndWraps() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        _ = manager.addWorkspace(title: "Build", select: false)
        _ = manager.addWorkspace(title: "Logs", select: false)
        // New workspaces may open beside the selected one, so step in the order the sidebar shows.
        let order = manager.tabs.map(\.id)
        #expect(order.count == 3 && order[0] == first.id)

        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == order[1], "Next from a one-tab pane moves to the next workspace")
        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == order[2])
        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == order[0], "Next on the last workspace wraps to the first")
        manager.stepTabOrWorkspace(forward: false)
        #expect(manager.selectedTabId == order[2], "Previous on the first workspace wraps to the last")
    }

    @Test
    func aPaneWithTwoTabsStillMovesBetweenSidebarWorkspaces() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        _ = manager.addWorkspace(title: "Build", select: false)
        let order = manager.tabs.map(\.id)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let panels = workspace.sidebarOrderedPanelIds()
        #expect(panels.count == 2)
        workspace.focusPanel(panels[0])

        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == order[1], "Next from a two-tab pane moves to the next workspace")
        #expect(workspace.focusedPanelId == panels[0], "the pane keeps its selected tab")
        manager.selectWorkspace(workspace)
        manager.stepTabOrWorkspace(forward: false)
        #expect(manager.selectedTabId == order[1], "Previous on the first workspace wraps to the last")
        #expect(workspace.focusedPanelId == panels[0])
    }
}
