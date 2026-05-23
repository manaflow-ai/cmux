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
        UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.legacyGlobalSearchDefaultsKey)
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-search-all-panels-shortcuts-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.legacyGlobalSearchDefaultsKey)
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testSearchAllPanelsDefaultShortcutIsRightSidebarCommandShiftF() {
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .searchAllPanels)

        XCTAssertEqual(
            defaultShortcut,
            StoredShortcut(key: "f", command: true, shift: true, option: false, control: false)
        )
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.searchAllPanels))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.searchAllPanels))
        XCTAssertFalse(KeyboardShortcutSettings.Action.allCases.map(\.rawValue).contains("globalSearch"))
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.searchAllPanels.normalizedRecordedShortcutResult(defaultShortcut),
            .accepted(defaultShortcut)
        )
    }

    func testSearchAllPanelsDefaultDoesNotShadowExplicitLegacyFindInDirectoryShortcut() {
        let legacyFindShortcut = StoredShortcut(key: "f", command: true, shift: true, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(legacyFindShortcut, for: .findInDirectory)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .findInDirectory), legacyFindShortcut)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .searchAllPanels), .unbound)

        KeyboardShortcutSettings.setShortcut(legacyFindShortcut, for: .searchAllPanels)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .searchAllPanels), legacyFindShortcut)
    }

    func testLegacyGlobalSearchUserDefaultsShortcutMigratesToSearchAllPanels() throws {
        let legacyShortcut = StoredShortcut(key: "k", command: true, shift: true, option: false, control: true)
        let legacyData = try JSONEncoder().encode(legacyShortcut)
        UserDefaults.standard.set(legacyData, forKey: KeyboardShortcutSettings.legacyGlobalSearchDefaultsKey)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .searchAllPanels), legacyShortcut)

        let newShortcut = StoredShortcut(key: "j", command: true, shift: true, option: false, control: true)
        KeyboardShortcutSettings.setShortcut(newShortcut, for: .searchAllPanels)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .searchAllPanels), newShortcut)

        KeyboardShortcutSettings.resetShortcut(for: .searchAllPanels)

        XCTAssertNil(UserDefaults.standard.object(forKey: KeyboardShortcutSettings.legacyGlobalSearchDefaultsKey))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .searchAllPanels), KeyboardShortcutSettings.Action.searchAllPanels.defaultShortcut)
    }

    func testSettingsFileStoreParsesSearchAllPanelsShortcut() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-search-all-panels-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "searchAllPanels": "cmd+ctrl+g"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .searchAllPanels),
            StoredShortcut(key: "g", command: true, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreParsesLegacyGlobalSearchShortcutAsSearchAllPanels() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-legacy-global-search-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": "cmd+ctrl+h"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .searchAllPanels),
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true)
        )
    }
}
