import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `"type": "setting"` and `"type": "settingPreset"` config actions:
/// decoding, the global-config-only rule, and tab bar resolution.
struct CmuxConfigSettingActionTests {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    private func settingChange(in config: CmuxConfigFile, id: String) throws -> CmuxSettingChange {
        let action = try #require(config.actions[id]?.action)
        guard case .setting(let change) = action else {
            Issue.record("expected a setting action for \(id), got \(action)")
            throw CancellationError()
        }
        return change
    }

    @Test func decodesEverySettingOperationAndPresets() throws {
        let config = try decode("""
        {
          "actions": {
            "scroll.fast": { "type": "setting", "path": "terminal.scrollSpeed", "set": 1.8 },
            "wrap": { "type": "setting", "path": "fileEditor.wordWrap", "toggle": true },
            "scroll.cycle": { "type": "setting", "path": "terminal.scrollSpeed", "cycle": [1, 1.4, 1.8] },
            "scroll.reset": { "type": "setting", "path": "terminal.scrollSpeed", "unset": true },
            "quiet": { "type": "settingPreset", "preset": "sidebar.quiet", "title": "Quiet Sidebar" }
          }
        }
        """)
        #expect(try settingChange(in: config, id: "scroll.fast") == .set(path: "terminal.scrollSpeed", value: .number(1.8)))
        #expect(try settingChange(in: config, id: "wrap") == .toggle(path: "fileEditor.wordWrap"))
        #expect(try settingChange(in: config, id: "scroll.cycle") == .cycle(
            path: "terminal.scrollSpeed",
            values: [.number(1), .number(1.4), .number(1.8)]
        ))
        #expect(try settingChange(in: config, id: "scroll.reset") == .unset(path: "terminal.scrollSpeed"))
        #expect(try settingChange(in: config, id: "quiet") == .preset(name: "sidebar.quiet"))
        #expect(config.actions["quiet"]?.title == "Quiet Sidebar")
    }

    @Test(arguments: [
        #"{ "type": "setting", "path": "terminal.scrollSpeed" }"#,
        #"{ "type": "setting", "path": "terminal.scrollSpeed", "set": 1, "toggle": true }"#,
        #"{ "type": "setting", "path": "fileEditor.wordWrap", "toggle": false }"#,
        #"{ "type": "setting", "path": "terminal.scrollSpeed", "cycle": [] }"#,
        #"{ "type": "setting", "set": 1 }"#,
        #"{ "type": "settingPreset" }"#,
    ])
    func rejectsMalformedSettingActions(_ action: String) {
        #expect(throws: (any Error).self) {
            try decode(#"{ "actions": { "bad": "# + action + " } }")
        }
    }

    @Test func settingActionEncodeDecodeRoundTrip() throws {
        let changes: [CmuxSettingChange] = [
            .set(path: "app.appearance", value: .string("dark")),
            .toggle(path: "fileEditor.wordWrap"),
            .cycle(path: "terminal.scrollSpeed", values: [.number(1), .number(1.4)]),
            .unset(path: "terminal.scrollSpeed"),
            .preset(name: "sidebar.quiet"),
        ]
        for change in changes {
            let original = CmuxConfigActionDefinition(action: .setting(change), title: "Change")
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CmuxConfigActionDefinition.self, from: data)
            #expect(decoded.action == .setting(change))
        }
    }

    @Test func onlyGlobalSourcesMayRunSettingActions() {
        let global = "/Users/me/.config/cmux/cmux.json"
        #expect(CmuxSettingActionTrust.allowsSettingAction(actionSourcePath: global, globalConfigPath: global))
        #expect(!CmuxSettingActionTrust.allowsSettingAction(actionSourcePath: nil, globalConfigPath: global))
        #expect(CmuxSettingActionTrust.allowsSettingAction(
            actionSourcePath: "/Users/me/.config/cmux/../cmux/cmux.json",
            globalConfigPath: global
        ))
        #expect(!CmuxSettingActionTrust.allowsSettingAction(
            actionSourcePath: "/Users/me/code/repo/.cmux/cmux.json",
            globalConfigPath: global
        ))
    }

    @MainActor
    @Test func registryKeepsGlobalSettingActionsAndDropsProjectOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-setting-actions-\(UUID().uuidString)", isDirectory: true)
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let localDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = localDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "wrap": { "type": "setting", "path": "fileEditor.wordWrap", "toggle": true, "title": "Toggle Wrap" }
          },
          "ui": { "surfaceTabBar": { "buttons": ["cmux.newTerminal", { "action": "wrap" }] } }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "sneaky": {
              "type": "setting",
              "path": "automation.socketControlMode",
              "set": "allowAll",
              "title": "Run Tests"
            }
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let wrap = try #require(store.resolvedAction(id: "wrap"))
        #expect(wrap.action == .setting(.toggle(path: "fileEditor.wordWrap")))
        #expect(wrap.actionSourcePath == globalConfigURL.path)
        #expect(store.paletteCustomActions().contains { $0.id == "wrap" })

        #expect(store.resolvedAction(id: "sneaky") == nil)
        #expect(!store.paletteCustomActions().contains { $0.id == "sneaky" })

        let button = try #require(store.surfaceTabBarButtons.first { $0.id == "wrap" })
        #expect(button.action.isSettingChange)
        #expect(button.actionSourcePath == globalConfigURL.path)
    }

    /// Packs the global config references are the user's choice, so their
    /// setting actions load; a project config's pack is dropped like the
    /// project config itself. `confirm` reaches both the palette action and
    /// the tab bar button.
    @MainActor
    @Test func globalPacksMayDeclareSettingActionsAndConfirmIsCarried() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-setting-packs-\(UUID().uuidString)", isDirectory: true)
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let globalPackDirectory = globalDirectory.appendingPathComponent("packs/mine", isDirectory: true)
        let localDirectory = root.appendingPathComponent("project", isDirectory: true)
        let localPackDirectory = localDirectory.appendingPathComponent("packs/team", isDirectory: true)
        for directory in [globalPackDirectory, localPackDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = localDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "packs": ["./packs/mine"],
          "ui": { "surfaceTabBar": { "buttons": [{ "action": "scroll.cycle" }] } }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "scroll.cycle": {
              "type": "setting", "path": "terminal.scrollSpeed", "cycle": [1, 1.4],
              "title": "Cycle Scroll", "confirm": true
            }
          },
          "settingPresets": {
            "sidebar.quiet": {
              "sidebar": { "showPorts": false }
            }
          }
        }
        """.write(to: globalPackDirectory.appendingPathComponent("cmux.pack.json"), atomically: true, encoding: .utf8)
        try #"{ "packs": ["./packs/team"] }"#.write(to: localConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "team.sneaky": { "type": "setting", "path": "automation.socketControlMode", "set": "allowAll" }
          }
        }
        """.write(to: localPackDirectory.appendingPathComponent("cmux.pack.json"), atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let cycle = try #require(store.resolvedAction(id: "scroll.cycle"))
        #expect(store.settingPresets["sidebar.quiet"] == .object([
            "sidebar": .object(["showPorts": .bool(false)])
        ]))
        #expect(cycle.confirm == true)
        #expect(CmuxSettingActionTrust.allowsSettingAction(
            actionSourcePath: cycle.actionSourcePath,
            globalConfigPath: globalConfigURL.path
        ))
        let button = try #require(store.surfaceTabBarButtons.first { $0.id == "scroll.cycle" })
        #expect(button.confirm == true)
        #expect(button.action.isSettingChange)

        #expect(store.resolvedAction(id: "team.sneaky") == nil)
    }

    @MainActor
    @Test func confirmationDialogShowsTheEquivalentCommand() {
        let alert = CmuxSettingActionRunner.confirmationAlert(
            for: .cycle(path: "terminal.scrollSpeed", values: [.number(1), .number(1.4)]),
            title: "Cycle Scroll"
        )
        #expect(alert.messageText == "Cycle Scroll")
        #expect(alert.informativeText.contains("cmux config cycle terminal.scrollSpeed 1 1.4"))
        #expect(alert.buttons.count == 2)

        let untitled = CmuxSettingActionRunner.confirmationAlert(for: .toggle(path: "fileEditor.wordWrap"), title: "  ")
        #expect(!untitled.messageText.isEmpty)
        #expect(untitled.informativeText.contains("cmux config toggle fileEditor.wordWrap"))
    }

    /// A project config can't retitle a global setting action, bind it to a
    /// shortcut, or drop its confirm, either in `actions` or on a button.
    @MainActor
    @Test func projectConfigCannotRelabelOrUnconfirmAGlobalSettingAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-setting-override-\(UUID().uuidString)", isDirectory: true)
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let localDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = localDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "socket.open": {
              "type": "setting", "path": "automation.socketControlMode", "set": "allowAll",
              "title": "Open Socket", "confirm": true
            }
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "socket.open": { "title": "Run Tests", "confirm": false, "shortcut": "cmd+shift+u" }
          },
          "ui": { "surfaceTabBar": { "buttons": [
            { "action": "socket.open", "title": "Run Tests", "confirm": false }
          ] } }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let action = try #require(store.resolvedAction(id: "socket.open"))
        #expect(action.title == "Open Socket")
        #expect(action.confirm == true)
        #expect(action.shortcut == nil)
        #expect(action.actionSourcePath == globalConfigURL.path)

        let button = try #require(store.surfaceTabBarButtons.first { $0.id == "socket.open" })
        #expect(button.title == "Open Socket")
        #expect(button.confirm == true)
        #expect(button.actionSourcePath == globalConfigURL.path)
    }
}
