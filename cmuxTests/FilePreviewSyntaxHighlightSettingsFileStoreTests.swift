import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File preview syntax highlight settings file store", .serialized)
struct FilePreviewSyntaxHighlightSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test("Settings file parses file editor syntax highlighting")
    func settingsFileParsesFileEditorSyntaxHighlighting() throws {
        let defaults = UserDefaults.standard

        try preservingDefaults(keys: [
            FilePreviewSyntaxHighlightSettings.key,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey
        ]) {
            defaults.removeObject(forKey: FilePreviewSyntaxHighlightSettings.key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            #expect(FilePreviewSyntaxHighlightSettings.isEnabled(defaults: defaults))

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "fileEditor": {
                    "syntaxHighlighting": false
                  }
                }
                """,
                to: settingsFileURL
            )

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            withExtendedLifetime(store) {
                #expect(!defaults.bool(forKey: FilePreviewSyntaxHighlightSettings.key))
                #expect(!FilePreviewSyntaxHighlightSettings.isEnabled(defaults: defaults))
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-syntax-highlight-settings-\(UUID().uuidString)",
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
