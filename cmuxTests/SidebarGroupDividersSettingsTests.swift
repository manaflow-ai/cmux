import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux.json plumbing for `sidebar.groupDividers`: the real settings file
/// store must import it into the `sidebarGroupDividers` defaults the app
/// reads, the JSON path must map to that defaults key, and the embedded schema
/// must declare the path so `cmux set sidebar.groupDividers` is accepted.
/// Models `SidebarCompactAgentStatusTests`' precedent for a sidebar boolean.
@Suite("Sidebar group dividers settings file", .serialized)
struct SidebarGroupDividersSettingsTests {
    private static let groupDividersKey = "sidebarGroupDividers"
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private static let keys = [
        groupDividersKey,
        settingsFileBackupsDefaultsKey,
        importedManagedDefaultsKey
    ]

    @Test
    func turnsGroupDividersOff() throws {
        try loadSettingsFile(
            """
            {
              "sidebar": {
                "groupDividers": false
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: Self.groupDividersKey) as? Bool == false)
            #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).showsGroupDividers)
        }
    }

    @Test
    func turnsGroupDividersOn() throws {
        try loadSettingsFile(
            """
            {
              "sidebar": {
                "groupDividers": true
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: Self.groupDividersKey) as? Bool == true)
            #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).showsGroupDividers)
        }
    }

    @Test
    func staysOnWhenTheFileDoesNotMentionIt() throws {
        try loadSettingsFile("{}") { defaults in
            #expect(defaults.object(forKey: Self.groupDividersKey) == nil)
            #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).showsGroupDividers)
        }
    }

    @Test
    func jsonKeyMapsToTheDefaultsKey() {
        let mapping = SidebarSettingsFileMapping.booleanSettings.first { $0.jsonKey == "groupDividers" }
        #expect(mapping?.defaultsKey == Self.groupDividersKey)
        #expect(SidebarWorkspaceDetailDefaults.groupDividersKey == Self.groupDividersKey)
    }

    @Test
    func embeddedSchemaDeclaresThePathWithDefaultOn() {
        let lookup = CmuxConfigSchemaPathLookup()
        #expect(lookup.isDeclared(["sidebar", "groupDividers"]))
        #expect((lookup.defaultValue(at: ["sidebar", "groupDividers"]) as? NSNumber)?.boolValue == true)
    }

    private func loadSettingsFile(_ contents: String, verify: (UserDefaults) -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-group-dividers-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        verify(defaults)
    }
}
