import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        KeyboardShortcutSettings.resetShortcut(for: .toggleSplitZoom)
    }
    func testShortcutDefaultKeysAreUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testToggleSplitZoomShortcutIsUnsetByDefault() {
        KeyboardShortcutSettings.resetShortcut(for: .toggleSplitZoom)
        XCTAssertNil(KeyboardShortcutSettings.toggleSplitZoomShortcut())
    }

    func testToggleSplitZoomShortcutCanBeSetAndCleared() {
        KeyboardShortcutSettings.resetShortcut(for: .toggleSplitZoom)

        let shortcut = StoredShortcut(key: "z", command: true, shift: false, option: true, control: false)
        KeyboardShortcutSettings.setOptionalShortcut(shortcut, for: .toggleSplitZoom)
        XCTAssertEqual(KeyboardShortcutSettings.toggleSplitZoomShortcut(), shortcut)

        KeyboardShortcutSettings.setOptionalShortcut(nil, for: .toggleSplitZoom)
        XCTAssertNil(KeyboardShortcutSettings.toggleSplitZoomShortcut())
    }
}
