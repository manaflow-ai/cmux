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

    @Test func onlyTheGlobalConfigMayRunSettingActions() {
        let global = "/Users/me/.config/cmux/cmux.json"
        #expect(CmuxSettingActionTrust.allowsSettingAction(actionSourcePath: global, globalConfigPath: global))
        #expect(CmuxSettingActionTrust.allowsSettingAction(actionSourcePath: nil, globalConfigPath: global))
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
}
