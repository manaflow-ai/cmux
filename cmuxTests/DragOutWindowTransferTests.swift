import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Drag-out live ownership", .serialized)
struct DragOutWindowTransferTests {
    private final class RejectTabCreation: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool { false }
    }

    @Test func failedAttachRestoresSamePanelInOriginalSplit() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let source = try #require(manager.selectedWorkspace)
        let firstPane = try #require(source.bonsplitController.allPaneIds.first)
        let moved = try #require(source.splitPaneWithNewTerminal(
            targetPane: firstPane, orientation: .horizontal, insertFirst: false,
            workingDirectory: nil, initialInput: nil
        ))
        let originalPane = try #require(source.paneId(forPanelId: moved.id))
        let originalIndex = source.indexInPane(forPanelId: moved.id)
        let originalPanes = source.bonsplitController.allPaneIds
        let originalFocus = source.focusedPanelId
        let destination = manager.addWorkspace(title: "Reject destination", select: false)
        let rejectingDelegate = RejectTabCreation()
        destination.bonsplitController.delegate = rejectingDelegate
        defer { destination.bonsplitController.delegate = destination }

        #expect(!app.moveSurface(panelId: moved.id, toWorkspace: destination.id,
                                 focus: false, focusWindow: false, preserveSourcePaneOnFailure: true))
        #expect(source.panels[moved.id] as? TerminalPanel === moved)
        #expect(source.paneId(forPanelId: moved.id) == originalPane)
        #expect(source.indexInPane(forPanelId: moved.id) == originalIndex)
        #expect(source.bonsplitController.allPaneIds == originalPanes)
        #expect(source.focusedPanelId == originalFocus)
        #expect(destination.panels[moved.id] == nil)
    }

    @Test func newWindowKeepsTheTerminalSurfaceAndRemovesBootstrap() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try #require(AppDelegate.shared)
            let sourceWindowId = app.createMainWindow(shouldActivate: false)
            defer { app.discardMainWindowWithoutClosedHistory(windowId: sourceWindowId) }
            let manager = try #require(app.tabManagerFor(windowId: sourceWindowId))
            let workspace = manager.addWorkspace(title: "Move live terminal", select: false, autoWelcomeIfNeeded: false)
            let panel = try #require(workspace.focusedTerminalPanel)
            let surface = panel.surface
            let newWindowId = try #require(app.moveSurfaceToNewWindow(panelId: panel.id))
            defer { app.discardMainWindowWithoutClosedHistory(windowId: newWindowId) }
            let target = try #require(app.tabManagerFor(windowId: newWindowId)?.selectedWorkspace)
            #expect(target.panels.count == 1, "panels=\(target.panels.map { "\($0.key.uuidString.prefix(4)):\(type(of: $0.value))" }) moved=\(panel.id.uuidString.prefix(4))")
            #expect(target.panels[panel.id] as? TerminalPanel === panel)
            #expect(panel.surface === surface)
            #expect(!manager.tabs.contains(where: { $0.id == workspace.id }))
            #expect(target.focusedPanelId == panel.id)
        }
    }

    @Test func newWindowKeepsBrowserWebViewObject() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try #require(AppDelegate.shared)
            let sourceWindowId = app.createMainWindow(shouldActivate: false)
            defer { app.discardMainWindowWithoutClosedHistory(windowId: sourceWindowId) }
            let source = try #require(app.tabManagerFor(windowId: sourceWindowId)?.selectedWorkspace)
            let pane = try #require(source.bonsplitController.allPaneIds.first)
            let browser = try #require(source.newBrowserSurface(inPane: pane, url: URL(string: "about:blank"), focus: false))
            let webView = browser.webView
            let newWindowId = try #require(app.moveSurfaceToNewWindow(panelId: browser.id))
            defer { app.discardMainWindowWithoutClosedHistory(windowId: newWindowId) }
            let target = try #require(app.tabManagerFor(windowId: newWindowId)?.selectedWorkspace)
            #expect(target.panels[browser.id] as? BrowserPanel === browser)
            #expect(browser.webView === webView)
            #expect(source.panels[browser.id] == nil)
            #expect(target.panels.count == 1, "panels=\(target.panels.map { "\($0.key.uuidString.prefix(4)):\(type(of: $0.value))" }) moved=\(browser.id.uuidString.prefix(4))")
        }
    }

    @Test func entireWorkspaceKeepsSplitAndPanelIdentity() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try #require(AppDelegate.shared)
            let sourceWindowId = app.createMainWindow(shouldActivate: false)
            defer { app.discardMainWindowWithoutClosedHistory(windowId: sourceWindowId) }
            let manager = try #require(app.tabManagerFor(windowId: sourceWindowId))
            let source = manager.addWorkspace(title: "Move complete layout", select: false, autoWelcomeIfNeeded: false)
            let pane = try #require(source.bonsplitController.allPaneIds.first)
            _ = try #require(source.splitPaneWithNewTerminal(targetPane: pane, orientation: .horizontal,
                                                            insertFirst: false, workingDirectory: nil, initialInput: nil))
            let panes = source.bonsplitController.allPaneIds
            let tabs = panes.map { source.bonsplitController.tabs(inPane: $0).map(\.id) }
            let panels = source.panels
            let focus = source.focusedPanelId
            let newWindowId = try #require(app.moveWorkspaceToNewWindow(workspaceId: source.id))
            defer { app.discardMainWindowWithoutClosedHistory(windowId: newWindowId) }
            let target = try #require(app.tabManagerFor(windowId: newWindowId)?.selectedWorkspace)
            #expect(target === source)
            #expect(target.bonsplitController.allPaneIds == panes)
            #expect(panes.map { target.bonsplitController.tabs(inPane: $0).map(\.id) } == tabs)
            #expect(target.focusedPanelId == focus)
            #expect(Set(target.panels.keys) == Set(panels.keys))
            for (id, original) in panels { #expect(target.panels[id] === original) }
            #expect(!manager.tabs.contains(where: { $0.id == source.id }))
        }
    }
}
