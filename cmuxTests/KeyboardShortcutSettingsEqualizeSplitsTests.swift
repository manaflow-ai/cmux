import XCTest
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsEqualizeSplitsTests: XCTestCase {
    func testSettingsFileStoreParsesEqualizeSplitsShortcut() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "equalizeSplits": "cmd+ctrl+e"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .equalizeSplits),
            StoredShortcut(key: "e", command: true, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreParsesSystemWideHotkeyWithoutSharedStoreRecursion() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": "cmd+ctrl+."
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showHideAllWindows),
            StoredShortcut(key: ".", command: true, shift: false, option: false, control: true)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }
}

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
