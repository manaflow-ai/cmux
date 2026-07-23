import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette explicit navigation outcomes")
struct CommandPaletteExplicitNavigationOutcomeTests {
    @Test
    func `Workspace navigation requires a live peer and starts from an explicit workspace`() {
        let manager = TabManager()
        let first = manager.tabs[0]

        #expect(!manager.selectNextTab(from: first.id))
        #expect(!manager.selectPreviousTab(from: UUID()))

        let second = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        #expect(manager.selectedTabId == first.id)

        #expect(manager.selectNextTab(from: first.id))
        #expect(manager.selectedTabId == second.id)
        #expect(manager.selectPreviousTab(from: second.id))
        #expect(manager.selectedTabId == first.id)
    }

    @Test
    func `Relative workspace reorder reports only authoritative order changes`() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, eagerLoadTerminal: false)

        #expect(!manager.reorderWorkspace(tabId: first.id, by: -1))
        #expect(manager.reorderWorkspace(tabId: first.id, by: 1))
        #expect(manager.tabs.map(\.id) == [second.id, first.id])

        #expect(manager.moveWorkspaceToTop(tabId: first.id))
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        #expect(!manager.moveWorkspaceToTop(tabId: first.id))
    }

    @Test
    func `Pane navigation reports unavailable without a peer tab`() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelID = try #require(workspace.focusedPanelId)

        #expect(!workspace.canSelectAdjacentSurface(fromPanelId: firstPanelID))
        #expect(!manager.selectNextSurface(
            tabId: workspace.id,
            fromPanelId: firstPanelID
        ))

        let secondPanel = try #require(
            workspace.newTerminalSurfaceInFocusedPane(focus: false)
        )
        #expect(workspace.canSelectAdjacentSurface(fromPanelId: firstPanelID))
        #expect(manager.selectNextSurface(
            tabId: workspace.id,
            fromPanelId: firstPanelID
        ))
        #expect(workspace.focusedPanelId == secondPanel.id)
    }
}
