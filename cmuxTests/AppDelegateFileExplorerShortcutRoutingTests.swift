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

    @Test func fileExplorerShortcutReboundToMenuDefaultKeepsStaleMenuSuppressed() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared, "Expected AppDelegate.shared")
            let openFolderDefault = KeyboardShortcutSettings.Action.openFolder.defaultShortcut
            let event = try #require(
                makeKeyDownEvent(shortcut: openFolderDefault, windowNumber: 0),
                "Failed to construct Open Folder default event"
            )

            KeyboardShortcutSettings.setShortcut(.unbound, for: .openFolder)
            KeyboardShortcutSettings.setShortcut(openFolderDefault, for: .fileExplorerOpenSelection)
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif

            #expect(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "View-scoped file explorer shortcuts must not let stale menu defaults fire"
            )
        }
    }

    @Test func fileExplorerShortcutReboundToMenuDefaultRoutesBeforeStaleMenuSuppression() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared, "Expected AppDelegate.shared")
            let openFolderDefault = KeyboardShortcutSettings.Action.openFolder.defaultShortcut

            KeyboardShortcutSettings.setShortcut(.unbound, for: .openFolder)
            KeyboardShortcutSettings.setShortcut(openFolderDefault, for: .fileExplorerOpenSelection)
            #if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
            #endif

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
            let resultsView = FileExplorerSearchResultsTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
            resultsView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
            var commitCount = 0
            resultsView.onCommit = {
                commitCount += 1
            }
            contentView.addSubview(resultsView)
            window.contentView = contentView
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            defer { window.orderOut(nil) }

            #expect(window.makeFirstResponder(resultsView))
            #expect(window.firstResponder === resultsView)

            let event = try #require(
                makeKeyDownEvent(shortcut: openFolderDefault, windowNumber: window.windowNumber),
                "Failed to construct Open Folder default event"
            )
            defer { appDelegate.clearShortcutEventFocusContextCache(for: event) }

            #expect(appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event))
            #expect(appDelegate.handleFocusedFileExplorerOpenSelectionShortcut(event, preferredWindow: window))
            #expect(commitCount == 1)
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
