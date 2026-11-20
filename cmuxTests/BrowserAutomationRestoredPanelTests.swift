import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Browser socket commands on a browser surface that session restore left as
/// a lightweight placeholder (never selected since relaunch).
@MainActor
@Suite(.serialized)
struct BrowserAutomationRestoredPanelTests {
    @Test
    func automationResolvesRestoredBrowserWithoutSelectingIt() throws {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let sourceBrowser = try #require(source.newBrowserSurface(
            inPane: sourcePane,
            url: URL(string: "about:blank"),
            focus: false
        ))
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let remap = workspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let restoredPanelID = try #require(remap[sourceBrowser.id])
        #expect(workspace.panels[restoredPanelID] is DeferredBrowserPanel)
        let focusedBefore = workspace.focusedPanelId

        let resolved = TerminalController.shared.v2ResolveBrowserPanelContext(
            params: ["workspace_id": workspace.id.uuidString, "surface_id": restoredPanelID.uuidString],
            tabManager: manager
        )

        // `cmux tree` reports the surface as a browser, so browser commands
        // must accept it: the placeholder becomes the live browser in place.
        #expect(resolved.error == nil)
        #expect(resolved.context?.surfaceId == restoredPanelID)
        #expect(workspace.panels[restoredPanelID] is BrowserPanel)
        // Automation never moves focus or selection (socket focus policy).
        #expect(workspace.focusedPanelId == focusedBefore)
    }

    @Test
    func soleBrowserFallbackFindsARestoredBrowser() throws {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let sourceBrowser = try #require(source.newBrowserSurface(
            inPane: sourcePane,
            url: URL(string: "about:blank"),
            focus: false
        ))
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let remap = workspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let restoredPanelID = try #require(remap[sourceBrowser.id])
        #expect(workspace.panels[restoredPanelID] is DeferredBrowserPanel)
        #expect(workspace.panels.values.filter { $0 is BrowserPanel }.isEmpty)
        #expect(workspace.focusedPanelId != restoredPanelID)

        // No surface named and a terminal focused: the workspace's only browser
        // is the restored one, so the command targets it.
        let resolved = TerminalController.shared.v2ResolveBrowserPanelContext(
            params: ["workspace_id": workspace.id.uuidString],
            tabManager: manager,
            allowSoleBrowserFallback: true
        )
        #expect(resolved.error == nil)
        #expect(resolved.context?.surfaceId == restoredPanelID)
    }
}
