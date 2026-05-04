import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsFileStoreRegressionTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testParsesNumberedBindingsWithoutConsultingActiveStoreConflicts() throws {
        let activeDirectoryURL = try makeTemporaryDirectory()
        let candidateDirectoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: activeDirectoryURL)
            try? FileManager.default.removeItem(at: candidateDirectoryURL)
        }

        let activeSettingsFileURL = activeDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "openBrowser": "cmd+3"
              }
            }
            """,
            to: activeSettingsFileURL
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: activeSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.settingsFileStore.override(for: .openBrowser),
            StoredShortcut(key: "3", command: true, shift: false, option: false, control: false)
        )

        let candidateSettingsFileURL = candidateDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "selectWorkspaceByNumber": "cmd+2"
              }
            }
            """,
            to: candidateSettingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: candidateSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
