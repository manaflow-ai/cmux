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

/// Previous/Next (Leo 2026-10-09, rapid switching): a focused pane with two or more tabs steps
/// its tabs and wraps inside the pane; otherwise the keys move between sidebar workspaces,
/// wrapping at the ends.
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
    func aPaneWithTwoTabsStepsItsTabsAndWrapsInsideThePane() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let other = manager.addWorkspace(title: "Build", select: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let order = workspace.sidebarOrderedPanelIds()
        #expect(order.count == 2)
        workspace.focusPanel(order[0])

        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == workspace.id, "a pane with two tabs keeps Next inside it")
        #expect(workspace.focusedPanelId == order[1])
        manager.stepTabOrWorkspace(forward: true)
        #expect(manager.selectedTabId == workspace.id, "Next on the pane's last tab wraps in the pane")
        #expect(workspace.focusedPanelId == order[0])
        manager.stepTabOrWorkspace(forward: false)
        #expect(workspace.focusedPanelId == order[1])
        #expect(manager.selectedTabId != other.id)
    }
}
