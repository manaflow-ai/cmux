import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace explicit terminal sources")
struct WorkspaceExplicitTerminalSourceTests {
    @Test
    func resolvedWorkingDirectoryUsesExplicitPanelWithoutChangingFocus() throws {
        let focusedCwd = "/tmp/cmux-focused-cwd-\(UUID().uuidString)"
        let targetCwd = "/tmp/cmux-target-cwd-\(UUID().uuidString)"
        let manager = TabManager(
            initialWorkingDirectory: focusedCwd,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: focusedPanelID))
        let targetPanel = try #require(workspace.newTerminalSurface(
            inPane: paneID,
            focus: false,
            workingDirectory: targetCwd
        ))

        #expect(workspace.focusedPanelId == focusedPanelID)
        #expect(workspace.resolvedWorkingDirectory(panelID: targetPanel.id) == targetCwd)
        #expect(workspace.resolvedWorkingDirectory() == focusedCwd)
        #expect(workspace.resolvedWorkingDirectory(panelID: UUID()) == nil)
        #expect(workspace.focusedPanelId == focusedPanelID)
    }

    @Test
    func newTerminalSurfaceRejectsStaleExplicitSourcePanel() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let originalPanelIDs = Set(workspace.panels.keys)

        let outcome = workspace.newTerminalSurfaceOutcome(
            inPane: paneID,
            focus: false,
            workingDirectoryFallbackSourcePanelId: UUID()
        )

        #expect(outcome.panel == nil)
        #expect(Set(workspace.panels.keys) == originalPanelIDs)
    }
}
