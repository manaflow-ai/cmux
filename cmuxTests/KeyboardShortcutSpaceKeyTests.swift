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

    @Test func settingsFileStoreParsesOptionalPrefixAndFailsClosedForInvalidValues() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "prefix": "ctrl+b"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.prefixShortcut() ==
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true)
        )

        let invalidURL = directoryURL.appendingPathComponent("invalid.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "prefix": ["ctrl+b", "c"]
          }
        }
        """.write(to: invalidURL, atomically: true, encoding: .utf8)
        let invalidStore = KeyboardShortcutSettingsFileStore(
            primaryPath: invalidURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        #expect(invalidStore.prefixShortcut().isUnbound)

        let malformedBindingURL = directoryURL.appendingPathComponent(
            "malformed-binding.json",
            isDirectory: false
        )
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": {
                "first": { "key": "b", "control": true },
                "second": { "key": "" }
              }
            }
          }
        }
        """.write(to: malformedBindingURL, atomically: true, encoding: .utf8)
        let malformedBindingStore = KeyboardShortcutSettingsFileStore(
            primaryPath: malformedBindingURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        #expect(malformedBindingStore.override(for: .newTab) == nil)

        let fallbackURL = directoryURL.appendingPathComponent(
            "fallback.json",
            isDirectory: false
        )
        try """
        {
          "shortcuts": {
            "prefix": "cmd+k"
          }
        }
        """.write(to: fallbackURL, atomically: true, encoding: .utf8)
        let fallbackStore = KeyboardShortcutSettingsFileStore(
            primaryPath: directoryURL.appendingPathComponent("missing.json").path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        #expect(
            fallbackStore.prefixShortcut() ==
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )
    }
}
