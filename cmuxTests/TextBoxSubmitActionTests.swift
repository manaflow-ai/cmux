import AppKit
import Carbon.HIToolbox
import Darwin
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
    @Test
    func testTextBoxSubmitActionSettingsReadConfiguredDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("custom-router", forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey)
        defaults.set(
            """
            [
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
            """,
            forKey: TerminalTextBoxInputSettings.submitActionsKey
        )

        let actions = TerminalTextBoxInputSettings.submitActions(defaults: defaults)
        XCTAssertTrue(actions.contains { $0.id == "custom-router" })
        XCTAssertEqual(
            TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
            "custom-router"
        )
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
        let prompt = "--help\nship user's fix\nwith\ttabs"
        let quotedPrompt = "'--help\nship user'\\''s fix\nwith\ttabs'"

        XCTAssertEqual(
            try #require(actionsByID["claude"]).command(forPrompt: prompt),
            "claude --dangerously-skip-permissions -- \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["codex"]).command(forPrompt: prompt),
            "codex --yolo -- \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["opencode"]).command(forPrompt: prompt),
            "opencode --prompt \(quotedPrompt)"
        )
        XCTAssertEqual(
            try #require(actionsByID["pi"]).command(forPrompt: prompt),
            "pi -- \(quotedPrompt)"
        )
        XCTAssertTrue(launchCommandsByID.isEmpty)
    }
    @Test
    func testCommandTemplateSubmitPlanExposesAgentLaunchCommandForActiveSessionTracking() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let prompt = "--help\nship user's fix\nwith\ttabs"
        let plan = TextBoxInputContainer.dispatchPlan(
            [.text(prompt)],
            applying: codex,
            shouldForceTextEntrySubmit: false,
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: nil
        )

        let expectedCommand = "codex --yolo -- '--help\nship user'\\''s fix\nwith\ttabs'"
        XCTAssertEqual(plan.launchCommand, expectedCommand)
        XCTAssertEqual(plan.launchContextCommand, "codex --yolo --")
        XCTAssertEqual(plan.events, TextBoxSubmit.dispatchEvents(for: [.text(expectedCommand)], terminalAgentContext: ""))
    }

    @Test
    func testRecordedTextBoxLaunchContextDoesNotStoreSubmittedPrompt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let prompt = String(repeating: "large prompt ", count: 200)
        panel.recordTextBoxLaunchCommand("codex --yolo '\(prompt)'")

        XCTAssertEqual(panel.textBoxState.launchCommand, "codex")
        XCTAssertFalse(panel.textBoxState.launchCommand?.contains(prompt) ?? true)
        XCTAssertFalse(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
        panel.updateShellActivityState(.commandRunning)
        XCTAssertFalse(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
    }

    @Test
    func testDeadHookPIDDoesNotForceActiveAgentTextEntry() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.recordAgentPID(key: "codex.dead-session", pid: 999_999, panelId: panel.id, refreshPorts: false)
        workspace.clearStaleAgentPIDs(panelId: panel.id, refreshPorts: false)
        let context = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertTrue(TextBoxInputContainer.allowsSubmitActionSelection(pendingProviderLaunchAction: nil, shouldForceTextEntrySubmit: TextBoxInputContainer.shouldForceTextEntrySubmit(allowsCommandTemplateSubmit: true, terminalAgentContext: context)))
    }

    @Test
    func testLiveHookPIDStillForcesActiveAgentTextEntryAfterSweep() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.recordAgentPID(key: "codex.current-process", pid: getpid(), panelId: panel.id, refreshPorts: false)
        workspace.clearStaleAgentPIDs(panelId: panel.id, refreshPorts: false)
        let context = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertFalse(TextBoxInputContainer.allowsSubmitActionSelection(pendingProviderLaunchAction: nil, shouldForceTextEntrySubmit: TextBoxInputContainer.shouldForceTextEntrySubmit(allowsCommandTemplateSubmit: true, terminalAgentContext: context)))
    }

    @Test
    func testTextBoxLaunchContextRequiresAgentExecutable() {
        XCTAssertEqual(
            TextBoxAgentDetection.boundedLaunchCommandContext(
                from: "agent-router --provider codex --prompt 'ship it'"
            ),
            nil
        )
        XCTAssertEqual(
            TextBoxAgentDetection.boundedLaunchCommandContext(
                from: "env FOO=bar codex --yolo"
            ),
            "codex"
        )
        XCTAssertEqual(
            TextBoxAgentDetection.boundedLaunchCommandContext(
                from: "zsh -lc 'claude --dangerously-skip-permissions'"
            ),
            "claude"
        )
    }


    @Test
    func testProviderLaunchEventsKeepPromptInTextBoxUntilAgentIsActive() {
        XCTAssertEqual(
            TextBoxSubmit.launchDispatchEvents(launchCommand: "codex --yolo"),
            [
                .pasteText("codex --yolo"),
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
        let actions = (0..<(TextBoxSubmitActionImageSupport.maximumCachedImageCount + 8)).map { index in
            TextBoxSubmitAction(
                id: "custom-\(index)",
                title: "Custom \(index)",
                kind: .textEntry,
                systemImage: "arrow.up",
                imagePath: "/tmp/custom-\(index).png",
                backgroundColorHex: "#FFFFFF"
            )
        }
        let keys = TextBoxInputContainer.submitActionImageCacheKeys(for: actions, expandPath: { $0 })

        XCTAssertEqual(
            keys.count,
            TextBoxSubmitActionImageSupport.maximumCachedImageCount
        )
        XCTAssertTrue(keys.contains("path:/tmp/custom-0.png"))
        XCTAssertFalse(keys.contains("path:/tmp/custom-\(TextBoxSubmitActionImageSupport.maximumCachedImageCount).png"))
    }

    @Test
    func testCustomSubmitActionImageDecodesAsBoundedIcon() throws {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 128,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try #require(representation.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-textbox-submit-icon-\(UUID().uuidString).png")
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(TextBoxSubmitActionImageSupport.image(atPath: url.path))
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
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
    func testCustomTextBoxSubmitActionOverrideKeepsConfiguredPresentationTitle() {
        let customCodex = TextBoxSubmitAction(
            id: "codex",
            title: "Codex Custom",
            kind: .commandTemplate,
            commandTemplate: "codex --model custom {{prompt}}",
            systemImage: "sparkles",
            backgroundColorHex: "#FFFFFF"
        )

        let action = TextBoxSubmitAction.normalizedCatalog([customCodex]).first { $0.id == "codex" }

        XCTAssertEqual(action?.title, "Codex Custom")
        if let action {
            XCTAssertEqual(TextBoxSubmitActionPresentation.localizedTitle(for: action), "Codex Custom")
        }
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

        XCTAssertTrue(template.contains(#""commandTemplate" : "codex --yolo -- {{prompt}}""#))
        XCTAssertTrue(template.contains(#""commandTemplate" : "opencode --prompt {{prompt}}""#))
        XCTAssertTrue(template.contains(#""commandTemplate" : "pi -- {{prompt}}""#))
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
        XCTAssertFalse(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: true,
                terminalAgentContext: "textBoxLaunchCommand:codex --yolo"
            )
        )
    }

    @Test
    func testTextBoxForceTextEntryDetectsAgentContextEdgeCases() {
        let contexts = [
            "restoredAgent:opencode",
            "agentPIDKey:omx.12345",
            "initialCommand:/bin/zsh -lc 'codex --yolo \"hi\"'",
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
        panel.recordTextBoxLaunchCommand("codex --yolo")

        let pendingContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertTrue(TextBoxAgentDetection.hasPendingTextBoxLaunchContext(pendingContext))
        XCTAssertFalse(TextBoxAgentDetection.supportsAgentPrefixes(context: pendingContext))
        XCTAssertFalse(TextBoxAgentDetection.supportsActiveAgentPrefixes(context: pendingContext))
        XCTAssertTrue(
            TextBoxInputContainer.isPendingProviderLaunchAwaitingAgent(
                pendingProviderLaunchAction: TextBoxSubmitAction.builtInActions[0],
                terminalAgentContext: pendingContext
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .promptIdle,
                terminalAgentContext: pendingContext
            )
        )

        panel.updateShellActivityState(.commandRunning)
        let runningContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        XCTAssertFalse(TextBoxAgentDetection.supportsAgentPrefixes(context: runningContext))
        XCTAssertFalse(TextBoxAgentDetection.supportsActiveAgentPrefixes(context: runningContext))
        XCTAssertFalse(TextBoxAgentDetection.hasPendingTextBoxLaunchContext(runningContext))
        XCTAssertFalse(
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
            ""
        )
    }

    @Test
    func testTextBoxLaunchCommandContextExpiresAfterCommandReturnsToPrompt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        panel.recordTextBoxLaunchCommand("codex --yolo")
        XCTAssertEqual(panel.textBoxState.pendingLaunchCommand, "codex")
        panel.updateShellActivityState(.commandRunning)
        #expect(panel.textBoxState.launchCommand != nil)
        #expect(panel.textBoxState.pendingLaunchCommand == nil)

        panel.updateShellActivityState(.promptIdle)
        #expect(panel.textBoxState.launchCommand == nil)
        XCTAssertFalse(
            TextBoxAgentDetection.supportsActiveAgentPrefixes(
                context: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            )
        )
    }

    @Test
    func testTextBoxLaunchCommandContextSurvivesStalePromptIdleBeforeRunning() throws {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.updateShellActivityState(.promptIdle)
        panel.recordTextBoxLaunchCommand("codex --yolo")
        #expect(panel.textBoxState.launchCommand != nil)
        XCTAssertEqual(panel.textBoxState.pendingLaunchCommand, "codex")

        panel.updateShellActivityState(.promptIdle)
        #expect(panel.textBoxState.launchCommand != nil)
        XCTAssertEqual(panel.textBoxState.pendingLaunchCommand, "codex")
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
    func testHookActiveAgentContextWinsOverStaleRestoredAgent() {
        let context = """
        restoredAgent:claude
        agentPIDKey:codex.12345
        """
        let activeContext = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: context
        )

        XCTAssertEqual(activeContext, "agentPIDKey:codex.12345")
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
        XCTAssertEqual(
            TextBoxInputContainer.providerLaunchCommand(
                for: claude,
                shouldForceTextEntrySubmit: false,
                allowsCommandTemplateSubmit: true
            ),
            "claude --dangerously-skip-permissions"
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
        XCTAssertTrue(
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
    func testUnknownLaunchOnlyCustomActionDoesNotEnterPendingProviderMode() {
        let router = TextBoxSubmitAction(
            id: "router",
            title: "Router",
            kind: .commandTemplate,
            commandTemplate: "agent-router",
            preservePromptAfterLaunch: true,
            systemImage: "sparkle",
            backgroundColorHex: "#FFFFFF"
        )

        XCTAssertEqual(
            TextBoxInputContainer.providerLaunchCommand(
                for: router,
                shouldForceTextEntrySubmit: false,
                allowsCommandTemplateSubmit: true
            ),
            nil
        )
    }

    @Test
    func testUnsupportedLaunchOnlyCustomActionFailsClosedAtPrompt() {
        let router = TextBoxSubmitAction(
            id: "router",
            title: "Router",
            kind: .commandTemplate,
            commandTemplate: "agent-router --provider codex",
            preservePromptAfterLaunch: true,
            systemImage: "sparkle",
            backgroundColorHex: "#FFFFFF"
        )

        XCTAssertTrue(
            TextBoxInputContainer.shouldFailClosedForCommandTemplate(
                action: router,
                shouldForceTextEntrySubmit: false,
                allowsCommandTemplateSubmit: true
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldFailClosedForCommandTemplate(
                action: router,
                shouldForceTextEntrySubmit: false,
                allowsCommandTemplateSubmit: false
            )
        )
    }

    @Test
    func testUnknownPromptCustomActionDoesNotEnterPendingProviderMode() {
        let router = TextBoxSubmitAction(
            id: "router",
            title: "Router",
            kind: .commandTemplate,
            commandTemplate: "agent-router --plan {{prompt}}",
            preservePromptAfterLaunch: nil,
            systemImage: "sparkle",
            backgroundColorHex: "#FFFFFF"
        )

        let plan = TextBoxInputContainer.dispatchPlan(
            [.text("keep working")],
            applying: router,
            shouldForceTextEntrySubmit: false,
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: nil
        )

        XCTAssertEqual(plan.launchContextCommand, nil)
        XCTAssertEqual(
            plan.events,
            TextBoxSubmit.dispatchEvents(
                for: [.text("agent-router --plan 'keep working'")],
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldFailClosedForCommandTemplate(
                action: router,
                shouldForceTextEntrySubmit: false,
                allowsCommandTemplateSubmit: true
            )
        )
    }

    @Test
    func testTextBoxPendingLaunchUsesInitialCommandContext() {
        let launchOnlyCodex = TextBoxSubmitAction(
            id: "custom-codex-launch",
            title: "Custom Codex Launch",
            kind: .commandTemplate,
            commandTemplate: "codex --yolo",
            preservePromptAfterLaunch: true,
            systemImage: "sparkles",
            backgroundColorHex: "#8FDBFF"
        )
        let context = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: launchOnlyCodex
        )

        XCTAssertEqual(context, "initialCommand:codex --yolo")
        XCTAssertTrue(TextBoxAgentDetection.supportsAgentPrefixes(context: context))
    }

    @Test
    func testTextBoxPendingLaunchClearsOnAgentDetectionOrPromptIdleFallback() {
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .commandRunning,
                terminalAgentContext: "initialCommand:codex --yolo"
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .promptIdle,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .unknown,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .commandRunning,
                terminalAgentContext: ""
            )
        )
        XCTAssertFalse(TextBoxInputContainer.shouldClearPendingProviderLaunch(shellActivityState: .promptIdle, terminalAgentContext: "textBoxPendingLaunchCommand:codex"))
        XCTAssertFalse(TextBoxInputContainer.shouldClearPendingProviderLaunch(shellActivityState: .promptIdle, terminalAgentContext: "restoredAgent:claude\ntextBoxPendingLaunchCommand:codex"))
        XCTAssertTrue(TextBoxInputContainer.shouldClearPendingProviderLaunch(shellActivityState: .commandRunning, terminalAgentContext: "textBoxPendingLaunchCommand:codex\nagentPIDKey:codex.12345"))
        XCTAssertFalse(
            TextBoxInputContainer.allowsSubmitActionSelection(
                pendingProviderLaunchAction: TextBoxSubmitAction.builtInActions[0],
                shouldForceTextEntrySubmit: false
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.allowsSubmitActionSelection(
                pendingProviderLaunchAction: nil,
                shouldForceTextEntrySubmit: false
            )
        )
        XCTAssertFalse(
            TextBoxInputContainer.allowsSubmitActionSelection(
                pendingProviderLaunchAction: nil,
                shouldForceTextEntrySubmit: true
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .promptIdle,
                terminalAgentContext: "textBoxPendingLaunchCommand:codex",
                pendingLaunchExpired: true
            )
        )
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertFalse(
            TextBoxInputContainer.isPendingProviderLaunchExpired(
                startedAt: startedAt,
                now: Date(timeIntervalSinceReferenceDate: 111.9)
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.isPendingProviderLaunchExpired(
                startedAt: startedAt,
                now: Date(timeIntervalSinceReferenceDate: 112)
            )
        )
        XCTAssertEqual(
            TextBoxInputContainer.pendingProviderLaunchTimeoutDelay(
                startedAt: startedAt,
                now: Date(timeIntervalSinceReferenceDate: 105),
                timeoutSeconds: 12
            ),
            7
        )
        XCTAssertEqual(
            TextBoxInputContainer.pendingProviderLaunchTimeoutDelay(
                startedAt: startedAt,
                now: Date(timeIntervalSinceReferenceDate: 113),
                timeoutSeconds: 12
            ),
            0
        )
        XCTAssertTrue(
            TextBoxInputContainer.isPendingProviderLaunchAwaitingAgent(
                pendingProviderLaunchAction: TextBoxSubmitAction.builtInActions[0],
                terminalAgentContext: ""
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearLaunchCommandWhenClearingPending(
                terminalAgentContext: ""
            )
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldClearLaunchCommandWhenClearingPending(
                terminalAgentContext: "textBoxLaunchCommand:codex"
            )
        )
    }

    @Test
    func testTerminalPanelViewAddsPendingTextBoxLaunchContext() {
        let context = TerminalPanelView.effectiveTerminalAgentContext(
            "restoredAgent:claude",
            pendingLaunchCommand: "codex"
        )

        XCTAssertTrue(TextBoxAgentDetection.hasPendingTextBoxLaunchContext(context))
        XCTAssertTrue(context.contains("restoredAgent:claude"))
        XCTAssertFalse(
            TextBoxInputContainer.shouldClearPendingProviderLaunch(
                shellActivityState: .promptIdle,
                terminalAgentContext: context
            )
        )
    }


    @Test
    func testTextBoxDefaultSubmitActionAcceptsTextEntryEscapeHatch() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(
            TextBoxSubmitAction.textEntryAction.id,
            forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey
        )
        XCTAssertEqual(
            TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
            TextBoxSubmitAction.textEntryAction.id
        )
    }


    @Test
    func testTextBoxMissingCustomDefaultSubmitActionFailsClosedToTextEntry() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("missing-router", forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey)
        defaults.set("[]", forKey: TerminalTextBoxInputSettings.submitActionsKey)

        XCTAssertEqual(
            TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults),
            TextBoxSubmitAction.textEntryAction.id
        )
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

        XCTAssertFalse(
            TextBoxInputContainer.allowsSubmitActionSelection(
                pendingProviderLaunchAction: nil,
                shouldForceTextEntrySubmit: true
            )
        )
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
    func testHookActiveAgentForcesTextEntryAtPromptIdle() {
        let context = "agentPIDKey:codex.12345"
        let shouldForceTextEntry = TextBoxInputContainer.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: context
        )

        XCTAssertTrue(shouldForceTextEntry)
        XCTAssertTrue(TextBoxAgentDetection.supportsActiveAgentPrefixes(context: context))
        XCTAssertFalse(
            TextBoxInputContainer.allowsSubmitActionSelection(
                pendingProviderLaunchAction: nil,
                shouldForceTextEntrySubmit: shouldForceTextEntry
            )
        )
        XCTAssertEqual(
            TextBoxInputContainer.submitActionPresentation(
                selectedSubmitAction: TextBoxSubmitAction.builtInActions[1],
                shouldForceTextEntrySubmit: shouldForceTextEntry
            ).action.id,
            TextBoxSubmitAction.textEntryAction.id
        )
    }

    @Test
    func testSuccessfulCommandTemplateSubmitResetsPanelActionToTextEntry() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })

        XCTAssertEqual(
            TextBoxInputContainer.panelSubmitActionIDAfterSuccessfulSubmit(
                currentSubmitActionID: codex.id,
                submittedAction: codex
            ),
            TextBoxSubmitAction.textEntryAction.id
        )
        XCTAssertEqual(
            TextBoxInputContainer.panelSubmitActionIDAfterSuccessfulSubmit(
                currentSubmitActionID: codex.id,
                submittedAction: TextBoxSubmitAction.textEntryAction
            ),
            codex.id
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
    func testFreshOwnedTerminalSubmitsProviderCommandWithoutBlockingCycle() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let panel = TerminalPanel(workspaceId: UUID())
        let allowsCommandTemplateSubmit = TextBoxInputContainer.allowsCommandTemplateSubmit(
            shellActivityState: panel.shellActivity.state
        )
        let shouldForceTextEntry = TextBoxInputContainer.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: ""
        )

        #expect(!shouldForceTextEntry)
        #expect(!TextBoxInputContainer.shouldUseTextEntryFallbackForCommandTemplate(
            action: codex,
            shouldForceTextEntrySubmit: shouldForceTextEntry,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        ))
        XCTAssertEqual(
            TextBoxInputContainer.dispatchPlan(
                [.text("hi how are you")],
                applying: codex,
                shouldForceTextEntrySubmit: shouldForceTextEntry,
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
                terminalAgentContext: "",
                pendingProviderLaunchAction: nil
            ).events,
            TextBoxSubmit.dispatchEvents(
                for: [.text("codex --yolo -- 'hi how are you'")],
                terminalAgentContext: ""
            )
        )
    }

    @Test
    func testUnknownShellStateFailsClosedWithoutBlockingCycle() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let allowsCommandTemplateSubmit = TextBoxInputContainer.allowsCommandTemplateSubmit(
            shellActivityState: .unknown
        )
        let shouldForceTextEntry = TextBoxInputContainer.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: ""
        )

        #expect(!shouldForceTextEntry)
        #expect(!TextBoxInputContainer.shouldUseTextEntryFallbackForCommandTemplate(
            action: codex,
            shouldForceTextEntrySubmit: shouldForceTextEntry,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        ))
        XCTAssertEqual(
            TextBoxInputContainer.submitActionPresentation(
                selectedSubmitAction: codex,
                shouldForceTextEntrySubmit: shouldForceTextEntry
            ).action.id,
            codex.id
        )
        XCTAssertTrue(
            TextBoxInputContainer.shouldFailClosedForCommandTemplate(
                action: codex,
                shouldForceTextEntrySubmit: shouldForceTextEntry,
                allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
            )
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
        XCTAssertEqual(state.launchCommand, "codex")
        #expect(state.pendingLaunchCommand == nil)

        state.updateShellActivityState(.commandRunning)
        XCTAssertEqual(state.launchCommand, "codex")
        #expect(state.pendingLaunchCommand == nil)
    }

    @Test
    func testTextBoxCycleSubmitActionUsesConfiguredShortcut() {
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

        let handledByTextBoxShortcut = textView.handleConfiguredTextBoxShortcut(shiftTabEvent)

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

            let backgroundWorkspace = manager.addWorkspace(select: false)
            guard let backgroundWorkspacePanel = backgroundWorkspace.focusedTerminalPanel else {
                XCTFail("Expected background workspace terminal")
                return
            }

            XCTAssertTrue(backgroundWorkspacePanel.isTextBoxActive)
            #expect(backgroundWorkspacePanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))

            guard let respawnSourcePanel = workspace.focusedTerminalPanel,
                  let respawnedPanel = workspace.respawnTerminalSurface(
                    panelId: respawnSourcePanel.id,
                    command: "echo respawned",
                    focus: false,
                    allowTextBoxFocusDefault: false
                  ) else {
                XCTFail("Expected background respawned terminal")
                return
            }

            XCTAssertTrue(respawnedPanel.isTextBoxActive)
            #expect(respawnedPanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))

            guard let remotePanePanel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: 42,
                focus: false,
                allowTextBoxFocusDefault: false,
                onInput: { _ in }
            ) else {
                XCTFail("Expected background remote tmux display pane")
                return
            }

            XCTAssertTrue(remotePanePanel.isTextBoxActive)
            #expect(remotePanePanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))
        }
    }


    @Test
    func testTerminalPanelPublishesShellActivityStateForTextBoxRouting() {
        let panel = TerminalPanel(workspaceId: UUID())

        XCTAssertEqual(panel.shellActivity.state, .promptIdle)
        panel.updateShellActivityState(.commandRunning)
        XCTAssertEqual(panel.shellActivity.state, .commandRunning)
    }

    @Test
    func testTerminalPanelKeepsStartupSurfacesUnknownUntilShellIntegrationReports() {
        var template = CmuxSurfaceConfigTemplate()
        template.initialInput = "echo from template\n"

        XCTAssertEqual(
            TerminalPanel(workspaceId: UUID(), initialCommand: "vim").shellActivity.state,
            .unknown
        )
        XCTAssertEqual(
            TerminalPanel(workspaceId: UUID(), tmuxStartCommand: "tmux new").shellActivity.state,
            .unknown
        )
        XCTAssertEqual(
            TerminalPanel(workspaceId: UUID(), initialInput: "echo hi\n").shellActivity.state,
            .unknown
        )
        XCTAssertEqual(
            TerminalPanel(workspaceId: UUID(), configTemplate: template).shellActivity.state,
            .unknown
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "TextBoxSubmitActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
