import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Canvas tab chrome must show the same title as the split tab bar, so a tab
/// renamed with Command-R (rename-tab) reads its custom name in canvas mode too.
@MainActor
@Suite("Canvas tab chrome title")
struct CanvasTabChromeTitleTests {
    @Test func renamedTerminalShowsCustomTitleAndRevertsWhenCleared() throws {
        let workspace = Workspace()
        defer { workspace.retireFromOwningTabManager() }
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let defaultTitle = try #require(workspace.panelTitle(panelId: panelId))

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Build Logs", propagateToCloud: false))
        #expect(
            WorkspaceCanvasHostView.tabChrome(panelId: panelId, panel: panel, workspace: workspace).title
                == "Build Logs"
        )

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil, propagateToCloud: false))
        #expect(
            WorkspaceCanvasHostView.tabChrome(panelId: panelId, panel: panel, workspace: workspace).title
                == defaultTitle
        )
    }

    @Test func renamedBrowserShowsCustomTitle() throws {
        let workspace = Workspace()
        defer { workspace.retireFromOwningTabManager() }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            // Offline fixture: only the tab title matters here.
            url: URL(string: "about:blank"),
            focus: false
        ))

        #expect(workspace.setPanelCustomTitle(panelId: browser.id, title: "Docs", propagateToCloud: false))
        #expect(
            WorkspaceCanvasHostView.tabChrome(panelId: browser.id, panel: browser, workspace: workspace).title
                == "Docs"
        )
    }
}
