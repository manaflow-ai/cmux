import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// `resolvedKeyCode()` consults the live keyboard layout through HIToolbox,
// which only accepts main-thread callers; from a detached Swift Testing
// worker it traps the whole app host (`BUG IN CLIENT OF LIBDISPATCH`).
@MainActor
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

    @Test func shortcutConfigParsingAcceptsModifiedEscapeForGlobalHotkey() throws {
        let escapeKeyCode = UInt16(53)
        let shortcut = try #require(StoredShortcut.parseConfig("ctrl+escape"))

        #expect(shortcut.key == "escape")
        #expect(shortcut.control)
        #expect(shortcut.configIdentifier == "ctrl+escape")
        #expect(StoredShortcut.parseConfig("ctrl+esc") == shortcut)
        #expect(shortcut.firstStroke.resolvedKeyCode() == escapeKeyCode)
        #expect(shortcut.matches(keyCode: escapeKeyCode, modifierFlags: [.control], eventCharacter: "\u{1b}"))
        #expect(StoredShortcut.parseConfig("escape") == nil)
        #expect(StoredShortcut.parseConfig("escape", allowBareFirstStroke: true)?.key == "escape")
    }

    @Test func recorderAcceptsEscapeWithModifierButBareEscapeStillCancels() throws {
        func escapeEvent(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ))
        }

        #expect(ShortcutStroke.isEscapeCancelEvent(try escapeEvent([])))
        let ctrlEscape = try escapeEvent([.control])
        #expect(!ShortcutStroke.isEscapeCancelEvent(ctrlEscape))
        #expect(
            ShortcutStroke.recordingResult(from: ctrlEscape, requireModifier: true) ==
            .accepted(ShortcutStroke(key: "escape", command: false, shift: false, option: false, control: true, keyCode: 53))
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
