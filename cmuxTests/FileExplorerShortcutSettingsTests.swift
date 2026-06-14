import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias StoredShortcut = cmux_DEV.StoredShortcut
private typealias ShortcutStroke = cmux_DEV.ShortcutStroke
#elseif canImport(cmux)
@testable import cmux
private typealias StoredShortcut = cmux.StoredShortcut
private typealias ShortcutStroke = cmux.ShortcutStroke
#endif

@MainActor
@Suite(.serialized) struct FileExplorerShortcutSettingsTests {
    @Test func openSelectionShortcutsAreSidebarFocusedAndSettingsBacked() throws {
        let primary = KeyboardShortcutSettings.Action.fileExplorerOpenSelection
        let finderAlias = KeyboardShortcutSettings.Action.fileExplorerOpenSelectionFinderAlias
        let primaryDefault = primary.defaultShortcut
        let finderAliasDefault = finderAlias.defaultShortcut

        #expect(primaryDefault.key == "\r")
        #expect(!primaryDefault.command)
        #expect(!primaryDefault.shift)
        #expect(!primaryDefault.option)
        #expect(!primaryDefault.control)
        #expect(finderAliasDefault.key == "↓")
        #expect(finderAliasDefault.command)
        #expect(!finderAliasDefault.shift)
        #expect(!finderAliasDefault.option)
        #expect(!finderAliasDefault.control)
        #expect(primary.allowsBareFirstStroke)
        #expect(finderAlias.allowsBareFirstStroke)
        #expect(!primary.allowsChordShortcut)
        #expect(!finderAlias.allowsChordShortcut)
        #expect(primary.shortcutContext == .rightSidebarFocus)
        #expect(finderAlias.shortcutContext == .rightSidebarFocus)

        let settingsPrimary = try #require(ShortcutAction(rawValue: primary.rawValue))
        let settingsFinderAlias = try #require(ShortcutAction(rawValue: finderAlias.rawValue))

        #expect(settingsPrimary.defaultStroke == CmuxSettings.ShortcutStroke(key: "\r"))
        #expect(settingsFinderAlias.defaultStroke == CmuxSettings.ShortcutStroke(key: "↓", command: true))
        #expect(settingsPrimary.displayName == primary.label)
        #expect(settingsFinderAlias.displayName == finderAlias.label)
    }

    @Test func openSelectionShortcutsStayColocatedWithRightSidebarActions() {
        let visibleActions = KeyboardShortcutSettings.settingsVisibleActions
        let expectedActions: [KeyboardShortcutSettings.Action] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
            .fileExplorerOpenSelection,
            .fileExplorerOpenSelectionFinderAlias,
        ]

        let startIndex = visibleActions.firstIndex(of: .focusRightSidebar) ?? visibleActions.endIndex
        let actualActions = Array(visibleActions.dropFirst(startIndex).prefix(expectedActions.count))

        #expect(actualActions == expectedActions)
    }

    @Test func settingsPackageVisibleActionsStayColocatedWithRightSidebarActions() {
        let visibleActions = ShortcutAction.settingsVisibleActions
        let expectedActions: [ShortcutAction] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
            .fileExplorerOpenSelection,
            .fileExplorerOpenSelectionFinderAlias,
        ]

        let startIndex = visibleActions.firstIndex(of: .focusRightSidebar) ?? visibleActions.endIndex
        let actualActions = Array(visibleActions.dropFirst(startIndex).prefix(expectedActions.count))

        #expect(actualActions == expectedActions)
    }

    @Test func openSelectionShortcutsStayOutOfAppWideBareStartCache() {
        withIsolatedShortcutSettings {
            #expect(!KeyboardShortcutBareStartCache.hasConfiguredBareShortcutStart(key: "\r"))

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "↓", command: false, shift: false, option: false, control: false),
                for: .fileExplorerOpenSelection
            )

            #expect(!KeyboardShortcutBareStartCache.hasConfiguredBareShortcutStart(key: "↓"))
        }
    }

    @Test func openSelectionMatcherHonorsWhenClauseOverride() throws {
        try withIsolatedShortcutSettings {
            try writeSettingsFile(
                """
                {
                  "shortcuts": {
                    "when": {
                      "fileExplorerOpenSelection": "terminalFocus"
                    }
                  }
                }
                """
            )
            KeyboardShortcutSettings.settingsFileStore.reload()

            let event = try #require(
                makeKeyDownEvent(shortcut: KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut)
            )
            let context = ShortcutFocusState(browser: false, markdown: false, sidebar: true).context

            #expect(!event.isFileExplorerOpenSelectionShortcut(in: context))
        }
    }

    @Test func openSelectionMatcherUsesPanelPlacementContext() throws {
        try withIsolatedShortcutSettings {
            let event = try #require(
                makeKeyDownEvent(shortcut: KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut)
            )

            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.pane))

            try writeSettingsFile(
                """
                {
                  "shortcuts": {
                    "when": {
                      "fileExplorerOpenSelection": "terminalFocus"
                    }
                  }
                }
                """
            )
            KeyboardShortcutSettings.settingsFileStore.reload()

            #expect(!event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
            #expect(!event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.pane))
        }
    }

    @Test func openSelectionPaneFocusPreventsNonBrowserShortcutShadowing() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
            let outlineView = FileExplorerNSOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.isEditable = false
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
            scrollView.documentView = outlineView
            contentView.addSubview(scrollView)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            defer { window.orderOut(nil) }

            #expect(window.makeFirstResponder(outlineView))
            #expect(window.firstResponder === outlineView)

            let commandR = StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            KeyboardShortcutSettings.setShortcut(commandR, for: .fileExplorerOpenSelection)
            let event = try #require(makeKeyDownEvent(shortcut: commandR, windowNumber: window.windowNumber))
            defer { appDelegate.clearShortcutEventFocusContextCache(for: event) }

            #expect(appDelegate.shortcutWhenClauseAllows(action: .fileExplorerOpenSelection, event: event))
            #expect(!appDelegate.shortcutWhenClauseAllows(action: .renameTab, event: event))
            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.pane))
        }
    }

    @Test func openSelectionSetShortcutRejectsChords() {
        withIsolatedShortcutSettings {
            let chord = StoredShortcut(
                first: ShortcutStroke(key: "o", command: true, shift: false, option: false, control: false),
                second: ShortcutStroke(key: "p", command: false, shift: false, option: false, control: false)
            )

            KeyboardShortcutSettings.setShortcut(chord, for: .fileExplorerOpenSelection)

            #expect(KeyboardShortcutSettings.shortcut(for: .fileExplorerOpenSelection) ==
                KeyboardShortcutSettings.Action.fileExplorerOpenSelection.defaultShortcut)
        }
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-explorer-shortcut-settings"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }

        try body()
    }

    private func writeSettingsFile(_ contents: String) throws {
        let settingsFileURL = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
        try FileManager.default.createDirectory(
            at: settingsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
    }

    private func makeKeyDownEvent(shortcut: StoredShortcut, windowNumber: Int = 0) -> NSEvent? {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode() else {
            return nil
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
