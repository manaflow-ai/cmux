import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal command palette action preconditions")
struct CommandPaletteTerminalActionPreconditionTests {
    @Test func findActionsRejectMissingSearchAndSelection() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)

        #expect(!manager.findNext(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.findPrevious(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.hideFind(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.searchSelection(workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.terminalPanel(for: panelID)?.searchState == nil)
    }
}
