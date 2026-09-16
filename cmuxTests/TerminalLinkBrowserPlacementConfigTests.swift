import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal link placement config", .serialized)
struct TerminalLinkBrowserPlacementConfigTests {
    @Test(arguments: ["reuseOrSplit", "samePane", "split"])
    func configAppliesAndRemovalRestoresPreviousValue(placement: String) throws {
        try withConfig(value: placement) { defaults, store, file in
            #expect(defaults.string(forKey: "browserTerminalLinkBrowserPlacement") == placement)
            try "{}".write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(defaults.object(forKey: "browserTerminalLinkBrowserPlacement") == nil)
        }
    }

    @Test(arguments: ["\"futurePlacement\"", "123", "true", "null"])
    func invalidPlacementDoesNotDiscardOtherBrowserSettings(raw: String) throws {
        let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
        try withConfig(value: value) { defaults, _, _ in
            #expect(defaults.object(forKey: "browserTerminalLinkBrowserPlacement") == nil)
            #expect(defaults.object(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey) as? Bool == false)
            #expect(defaults.string(forKey: BrowserLinkOpenSettings.browserHostWhitelistKey) == "localhost")
            #expect(defaults.string(forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey) == "external.invalid")
        }
    }

    private func withConfig(
        value: Any,
        body: (UserDefaults, CmuxSettingsFileStore, URL) throws -> Void
    ) throws {
        let suite = "terminal-link-config-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let config: [String: Any] = ["browser": [
            "terminalLinkBrowserPlacement": value,
            "interceptTerminalOpenCommandInCmuxBrowser": false,
            "hostsToOpenInEmbeddedBrowser": ["localhost"],
            "urlsToAlwaysOpenExternally": ["external.invalid"],
        ]]
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        let store = CmuxSettingsFileStore(
            primaryPath: file.path, fallbackPath: nil, additionalFallbackPaths: [],
            userDefaults: defaults, startWatching: false
        )
        try body(defaults, store, file)
    }
}
