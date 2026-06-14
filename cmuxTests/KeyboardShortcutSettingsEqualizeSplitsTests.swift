import XCTest
import enum CmuxSettings.ShortcutAction

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsEqualizeSplitsTests: XCTestCase {
    func testSettingsPackageCatalogIncludesResizeSplitShortcutActions() {
        let expected: [(KeyboardShortcutSettings.Action, ShortcutAction)] = [
            (.resizeSplitLeft, .resizeSplitLeft),
            (.resizeSplitRight, .resizeSplitRight),
            (.resizeSplitUp, .resizeSplitUp),
            (.resizeSplitDown, .resizeSplitDown),
        ]

        let packageActions = Set(ShortcutAction.allCases)
        for (appAction, packageAction) in expected {
            XCTAssertTrue(packageActions.contains(packageAction))
            XCTAssertEqual(packageAction.rawValue, appAction.rawValue)
        }
    }

    func testResizeSplitDefaultsAreUnbound() {
        let expected: [KeyboardShortcutSettings.Action] = [
            .resizeSplitLeft,
            .resizeSplitRight,
            .resizeSplitUp,
            .resizeSplitDown,
        ]

        for action in expected {
            XCTAssertEqual(
                action.defaultShortcut,
                .unbound,
                "Expected \(action.rawValue) to be opt-in so Ctrl+B reaches the focused terminal"
            )
        }
    }

    func testSettingsFileStoreParsesEqualizeSplitsShortcut() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "equalizeSplits": "cmd+ctrl+e"
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
            store.override(for: .equalizeSplits),
            StoredShortcut(key: "e", command: true, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreParsesResizeSplitShortcutChord() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "bindings": {
                  "resizeSplitRight": ["ctrl+b", "alt+right"]
                }
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
            store.override(for: .resizeSplitRight),
            tmuxResizeShortcut(chordKey: "→")
        )
    }

    func testSettingsFileStoreParsesSystemWideHotkeyWithoutSharedStoreRecursion() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": "cmd+ctrl+."
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
            store.override(for: .showHideAllWindows),
            StoredShortcut(key: ".", command: true, shift: false, option: false, control: true)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }

    private func tmuxResizeShortcut(chordKey: String) -> StoredShortcut {
        StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: chordKey,
            chordCommand: false,
            chordShift: false,
            chordOption: true,
            chordControl: false
        )
    }
}
