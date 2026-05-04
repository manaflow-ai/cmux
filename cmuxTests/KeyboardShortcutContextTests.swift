import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutContextTests: XCTestCase {
    func testRenameTabAndBrowserReloadCanShareDefaultChordAcrossContexts() {
        let renameTabShortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut

        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.shortcutContext, .nonBrowserPanel)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.shortcutContext, .browserPanel)
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: KeyboardShortcutSettings.Action.browserReload.defaultShortcut,
                proposedAction: .browserReload,
                configuredShortcut: renameTabShortcut
            )
        )
    }

    func testRenameWorkspaceIsScopedOutsideBrowserPanels() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.shortcutContext, .nonBrowserPanel)
    }

    func testReactGrabStaysApplicationScopedForTerminalPastebackRouting() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleReactGrab.shortcutContext, .application)
    }

    func testShortcutSettingsFilePreservesConfiguredShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newWindow),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-context-\(UUID().uuidString)", isDirectory: true)
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
