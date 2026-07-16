import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Sidebar state indicator colors settings file", .serialized)
struct SidebarStateIndicatorColorsSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    private let runningKey = SidebarCatalogSection().stateIndicatorRunningColorHex.userDefaultsKey
    private let needsInputKey = SidebarCatalogSection().stateIndicatorNeedsInputColorHex.userDefaultsKey
    private let idleKey = SidebarCatalogSection().stateIndicatorIdleColorHex.userDefaultsKey

    @Test
    func settingsFileStoreAppliesConfiguredStateColors() throws {
        try loadSettings(stateIndicatorColorsJSON: """
        {
          "running": "#FF9500",
          "needsInput": "#FF3B30",
          "idle": "#8E8E93"
        }
        """) { defaults in
            #expect(defaults.string(forKey: runningKey) == "#FF9500")
            #expect(defaults.string(forKey: needsInputKey) == "#FF3B30")
            #expect(defaults.string(forKey: idleKey) == "#8E8E93")
        }
    }

    @Test
    func settingsFileStoreNormalizesCaseAndMissingHash() throws {
        // Values round-trip through WorkspaceTabColorSettings.normalizedHex:
        // lowercase is uppercased and a missing leading "#" is added.
        try loadSettings(stateIndicatorColorsJSON: """
        {
          "running": "#ff9500",
          "needsInput": "4c8dff"
        }
        """) { defaults in
            #expect(defaults.string(forKey: runningKey) == "#FF9500")
            #expect(defaults.string(forKey: needsInputKey) == "#4C8DFF")
            #expect(defaults.string(forKey: idleKey) == nil)
        }
    }

    @Test
    func settingsFileStoreClearsColorOnExplicitNull() throws {
        try loadSettings(
            presetDefaults: [runningKey: "#123456"],
            stateIndicatorColorsJSON: """
            {
              "running": null
            }
            """
        ) { defaults in
            #expect(defaults.string(forKey: runningKey) == nil)
        }
    }

    @Test
    func settingsFileStoreIgnoresInvalidValues() throws {
        // Non-hex strings, wrong lengths, and non-string values are logged
        // as invalid and leave the stored value untouched.
        try loadSettings(
            presetDefaults: [runningKey: "#123456"],
            stateIndicatorColorsJSON: """
            {
              "running": "#GGGGGG",
              "needsInput": "#FFF",
              "idle": 42
            }
            """
        ) { defaults in
            #expect(defaults.string(forKey: runningKey) == "#123456")
            #expect(defaults.string(forKey: needsInputKey) == nil)
            #expect(defaults.string(forKey: idleKey) == nil)
        }
    }

    @Test
    func settingsFileStoreLeavesUnmentionedStatesUntouched() throws {
        try loadSettings(
            presetDefaults: [idleKey: "#123456"],
            stateIndicatorColorsJSON: """
            {
              "running": "#FF9500"
            }
            """
        ) { defaults in
            #expect(defaults.string(forKey: runningKey) == "#FF9500")
            #expect(defaults.string(forKey: needsInputKey) == nil)
            #expect(defaults.string(forKey: idleKey) == "#123456")
        }
    }

    private func loadSettings(
        presetDefaults: [String: String] = [:],
        stateIndicatorColorsJSON: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            runningKey,
            needsInputKey,
            idleKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            for (key, value) in presetDefaults {
                defaults.set(value, forKey: key)
            }

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "sidebar": {
                "stateIndicatorColors": \(stateIndicatorColorsJSON)
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
            "cmux-state-indicator-colors-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
