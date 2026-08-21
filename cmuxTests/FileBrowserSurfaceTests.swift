import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileBrowserSurfaceTests {
    @Test
    func defaultSurfaceTabBarButtonsIncludeFileBrowserAsFifthButton() {
        #expect(
            CmuxSurfaceTabBarButton.defaults.map(\.id) == [
                "cmux.newTerminal",
                "cmux.newBrowser",
                "cmux.splitRight",
                "cmux.splitDown",
                "cmux.newFileBrowser"
            ]
        )
    }

    @Test
    func snapshotRoundTripsFileBrowserSourceAndToleratesLegacyPayload() throws {
        let sourcePanelID = UUID()
        let original = SessionRightSidebarToolPanelSnapshot(
            mode: .files,
            sourcePanelID: sourcePanelID,
            rootDirectory: "/tmp/project"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: data)
        #expect(decoded.mode == .files)
        #expect(decoded.sourcePanelID == sourcePanelID)
        #expect(decoded.rootDirectory == "/tmp/project")

        let legacyData = #"{"mode":"files"}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: legacyData)
        #expect(legacy.mode == .files)
        #expect(legacy.sourcePanelID == nil)
        #expect(legacy.rootDirectory == nil)
    }

    @Test
    func surfaceIsScopedToPaneAndReusesWithinPane() throws {
        let workspace = Workspace()
        let firstTerminalID = try #require(workspace.focusedPanelId)
        let firstPaneID = try #require(workspace.paneId(forPanelId: firstTerminalID))
        let secondTerminal = try #require(
            workspace.newTerminalSplit(from: firstTerminalID, orientation: .horizontal)
        )
        let secondPaneID = try #require(workspace.paneId(forPanelId: secondTerminal.id))
        workspace.panelDirectories[firstTerminalID] = "/tmp/first-pane"
        workspace.panelDirectories[secondTerminal.id] = "/tmp/second-pane"

        let firstBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: firstPaneID, focus: false)
        )
        let secondBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: secondPaneID, focus: false)
        )
        let reusedFirstBrowser = try #require(
            workspace.openOrFocusFileBrowserSurface(inPane: firstPaneID, focus: false)
        )

        #expect(firstBrowser.id != secondBrowser.id)
        #expect(firstBrowser.id == reusedFirstBrowser.id)
        #expect(firstBrowser.sourcePanelID == firstTerminalID)
        #expect(firstBrowser.rootDirectory == "/tmp/first-pane")
        #expect(secondBrowser.sourcePanelID == secondTerminal.id)
        #expect(secondBrowser.rootDirectory == "/tmp/second-pane")
        #expect(workspace.paneId(forPanelId: firstBrowser.id) == firstPaneID)
        #expect(workspace.paneId(forPanelId: secondBrowser.id) == secondPaneID)
        #expect(
            workspace.panels.values.compactMap { $0 as? RightSidebarToolPanel }
                .filter { $0.mode == .files }.count == 2
        )
    }
}
