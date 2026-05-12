import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSpaceKeyTests: XCTestCase {
    func testShortcutConfigParsingRoundTripsSpaceKey() throws {
        let spaceKeyCode = UInt16(0x31)
        let shortcut = try XCTUnwrap(StoredShortcut.parseConfig("cmd+shift+space"))

        XCTAssertEqual(shortcut.key, "space")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
        XCTAssertEqual(
            shortcut.firstStroke.resolvedKeyCode { keyCode, _ in
                keyCode == spaceKeyCode ? " " : nil
            },
            spaceKeyCode
        )
        XCTAssertEqual(shortcut.configIdentifier, "cmd+shift+space")
        XCTAssertTrue(
            shortcut.matches(
                keyCode: spaceKeyCode,
                modifierFlags: [.command, .shift],
                eventCharacter: " "
            )
        )

        for rawShortcut in ["space", "cmd+space", "shift+space", "cmd+shift+space", "ctrl+space", "opt+space"] {
            let parsedShortcut = try XCTUnwrap(StoredShortcut.parseConfig(rawShortcut))
            XCTAssertEqual(parsedShortcut.key, "space")
            XCTAssertEqual(parsedShortcut.firstStroke.resolvedKeyCode(), spaceKeyCode)
            XCTAssertEqual(parsedShortcut.configIdentifier, rawShortcut)
        }

        XCTAssertEqual(StoredShortcut.parseConfig("cmd+shift+Space")?.configIdentifier, "cmd+shift+space")
        XCTAssertEqual(StoredShortcut.parseConfig("cmd+shift+<space>")?.configIdentifier, "cmd+shift+space")
        XCTAssertEqual(StoredShortcut.parseConfig("cmd+shift+<Space>")?.configIdentifier, "cmd+shift+space")
        XCTAssertEqual(StoredShortcut.parseConfig("cmd+shift+spacebar")?.configIdentifier, "cmd+shift+space")
        XCTAssertEqual(StoredShortcut.parseConfig("cmd+shift+ ")?.configIdentifier, "cmd+shift+space")
        XCTAssertEqual(StoredShortcut.parseConfig(" ")?.configIdentifier, "space")
    }

    func testShortcutConfigParsingRoundTripsPageKeys() throws {
        let pageUpKeyCode = UInt16(116)
        let pageDownKeyCode = UInt16(121)

        let pageUpShortcut = try XCTUnwrap(StoredShortcut.parseConfig("ctrl+page_up"))
        XCTAssertEqual(pageUpShortcut.key, "pageUp")
        XCTAssertFalse(pageUpShortcut.command)
        XCTAssertFalse(pageUpShortcut.shift)
        XCTAssertFalse(pageUpShortcut.option)
        XCTAssertTrue(pageUpShortcut.control)
        XCTAssertEqual(pageUpShortcut.firstStroke.resolvedKeyCode(), pageUpKeyCode)
        XCTAssertEqual(pageUpShortcut.configIdentifier, "ctrl+pageUp")
        XCTAssertTrue(
            pageUpShortcut.matches(
                keyCode: pageUpKeyCode,
                modifierFlags: [.control, .function],
                eventCharacter: String(UnicodeScalar(NSPageUpFunctionKey)!)
            )
        )

        let pageDownShortcut = try XCTUnwrap(StoredShortcut.parseConfig("ctrl+page_down"))
        XCTAssertEqual(pageDownShortcut.key, "pageDown")
        XCTAssertEqual(pageDownShortcut.firstStroke.resolvedKeyCode(), pageDownKeyCode)
        XCTAssertEqual(pageDownShortcut.configIdentifier, "ctrl+pageDown")
        XCTAssertTrue(
            pageDownShortcut.matches(
                keyCode: pageDownKeyCode,
                modifierFlags: [.control, .function],
                eventCharacter: String(UnicodeScalar(NSPageDownFunctionKey)!)
            )
        )

        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+pageup")?.configIdentifier, "ctrl+pageUp")
        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+page-up")?.configIdentifier, "ctrl+pageUp")
        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+<pageup>")?.configIdentifier, "ctrl+pageUp")
        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+pagedown")?.configIdentifier, "ctrl+pageDown")
        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+page-down")?.configIdentifier, "ctrl+pageDown")
        XCTAssertEqual(StoredShortcut.parseConfig("ctrl+<pagedown>")?.configIdentifier, "ctrl+pageDown")
    }

    func testSettingsFileStoreParsesSpaceShortcutBinding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "toggleSplitZoom": "cmd+shift+space"
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .toggleSplitZoom),
            StoredShortcut(key: "space", command: true, shift: true, option: false, control: false)
        )
    }
}
