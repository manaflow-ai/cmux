import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette config action mapping")
struct CommandPaletteConfigActionMappingTests {
    private func configAction(
        id: String,
        action: CmuxSurfaceTabBarButtonAction = .command("echo test"),
        target: CmuxConfigTerminalCommandTarget? = nil,
        sourcePath: String = "/tmp/cmux.json"
    ) -> CmuxResolvedConfigAction {
        CmuxResolvedConfigAction(
            id: id,
            title: id,
            subtitle: nil,
            keywords: [],
            palette: true,
            shortcut: nil,
            icon: nil,
            tooltip: nil,
            action: action,
            confirm: nil,
            terminalCommandTarget: target,
            actionSourcePath: sourcePath,
            iconSourcePath: nil,
            newWorkspaceMenu: nil
        )
    }

    @Test func builtInActionsMapToTheirExistingPaletteEntries() {
        let expectedMappings: [(String, CmuxSurfaceTabBarBuiltInAction)] = [
            ("palette.newWorkspace", .newWorkspace),
            (ContentView.commandPaletteCloudOpenCommandId, .cloudVM),
            ("palette.mobileConnect", .mobileConnect),
            ("palette.newTerminalTab", .newTerminal),
            ("palette.newBrowserTab", .newBrowser),
            ("palette.newAgentChat", .newAgentChat),
            ("palette.terminalSplitRight", .splitRight),
            ("palette.terminalSplitDown", .splitDown),
        ]

        for (commandID, builtInAction) in expectedMappings {
            #expect(
                ContentView.commandPaletteBuiltInConfigActionID(for: commandID)
                    == builtInAction.configID
            )
        }
    }

    @Test func unrelatedPaletteEntryHasNoBuiltInConfigMapping() {
        #expect(ContentView.commandPaletteBuiltInConfigActionID(for: "palette.openSettings") == nil)
    }

    @Test func configuredBuiltInFocusArgumentIsOptionalAndAutomationDefaultsTrue() {
        #expect(ContentView.commandPaletteOptionalFocusArguments == [
            CmuxActionArgumentDefinition(
                name: "focus",
                valueType: .boolean,
                required: false
            )
        ])
        #expect(
            ContentView.commandPaletteResolvedFocus(explicit: nil, source: .automation)
                == true
        )
        #expect(
            ContentView.commandPaletteResolvedFocus(explicit: nil, source: .commandPalette)
                == nil
        )
        #expect(
            ContentView.commandPaletteResolvedFocus(explicit: false, source: .automation)
                == false
        )
        #expect(
            ContentView.commandPaletteResolvedFocus(explicit: true, source: .commandPalette)
                == true
        )
    }

    @Test func configuredActionTargetRequirementsAreDerivedFromActionType() {
        #expect(
            configAction(
                id: "terminal.current",
                target: .currentTerminal
            ).paletteTargetRequirement == .terminalPanel
        )
        #expect(
            configAction(id: "terminal.newTab").paletteTargetRequirement == .panelInPane
        )
        #expect(
            configAction(
                id: "workspace",
                action: .workspace(CmuxWorkspaceDefinition(), restart: nil)
            ).paletteTargetRequirement == .workspace
        )
        #expect(
            configAction(
                id: "window",
                action: .builtIn(.newAgentChat)
            ).paletteTargetRequirement == .window
        )
    }

    @Test func newTabVisibilityRequiresFocusedPanelInLivePane() {
        var context = CommandPaletteContextSnapshot()
        #expect(!ContentView.commandPalettePanelInPaneIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(!ContentView.commandPalettePanelInPaneIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, false)
        context.setBool(CommandPaletteContextKeys.panelHasPane, true)
        #expect(!ContentView.commandPalettePanelInPaneIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(ContentView.commandPalettePanelInPaneIsAvailable(context))
    }

    @Test func configCompositionFiltersOnlyExactLiveIDCollisions() {
        let exactCollision = configAction(
            id: "palette.openSettings",
            sourcePath: "/project-a/.cmux/cmux.json"
        )
        let nonCollision = configAction(
            id: "palette.openSettings.extra",
            sourcePath: "/project-b/.cmux/cmux.json"
        )
        let catalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [exactCollision, nonCollision],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )

        let composition = catalog.composingPaletteActions(
            reservedActionIDs: ["palette.openSettings"],
            diagnosticActionID: { "diagnostic.\($0.id)" }
        )

        #expect(composition.actions.map(\.id) == ["palette.openSettings.extra"])
        #expect(composition.issues.count == 1)
        #expect(composition.issues.first?.kind == .paletteActionIDCollision)
        #expect(composition.issues.first?.commandName == "palette.openSettings")
        #expect(composition.issues.first?.sourcePath == "/project-a/.cmux/cmux.json")
    }
}
