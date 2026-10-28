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
@MainActor
@Suite("TextBox new-terminal settings file precedence", .serialized)
struct TerminalTextBoxSettingsFilePrecedenceTests {
    private let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
    private let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey

    @Test
    func settingsFileWinsOverDivergedDefaultsAtLaunch() async throws {
        try await withSettingsFile { defaults, settingsFileURL in
            _ = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)
            #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
            #expect(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))

            // A Settings toggle or `defaults write` leaves app defaults behind
            // the unchanged cmux.json value.
            divergeDefaults(defaults)

            // Relaunch: a fresh store resolves the same file.
            _ = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)

            expectFileValuesApplied(defaults)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reloadConfigAppliesUnchangedSettingsFileOverDivergedDefaults() async throws {
        try await withSettingsFile { defaults, settingsFileURL in
            let notificationCenter = NotificationCenter()
            let store = makeStore(
                settingsFileURL: settingsFileURL,
                defaults: defaults,
                notificationCenter: notificationCenter,
                startWatching: true
            )
            try await withInstalledSettingsFileStore(store) {
                divergeDefaults(defaults)

                // Passive replay runs on the main queue; drain it before
                // checking that an in-session Settings change survives (#3844).
                notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
                await drainMainQueue()
                expectDivergedValuesKept(defaults)

                // A Settings-driven Ghostty reload keeps the Settings change.
                await awaitReloadCommit { commitCompletion in
                    GhosttyApp.shared.reloadConfiguration(
                        source: "settings.terminal.ghosttyOption",
                        commitCompletion: commitCompletion
                    )
                }
                expectDivergedValuesKept(defaults)

                // `cmux reload-config` reloads the unchanged file.
                await awaitReloadCommit { commitCompletion in
                    TerminalController.shared.controlSidebarReloadConfigWithAdmission(
                        commitCompletion: commitCompletion
                    )
                }

                expectFileValuesApplied(defaults)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func fileWatcherReappliesUnchangedTextBoxSettings() async throws {
        try await withSettingsFile { defaults, settingsFileURL in
            let (events, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let store = makeStore(
                settingsFileURL: settingsFileURL,
                defaults: defaults,
                startWatching: true,
                onWatchedFileReload: { _ in continuation.yield() }
            )

            divergeDefaults(defaults)
            // Rewriting the same values must still apply file authority.
            try #"{"terminal":{"showTextBoxOnNewTerminals":true,"focusTextBoxOnNewTerminals":true}}"#
                .write(to: settingsFileURL, atomically: true, encoding: .utf8)
            for await _ in events { break }
            expectFileValuesApplied(defaults)
            withExtendedLifetime(store) {}
        }
    }

    @Test
    func removingKeyFromSettingsFileRestoresSettingsValue() async throws {
        try await withSettingsFile(initialDefaults: false) { defaults, settingsFileURL in
            let store = makeStore(settingsFileURL: settingsFileURL, defaults: defaults)
            expectFileValuesApplied(defaults)

            try #"{"terminal":{}}"#.write(to: settingsFileURL, atomically: true, encoding: .utf8)
            store.reload(appliesFileAuthoritativeKeys: true)

            expectDivergedValuesKept(defaults)
        }
    }

    private func divergeDefaults(_ defaults: UserDefaults) {
        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)
    }

    private func expectFileValuesApplied(
        _ defaults: UserDefaults,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults), sourceLocation: sourceLocation)
        #expect(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults), sourceLocation: sourceLocation)
    }

    private func expectDivergedValuesKept(
        _ defaults: UserDefaults,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(defaults.object(forKey: showKey) as? Bool == false, sourceLocation: sourceLocation)
        #expect(defaults.object(forKey: focusKey) as? Bool == false, sourceLocation: sourceLocation)
    }

    /// Returns once the reload's settings step ran: the commit callback fires
    /// after it whether or not the Ghostty configuration commits.
    private func awaitReloadCommit(
        _ enqueue: (@escaping GhosttyApp.ConfigurationReloadCommitCompletion) -> Bool
    ) async {
        await withCheckedContinuation { continuation in
            let admitted = enqueue { _ in continuation.resume() }
            // A rejected callback is never retained, so it never runs.
            #expect(admitted)
            if !admitted { continuation.resume() }
        }
    }

    /// Runs after every block already queued on the main queue.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeStore(
        settingsFileURL: URL,
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = NotificationCenter(),
        startWatching: Bool = false,
        onWatchedFileReload: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) -> KeyboardShortcutSettingsFileStore {
        KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: notificationCenter,
            userDefaults: defaults,
            startWatching: startWatching,
            isUserDefaultsKeyForcedByProfile: { _ in false },
            onWatchedFileReload: onWatchedFileReload
        )
    }

    private func withInstalledSettingsFileStore(
        _ store: KeyboardShortcutSettingsFileStore,
        _ body: () async throws -> Void
    ) async rethrows {
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = store
        defer { KeyboardShortcutSettings.settingsFileStore = originalStore }
        try await body()
    }

    private func withSettingsFile(
        initialDefaults: Bool? = nil,
        _ body: (UserDefaults, URL) async throws -> Void
    ) async throws {
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
        try #"{"terminal":{"showTextBoxOnNewTerminals":true,"focusTextBoxOnNewTerminals":true}}"#
            .write(to: settingsFileURL, atomically: true, encoding: .utf8)
        try await body(defaults, settingsFileURL)
    }
}
