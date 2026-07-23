import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Right sidebar exact target binding")
struct RightSidebarExactTargetBindingTests {
    @Test("Right sidebar actions declare optional Boolean focus")
    func rightSidebarActionsDeclareFocusArgument() {
        let expectedArguments = [
            CmuxActionArgumentDefinition(
                name: "focus",
                valueType: .boolean,
                required: false
            )
        ]
        let modeContributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
        let paneContributions = ContentView.commandPaletteRightSidebarToolPaneCommandContributions()

        #expect(!modeContributions.isEmpty)
        #expect(!paneContributions.isEmpty)
        #expect(modeContributions.allSatisfy { $0.arguments == expectedArguments })
        #expect(paneContributions.allSatisfy { $0.arguments == expectedArguments })
    }

    @Test("Right sidebar focus is explicit and automation defaults to focused")
    func rightSidebarFocusPolicyIsDeterministic() {
        #expect(ContentView.commandPaletteRightSidebarShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            targetIsSelected: true
        ) == false)
        #expect(ContentView.commandPaletteRightSidebarShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteRightSidebarShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteRightSidebarShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetIsSelected: false
        ) == false)
    }

    @Test("Explicit background binding resolves without changing workspace selection")
    func explicitBackgroundBindingPreservesSelection() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(manager.selectedWorkspace)
        let backgroundWorkspace = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let backgroundPanelID = try #require(backgroundWorkspace.focusedPanelId)
        let state = FileExplorerState()

        state.bindRightSidebarContent(
            workspaceID: backgroundWorkspace.id,
            panelID: backgroundPanelID
        )
        let target = manager.rightSidebarContentTarget(
            explicitWorkspaceID: state.rightSidebarContentWorkspaceID,
            explicitPanelID: state.rightSidebarContentPanelID
        )

        #expect(target?.workspace === backgroundWorkspace)
        #expect(target?.panelID == backgroundPanelID)
        #expect(manager.selectedWorkspace === selectedWorkspace)
    }

    @Test("Stale explicit targets fail closed instead of falling back to selection")
    func staleExplicitTargetsFailClosed() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(manager.selectedWorkspace)

        #expect(manager.rightSidebarContentTarget(
            explicitWorkspaceID: UUID(),
            explicitPanelID: nil
        ).map { _ in false } ?? true)
        #expect(manager.rightSidebarContentTarget(
            explicitWorkspaceID: selectedWorkspace.id,
            explicitPanelID: UUID()
        ).map { _ in false } ?? true)
        #expect(manager.rightSidebarContentTarget(
            explicitWorkspaceID: nil,
            explicitPanelID: UUID()
        ).map { _ in false } ?? true)
    }

    @Test("Clearing automation binding restores selected-workspace behavior")
    func clearingBindingRestoresSelectionBehavior() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(manager.selectedWorkspace)
        let backgroundWorkspace = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let state = FileExplorerState()
        state.bindRightSidebarContent(
            workspaceID: backgroundWorkspace.id,
            panelID: backgroundWorkspace.focusedPanelId
        )

        state.clearRightSidebarContentBinding()
        let target = manager.rightSidebarContentTarget(
            explicitWorkspaceID: state.rightSidebarContentWorkspaceID,
            explicitPanelID: state.rightSidebarContentPanelID
        )

        #expect(target?.workspace === selectedWorkspace)
        #expect(target?.panelID == nil)
    }

    @Test("Tool pane root uses the explicit source panel instead of workspace focus")
    func toolPaneRootUsesExplicitSourcePanel() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-right-sidebar-target-\(UUID().uuidString)", isDirectory: true)
        let focusedDirectory = fixtureRoot.appendingPathComponent("focused", isDirectory: true)
        let targetDirectory = fixtureRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: focusedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let manager = TabManager(
            initialWorkingDirectory: focusedDirectory.path,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: focusedPanelID))
        let targetPanel = try #require(workspace.newTerminalSurface(
            inPane: paneID,
            focus: false,
            workingDirectory: targetDirectory.path
        ))

        let toolPanel = try #require(workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneID,
            mode: .files,
            focus: false,
            sourcePanelID: targetPanel.id
        ))

        #expect(toolPanel.fileExplorerStore.rootPath == targetDirectory.path)
        #expect(workspace.focusedPanelId == focusedPanelID)

        toolPanel.bindWorkspaceRoot(toSourcePanelID: UUID())
        #expect(toolPanel.fileExplorerStore.rootPath.isEmpty)
        #expect(workspace.focusedPanelId == focusedPanelID)

        let reboundPanel = workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneID,
            mode: .files,
            focus: false,
            sourcePanelID: nil
        )
        #expect(reboundPanel === toolPanel)
        #expect(toolPanel.fileExplorerStore.rootPath == focusedDirectory.path)
        #expect(workspace.focusedPanelId == focusedPanelID)
    }
}
