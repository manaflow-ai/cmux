import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias StoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias StoredShortcut = cmux.StoredShortcut
#endif

private typealias SettingsShortcutStroke = CmuxSettings.ShortcutStroke

@Suite(.serialized) struct KeyboardShortcutSpaceKeyTests {
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

    @Test func paneFocusCommandBracketDefaultsAreScopedToSplitWorkspacesAndPriorityRouted() {
        let focusLeft = KeyboardShortcutSettings.Action.focusLeft.defaultShortcut
        let focusRight = KeyboardShortcutSettings.Action.focusRight.defaultShortcut

        #expect(focusLeft == KeyboardShortcutSettings.Action.focusHistoryBack.defaultShortcut)
        #expect(focusRight == KeyboardShortcutSettings.Action.focusHistoryForward.defaultShortcut)
        #expect(focusLeft == KeyboardShortcutSettings.Action.browserBack.defaultShortcut)
        #expect(focusRight == KeyboardShortcutSettings.Action.browserForward.defaultShortcut)
        #expect(ShortcutAction.focusLeft.defaultStroke == SettingsShortcutStroke(key: "[", command: true))
        #expect(ShortcutAction.focusRight.defaultStroke == SettingsShortcutStroke(key: "]", command: true))

        #expect(!KeyboardShortcutSettings.Action.focusLeft.hasPriorityShortcutRouting)
        #expect(!KeyboardShortcutSettings.Action.focusRight.hasPriorityShortcutRouting)
        #expect(KeyboardShortcutSettings.Action.focusLeft.hasShortcutConflictPriority(over: .focusHistoryBack))
        #expect(KeyboardShortcutSettings.Action.focusLeft.hasShortcutConflictPriority(over: .browserBack))
        #expect(KeyboardShortcutSettings.Action.focusRight.hasShortcutConflictPriority(over: .focusHistoryForward))
        #expect(KeyboardShortcutSettings.Action.focusRight.hasShortcutConflictPriority(over: .browserForward))
        #expect(!KeyboardShortcutSettings.Action.focusLeft.hasShortcutConflictPriority(over: .closeTab))

        var splitContext = ShortcutContext()
        splitContext.setInt(ShortcutContextKnownKey.paneCount.rawValue, 2)
        #expect(KeyboardShortcutSettings.Action.focusLeft.shortcutContext.defaultWhenClause.evaluate(splitContext))
        #expect(KeyboardShortcutSettings.Action.focusRight.shortcutContext.defaultWhenClause.evaluate(splitContext))

        var singlePaneContext = ShortcutContext()
        singlePaneContext.setInt(ShortcutContextKnownKey.paneCount.rawValue, 1)
        #expect(!KeyboardShortcutSettings.Action.focusLeft.shortcutContext.defaultWhenClause.evaluate(singlePaneContext))
        #expect(!KeyboardShortcutSettings.Action.focusRight.shortcutContext.defaultWhenClause.evaluate(singlePaneContext))

        var sidebarSplitContext = ShortcutContext()
        sidebarSplitContext.setInt(ShortcutContextKnownKey.paneCount.rawValue, 2)
        sidebarSplitContext.setBool(ShortcutContextKnownKey.sidebarFocus.rawValue, true)
        #expect(!KeyboardShortcutSettings.Action.focusLeft.shortcutContext.defaultWhenClause.evaluate(sidebarSplitContext))
        #expect(!KeyboardShortcutSettings.Action.focusRight.shortcutContext.defaultWhenClause.evaluate(sidebarSplitContext))

        #expect(
            !ShortcutWhenClause.bindingsCollide(
                KeyboardShortcutSettings.Action.focusHistoryBack.shortcutContext.defaultWhenClause,
                lhsHasPriority: KeyboardShortcutSettings.Action.focusHistoryBack
                    .hasShortcutConflictPriority(over: .focusLeft),
                KeyboardShortcutSettings.Action.focusLeft.shortcutContext.defaultWhenClause,
                rhsHasPriority: KeyboardShortcutSettings.Action.focusLeft
                    .hasShortcutConflictPriority(over: .focusHistoryBack)
            )
        )
        #expect(
            !ShortcutWhenClause.bindingsCollide(
                KeyboardShortcutSettings.Action.browserBack.shortcutContext.defaultWhenClause,
                lhsHasPriority: KeyboardShortcutSettings.Action.browserBack
                    .hasShortcutConflictPriority(over: .focusLeft),
                KeyboardShortcutSettings.Action.focusLeft.shortcutContext.defaultWhenClause,
                rhsHasPriority: KeyboardShortcutSettings.Action.focusLeft
                    .hasShortcutConflictPriority(over: .browserBack)
            )
        )
        #expect(
            KeyboardShortcutSettings.Action.closeTab.conflicts(
                with: focusLeft,
                proposedAction: .focusLeft,
                configuredShortcut: focusLeft
            )
        )
    }

    @Test func paneFocusMenuShortcutsSuppressDuplicateHistoryKeys() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try "{}".write(to: settingsFileURL, atomically: true, encoding: .utf8)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let focusBack = KeyboardShortcutSettings.shortcut(for: .focusHistoryBack)
        let focusForward = KeyboardShortcutSettings.shortcut(for: .focusHistoryForward)

        #expect(focusBack == KeyboardShortcutSettings.shortcut(for: .focusLeft))
        #expect(focusForward == KeyboardShortcutSettings.shortcut(for: .focusRight))
        #expect(focusBack == KeyboardShortcutSettings.shortcut(for: .browserBack))
        #expect(focusForward == KeyboardShortcutSettings.shortcut(for: .browserForward))
        #expect(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryBack) == .unbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryForward) == .unbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .browserBack) == .unbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .browserForward) == .unbound)

        KeyboardShortcutSettings.clearShortcut(for: .focusLeft)
        KeyboardShortcutSettings.clearShortcut(for: .focusRight)

        #expect(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryBack) == focusBack)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryForward) == focusForward)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .browserBack) == .unbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .browserForward) == .unbound)
    }

    @Test func settingsPackageShortcutConflictPriorityMatchesRuntime() {
        for action in KeyboardShortcutSettings.Action.allCases {
            guard let settingsAction = ShortcutAction(rawValue: action.rawValue) else {
                continue
            }
            for other in KeyboardShortcutSettings.Action.allCases {
                guard let settingsOther = ShortcutAction(rawValue: other.rawValue) else {
                    continue
                }
                #expect(
                    settingsAction.hasShortcutConflictPriority(over: settingsOther) ==
                        action.hasShortcutConflictPriority(over: other),
                    "\(action.rawValue) over \(other.rawValue)"
                )
            }
        }
    }
}
