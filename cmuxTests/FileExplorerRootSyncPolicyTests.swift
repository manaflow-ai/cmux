import AppKit
import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File explorer root sync policy")
struct FileExplorerRootSyncPolicyTests {
    @Test("Hidden right sidebar keeps file explorer root lazy")
    func hiddenRightSidebarKeepsFileExplorerRootLazy() {
        for mode in RightSidebarMode.allCases {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: false,
                    mode: mode
                ) == false
            )
        }
    }

    @Test("Visible Files and Find may sync file explorer root")
    func visibleFileModesMaySyncFileExplorerRoot() {
        for mode in [RightSidebarMode.files, .find] {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                )
            )
        }
    }

    @Test("Visible non-file modes keep file explorer root lazy")
    func visibleNonFileModesKeepFileExplorerRootLazy() {
        let fileModes = Set([RightSidebarMode.files, .find])
        for mode in RightSidebarMode.allCases.filter({ !fileModes.contains($0) }) {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                ) == false
            )
        }
    }
}

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

@MainActor
@Suite("Right sidebar keyboard navigation")
struct RightSidebarKeyboardNavigationTests {
    @Test("Return and keypad Enter open the selected item")
    func returnAndKeypadEnterOpenSelection() throws {
        for keyCode in [UInt16(36), UInt16(76)] {
            let event = try #require(Self.keyEvent(keyCode: keyCode, modifierFlags: []))
            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        }
    }

    @Test("Command Down opens the selected item")
    func commandDownOpensSelection() throws {
        let event = try #require(Self.keyEvent(keyCode: 125, modifierFlags: [.command]))
        #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    @Test("Plain Down, Shift Return, and Command Return keep their existing routes")
    func nonActivationKeysDoNotOpenSelection() throws {
        let plainDown = try #require(Self.keyEvent(keyCode: 125, modifierFlags: []))
        let shiftReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.shift]))
        let commandReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.command]))

        #expect(!plainDown.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!shiftReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!commandReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    private static func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
