import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DiffViewerShortcutSettingsTests: XCTestCase {
    func testDiffViewerContentShortcutsUseBrowserScopedDefaults() {
        let expected: [(KeyboardShortcutSettings.Action, StoredShortcut)] = [
            (.diffViewerScrollHalfPageDown, StoredShortcut(key: "d", command: false, shift: false, option: false, control: true)),
            (.diffViewerScrollHalfPageUp, StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)),
            (.diffViewerSelectNextFile, StoredShortcut(key: "n", command: false, shift: false, option: false, control: true)),
            (.diffViewerSelectPreviousFile, StoredShortcut(key: "p", command: false, shift: false, option: false, control: true)),
        ]

        for (action, shortcut) in expected {
            XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: action), shortcut, action.rawValue)
            XCTAssertEqual(action.normalizedRecordedShortcutResult(shortcut), .accepted(shortcut), action.rawValue)
            XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(action), action.rawValue)
            XCTAssertEqual(action.defaultWhenClause, .atom(.browserFocus), action.rawValue)
        }

        XCTAssertEqual(KeyboardShortcutSettings.Action.commandPaletteNext.defaultWhenClause, .key("commandPaletteVisible"))
        XCTAssertEqual(KeyboardShortcutSettings.Action.commandPalettePrevious.defaultWhenClause, .key("commandPaletteVisible"))
    }
}
