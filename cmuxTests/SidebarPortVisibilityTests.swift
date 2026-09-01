import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar port visibility", .serialized)
struct SidebarPortVisibilityTests {
    @Test("Default policy excludes the OS ephemeral range without discarding observations")
    func defaultPolicyExcludesEphemeralRangeWithoutDiscardingObservations() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(settings: UserDefaultsSettingsClient(defaults: defaults))
        let panelID = try #require(workspace.focusedPanelId)
        let panelPorts = [49_151, 49_152, 65_535]
        let agentPorts = [3_000, 63_315]

        workspace.surfaceListeningPorts[panelID] = panelPorts
        workspace.agentListeningPorts = agentPorts
        workspace.recomputeListeningPorts()

        #expect(workspace.surfaceListeningPorts[panelID] == panelPorts)
        #expect(workspace.agentListeningPorts == agentPorts)
        #expect(workspace.listeningPorts == [3_000, 49_151])
    }

    @Test("Settings notification republishes every raw observation for an empty override")
    func settingsNotificationRepublishesEveryRawObservationForEmptyOverride() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = SettingCatalog()
        let settings = UserDefaultsSettingsClient(defaults: defaults)

        let manager = TabManager(settings: settings)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.agentListeningPorts = [3_000, 49_152, 65_535]
        workspace.recomputeListeningPorts()

        #expect(workspace.listeningPorts == [3_000])

        settings.set([], for: catalog.sidebar.ignoredPorts)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: defaults
        )

        #expect(workspace.listeningPorts == [3_000, 49_152, 65_535])
    }

    @Test("Custom-sidebar surface snapshots apply the policy without discarding observations")
    func customSidebarSurfaceSnapshotsApplyPolicyWithoutDiscardingObservations() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(settings: UserDefaultsSettingsClient(defaults: defaults))
        let panelID = try #require(workspace.focusedPanelId)
        let observedPorts = [49_151, 49_152, 65_535]

        workspace.surfaceListeningPorts[panelID] = observedPorts
        workspace.recomputeListeningPorts()

        let snapshot = workspace.customSidebarWorkspaceSnapshot(
            index: 0,
            selectedId: workspace.id,
            unreadCount: 0
        )
        let surface = try #require(snapshot.surfaces.first { $0.panelId == panelID })

        #expect(surface.listeningPorts == [49_151])
        #expect(workspace.surfaceListeningPorts[panelID] == observedPorts)
    }

    @Test("cmux.json parses exact ports and inclusive ignored ranges")
    func settingsFileParsesExactPortsAndInclusiveRanges() throws {
        let catalog = SettingCatalog()
        let key = catalog.sidebar.ignoredPorts
        try preservingStandardDefaults(keys: [
            key.userDefaultsKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]) {
            let directoryURL = FileManager.default.temporaryDirectory
                .appending(path: "cmux-sidebar-port-settings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appending(path: "cmux.json")
            try """
            {
              "sidebar": {
                "ignoredPorts": [24678, "49152-65535"]
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )
            let exactPort = try #require(SidebarIgnoredPortRule(port: 24_678))
            let ephemeralRange = try #require(
                SidebarIgnoredPortRule(range: 49_152...65_535)
            )

            #expect(UserDefaultsSettingsClient(defaults: .standard).value(for: key) == [
                exactPort,
                ephemeralRange,
            ])
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "cmux-sidebar-port-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func preservingStandardDefaults(
        keys: [String],
        _ body: () throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }
}
