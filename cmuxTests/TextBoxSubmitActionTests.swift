import AppKit
import Carbon.HIToolbox
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    #expect(lhs == rhs)
}

private func XCTAssertTrue(_ condition: Bool) {
    #expect(condition)
}

private func XCTAssertFalse(_ condition: Bool) {
    #expect(!condition)
}

private func XCTFail(_ message: String) {
    Issue.record(Comment(rawValue: message))
}

@Suite(.serialized)
@MainActor
struct TextBoxSubmitActionTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func testSettingsFileStoreAppliesTextBoxSubmitActionSettings() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            KeyboardShortcutSettings.resetAll()
        }

        let defaults = UserDefaults.standard
        let actionsKey = TerminalTextBoxInputSettings.submitActionsKey
        let defaultActionKey = TerminalTextBoxInputSettings.defaultSubmitActionKey
        try preservingDefaults(keys: [actionsKey, defaultActionKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            defaults.removeObject(forKey: actionsKey)
            defaults.removeObject(forKey: defaultActionKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "textBoxDefaultSubmitAction": "custom-router",
                    "textBoxSubmitActions": [
                      {
                        "id": "custom-router",
                        "title": "Custom Router",
                        "kind": "commandTemplate",
                        "commandTemplate": "router --prompt {{prompt}}",
                        "systemImage": "wand.and.stars",
                        "imagePath": "/tmp/router.png",
                        "backgroundColorHex": "#123456"
                      }
                    ]
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: defaultActionKey), "custom-router")
            let actions = TerminalTextBoxInputSettings.submitActions(defaults: defaults)
            XCTAssertTrue(actions.contains { $0.id == "custom-router" })
            XCTAssertEqual(
                TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
                "custom-router"
            )
        }
    }


    @Test
    func testTextBoxSubmitActionQuotesPromptForCommandTemplate() {
        let action = TextBoxSubmitAction(
            id: "router",
            title: "Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt {{prompt}}",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )

        XCTAssertEqual(
            action.command(forPrompt: "ship user's fix"),
            "router --prompt 'ship user'\\''s fix'"
        )
        XCTAssertEqual(
            action.command(forPrompt: "line one\nline\t'two'"),
            "router --prompt 'line one\nline\t'\\''two'\\'''"
        )
    }

    @Test
    func testTextBoxSubmitActionRejectsPromptPlaceholderInsideShellQuotes() {
        let singleQuoted = TextBoxSubmitAction(
            id: "single-quoted-router",
            title: "Single Quoted Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt '{{prompt}}'",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )
        let doubleQuoted = TextBoxSubmitAction(
            id: "double-quoted-router",
            title: "Double Quoted Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt \"{{prompt}}\"",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )
        let unquotedEmbedded = TextBoxSubmitAction(
            id: "embedded-router",
            title: "Embedded Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt={{prompt}}",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )

        XCTAssertFalse(singleQuoted.isValid)
        XCTAssertFalse(doubleQuoted.isValid)
        XCTAssertEqual(singleQuoted.command(forPrompt: "hi; rm -rf /"), nil)
        XCTAssertEqual(doubleQuoted.command(forPrompt: "hi; rm -rf /"), nil)
        XCTAssertTrue(unquotedEmbedded.isValid)
        XCTAssertEqual(
            unquotedEmbedded.command(forPrompt: "hi; rm -rf /"),
            "router --prompt='hi; rm -rf /'"
        )
    }


    @Test
    func testBuiltInTextBoxSubmitActionsUseExpectedCommandModes() throws {
        let launchCommandsByID = Dictionary(
            uniqueKeysWithValues: TextBoxSubmitAction.builtInActions.compactMap { action in
                action.launchCommand().map { (action.id, $0) }
            }
        )

        let actionsByID = Dictionary(
            uniqueKeysWithValues: TextBoxSubmitAction.builtInActions.map { ($0.id, $0) }
        )
        let prompt = "ship user's fix\nwith\ttabs"
        let quotedPrompt = "'ship user'\\''s fix\nwith\ttabs'"

        XCTAssertEqual(
            try #require(actionsByID["claude"]).command(forPrompt: prompt),
            "claude --dangerously-skip-permissions \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["codex"]).command(forPrompt: prompt),
            "codex --dangerously-bypass-approvals-and-sandbox \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["opencode"]).command(forPrompt: prompt),
            "opencode --prompt \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["pi"]).command(forPrompt: prompt),
            "pi \(quotedPrompt)"
        )
        XCTAssertTrue(launchCommandsByID.isEmpty)
    }

    @Test
    func testCommandTemplateSubmitPlanExposesAgentLaunchCommandForActiveSessionTracking() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let plan = TextBoxInputContainer.dispatchPlan(
            [.text("ship user's fix\nwith\ttabs")],
            applying: codex,
            shouldForceTextEntrySubmit: false,
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: nil
        )

        let expectedCommand = "codex --dangerously-bypass-approvals-and-sandbox 'ship user'\\''s fix\nwith\ttabs'"
        XCTAssertEqual(plan.launchCommand, expectedCommand)
        XCTAssertEqual(plan.launchContextCommand, "codex --dangerously-bypass-approvals-and-sandbox")
        XCTAssertEqual(plan.events, TextBoxSubmit.dispatchEvents(for: [.text(expectedCommand)], terminalAgentContext: ""))
    }

    @Test
    func testRecordedTextBoxLaunchContextDoesNotStoreSubmittedPrompt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let prompt = String(repeating: "large prompt ", count: 200)
        panel.recordTextBoxLaunchCommand("codex --dangerously-bypass-approvals-and-sandbox '\(prompt)'")

        XCTAssertEqual(panel.textBoxState.launchCommand, "codex")
        XCTAssertFalse(panel.textBoxState.launchCommand?.contains(prompt) ?? true)
        XCTAssertFalse(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
        panel.updateShellActivityState(.commandRunning)
        XCTAssertTrue(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
    }


    @Test
    func testProviderLaunchEventsKeepPromptInTextBoxUntilAgentIsActive() {
        XCTAssertEqual(
            TextBoxSubmit.launchDispatchEvents(launchCommand: "codex --dangerously-bypass-approvals-and-sandbox"),
            [
                .pasteText("codex --dangerously-bypass-approvals-and-sandbox"),
                .namedKey("return"),
            ]
        )
    }


    @Test
    func testDefaultTextBoxSubmitActionCatalogIncludesTextEntryEscapeHatch() {
        XCTAssertEqual(
            TerminalTextBoxInputSettings.submitActions(configuredJSON: nil).map(\.id),
            ["text-entry", "claude", "codex", "opencode", "pi"]
        )
    }

    @Test
    func testDefaultTextBoxSubmitActionIsPlainTextEntry() {
        XCTAssertEqual(
            TerminalTextBoxInputSettings.defaultSubmitActionID,
            TextBoxSubmitAction.textEntryAction.id
        )
    }

    @Test
    func testSubmitActionImageCacheKeyListIsBounded() {
        let keys = (0..<(TextBoxSubmitActionImageSupport.maximumCachedImageCount + 8)).map { index in
            "path:/tmp/custom-\(index).png"
        }

        XCTAssertEqual(
            Array(Set(keys))
                .sorted()
                .prefix(TextBoxSubmitActionImageSupport.maximumCachedImageCount)
                .count,
            TextBoxSubmitActionImageSupport.maximumCachedImageCount
        )
    }


    @Test
    func testCustomTextBoxSubmitActionCatalogKeepsTextEntrySelectable() throws {
        let customAction = TextBoxSubmitAction(
            id: "custom-router",
            title: "Custom Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt {{prompt}}",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )
        let data = try JSONEncoder().encode([customAction])
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(
            TerminalTextBoxInputSettings.submitActions(configuredJSON: json).map(\.id),
            ["text-entry", "claude", "codex", "opencode", "pi", "custom-router"]
        )
    }


    @Test
    func testTextBoxCustomDefaultFallsBackToTextEntryWhenConfiguredActionIsMissing() {
        let customAction = TextBoxSubmitAction(
            id: "custom-router",
            title: "Custom Router",
            kind: .commandTemplate,
            commandTemplate: "router --prompt {{prompt}}",
            systemImage: "wand.and.stars",
            backgroundColorHex: "#123456"
        )

        XCTAssertEqual(
            TextBoxInputContainer.selectedSubmitAction(
                defaultSubmitActionID: "custom-router",
                submitActions: TextBoxSubmitAction.builtInActions
            ).id,
            TextBoxSubmitAction.textEntryAction.id
        )
        XCTAssertEqual(
            TextBoxInputContainer.selectedSubmitAction(
                defaultSubmitActionID: "custom-router",
                submitActions: TextBoxSubmitAction.builtInActions + [customAction]
            ).id,
            "custom-router"
        )
    }


    @Test
    func testDefaultConfigTemplateIncludesTextBoxLaunchPromptFlag() {
        let template = CmuxSettingsFileStore.defaultTemplate()

        XCTAssertTrue(template.contains(#""commandTemplate" : "codex --dangerously-bypass-approvals-and-sandbox {{prompt}}""#))
        XCTAssertTrue(template.contains(#""commandTemplate" : "opencode --prompt {{prompt}}""#))
        XCTAssertTrue(template.contains(#""commandTemplate" : "pi {{prompt}}""#))
        XCTAssertFalse(template.contains(#""preservePromptAfterLaunch" : true"#))
    }


    @Test
    func testTextBoxForceTextEntryRequiresDetectedActiveAgent() {
        XCTAssertFalse(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: ""
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: "textBoxLaunchCommand:codex --dangerously-bypass-approvals-and-sandbox"
            )
        )
    }

    @Test
    func testTextBoxForceTextEntryDetectsAgentContextEdgeCases() {
        let contexts = [
            "restoredAgent:opencode",
            "agentPIDKey:omx.12345",
            "initialCommand:/bin/zsh -lc 'codex --dangerously-bypass-approvals-and-sandbox \"hi\"'",
            "tmuxStartCommand:env FOO=bar opencode --prompt 'line one\nline two'",
            "initialCommand:pi 'question with\ttab'",
            "initialCommand:claude --dangerously-skip-permissions 'question'"
        ]

        for context in contexts {
            #expect(
                TextBoxInputContainer.shouldForceTextEntrySubmit(
                    allowsCommandTemplateSubmit: false,
                    terminalAgentContext: context
                ),
                Comment(rawValue: context)
            )
        }
    }

    @Test
    func testTerminalAgentContextUsesStructuredTextBoxLaunchCommand() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.panelTitles[panel.id] = "user-controlled title"
        panel.recordTextBoxLaunchCommand("codex --dangerously-bypass-approvals-and-sandbox")

        let pendingContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertFalse(TextBoxAgentDetection.supportsAgentPrefixes(context: pendingContext))
        XCTAssertFalse(TextBoxAgentDetection.supportsActiveAgentPrefixes(context: pendingContext))

        panel.updateShellActivityState(.commandRunning)
        let runningContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertTrue(TextBoxAgentDetection.supportsAgentPrefixes(context: runningContext))
        XCTAssertTrue(TextBoxAgentDetection.supportsActiveAgentPrefixes(context: runningContext))
        XCTAssertTrue(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: runningContext
            )
        )
        XCTAssertEqual(
            TextBoxInputContainer.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: runningContext
            ),
            runningContext
        )
    }

    @Test
    func testTextBoxLaunchCommandContextExpiresAfterCommandReturnsToPrompt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        panel.recordTextBoxLaunchCommand("codex --dangerously-bypass-approvals-and-sandbox")
        panel.updateShellActivityState(.commandRunning)
        #expect(panel.textBoxState.launchCommand != nil)

        panel.updateShellActivityState(.promptIdle)
        #expect(panel.textBoxState.launchCommand == nil)
        XCTAssertFalse(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
    }

    @Test
    func testTextBoxLaunchCommandContextClearsOnPromptIdleBeforeRunning() throws {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.updateShellActivityState(.promptIdle)
        panel.recordTextBoxLaunchCommand("codex --dangerously-bypass-approvals-and-sandbox")
        #expect(panel.textBoxState.launchCommand != nil)

        panel.updateShellActivityState(.promptIdle)
        #expect(panel.textBoxState.launchCommand == nil)
    }


    @Test
    func testTextBoxTextEntryClearsStaleAgentContextWhenShellIsPromptIdle() {
        XCTAssertEqual(
            TextBoxInputContainer.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: "restoredAgent:claude"
            ),
            ""
        )
        XCTAssertEqual(
            TextBoxInputContainer.textEntryTerminalAgentContext(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: "restoredAgent:claude"
            ),
            "restoredAgent:claude"
        )
    }

    @Test
    func testActiveTextBoxLaunchContextWinsOverStaleRestoredAgent() {
        let context = """
        restoredAgent:claude
        textBoxLaunchCommand:codex
        """
        let activeContext = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: context
        )

        XCTAssertEqual(activeContext, "textBoxLaunchCommand:codex")
        XCTAssertFalse(TextBoxAgentDetection.isClaudeCode(context: activeContext))
    }

    @Test
    func testTextBoxPendingPromptFreeClaudeLaunchWaitsForActiveAgentContext() {
        let claude = TextBoxSubmitAction(
            id: "claude",
            title: "Claude",
            kind: .commandTemplate,
            commandTemplate: "claude --dangerously-skip-permissions",
            preservePromptAfterLaunch: true,
            systemImage: "sparkle",
            backgroundColorHex: "#F6D5C8"
        )
        XCTAssertTrue(
            TextBoxInputContainer.isPendingProviderLaunchAwaitingAgent(
                pendingProviderLaunchAction: claude,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.isPendingProviderLaunchAwaitingAgent(
                pendingProviderLaunchAction: claude,
                terminalAgentContext: "textBoxLaunchCommand:claude"
            )
        )
        let context = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: false,
            terminalAgentContext: "textBoxLaunchCommand:claude",
            pendingProviderLaunchAction: claude
        )

        XCTAssertTrue(TextBoxAgentDetection.isClaudeCode(context: context))
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("line one\nline two")],
                terminalAgentContext: context
            ).last,
            .namedKey("ctrl+enter")
        )
    }

    @Test
    func testTextBoxPendingLaunchUsesInitialCommandContext() {
        let launchOnlyCodex = TextBoxSubmitAction(
            id: "custom-codex-launch",
            title: "Custom Codex Launch",
            kind: .commandTemplate,
            commandTemplate: "codex --dangerously-bypass-approvals-and-sandbox",
            preservePromptAfterLaunch: true,
            systemImage: "sparkles",
            backgroundColorHex: "#8FDBFF"
        )
        let context = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: launchOnlyCodex
        )

        XCTAssertEqual(context, "initialCommand:codex --dangerously-bypass-approvals-and-sandbox")
        XCTAssertTrue(TextBoxAgentDetection.supportsAgentPrefixes(context: context))
    }

    @Test
    func testTextBoxPendingLaunchClearsOnAgentDetectionOrPromptIdleFallback() {
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: "initialCommand:codex --dangerously-bypass-approvals-and-sandbox"
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: ""
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearLaunchCommandWhenClearingPending(
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearLaunchCommandWhenClearingPending(
                terminalAgentContext: "textBoxLaunchCommand:codex"
            )
        )
    }


    @Test
    func testTextBoxDefaultSubmitActionAcceptsTextEntryEscapeHatch() {
        let defaults = UserDefaults.standard
        let defaultActionKey = TerminalTextBoxInputSettings.defaultSubmitActionKey
        preservingDefaults(keys: [defaultActionKey]) {
            defaults.set(TextBoxSubmitAction.textEntryAction.id, forKey: defaultActionKey)
            XCTAssertEqual(
                TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
                TextBoxSubmitAction.textEntryAction.id
            )
        }
    }


    @Test
    func testTextBoxMissingCustomDefaultSubmitActionFailsClosedToTextEntry() {
        let defaults = UserDefaults.standard
        let defaultActionKey = TerminalTextBoxInputSettings.defaultSubmitActionKey
        let actionsKey = TerminalTextBoxInputSettings.submitActionsKey
        preservingDefaults(keys: [defaultActionKey, actionsKey]) {
            defaults.set("missing-router", forKey: defaultActionKey)
            defaults.set("[]", forKey: actionsKey)

            XCTAssertEqual(
                TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
                TextBoxSubmitAction.textEntryAction.id
            )
        }
    }


    @Test
    func testTextBoxShiftTabCyclesSubmitAction() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var cycleCount = 0
        textView.onCycleSubmitAction = {
            cycleCount += 1
        }

        guard let shiftTabEvent = makeKeyDownEvent(key: "\t", modifiers: .shift, keyCode: UInt16(kVK_Tab)) else {
            XCTFail("Failed to construct Shift-Tab event")
            return
        }

        textView.keyDown(with: shiftTabEvent)

        XCTAssertEqual(cycleCount, 1)
        XCTAssertEqual(textView.string, "")
    }

    @Test
    func testForcedTextEntryPresentationShowsTextEntryInsteadOfProviderLogo() {
        let selectedAction = TextBoxSubmitAction.builtInActions[0]

        let presentation = TextBoxInputContainer.submitActionPresentation(
            selectedSubmitAction: selectedAction,
            shouldForceTextEntrySubmit: true
        )

        XCTAssertEqual(presentation.action.id, TextBoxSubmitAction.textEntryAction.id)
        XCTAssertTrue(presentation.isForcedTextEntry)
        XCTAssertEqual(presentation.label, "Text Entry")
        XCTAssertTrue(presentation.helpText.contains("Shift-Tab is disabled"))
    }

    @Test
    func testForcedTextEntryPreventsShiftTabCycling() {
        let actions = TextBoxSubmitAction.builtInActions

        #expect(
            TextBoxInputContainer.nextCycledSubmitActionID(
                defaultSubmitActionID: actions[0].id,
                submitActions: actions,
                shouldForceTextEntrySubmit: true
            ) == nil
        )
        XCTAssertEqual(
            TextBoxInputContainer.nextCycledSubmitActionID(
                defaultSubmitActionID: actions[0].id,
                submitActions: actions,
                shouldForceTextEntrySubmit: false
            ),
            actions[1].id
        )
    }

    @Test
    func testUnknownNonIdleTerminalStillCyclesSubmitAction() {
        let actions = TextBoxSubmitAction.builtInActions
        let shouldForceTextEntry = TextBoxInputContainer.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: false,
            terminalAgentContext: ""
        )

        XCTAssertFalse(shouldForceTextEntry)
        XCTAssertEqual(
            TextBoxInputContainer.nextCycledSubmitActionID(
                defaultSubmitActionID: actions[0].id,
                submitActions: actions,
                shouldForceTextEntrySubmit: shouldForceTextEntry
            ),
            actions[1].id
        )
    }

    @Test
    func testCommandTemplateSubmitRequiresPromptIdleShellState() {
        #expect(TextBoxInputContainer.allowsCommandTemplateSubmit(shellActivityState: .promptIdle))
        #expect(!TextBoxInputContainer.allowsCommandTemplateSubmit(shellActivityState: .unknown))
        #expect(!TextBoxInputContainer.allowsCommandTemplateSubmit(shellActivityState: .commandRunning))
    }

    @Test
    func testUnknownShellStateFallsBackToTextEntryWithoutBlockingCycle() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let shouldForceTextEntry = TextBoxInputContainer.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: false,
            terminalAgentContext: ""
        )

        #expect(!shouldForceTextEntry)
        #expect(TextBoxInputContainer.shouldUseTextEntryFallbackForCommandTemplate(
            action: codex,
            shouldForceTextEntrySubmit: shouldForceTextEntry,
            allowsCommandTemplateSubmit: false
        ))
        #expect(!TextBoxInputContainer.shouldUseTextEntryFallbackForCommandTemplate(
            action: codex,
            shouldForceTextEntrySubmit: shouldForceTextEntry,
            allowsCommandTemplateSubmit: true
        ))
        XCTAssertEqual(
            TextBoxInputContainer.submitActionPresentation(
                selectedSubmitAction: codex,
                shouldForceTextEntrySubmit: shouldForceTextEntry
            ).action.id,
            codex.id
        )
        XCTAssertEqual(
            TextBoxInputContainer.dispatchPlan(
                [.text("ordinary shell input")],
                applying: codex,
                shouldForceTextEntrySubmit: shouldForceTextEntry,
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: "",
                pendingProviderLaunchAction: nil
            ).events,
            TextBoxSubmit.dispatchEvents(for: [.text("ordinary shell input")], terminalAgentContext: "")
        )
        XCTAssertEqual(
            TextBoxInputContainer.nextCycledSubmitActionID(
                defaultSubmitActionID: codex.id,
                submitActions: TextBoxSubmitAction.builtInActions,
                shouldForceTextEntrySubmit: shouldForceTextEntry
            ),
            "opencode"
        )
    }

    @Test
    func testDuplicateCommandRunningDoesNotRewriteTextBoxLaunchState() {
        let state = TerminalPanelTextBoxState()
        state.recordLaunchCommand("codex")

        state.updateShellActivityState(.commandRunning)
        XCTAssertEqual(state.activeLaunchCommand, "codex")

        state.updateShellActivityState(.commandRunning)
        XCTAssertEqual(state.activeLaunchCommand, "codex")
    }

    @Test
    func testTextBoxCycleSubmitActionUsesConfiguredShortcut() {
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .cycleTextBoxSubmitAction)
        defer {
            KeyboardShortcutSettings.setShortcut(originalShortcut, for: .cycleTextBoxSubmitAction)
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var cycleCount = 0
        textView.onCycleSubmitAction = {
            cycleCount += 1
        }

        KeyboardShortcutSettings.setShortcut(.unbound, for: .cycleTextBoxSubmitAction)
        guard let shiftTabEvent = makeKeyDownEvent(key: "\t", modifiers: .shift, keyCode: UInt16(kVK_Tab)) else {
            XCTFail("Failed to construct Shift-Tab event")
            return
        }
        textView.keyDown(with: shiftTabEvent)
        XCTAssertEqual(cycleCount, 0)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: true, option: false, control: false),
            for: .cycleTextBoxSubmitAction
        )
        guard let customEvent = makeKeyDownEvent(key: "J", modifiers: [.command, .shift], keyCode: UInt16(kVK_ANSI_J)) else {
            XCTFail("Failed to construct custom cycle event")
            return
        }
        textView.keyDown(with: customEvent)
        XCTAssertEqual(cycleCount, 1)
    }


    @Test
    func testTextBoxShiftTabDefersDuringIMEComposition() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var cycleCount = 0
        textView.onCycleSubmitAction = {
            cycleCount += 1
        }
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let shiftTabEvent = makeKeyDownEvent(key: "\t", modifiers: .shift, keyCode: UInt16(kVK_Tab)) else {
            XCTFail("Failed to construct Shift-Tab event")
            return
        }

        let handledByTextBoxShortcut = textView.debugHandleConfiguredTextBoxShortcutForTesting(shiftTabEvent)

        XCTAssertFalse(handledByTextBoxShortcut)
        XCTAssertEqual(cycleCount, 0)
        XCTAssertTrue(textView.hasMarkedText())
    }

    @Test
    func testFocusTextBoxOnNewTerminalsDefaultDoesNotFocusBackgroundOrAutomationTerminals() {
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        preservingDefaults(keys: [showKey, focusKey]) {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: showKey)
            defaults.set(true, forKey: focusKey)

            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId else {
                XCTFail("Expected initial terminal workspace")
                return
            }

            guard let backgroundPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
                XCTFail("Expected background terminal tab")
                return
            }

            XCTAssertTrue(backgroundPanel.isTextBoxActive)
            #expect(backgroundPanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))

            guard let automationPanel = workspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                allowTextBoxFocusDefault: false
            ) else {
                XCTFail("Expected automation terminal tab")
                return
            }

            XCTAssertTrue(automationPanel.isTextBoxActive)
            #expect(automationPanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))

            let automationWorkspace = manager.addWorkspace(
                select: true,
                allowTextBoxFocusDefault: false
            )
            guard let automationWorkspacePanel = automationWorkspace.focusedTerminalPanel else {
                XCTFail("Expected automation workspace terminal")
                return
            }

            XCTAssertTrue(automationWorkspacePanel.isTextBoxActive)
            #expect(automationWorkspacePanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))
        }
    }


    @Test
    func testTerminalPanelPublishesShellActivityStateForTextBoxRouting() {
        let panel = TerminalPanel(workspaceId: UUID())

        XCTAssertEqual(panel.shellActivity.state, .unknown)
        panel.updateShellActivityState(.promptIdle)
        XCTAssertEqual(panel.shellActivity.state, .promptIdle)
        panel.updateShellActivityState(.commandRunning)
        XCTAssertEqual(panel.shellActivity.state, .commandRunning)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-submit-action-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }
        try body()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
