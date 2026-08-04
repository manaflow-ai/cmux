import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCustomLayoutOrderTests {
    @Test(arguments: [0, 1, 2, 3])
    func allTerminalSurfacesPreserveDeclaredOrder(focusedIndex: Int) throws {
        let names = ["AAA", "BBB", "CCC", "DDD"]
        let surfaces = names.enumerated().map { index, name in
            CmuxSurfaceDefinition(type: .terminal, name: name, focus: index == focusedIndex)
        }

        let workspace = Workspace()
        workspace.applyCustomLayout(
            .pane(CmuxPaneDefinition(surfaces: surfaces)),
            baseCwd: NSTemporaryDirectory()
        )

        let snapshot = try Self.surfaceSnapshot(in: workspace)
        #expect(snapshot.titles == names)
        #expect(snapshot.selectedTitle == names[focusedIndex])
    }

    @Test(arguments: [0, 1, 2])
    func mixedTerminalAndBrowserSurfacesPreserveDeclaredOrder(focusedIndex: Int) throws {
        let names = ["Docs", "Shell", "Logs"]
        let surfaces = [
            CmuxSurfaceDefinition(
                type: .browser,
                name: names[0],
                url: nil,
                focus: focusedIndex == 0
            ),
            CmuxSurfaceDefinition(type: .terminal, name: names[1], focus: focusedIndex == 1),
            CmuxSurfaceDefinition(type: .terminal, name: names[2], focus: focusedIndex == 2),
        ]

        let workspace = Workspace()
        workspace.applyCustomLayout(
            .pane(CmuxPaneDefinition(surfaces: surfaces)),
            baseCwd: NSTemporaryDirectory()
        )

        let snapshot = try Self.surfaceSnapshot(in: workspace)
        #expect(snapshot.titles == names)
        #expect(snapshot.selectedTitle == names[focusedIndex])
    }

    @Test(arguments: [NewTabPosition.current, .end])
    func layoutApplicationRestoresInteractiveNewTabPlacement(initialPlacement: NewTabPosition) throws {
        let workspace = Workspace()
        workspace.bonsplitController.configuration.newTabPosition = initialPlacement
        workspace.applyCustomLayout(
            .pane(CmuxPaneDefinition(surfaces: [
                CmuxSurfaceDefinition(type: .terminal, name: "AAA"),
                CmuxSurfaceDefinition(type: .terminal, name: "BBB", focus: true),
                CmuxSurfaceDefinition(type: .terminal, name: "CCC"),
            ])),
            baseCwd: NSTemporaryDirectory()
        )

        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let layoutTabIds = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        try #require(layoutTabIds.count == 3)

        switch (initialPlacement, workspace.bonsplitController.configuration.newTabPosition) {
        case (.current, .current), (.end, .end):
            break
        default:
            Issue.record("Layout application did not restore the initial new-tab placement")
        }

        let newPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let newTabId = try #require(workspace.surfaceIdFromPanelId(newPanel.id))
        let expectedTabIds: [TabID]
        switch initialPlacement {
        case .current:
            expectedTabIds = [layoutTabIds[0], layoutTabIds[1], newTabId, layoutTabIds[2]]
        case .end:
            expectedTabIds = [layoutTabIds[0], layoutTabIds[1], layoutTabIds[2], newTabId]
        }

        #expect(workspace.bonsplitController.tabs(inPane: paneId).map(\.id) == expectedTabIds)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == layoutTabIds[1])
    }

    @Test func capturedLayoutRestoresSelectedTabInBackgroundPane() throws {
        let original = Workspace()
        original.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Background A"),
                        CmuxSurfaceDefinition(type: .terminal, name: "Background B"),
                    ])),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Focused"),
                    ])),
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        guard case .split(let originalRoot) = original.bonsplitController.treeSnapshot(),
              case .pane(let originalBackground) = originalRoot.first,
              case .pane(let originalFocused) = originalRoot.second,
              let originalBackgroundID = UUID(uuidString: originalBackground.id),
              let originalFocusedID = UUID(uuidString: originalFocused.id) else {
            Issue.record("Expected a two-pane workspace")
            return
        }

        let originalBackgroundPane = PaneID(id: originalBackgroundID)
        let originalFocusedPane = PaneID(id: originalFocusedID)
        let originalBackgroundTabs = original.bonsplitController.tabs(inPane: originalBackgroundPane)
        let originalFocusedTab = try #require(original.bonsplitController.tabs(inPane: originalFocusedPane).first)
        try #require(originalBackgroundTabs.count == 2)

        original.bonsplitController.selectTab(originalBackgroundTabs[1].id)
        let originalFocusedPanelID = try #require(original.panelIdFromSurfaceId(originalFocusedTab.id))
        original.focusPanel(originalFocusedPanelID)

        #expect(original.bonsplitController.focusedPaneId == originalFocusedPane)
        #expect(original.bonsplitController.selectedTab(inPane: originalBackgroundPane)?.title == "Background B")

        let capturedLayout = try #require(original.captureLayoutDefinition().workspace.layout)
        let restored = Workspace()
        restored.applyCustomLayout(capturedLayout, baseCwd: NSTemporaryDirectory())

        guard case .split(let restoredRoot) = restored.bonsplitController.treeSnapshot(),
              case .pane(let restoredBackground) = restoredRoot.first,
              let restoredBackgroundID = UUID(uuidString: restoredBackground.id) else {
            Issue.record("Expected the captured two-pane workspace to restore")
            return
        }

        let restoredBackgroundPane = PaneID(id: restoredBackgroundID)
        #expect(restored.bonsplitController.selectedTab(inPane: restoredBackgroundPane)?.title == "Background B")
    }

    private static func surfaceSnapshot(in workspace: Workspace) throws -> (titles: [String], selectedTitle: String?) {
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let titles = workspace.bonsplitController.tabs(inPane: paneId).map(\.title)
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: paneId)?.title
        return (titles, selectedTitle)
    }
}
