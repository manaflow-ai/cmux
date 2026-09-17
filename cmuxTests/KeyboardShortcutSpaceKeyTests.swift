import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct KeyboardShortcutSpaceKeyTests {
    @Test func shortcutConfigParsingRoundTripsReturnKey() throws {
        let shortcut = try #require(StoredShortcut.parseConfig("return", allowBareFirstStroke: true))

        #expect(shortcut.key == "\r")
        #expect(!shortcut.command)
        #expect(!shortcut.shift)
        #expect(!shortcut.option)
        #expect(!shortcut.control)
        #expect(shortcut.configIdentifier == "return")
        #expect(StoredShortcut.parseConfig("enter", allowBareFirstStroke: true) == shortcut)
        #expect(
            KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut.configIdentifier == "return"
        )
        #expect(
            StoredShortcut.parseConfig(
                KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut.configIdentifier,
                allowBareFirstStroke: true
            ) ==
            KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut
        )
    }

    @Test func shortcutConfigParsingRoundTripsSpaceKey() throws {
        let spaceKeyCode = UInt16(0x31)
        let shortcut = try #require(StoredShortcut.parseConfig("cmd+shift+space"))

        #expect(shortcut.key == "space")
        #expect(shortcut.command)
        #expect(shortcut.shift)
        #expect(!shortcut.option)
        #expect(!shortcut.control)
        #expect(
            shortcut.firstStroke.resolvedKeyCode { keyCode, _ in
                keyCode == spaceKeyCode ? " " : nil
            } ==
            spaceKeyCode
        )
        #expect(shortcut.configIdentifier == "cmd+shift+space")
        #expect(
            shortcut.matches(
                keyCode: spaceKeyCode,
                modifierFlags: [.command, .shift],
                eventCharacter: " "
            )
        )

        for rawShortcut in ["space", "cmd+space", "shift+space", "cmd+shift+space", "ctrl+space", "opt+space"] {
            let parsedShortcut = try #require(StoredShortcut.parseConfig(rawShortcut))
            #expect(parsedShortcut.key == "space")
            #expect(parsedShortcut.firstStroke.resolvedKeyCode() == spaceKeyCode)
            #expect(parsedShortcut.configIdentifier == rawShortcut)
        }

        #expect(StoredShortcut.parseConfig("cmd+shift+Space")?.configIdentifier == "cmd+shift+space")
        #expect(StoredShortcut.parseConfig("cmd+shift+<space>")?.configIdentifier == "cmd+shift+space")
        #expect(StoredShortcut.parseConfig("cmd+shift+<Space>")?.configIdentifier == "cmd+shift+space")
        #expect(StoredShortcut.parseConfig("cmd+shift+spacebar")?.configIdentifier == "cmd+shift+space")
        #expect(StoredShortcut.parseConfig("cmd+shift+ ")?.configIdentifier == "cmd+shift+space")
        #expect(StoredShortcut.parseConfig(" ")?.configIdentifier == "space")
        #expect(StoredShortcut.parseConfig("   ") == .unbound)
        #expect(StoredShortcut.parseConfig("\t") == .unbound)
        #expect(StoredShortcut.parseConfig("cmd+shift+   ") == nil)
    }

    @Test func settingsFileStoreParsesSpaceShortcutBinding() throws {
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

        #expect(
            store.override(for: .toggleSplitZoom) ==
            StoredShortcut(key: "space", command: true, shift: true, option: false, control: false)
        )
    }
}
