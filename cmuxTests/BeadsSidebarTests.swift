import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalControllerSocketSecurityTests {
    @Test func beadsSidebarUsesExistingRailWithoutCreatingPanes() throws {
        let defaults = UserDefaults.standard
        let keys = ["rightSidebar.mode", "fileExplorer.isVisible", "rightSidebar.tabs.hidden"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: "rightSidebar.tabs.hidden")
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let tabManager = TabManager()
        let state = FileExplorerState()
        let windowID = UUID()
        app.fileExplorerState = state
        app.registerMainWindowContextForTesting(
            windowId: windowID, tabManager: tabManager, fileExplorerState: state
        )
        defer { app.unregisterMainWindowContextForTesting(windowId: windowID) }
        state.mode = .files
        state.setVisible(false)
        let initialWorkspace = tabManager.selectedTabId
        let initialPanels = tabManager.tabs.map { Set($0.panels.keys) }

        let response = TerminalController.shared.handleSocketLine("right_sidebar set beads --no-focus")
        try #require(response == "OK", "Built-in Beads mode must be accepted: \(response)")
        #expect(state.isVisible)
        #expect(state.mode.rawValue == "beads")
        #expect(FileExplorerState().mode.rawValue == "beads", "Selection survives a new window")
        #expect(tabManager.selectedTabId == initialWorkspace)
        #expect(tabManager.tabs.map { Set($0.panels.keys) } == initialPanels)
        #expect(!state.mode.canOpenAsPane)
        #expect(RightSidebarMode.visibleModes().contains(state.mode))
        #expect(state.mode.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false))

        let palette = ContentView.commandPaletteRightSidebarModeCommandContributions()
        let command = try #require(palette.first { $0.commandId == "palette.showRightSidebarBeads" })
        #expect(command.enablement(CommandPaletteContextSnapshot()))
        #expect(command.when(CommandPaletteContextSnapshot()))

        for mode in ["find", "files", "beads"] {
            #expect(TerminalController.shared.handleSocketLine("right_sidebar set \(mode) --no-focus") == "OK")
            #expect(state.mode.rawValue == mode)
        }
        #expect(tabManager.tabs.map { Set($0.panels.keys) } == initialPanels)
    }
}
