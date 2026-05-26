import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GlobalSearchShortcutSettingsTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-shortcuts-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testGlobalSearchDefaultShortcutIsRemappableAndSystemWideSafe() {
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .globalSearch)

        XCTAssertEqual(
            defaultShortcut,
            StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        )
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.globalSearch))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.globalSearch))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .sendFeedback), .unbound)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(defaultShortcut),
            .accepted(defaultShortcut)
        )
    }

    func testGlobalSearchRejectsBareSystemWideShortcut() {
        let bareShortcut = StoredShortcut(key: "f", command: false, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(bareShortcut),
            .rejected(.systemWideHotkeyRequiresModifier)
        )
    }

    func testGlobalSearchRejectsConfiguredShowHideHotkeyConflict() {
        let reservedShortcut = StoredShortcut(key: "g", command: true, shift: false, option: true, control: true)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .globalSearch)
        SystemWideHotkeySettings.setShortcut(reservedShortcut)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(reservedShortcut),
            .rejected(.reservedBySystem)
        )
    }

    func testSettingsFileStoreParsesGlobalSearchShortcut() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": "cmd+ctrl+g"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .globalSearch),
            StoredShortcut(key: "g", command: true, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreRejectsGlobalSearchChordBinding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-invalid-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": ["cmd+k", "f"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(store.override(for: .globalSearch))
    }
}
