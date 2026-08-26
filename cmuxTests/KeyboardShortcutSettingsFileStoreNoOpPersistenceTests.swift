import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct KeyboardShortcutSettingsFileStoreNoOpPersistenceTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func preservesSemanticallyEqualLegacyPersistenceWithoutUserDefaultsWrites() async throws {
        let defaultsSuiteName = "KeyboardShortcutSettingsFileStoreNoOpPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let scrollBarKey = TerminalScrollBarSettings.showScrollBarKey
        let autoResumeKey = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let legacySidebarKey = SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey

        defaults.set(false, forKey: scrollBarKey)
        defaults.set(false, forKey: autoResumeKey)
        defaults.removeObject(forKey: legacySidebarKey)

        // Older cmux versions encoded these dictionaries without sorted keys. The whitespace
        // and descending key order make the bytes intentionally non-canonical while preserving
        // the same decoded values as the settings file below.
        let legacyImportedData = Data(
            """
            {
              "\(scrollBarKey)": {"bool":{"_0":false}},
              "\(autoResumeKey)": {"bool":{"_0":false}}
            }
            """.utf8
        )
        let legacyBackupsData = Data(
            """
            {
              "\(scrollBarKey)": {"kind":"absent"},
              "\(autoResumeKey)": {"kind":"absent"}
            }
            """.utf8
        )
        defaults.set(legacyImportedData, forKey: importedManagedDefaultsKey)
        defaults.set(legacyBackupsData, forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "terminal": {
                "showScrollBar": false,
                "autoResumeAgentSessions": false
              }
            }
            """,
            to: settingsFileURL
        )

        await confirmation(expectedCount: 0) { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { _ in
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                notificationCenter: NotificationCenter(),
                userDefaults: defaults,
                languageSettingsStore: LanguageSettingsStore(defaults: defaults, domainName: defaultsSuiteName),
                startWatching: false
            )
        }

        #expect(defaults.data(forKey: importedManagedDefaultsKey) == legacyImportedData)
        #expect(defaults.data(forKey: settingsFileBackupsDefaultsKey) == legacyBackupsData)
    }

    @MainActor
    @Test
    func languageResetRemovesOverrideFromInjectedDefaultsSuite() throws {
        let defaultsSuiteName = "KeyboardShortcutSettingsFileStoreLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "language": "ja"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            languageSettingsStore: LanguageSettingsStore(defaults: defaults, domainName: defaultsSuiteName),
            startWatching: false
        )
        store.applyDeferredManagedDefaultSideEffects()

        #expect(defaults.persistentDomain(forName: defaultsSuiteName)?["AppleLanguages"] as? [String] == ["ja"])
        #expect(defaults.persistentDomain(forName: defaultsSuiteName)?["appLanguageAppliedOverride"] as? String == "ja")

        try writeSettingsFile(
            """
            {
              "app": {
                "language": "system"
              }
            }
            """,
            to: settingsFileURL
        )
        store.reload()

        #expect(defaults.persistentDomain(forName: defaultsSuiteName)?["AppleLanguages"] == nil)
        #expect(defaults.persistentDomain(forName: defaultsSuiteName)?["appLanguageAppliedOverride"] == nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-no-op-persistence-\(UUID().uuidString)",
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

}
