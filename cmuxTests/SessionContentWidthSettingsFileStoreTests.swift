import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session content width settings file", .serialized)
struct SessionContentWidthSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesWidthAndAlignment() throws {
        try loadSettings(maxWidthJSON: "1111", alignmentJSON: "\"right\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 1120
            )
            #expect(
                defaults.string(forKey: SessionContentWidthSettings.alignmentKey) ==
                    SessionContentAlignment.right.rawValue
            )
        }
    }

    @Test
    func settingsFileStoreDisablesWidthCapWithFalse() throws {
        try loadSettings(maxWidthJSON: "false", alignmentJSON: "\"center\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) ==
                    SessionContentWidthSettings.noMaximumWidth
            )
        }
    }

    @Test
    func settingsFileStoreAcceptsWidthAboveLegacyLimit() throws {
        try loadSettings(maxWidthJSON: "10000", alignmentJSON: "\"center\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 10_000
            )
        }
    }

    @Test
    func settingsFileStoreReloadAppliesCanonicalTerminalGuardrailSetting() throws {
        let suiteName = "cmux-session-content-width-guardrail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try #"{"terminal":{"runawayMemoryGuardrail":{"enabled":false,"thresholdGB":8}}}"#
            .write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: false
        )
        let terminal = TerminalCatalogSection()
        #expect(defaults.bool(forKey: terminal.runawayMemoryGuardrailEnabled.userDefaultsKey) == false)

        try #"{"terminal":{"runawayMemoryGuardrail":{"enabled":true,"thresholdGB":12}}}"#
            .write(to: settingsFileURL, atomically: true, encoding: .utf8)
        store.reload()

        #expect(defaults.bool(forKey: terminal.runawayMemoryGuardrailEnabled.userDefaultsKey))
        #expect(defaults.double(forKey: terminal.runawayMemoryGuardrailThresholdGB.userDefaultsKey) == 12)
    }

    /// Runs off the main actor on purpose: Swift Testing's cooperative threads
    /// have 512 KB stacks, which the integrations parser overflowed in -Onone
    /// builds while it built a `SettingCatalog()` per key (#17446).
    @Test
    func settingsFileStoreAppliesCanonicalIntegrationHooks() throws {
        let suiteName = "cmux-session-content-width-integrations-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try #"{"integrations":{"claudeCode":{"hooksEnabled":false,"customClaudePath":"/opt/claude"},"kiro":{"notificationLevel":"verbose"}}}"#
            .write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: false
        )

        let integrations = IntegrationsCatalogSection()
        #expect(defaults.bool(forKey: integrations.claudeCodeHooksEnabled.userDefaultsKey) == false)
        #expect(defaults.string(forKey: integrations.claudeCodeCustomClaudePath.userDefaultsKey) == "/opt/claude")
        #expect(defaults.string(forKey: integrations.kiroNotificationLevel.userDefaultsKey) == "verbose")
    }

    @Test
    func settingsFileStoreAppliesCanonicalBetaAndSidebarSettings() throws {
        let defaults = UserDefaults.standard
        let catalog = SettingCatalog()
        let keys = [
            catalog.betaFeatures.remoteTmux.userDefaultsKey,
            catalog.sidebar.branchVerticalLayout.userDefaultsKey,
            catalog.sidebar.activeTabIndicatorStyle.userDefaultsKey,
            catalog.sidebar.selectionColorHex.userDefaultsKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
        try preservingDefaults(keys: keys) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try ###"{"remoteTmux":{"beta":{"enabled":true}},"sidebar":{"branchVerticalLayout":false,"activeTabIndicatorStyle":"solidFill","selectionColor":"#123456"}}"###
                .write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.bool(forKey: catalog.betaFeatures.remoteTmux.userDefaultsKey))
            #expect(defaults.bool(forKey: catalog.sidebar.branchVerticalLayout.userDefaultsKey) == false)
            #expect(defaults.string(forKey: catalog.sidebar.activeTabIndicatorStyle.userDefaultsKey) == "solidFill")
            #expect(defaults.string(forKey: catalog.sidebar.selectionColorHex.userDefaultsKey) == "#123456")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func canonicalSidebarAndIntegrationEditsApplyThroughWatcher() async throws {
        let suite = "cmux-catalog-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let catalog = SettingCatalog()
        try #"{"sidebar":{"activeTabIndicatorStyle":"leftRail"},"integrations":{"codex":{"hooksEnabled":true}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let indicatorKey = catalog.sidebar.activeTabIndicatorStyle.userDefaultsKey
        let hooksKey = catalog.integrations.codexHooksEnabled.userDefaultsKey
        let (updates, continuation) = AsyncStream<(String?, Bool)>.makeStream()
        defer { continuation.finish() }
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            userDefaults: defaults,
            startWatching: true,
            onWatchedFileReload: { _ in
                continuation.yield((defaults.string(forKey: indicatorKey), defaults.bool(forKey: hooksKey)))
            }
        )
        #expect(defaults.string(forKey: catalog.sidebar.activeTabIndicatorStyle.userDefaultsKey) == "leftRail")
        try #"{"workspaceColors":{"indicatorStyle":"leftRail"},"sidebar":{"activeTabIndicatorStyle":"solidFill"},"automation":{"codexIntegration":true},"integrations":{"codex":{"hooksEnabled":false}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        var iterator = updates.makeAsyncIterator()
        let update = await iterator.next()
        #expect(update?.0 == "solidFill")
        #expect(update?.1 == false)
        #expect(defaults.string(forKey: catalog.sidebar.activeTabIndicatorStyle.userDefaultsKey) == "solidFill")
        #expect(store.configurationIssues.isEmpty)
        withExtendedLifetime(store) {}
    }

    private func loadSettings(
        maxWidthJSON: String,
        alignmentJSON: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            SessionContentWidthSettings.maxWidthKey,
            SessionContentWidthSettings.alignmentKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                "sessionContentMaxWidth": \(maxWidthJSON),
                "sessionContentAlignment": \(alignmentJSON)
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            try verify(defaults)
        }
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-session-content-width-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Session content width presentation")
struct SessionContentWidthPresentationTests {
    private let bounds = CGRect(x: 10, y: 20, width: 1000, height: 600)

    @Test
    func disabledPresentationUsesFullPaneBounds() {
        #expect(SessionContentWidthPresentation.disabled.contentFrame(in: bounds) == bounds)
    }

    @Test(arguments: [
        (SessionContentAlignment.left, 10.0),
        (SessionContentAlignment.center, 210.0),
        (SessionContentAlignment.right, 410.0),
    ])
    func cappedPresentationAlignsInsidePane(
        alignment: SessionContentAlignment,
        expectedX: CGFloat
    ) {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: 600,
            storedAlignment: alignment.rawValue
        )

        #expect(
            presentation.contentFrame(in: bounds) ==
                CGRect(x: expectedX, y: 20, width: 600, height: 600)
        )
    }

    @Test
    func narrowPaneUsesFullPaneBounds() {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: 1200,
            storedAlignment: SessionContentAlignment.right.rawValue
        )

        #expect(presentation.contentFrame(in: bounds) == bounds)
    }
}
