import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutContextTests: XCTestCase {
    func testRenameTabAndBrowserReloadCanShareDefaultChordAcrossContexts() {
        let renameTabShortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut

        XCTAssertEqual(renameTabShortcut, KeyboardShortcutSettings.Action.browserReload.defaultShortcut)
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.shortcutContext, .nonBrowserPanel)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.shortcutContext, .browserPanel)
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: KeyboardShortcutSettings.Action.browserReload.defaultShortcut,
                proposedAction: .browserReload,
                configuredShortcut: renameTabShortcut
            )
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.browserReload.conflicts(
                with: renameTabShortcut,
                proposedAction: .renameTab,
                configuredShortcut: KeyboardShortcutSettings.Action.browserReload.defaultShortcut
            )
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: renameTabShortcut,
                proposedAction: .renameWorkspace,
                configuredShortcut: renameTabShortcut
            )
        )
    }

    func testRenameTabCanReassignCommandRAfterUnbindingWithoutBrowserReloadConflict() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
        XCTAssertEqual(commandR, KeyboardShortcutSettings.Action.renameTab.defaultShortcut)
        XCTAssertEqual(commandR, KeyboardShortcutSettings.Action.browserReload.defaultShortcut)

        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)
        KeyboardShortcutSettings.clearShortcut(for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.renameTab.normalizedRecordedShortcutResult(commandR),
            .accepted(commandR)
        )

        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), commandR)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
    }

    func testSwapPathIgnoresNonOverlappingShortcutContexts() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        KeyboardShortcutSettings.clearShortcut(for: .renameTab)

        KeyboardShortcutSettings.swapShortcutConflict(
            proposedShortcut: commandR,
            currentAction: .renameTab,
            conflictingAction: .browserReload,
            previousShortcut: .unbound
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertNil(
            ShortcutRecorderValidationPresentation(
                attempt: ShortcutRecorderRejectedAttempt(
                    reason: .conflictsWithAction(.browserReload),
                    proposedShortcut: commandR
                ),
                action: .renameTab,
                currentShortcut: .unbound,
                shortcutForAction: { $0.defaultShortcut }
            )
        )
    }

    func testRenameWorkspaceIsScopedOutsideBrowserPanels() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.shortcutContext, .nonBrowserPanel)
    }

    func testRightSidebarContextIsOnlyAvailableWhenRightSidebarHasFocus() {
        let context = KeyboardShortcutSettings.Action.switchRightSidebarToFiles.shortcutContext

        XCTAssertEqual(context, .rightSidebarFocus)
        XCTAssertFalse(context.isAvailable(focusedBrowserPanel: false, rightSidebarFocused: false))
        XCTAssertTrue(context.isAvailable(focusedBrowserPanel: false, rightSidebarFocused: true))
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.shortcutContext
                .isAvailable(focusedBrowserPanel: false, rightSidebarFocused: true)
        )
        XCTAssertTrue(context.overlaps(KeyboardShortcutSettings.Action.commandPalette.shortcutContext))
        XCTAssertFalse(context.overlaps(KeyboardShortcutSettings.Action.renameTab.shortcutContext))
    }

    func testReactGrabStaysApplicationScopedForTerminalPastebackRouting() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleReactGrab.shortcutContext, .application)
    }

    func testMarkdownShortcutsConflictWithNonBrowserShortcuts() {
        let commandR = KeyboardShortcutSettings.Action.renameTab.defaultShortcut

        XCTAssertEqual(KeyboardShortcutSettings.Action.markdownFindNext.shortcutContext, .markdownPanel)
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.shortcutContext, .nonBrowserPanel)
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.renameTab.conflicts(
                with: commandR,
                proposedAction: .markdownFindNext,
                configuredShortcut: commandR
            )
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.markdownFindNext.conflicts(
                with: commandR,
                proposedAction: .renameTab,
                configuredShortcut: commandR
            )
        )
    }

    func testMarkdownControlFindAliasesDoNotConflictWithCommandPaletteNavigation() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let controlN = KeyboardShortcutSettings.Action.markdownFindNextAlternate.defaultShortcut
        let controlP = KeyboardShortcutSettings.Action.markdownFindPreviousAlternate.defaultShortcut

        XCTAssertEqual(controlN, KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut)
        XCTAssertEqual(controlP, KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.markdownFindNextAlternate.normalizedRecordedShortcutResult(controlN),
            .accepted(controlN)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.markdownFindPreviousAlternate.normalizedRecordedShortcutResult(controlP),
            .accepted(controlP)
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.commandPaletteNext.conflicts(
                with: controlN,
                proposedAction: .markdownFindNextAlternate,
                configuredShortcut: KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut
            )
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.commandPalettePrevious.conflicts(
                with: controlP,
                proposedAction: .markdownFindPreviousAlternate,
                configuredShortcut: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut
            )
        )
    }

    func testMarkdownShortcutsStillConflictWithNormalApplicationShortcuts() {
        let commandN = KeyboardShortcutSettings.Action.newTab.defaultShortcut

        XCTAssertTrue(
            KeyboardShortcutSettings.Action.newTab.conflicts(
                with: commandN,
                proposedAction: .markdownFindNextAlternate,
                configuredShortcut: commandN
            )
        )
    }

    func testShortcutSettingsFilePreservesConfiguredShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "cmd+n"
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
            store.override(for: .newWindow),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
    }

    func testShortcutSettingsFilePreservesUnboundShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "none"
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

        XCTAssertEqual(store.override(for: .newWindow), StoredShortcut.unbound)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
