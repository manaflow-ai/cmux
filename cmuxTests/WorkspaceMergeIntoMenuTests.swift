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

/// Merge Workspace into, from the sidebar row menu and the Workspace menu:
/// the keyboard and menu form of dropping a workspace on a pane.
@MainActor
@Suite(.serialized)
struct WorkspaceMergeIntoMenuTests {
    @MainActor
    private struct Fixture {
        let previousApp: AppDelegate?
        let app: AppDelegate
        let windowId = UUID()
        let manager: TabManager
        // Merge targets are listed per live window, as the menus see them.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        init() {
            // AppDelegate.init claims AppDelegate.shared; later suites rely on the host's.
            previousApp = AppDelegate.shared
            app = AppDelegate()
            manager = TabManager()
            app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager, window: window)
        }

        func tearDown() {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
            AppDelegate.shared = previousApp
        }
    }

    @Test
    func theMenuListsEveryOtherWorkspaceInSidebarOrder() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let first = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let second = fixture.manager.addWorkspace(title: "Logs", select: false)
        let third = fixture.manager.addWorkspace(title: "Build", select: false)

        let targets = fixture.app.workspaceMergeTargets(for: second.id)

        #expect(targets.map(\.workspaceId) == [first.id, third.id], "the source itself is not a target")
        #expect(targets.allSatisfy { $0.isEnabled })
        #expect(targets.last?.label == "Build")
    }

    @Test
    func mergingAppendsEveryTabToTheTargetsFocusedPaneAndClosesTheSource() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let target = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let firstPanel = try XCTUnwrap(target.focusedTerminalPanel?.id)
        let splitPanel = try XCTUnwrap(target.newTerminalSplit(from: firstPanel, orientation: .horizontal, focus: false))
        let focusedPane = try XCTUnwrap(target.paneId(forPanelId: splitPanel.id))
        target.bonsplitController.focusPane(focusedPane)
        let source = fixture.manager.addWorkspace(title: "Build", select: false)
        let sourcePane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePane, focus: false))
        let sourceOrder = source.sidebarOrderedPanelIds()
        #expect(sourceOrder.count == 2)

        #expect(fixture.app.mergeWorkspaceIntoFocusedPane(source.id, into: target.id, focus: false, focusWindow: false))

        #expect(fixture.manager.tabs.map(\.id) == [target.id], "the emptied workspace closed")
        #expect(sourceOrder.allSatisfy { target.paneId(forPanelId: $0) == focusedPane }, "every tab lands in the focused pane")
        let order = ([splitPanel.id] + sourceOrder).map { target.indexInPane(forPanelId: $0) }
        #expect(order == [0, 1, 2], "after the pane's own tab, in the source's order")
        #expect(target.bonsplitController.allPaneIds.count == 2, "no new split")
    }

    @Test
    func aWorkspaceCannotMergeIntoItself() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let only = try XCTUnwrap(fixture.manager.selectedWorkspace)

        #expect(!fixture.app.mergeWorkspaceIntoFocusedPane(only.id, into: only.id, focus: false, focusWindow: false))
        #expect(fixture.manager.tabs.map(\.id) == [only.id])
    }
}
