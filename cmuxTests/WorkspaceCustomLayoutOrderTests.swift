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
        let names = ["Shell", "Docs", "Logs"]
        let surfaces = [
            CmuxSurfaceDefinition(type: .terminal, name: names[0], focus: focusedIndex == 0),
            CmuxSurfaceDefinition(
                type: .browser,
                name: names[1],
                url: "https://example.com",
                focus: focusedIndex == 1
            ),
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

    private static func surfaceSnapshot(in workspace: Workspace) throws -> (titles: [String], selectedTitle: String?) {
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let titles = workspace.bonsplitController.tabs(inPane: paneId).map(\.title)
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: paneId)?.title
        return (titles, selectedTitle)
    }
}
