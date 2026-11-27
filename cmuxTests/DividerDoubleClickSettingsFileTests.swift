import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Divider double click settings file")
struct DividerDoubleClickSettingsFileTests {
    @Test(arguments: [true, false])
    func parsesAndReloadsDividerDoubleClickSetting(enabled: Bool) throws {
        let suite = "divider-double-click-file-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let source = "{\"app\":{\"equalizeSplitsOnDividerDoubleClick\":\(enabled)}}"
        try Data(source.utf8).write(to: file)
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path, fallbackPath: nil, additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(), userDefaults: defaults,
            languageSettingsStore: LanguageSettingsStore(defaults: defaults, domainName: suite),
            startWatching: false
        )
        let key = SettingCatalog().app.equalizeSplitsOnDividerDoubleClick
        #expect(defaults.object(forKey: key.userDefaultsKey) as? Bool == enabled)
        #expect(KeyboardShortcutSettingsFileStore.supportedSettingsJSONPaths.contains(key.id))
        let updated = "{\"app\":{\"equalizeSplitsOnDividerDoubleClick\":\(!enabled)}}"
        try Data(updated.utf8).write(to: file)
        _ = store.reload()
        #expect(defaults.object(forKey: key.userDefaultsKey) as? Bool == !enabled)
        #expect(try String(contentsOf: file, encoding: .utf8) == updated)
    }
}
