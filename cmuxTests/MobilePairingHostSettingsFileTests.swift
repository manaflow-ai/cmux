import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Mac reached only over SSH (a headless or remote Mac mini) cannot flip the
/// Settings > Mobile toggle, so cmux.json must be able to opt it in to iOS
/// pairing. The value has to reach the exact gate the pairing host reads.
@Suite("iOS pairing host in cmux.json")
struct MobilePairingHostSettingsFileTests {
    private let key = MobileHostService.listeningEnabledDefaultsKey

    @Test
    func settingsFileEnablesIOSPairingHost() throws {
        try withSettingsFile(#"{"mobile":{"iOSPairingHost":{"enabled":true}}}"#) { defaults, _, _ in
            #expect(defaults.object(forKey: key) as? Bool == true)
            #expect(MobileHostService.isListeningEnabled(defaults: defaults))
        }
    }

    @Test
    func settingsFileCanTurnIOSPairingHostOff() throws {
        try withSettingsFile(
            #"{"mobile":{"iOSPairingHost":{"enabled":false}}}"#,
            seed: { $0.set(true, forKey: key) }
        ) { defaults, _, _ in
            #expect(defaults.object(forKey: key) as? Bool == false)
            #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
        }
    }

    /// Removing the key from cmux.json hands the setting back to Settings.
    @Test
    func removingTheKeyRestoresThePreviousValue() throws {
        try withSettingsFile(#"{"mobile":{"iOSPairingHost":{"enabled":true}}}"#) { defaults, store, file in
            #expect(MobileHostService.isListeningEnabled(defaults: defaults))
            try Data(#"{"mobile":{}}"#.utf8).write(to: file)
            _ = store.reload()
            #expect(defaults.object(forKey: key) == nil)
            #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
        }
    }

    @Test
    func settingsFileIgnoresNonBooleanIOSPairingHost() throws {
        try withSettingsFile(#"{"mobile":{"iOSPairingHost":{"enabled":"yes"}}}"#) { defaults, store, _ in
            #expect(defaults.object(forKey: key) == nil)
            #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
            #expect(store.configurationIssues.contains { $0.contains("mobile.iOSPairingHost.enabled") })
        }
    }

    /// The schema allows an empty object, so it must not count as an invalid
    /// value (an invalid value freezes the whole file at its last good state).
    @Test
    func emptyIOSPairingHostObjectIsNotAnError() throws {
        try withSettingsFile(#"{"mobile":{"iOSPairingHost":{}}}"#) { defaults, store, _ in
            #expect(defaults.object(forKey: key) == nil)
            #expect(!store.configurationIssues.contains { $0.contains("iOSPairingHost") })
        }
    }

    private func withSettingsFile(
        _ contents: String,
        seed: (UserDefaults) -> Void = { _ in },
        _ body: (UserDefaults, KeyboardShortcutSettingsFileStore, URL) throws -> Void
    ) throws {
        let suite = "mobile-pairing-host-file-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        seed(defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try Data(contents.utf8).write(to: file)
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path, fallbackPath: nil, additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(), userDefaults: defaults,
            languageSettingsStore: LanguageSettingsStore(defaults: defaults, domainName: suite),
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
        try withExtendedLifetime(store) { try body(defaults, store, file) }
    }
}
