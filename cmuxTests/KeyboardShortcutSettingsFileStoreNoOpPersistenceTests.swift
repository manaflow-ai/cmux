import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// `queue: nil` delivers these notifications synchronously on the test thread.
private final class SettingsStoreUserDefaultsNotificationCounter: @unchecked Sendable {
    var count = 0
}

@Suite(.serialized)
struct KeyboardShortcutSettingsFileStoreNoOpPersistenceTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func preservesSemanticallyEqualLegacyPersistenceWithoutUserDefaultsWrites() throws {
        let defaults = UserDefaults.standard
        let scrollBarKey = TerminalScrollBarSettings.showScrollBarKey
        let autoResumeKey = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let legacySidebarKey = SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey

        try preservingDefaults(keys: [
            scrollBarKey,
            autoResumeKey,
            legacySidebarKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
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

            let notificationCounter = SettingsStoreUserDefaultsNotificationCounter()
            let observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { _ in
                notificationCounter.count += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                notificationCenter: NotificationCenter(),
                startWatching: false
            )

            #expect(notificationCounter.count == 0)
            #expect(defaults.data(forKey: importedManagedDefaultsKey) == legacyImportedData)
            #expect(defaults.data(forKey: settingsFileBackupsDefaultsKey) == legacyBackupsData)
        }
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
}
