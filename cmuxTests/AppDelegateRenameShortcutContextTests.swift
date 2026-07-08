import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ShortcutContextMenuActionProbe: NSObject {
    var callCount = 0

    @objc func perform(_ sender: Any?) {
        callCount += 1
    }
}

private final class ShortcutContextGhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var keyDownCallCount = 0
    var lastAfterMenuMissCharactersIgnoringModifiers: String?
    var lastKeyDownCharactersIgnoringModifiers: String?
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        lastAfterMenuMissCharactersIgnoringModifiers = event.charactersIgnoringModifiers
        return performAfterMenuMissResult
    }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }
}

private final class ShortcutNotificationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var posted = false

    var wasPosted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }

    func markPosted() {
        lock.lock()
        posted = true
        lock.unlock()
    }
}

@MainActor
@Suite(.serialized)
struct AppDelegateRenameShortcutContextTests {
    @Test func defaultCmdRRequestsRenameTabOnlyWhenBrowserNotFocused() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let renameWorkspacePosted = ShortcutNotificationFlag()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspacePosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let cmdR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: cmdR))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(renameTabPosted.wasPosted)
            #expect(!renameWorkspacePosted.wasPosted)
        }
    }

    @Test func defaultCmdShiftRRequestsRenameWorkspaceOnlyWhenBrowserNotFocused() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let renameWorkspacePosted = ShortcutNotificationFlag()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspacePosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let cmdShiftR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command, .shift],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: cmdShiftR))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(renameWorkspacePosted.wasPosted)
            #expect(!renameTabPosted.wasPosted)
        }
    }

    @Test func focusedBrowserCmdRUsesReloadInsteadOfRenameTabDefault() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let browserPanelId = try #require(manager.openBrowser(inWorkspace: workspace.id))
            let browserPanel = try #require(workspace.browserPanel(for: browserPanelId))

            #expect(manager.focusedBrowserPanel != nil)

            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let browserReloadPosted = ShortcutNotificationFlag()
            let browserReloadToken = NotificationCenter.default.addObserver(
                forName: .debugBrowserReloadShortcutInvoked,
                object: browserPanel,
                queue: nil
            ) { _ in
                browserReloadPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(browserReloadToken) }

            let event = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(!renameTabPosted.wasPosted)
            #expect(browserReloadPosted.wasPosted)
        }
    }

    @Test func focusedBrowserCmdShiftRUsesHardReloadInsteadOfRenameWorkspaceDefault() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let browserPanelId = try #require(manager.openBrowser(inWorkspace: workspace.id))
            let browserPanel = try #require(workspace.browserPanel(for: browserPanelId))

            #expect(manager.focusedBrowserPanel != nil)

            let renameWorkspacePosted = ShortcutNotificationFlag()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspacePosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let hardReloadPosted = ShortcutNotificationFlag()
            let hardReloadToken = NotificationCenter.default.addObserver(
                forName: .debugBrowserHardReloadShortcutInvoked,
                object: browserPanel,
                queue: nil
            ) { _ in
                hardReloadPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(hardReloadToken) }

            let event = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command, .shift],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(!renameWorkspacePosted.wasPosted)
            #expect(hardReloadPosted.wasPosted)
        }
    }

    @Test func focusedWindowDockBrowserCmdRUsesReloadShortcut() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
            BrowserAvailabilitySettings.setDisabled(false)
            defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let pane = try #require(dock.resolvePane(requestedPaneID: nil))
            let browserPanelId = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: true))
            let browserPanel = try #require(dock.browserPanel(for: browserPanelId))

            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
            #expect(dock.focusedPanelId == browserPanelId)

            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let browserReloadPosted = ShortcutNotificationFlag()
            let browserReloadToken = NotificationCenter.default.addObserver(
                forName: .debugBrowserReloadShortcutInvoked,
                object: browserPanel,
                queue: nil
            ) { _ in
                browserReloadPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(browserReloadToken) }

            let event = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(!renameTabPosted.wasPosted)
            #expect(browserReloadPosted.wasPosted)
        }
    }

    @Test func reactGrabShortcutRoutesFromFocusedTerminalToSingleBrowserPane() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let terminalPanelId = try #require(workspace.focusedPanelId)
            let browserPanelId = try #require(manager.openBrowser(inWorkspace: workspace.id))
            let browserPanel = try #require(workspace.browserPanel(for: browserPanelId))

            workspace.focusPanel(terminalPanelId)
            #expect(manager.focusedBrowserPanel == nil)
            #expect(workspace.focusedPanelId == terminalPanelId)

            let event = try #require(makeKeyDownEvent(
                key: "g",
                modifiers: [.command, .shift],
                keyCode: 5,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(workspace.focusedPanelId == browserPanelId)
            #expect(browserPanel.pendingReactGrabReturnTargetPanelId == terminalPanelId)
        }
    }

    @Test func windowPerformKeyEquivalentForwardsBrowserReloadShortcutToTerminalWhenRenameTabIsUnbound() throws {
        try withIsolatedShortcutSettings {
            let previousMainMenu = NSApp.mainMenu
            let probeWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
            let probeView = ShortcutContextGhosttyCommandEquivalentProbeView(
                frame: NSRect(x: 0, y: 0, width: 200, height: 120)
            )
            let menuProbe = ShortcutContextMenuActionProbe()

            defer {
                NSApp.mainMenu = previousMainMenu
                probeWindow.orderOut(nil)
            }

            let menu = NSMenu(title: "Test")
            let reloadItem = NSMenuItem(
                title: "Reload Page",
                action: #selector(ShortcutContextMenuActionProbe.perform(_:)),
                keyEquivalent: "r"
            )
            reloadItem.keyEquivalentModifierMask = [.command]
            reloadItem.target = menuProbe
            menu.addItem(reloadItem)
            NSApp.mainMenu = menu

            probeWindow.contentView = contentView
            contentView.addSubview(probeView)
            probeWindow.makeKeyAndOrderFront(nil)
            probeWindow.displayIfNeeded()
            #expect(probeWindow.makeFirstResponder(probeView))

            let event = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: probeWindow.windowNumber
            ))

            KeyboardShortcutSettings.setShortcut(.unbound, for: .renameTab)
            KeyboardShortcutSettings.resetShortcut(for: .browserReload)

            #expect(probeWindow.performKeyEquivalent(with: event))
            #expect(menuProbe.callCount == 0)
            #expect(probeView.afterMenuMissCallCount == 1)
            #expect(probeView.lastAfterMenuMissCharactersIgnoringModifiers == "r")
            #expect(probeView.keyDownCallCount == 0)
        }
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-rename-shortcut-context"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
        }
        try body()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func mainWindow(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
