import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux.json owns `terminal.showTextBoxOnNewTerminals` and
/// `terminal.focusTextBoxOnNewTerminals`: a stale app-defaults value must not
/// hide the file's value at launch or after `cmux reload-config` (#26540).
@Suite("TextBox new-terminal settings file precedence", .serialized)
struct TerminalTextBoxSettingsFilePrecedenceTests {
    private let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
    private let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey

    @Test
    func settingsFileWinsOverDivergedDefaultsAtLaunch() throws {
        try withSettingsFile(show: true, focus: true) { defaults, settingsFileURL in
            _ = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)
            #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
            #expect(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))

            // A Settings toggle or `defaults write` leaves app defaults behind
            // the unchanged cmux.json value.
            defaults.set(false, forKey: showKey)
            defaults.set(false, forKey: focusKey)

            // Relaunch: a fresh store resolves the same file.
            _ = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)

            #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
            #expect(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))
        }
    }

    @Test
    func reloadAppliesUnchangedSettingsFileOverDivergedDefaults() throws {
        try withSettingsFile(show: true, focus: true) { defaults, settingsFileURL in
            let notificationCenter = NotificationCenter()
            let store = makeStore(
                settingsFileURL: settingsFileURL,
                defaults: defaults,
                notificationCenter: notificationCenter,
                startWatching: true
            )
            withExtendedLifetime(store) {
                defaults.set(false, forKey: showKey)
                defaults.set(false, forKey: focusKey)

                // Passive replay keeps an in-session Settings change (#3844).
                notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
                #expect(!TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
                #expect(!TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))

                // `cmux reload-config` reloads the unchanged file.
                store.reload()

                #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
                #expect(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))
            }
        }
    }

    @Test
    func removingKeyFromSettingsFileRestoresSettingsValue() throws {
        try withSettingsFile(show: true, focus: true, initialDefaults: false) { defaults, settingsFileURL in
            let store = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)
            #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))

            try #"{"terminal":{}}"#.write(to: settingsFileURL, atomically: true, encoding: .utf8)
            store.reload()

            #expect(defaults.object(forKey: showKey) as? Bool == false)
            #expect(defaults.object(forKey: focusKey) as? Bool == false)
        }
    }

    private func makeStore(
        settingsFileURL: URL,
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = NotificationCenter(),
        startWatching: Bool = false
    ) -> KeyboardShortcutSettingsFileStore {
        KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: notificationCenter,
            userDefaults: defaults,
            startWatching: startWatching,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
    }

    private func withSettingsFile(
        show: Bool,
        focus: Bool,
        initialDefaults: Bool? = nil,
        _ body: (UserDefaults, URL) throws -> Void
    ) throws {
        let suiteName = "cmux-textbox-settings-precedence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let initialDefaults {
            defaults.set(initialDefaults, forKey: showKey)
            defaults.set(initialDefaults, forKey: focusKey)
        }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-textbox-precedence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try #"{"terminal":{"showTextBoxOnNewTerminals":\#(show),"focusTextBoxOnNewTerminals":\#(focus)}}"#
            .write(to: settingsFileURL, atomically: true, encoding: .utf8)
        try body(defaults, settingsFileURL)
    }
}
