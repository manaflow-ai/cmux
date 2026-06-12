import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateFileExplorerShortcutRoutingTests {
    @Test func fileExplorerFinderAliasIsNotSuppressedAsStaleMenuShortcut() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared, "Expected AppDelegate.shared")
            let event = try #require(
                makeKeyDownEvent(
                    shortcut: KeyboardShortcutSettings.Action.fileExplorerOpenSelectionFinderAlias.defaultShortcut,
                    windowNumber: 0
                ),
                "Failed to construct Cmd+Down event"
            )

            KeyboardShortcutSettings.setShortcut(.unbound, for: .fileExplorerOpenSelectionFinderAlias)
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif

            #expect(
                !appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "File explorer open shortcuts are view-scoped, not menu-backed stale defaults"
            )
        }
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-explorer-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif
        }

        try body()
    }

    private func makeKeyDownEvent(shortcut: StoredShortcut, windowNumber: Int) -> NSEvent? {
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
