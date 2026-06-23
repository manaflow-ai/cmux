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
    Issue.record(message)
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
    }


    @Test
    func testBuiltInTextBoxSubmitActionsUsePromptFreeLaunchCommands() {
        let launchCommandsByID = Dictionary(
            uniqueKeysWithValues: TextBoxSubmitAction.builtInActions.compactMap { action in
                action.launchCommand().map { (action.id, $0) }
            }
        )

        XCTAssertEqual(launchCommandsByID["claude"], "claude")
        XCTAssertEqual(launchCommandsByID["codex"], "codex")
        XCTAssertEqual(launchCommandsByID["opencode"], "opencode")
        XCTAssertEqual(launchCommandsByID["pi"], "pi")
        XCTAssertTrue(TextBoxSubmitAction.builtInActions.allSatisfy { $0.command(forPrompt: "secret") == nil })
    }


    @Test
    func testProviderLaunchEventsKeepPromptInTextBoxUntilAgentIsActive() {
        XCTAssertEqual(
            TextBoxSubmit.launchDispatchEvents(launchCommand: "codex"),
            [
                .pasteText("codex"),
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

        XCTAssertTrue(template.contains(#""commandTemplate" : "codex""#))
        XCTAssertTrue(template.contains(#""preservePromptAfterLaunch" : true"#))
    }


    @Test
    func testTextBoxForceTextEntryUsesShellEligibilityOverStaleAgentMetadata() {
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
        XCTAssertTrue(
            TextBoxInputContainer.shouldForceTextEntrySubmit(
                allowsCommandTemplateSubmit: false,
                terminalAgentContext: ""
            )
        )
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
    func testTextBoxPendingClaudeLaunchPreservesSubmitContextWhilePromptIdle() throws {
        let claude = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "claude" })
        let context = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
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
    func testTextBoxPendingLaunchUsesInitialCommandContext() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        let context = TextBoxInputContainer.textEntryTerminalAgentContext(
            allowsCommandTemplateSubmit: true,
            terminalAgentContext: "",
            pendingProviderLaunchAction: codex
        )

        XCTAssertEqual(context, "initialCommand:codex")
        XCTAssertTrue(TextBoxAgentDetection.supportsAgentPrefixes(context: context))
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

        textView.keyDown(with: shiftTabEvent)

        XCTAssertEqual(cycleCount, 0)
        XCTAssertTrue(textView.hasMarkedText())
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
