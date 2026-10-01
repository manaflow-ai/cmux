import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers how enabled extension plugins reach the action registry, cmux.json
/// overrides, and the automation engine.
@Suite("Plugin runtime")
@MainActor
struct CmuxPluginRuntimeTests {
    private let home: URL
    private let paths: CmuxPluginPaths

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-runtime-\(UUID().uuidString)", isDirectory: true)
        paths = CmuxPluginPaths(homeDirectory: home)
        let directory = paths.installDirectory(for: "demo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        [plugin]
        name = "demo"
        kind = "extension"

        [[actions]]
        id = "hello"
        title = "Say Hello"
        argv = ["./hello.sh"]
        shortcut = "cmd+shift+u"

        [[actions]]
        id = "hidden"
        title = "Hidden"
        argv = ["true"]
        palette = false

        [[events]]
        event = "workspace.created"
        argv = ["./on-created.sh", "--quiet"]
        timeout_seconds = 5
        """.write(to: directory.appendingPathComponent("cmux-plugin.toml"), atomically: true, encoding: .utf8)
    }

    private func enableDemo() throws {
        let plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        try CmuxPluginEnablementStore(fileURL: paths.enablementFile).enable("demo", fingerprint: plugin.fingerprint)
    }

    @Test("A disabled plugin contributes no actions or rules")
    func disabledPluginIsInert() {
        let runtime = CmuxPluginRuntime(paths: paths)
        #expect(runtime.configActions(reservedShortcuts: []).isEmpty)
        #expect(runtime.automationRules().isEmpty)
        #expect(!runtime.invoke(registryID: "plugin.demo.hello", workspaceID: nil, surfaceID: nil))
    }

    @Test("Enabled actions are namespaced, keep palette visibility, and yield reserved shortcuts")
    func enabledActions() throws {
        try enableDemo()
        let runtime = CmuxPluginRuntime(paths: paths)
        let actions = runtime.configActions(reservedShortcuts: [])
        #expect(actions.map(\.id) == ["plugin.demo.hello", "plugin.demo.hidden"])
        let hello = try #require(actions.first)
        #expect(hello.action == .plugin("plugin.demo.hello"))
        #expect(hello.palette)
        #expect(hello.shortcut == StoredShortcut.parseConfig("cmd+shift+u"))
        #expect(hello.actionSourcePath?.hasSuffix("demo/cmux-plugin.toml") == true)
        #expect(actions.last?.palette == false)

        let reserved = try #require(StoredShortcut.parseConfig("cmd+shift+u"))
        #expect(runtime.configActions(reservedShortcuts: [reserved]).first?.shortcut == nil)
    }

    @Test("Event hooks become run rules with the plugin environment")
    func eventRules() throws {
        try enableDemo()
        let rules = CmuxPluginRuntime(paths: paths).automationRules()
        let rule = try #require(rules.first)
        #expect(rules.count == 1)
        #expect(rule.id == "plugin.demo.events.0")
        #expect(rule.when.event == "workspace.created")
        let action = try #require(rule.actions.first)
        #expect(action.action == "run")
        #expect(action.double(for: "timeout_seconds") == 5)
        let command = try #require(action.string(for: "command"))
        #expect(command.contains("export CMUX_PLUGIN_ID='demo'"))
        #expect(command.hasSuffix("/demo/on-created.sh' '--quiet'"))
    }

    @Test("cmux.json can rebind a plugin action, and the binding reaches shortcut routing")
    func cmuxJSONOverridesPluginAction() throws {
        try enableDemo()
        let runtime = CmuxPluginRuntime(paths: paths)
        let configURL = home.appendingPathComponent("cmux.json")
        try #"{ "actions": { "plugin.demo.hidden": { "shortcut": "cmd+shift+j", "palette": true } } }"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false,
            pluginActions: { runtime.configActions(reservedShortcuts: []) }
        )
        store.loadAll()

        let hidden = try #require(store.resolvedAction(id: "plugin.demo.hidden"))
        #expect(hidden.shortcut == StoredShortcut.parseConfig("cmd+shift+j"))
        #expect(hidden.palette)
        #expect(hidden.action == .plugin("plugin.demo.hidden"))
        #expect(store.shortcutActions().map(\.id).contains("plugin.demo.hidden"))
        #expect(store.paletteCustomActions().map(\.id).contains("plugin.demo.hello"))
    }

    @Test("The automation engine loads plugin rules beside the file and keeps them out of enable/disable")
    func engineMergesPluginRules() async throws {
        try enableDemo()
        let runtime = CmuxPluginRuntime(paths: paths)
        let store = AutomationConfigStore(fileURL: home.appendingPathComponent("automations.json"))
        let engine = AutomationEngine(
            configStore: store,
            eventBus: CmuxEventBus(retainedEventLimit: 8),
            pluginRulesProvider: { runtime.automationRules() }
        )
        defer { engine.stop() }
        engine.start()

        var loaded = false
        for _ in 0..<250 {
            if engine.rule(withID: "plugin.demo.events.0") != nil {
                loaded = true
                break
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(loaded)
        #expect(!engine.scheduleSetEnabled(id: "plugin.demo.events.0", enabled: false))
    }
}
