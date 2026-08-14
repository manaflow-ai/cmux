import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File preview syntax highlight settings file store")
struct FilePreviewSyntaxHighlightSettingsFileStoreTests {
    @Test("Settings file parses file editor syntax highlighting")
    func settingsFileParsesFileEditorSyntaxHighlighting() throws {
        let defaultsSuiteName = "com.cmuxterm.tests.file-preview-syntax.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

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
            defaults: defaults,
            startWatching: false
        )

        withExtendedLifetime(store) {
            #expect(defaults.object(forKey: FilePreviewSyntaxHighlightSettings.key) as? Bool == false)
            #expect(!FilePreviewSyntaxHighlightSettings.isEnabled(defaults: defaults))
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
}
