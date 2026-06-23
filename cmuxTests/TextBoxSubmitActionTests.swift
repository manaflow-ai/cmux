import XCTest
import AppKit
import Carbon.HIToolbox

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TextBoxSubmitActionTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testSettingsFileStoreAppliesTextBoxSubmitActionSettings() throws {
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

    func testProviderLaunchEventsKeepPromptInTextBoxUntilAgentIsActive() {
        XCTAssertEqual(
            TextBoxSubmit.launchDispatchEvents(launchCommand: "codex"),
            [
                .pasteText("codex"),
                .namedKey("return"),
            ]
        )
    }

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

    func testDefaultConfigTemplateIncludesTextBoxLaunchPromptFlag() {
        let template = CmuxSettingsFileStore.defaultTemplate()

        XCTAssertTrue(template.contains(#""commandTemplate" : "codex""#))
        XCTAssertTrue(template.contains(#""preservePromptAfterLaunch" : true"#))
    }

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

    func testTerminalPanelPublishesShellActivityStateForTextBoxRouting() {
        let panel = TerminalPanel(workspaceId: UUID())

        XCTAssertEqual(panel.shellActivityState, .unknown)
        panel.updateShellActivityState(.promptIdle)
        XCTAssertEqual(panel.shellActivityState, .promptIdle)
        panel.updateShellActivityState(.commandRunning)
        XCTAssertEqual(panel.shellActivityState, .commandRunning)
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
