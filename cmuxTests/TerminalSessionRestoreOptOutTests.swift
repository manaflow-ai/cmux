import Foundation
import CmuxCore
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalSessionRestoreOptOutTests {
    private let restoreTerminalSessionsKey = "terminal.restoreTerminalSessions"

    @Test
    func disablingTerminalRestoreSkipsTerminalWorkspaces() throws {
        let source = TabManager()
        let terminalWorkspace = try #require(source.selectedWorkspace)
        let browserWorkspace = source.addWorkspace(
            title: "Browser-only workspace",
            workingDirectory: "/tmp/cmux-browser-only",
            select: false
        )
        browserWorkspace.setCustomTitle("Browser-only workspace")
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let terminalWorkspaceId = try #require(snapshot.workspaces[0].workspaceId)
        var browserSnapshot = snapshot.workspaces[1]
        browserSnapshot.customTitle = browserWorkspace.customTitle
        browserSnapshot.currentDirectory = ""
        browserSnapshot.panels = []
        browserSnapshot.layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )
        browserSnapshot.focusedPanelId = nil
        browserSnapshot.dock = nil

        var filteredInput = snapshot
        filteredInput.workspaces = [snapshot.workspaces[0], browserSnapshot]
        filteredInput.selectedWorkspaceIndex = 1

        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: restoreTerminalSessionsKey)
        defaults.set(false, forKey: restoreTerminalSessionsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: restoreTerminalSessionsKey)
            } else {
                defaults.removeObject(forKey: restoreTerminalSessionsKey)
            }
        }

        let restored = TabManager()
        restored.restoreSessionSnapshot(filteredInput)

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs.first?.customTitle == "Browser-only workspace")
        #expect(!restored.tabs.contains { $0.id == terminalWorkspaceId })
        #expect(restored.tabs.first?.id != terminalWorkspace.id)
    }
}
