import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `sidebar.hiddenStatusKeys` in cmux.json reaches the catalog key the sidebar
/// reads, as a string array, with entries trimmed and empty ones dropped.
///
/// Each test gives the store its own UserDefaults suite, so nothing here
/// touches the app-host process's live defaults or the store's shared backup
/// records under them.
@Suite(.serialized)
struct SidebarHiddenStatusKeysSettingsFileTests {
    private let key = SidebarCatalogSection().hiddenStatusKeys

    private struct Fixture {
        let defaults: UserDefaults
        let store: CmuxSettingsFileStore
        let configURL: URL
    }

    private func withConfig(
        _ json: String,
        preset: [String]? = nil,
        _ body: (Fixture) throws -> Void
    ) throws {
        let suiteName = "SidebarHiddenStatusKeysSettingsFileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-status-keys-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        if let preset { defaults.set(preset, forKey: key.userDefaultsKey) }
        try json.write(to: configURL, atomically: true, encoding: .utf8)
        let store = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            startWatching: false
        )
        try body(Fixture(defaults: defaults, store: store, configURL: configURL))
    }

    private func stored(_ defaults: UserDefaults) -> [String] {
        UserDefaultsSettingsClient(defaults: defaults).value(for: key)
    }

    private func reportsInvalidKey(_ store: CmuxSettingsFileStore) -> Bool {
        store.configurationIssues.contains { $0.contains(key.id) }
    }

    @Test func arrayReachesTheCatalogKeyTrimmedAndWithoutEmptyEntries() throws {
        try withConfig(#"{"sidebar":{"hiddenStatusKeys":[" claude_code ", "", "codex", "deploy"]}}"#) { fixture in
            #expect(stored(fixture.defaults) == ["claude_code", "codex", "deploy"])
            #expect(!reportsInvalidKey(fixture.store))
        }
    }

    @Test func emptyArrayClearsAnEarlierValue() throws {
        try withConfig(#"{"sidebar":{"hiddenStatusKeys":[]}}"#, preset: ["claude_code"]) { fixture in
            #expect(stored(fixture.defaults) == [])
        }
    }

    @Test(arguments: [
        #"{"sidebar":{"hiddenStatusKeys":"claude_code"}}"#,
        #"{"sidebar":{"hiddenStatusKeys":null}}"#,
        #"{"sidebar":{"hiddenStatusKeys":["claude_code", 7]}}"#,
    ])
    func invalidValueIsReportedAndLeavesTheStoredValueAlone(json: String) throws {
        try withConfig(json, preset: ["deploy"]) { fixture in
            #expect(stored(fixture.defaults) == ["deploy"])
            #expect(reportsInvalidKey(fixture.store))
        }
    }

    @Test func removingTheKeyRestoresThePreviousValue() throws {
        try withConfig(#"{"sidebar":{"hiddenStatusKeys":["claude_code"]}}"#, preset: ["deploy"]) { fixture in
            #expect(stored(fixture.defaults) == ["claude_code"])
            try #"{"sidebar":{}}"#.write(to: fixture.configURL, atomically: true, encoding: .utf8)
            fixture.store.reload()
            #expect(stored(fixture.defaults) == ["deploy"])
        }
    }
}
