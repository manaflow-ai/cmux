import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Sidebar metadata collapse settings file", .serialized)
@MainActor
struct SidebarMetadataCollapseSettingsFileTests {
    struct ParsingCase: Sendable, CustomTestStringConvertible {
        let jsonValue: String
        let expectedValue: Int?

        var testDescription: String {
            "\(jsonValue) → \(expectedValue.map(String.init) ?? "ignored")"
        }
    }

    private static let parsingCases = [
        ParsingCase(jsonValue: "6", expectedValue: 6),
        ParsingCase(jsonValue: "0", expectedValue: 0),
        ParsingCase(jsonValue: "null", expectedValue: 0),
        ParsingCase(jsonValue: "-1", expectedValue: nil),
        ParsingCase(jsonValue: "1.5", expectedValue: nil),
        ParsingCase(jsonValue: "true", expectedValue: nil),
    ]

    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test(arguments: parsingCases)
    func parsesMetadataCollapseLimit(_ parsingCase: ParsingCase) throws {
        let defaults = UserDefaults.standard
        let key = "sidebarMetadataCollapseLimit"

        try preservingDefaults(keys: [
            key,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "sidebarAppearance": {
                "metadataCollapseLimit": \(parsingCase.jsonValue)
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.object(forKey: key) as? Int == parsingCase.expectedValue)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-metadata-collapse-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
