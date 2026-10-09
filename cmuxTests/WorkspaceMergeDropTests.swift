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

/// A sidebar workspace dropped on a pane brings its tabs in (cmux-next #17542):
/// the center adds them at the drop index, an edge splits with the first and the
/// rest follow, and the emptied workspace closes.
@MainActor
@Suite(.serialized)
struct WorkspaceMergeDropTests {
    @MainActor
    private struct Fixture {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()

        init() {
            app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        }

        func tearDown() {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
        }
    }

    @Test
    func aSingleTabWorkspaceDroppedOnAPaneMovesItsTabAndCloses() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let target = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let targetPane = try XCTUnwrap(target.bonsplitController.allPaneIds.first)
        let targetPanel = try XCTUnwrap(target.focusedTerminalPanel?.id)
        let source = fixture.manager.addWorkspace(title: "Logs", select: false)
        let sourcePanel = try XCTUnwrap(source.focusedTerminalPanel?.id)

        #expect(fixture.app.canMergeWorkspace(source.id, into: target.id))
        #expect(fixture.app.mergeWorkspace(source.id, into: target.id,
                                           destination: .insert(targetPane: targetPane, targetIndex: nil),
                                           focus: false, focusWindow: false))

        #expect(fixture.manager.tabs.map(\.id) == [target.id], "the emptied workspace closed")
        #expect(target.panels[sourcePanel] != nil && target.panels[targetPanel] != nil)
        #expect(target.paneId(forPanelId: sourcePanel) == targetPane)
        #expect(target.bonsplitController.allPaneIds.count == 1, "the center adds a tab, no split")
    }

    @Test
    func everyTabOfAMultiTabWorkspaceLandsInOrderAtTheDropIndex() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let target = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let targetPane = try XCTUnwrap(target.bonsplitController.allPaneIds.first)
        let targetPanel = try XCTUnwrap(target.focusedTerminalPanel?.id)
        let source = fixture.manager.addWorkspace(title: "Build", select: false)
        let sourcePane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePane, focus: false))
        _ = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePane, focus: false))
        // New tabs open beside the selected one, so read the order the tab bar shows.
        let sourceOrder = source.sidebarOrderedPanelIds()
        #expect(sourceOrder.count == 3)

        // Index 0: before the target's own tab.
        #expect(fixture.app.mergeWorkspace(source.id, into: target.id,
                                           destination: .insert(targetPane: targetPane, targetIndex: 0),
                                           focus: false, focusWindow: false))

        #expect(!fixture.manager.tabs.contains { $0.id == source.id })
        let order = (sourceOrder + [targetPanel]).map { target.indexInPane(forPanelId: $0) }
        #expect(order == [0, 1, 2, 3], "the source's tabs keep their order, before the target's tab")
    }

    @Test
    func anEdgeDropSplitsThePaneAndEveryTabFollowsIntoTheNewPane() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let target = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let targetPane = try XCTUnwrap(target.bonsplitController.allPaneIds.first)
        let targetPanel = try XCTUnwrap(target.focusedTerminalPanel?.id)
        let source = fixture.manager.addWorkspace(title: "Servers", select: false)
        let sourcePane = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let first = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let second = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePane, focus: false)).id

        #expect(fixture.app.mergeWorkspace(source.id, into: target.id,
                                           destination: .split(targetPane: targetPane, orientation: .horizontal, insertFirst: false),
                                           focus: false, focusWindow: false))

        #expect(!fixture.manager.tabs.contains { $0.id == source.id })
        #expect(target.bonsplitController.allPaneIds.count == 2)
        let newPane = try XCTUnwrap(target.paneId(forPanelId: first))
        #expect(newPane != targetPane)
        #expect(target.paneId(forPanelId: second) == newPane)
        #expect(target.paneId(forPanelId: targetPanel) == targetPane)
        #expect([first, second].map { target.indexInPane(forPanelId: $0) } == [0, 1])
    }

    @Test
    func aWorkspaceNeverMergesIntoItself() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let workspace = try XCTUnwrap(fixture.manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelCount = workspace.panels.count

        #expect(!fixture.app.canMergeWorkspace(workspace.id, into: workspace.id))
        #expect(!fixture.app.mergeWorkspace(workspace.id, into: workspace.id,
                                            destination: .insert(targetPane: pane, targetIndex: nil),
                                            focus: false, focusWindow: false))
        #expect(workspace.panels.count == panelCount)
        #expect(fixture.manager.tabs.map(\.id) == [workspace.id])
    }

    @Test
    func aRegisteredRowResolvesAsAWorkspaceMergeSource() {
        let workspaceId = UUID()
        let dragID = UUID()
        let resolver = PaneTransferSourceResolver(
            vaultSessionRegistry: { nil },
            tabTransferRegistry: { nil },
            filePreview: { _ in nil },
            surfaceResource: { _ in nil },
            surfaceIsLive: { _ in false },
            workspaceMerge: { $0 == dragID ? workspaceId : nil }
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WorkspaceMergeDropTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(resolver.registeredSource(id: dragID, pasteboard: pasteboard) == .workspaceMerge(workspaceId))
        #expect(resolver.registeredSource(id: UUID(), pasteboard: pasteboard) == nil)
    }

    /// Panes see the row's merge capability; sidebar destinations keep reading
    /// the same drag as a workspace reorder, never as a tab move.
    @Test
    func theSidebarKeepsReadingAWorkspaceRowAsAReorder() throws {
        let registry = TabDragTransferRegistry()
        let registration = try XCTUnwrap(
            WorkspaceMergeDragPayload(title: "Logs", tabCount: 2, dragID: UUID()).register(with: registry)
        )
        defer { registry.end(registration) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WorkspaceMergeDropTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(SidebarTabDragPayload(tabId: UUID(), sessionId: nil).pasteboardValue,
                       forType: DragOverlayRoutingPolicy.sidebarTabReorderType)
        for type in registration.pasteboardItem.types {
            if let value = registration.pasteboardItem.string(forType: type) { item.setString(value, forType: type) }
        }
        pasteboard.writeObjects([item])

        #expect(registry.resolve(from: pasteboard) != nil, "pane targets resolve the merge capability")
        #expect(BonsplitTabDragPayload.transfer(from: pasteboard, registry: registry) == nil,
                "sidebar targets read the reorder payload instead")
    }
}
