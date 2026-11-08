import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct FullWidthTabCommandTests {
    @Test func toggleFocusedFullWidthTabTogglesFocusedPane() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))

        #expect(manager.toggleFocusedFullWidthTab())
        #expect(workspace.focusedPanelId == panelId)
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))

        #expect(manager.toggleFocusedFullWidthTab())
        #expect(workspace.focusedPanelId == panelId)
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneId))
    }
}
