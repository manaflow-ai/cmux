import XCTest

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

private final class ShortcutContextNotificationCounter: @unchecked Sendable {
    var count = 0
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

@MainActor
final class AppDelegateRenameShortcutContextTests: XCTestCase {
    private var savedShortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var actionsWithPersistedShortcut: Set<KeyboardShortcutSettings.Action> = []
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
        actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-rename-shortcut-context")
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        for action in KeyboardShortcutSettings.Action.allCases {
            if actionsWithPersistedShortcut.contains(action),
               let savedShortcut = savedShortcutsByAction[action] {
                KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        super.tearDown()
    }

    func testDefaultCmdRRequestsRenameTabOnlyWhenBrowserNotFocused() {
        withShortcutAppDelegate(browserPanel: nil) { appDelegate in
            let renameTabRequests = ShortcutContextNotificationCounter()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let renameWorkspaceRequests = ShortcutContextNotificationCounter()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspaceRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            guard let cmdR = makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+R event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: cmdR))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

            XCTAssertEqual(renameTabRequests.count, 1)
            XCTAssertEqual(renameWorkspaceRequests.count, 0)
        }
    }

    func testDefaultCmdShiftRRequestsRenameWorkspaceOnlyWhenBrowserNotFocused() {
        withShortcutAppDelegate(browserPanel: nil) { appDelegate in
            let renameWorkspaceRequests = ShortcutContextNotificationCounter()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspaceRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let renameTabRequests = ShortcutContextNotificationCounter()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            guard let cmdShiftR = makeKeyDownEvent(
                key: "r",
                modifiers: [.command, .shift],
                keyCode: 15,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+Shift+R event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: cmdShiftR))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

            XCTAssertEqual(renameWorkspaceRequests.count, 1)
            XCTAssertEqual(renameTabRequests.count, 0)
        }
    }

    func testFocusedBrowserCmdRUsesReloadInsteadOfRenameTabDefault() {
        let browserPanel = BrowserPanel(workspaceId: UUID())
        defer { closeBrowserPanel(browserPanel) }

        withShortcutAppDelegate(browserPanel: browserPanel) { appDelegate in
            let renameTabRequests = ShortcutContextNotificationCounter()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let browserReloadRequests = ShortcutContextNotificationCounter()
            let browserReloadToken = NotificationCenter.default.addObserver(
                forName: .debugBrowserReloadShortcutInvoked,
                object: browserPanel,
                queue: nil
            ) { _ in
                browserReloadRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(browserReloadToken) }

            guard let event = makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+R event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

            XCTAssertEqual(renameTabRequests.count, 0)
            XCTAssertEqual(browserReloadRequests.count, 1)
        }
    }

    func testFocusedBrowserCmdShiftRDoesNotRequestRenameWorkspaceDefault() {
        let browserPanel = BrowserPanel(workspaceId: UUID())
        defer { closeBrowserPanel(browserPanel) }

        withShortcutAppDelegate(browserPanel: browserPanel) { appDelegate in
            let renameWorkspaceRequests = ShortcutContextNotificationCounter()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspaceRequests.count += 1
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            guard let event = makeKeyDownEvent(
                key: "r",
                modifiers: [.command, .shift],
                keyCode: 15,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+Shift+R event")
                return
            }

#if DEBUG
            XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

            XCTAssertEqual(renameWorkspaceRequests.count, 0)
        }
    }

    func testReactGrabShortcutRoutesFromFocusedTerminalToSingleBrowserPane() {
        let terminalPanelId = UUID()
        let browserPanelId = UUID()
        XCTAssertEqual(
            resolveReactGrabShortcutRoute(
                panels: [
                    ReactGrabShortcutPanelSnapshot(
                        id: terminalPanelId,
                        panelType: .terminal,
                        isFocused: true
                    ),
                    ReactGrabShortcutPanelSnapshot(
                        id: browserPanelId,
                        panelType: .browser,
                        isFocused: false
                    ),
                ]
            ),
            ReactGrabShortcutRoute(
                browserPanelId: browserPanelId,
                returnTerminalPanelId: terminalPanelId
            )
        )

        withShortcutAppDelegate(browserPanel: nil) { appDelegate in
            var handlerCallCount = 0
            appDelegate.debugToggleReactGrabShortcutHandler = {
                handlerCallCount += 1
                return true
            }

            guard let event = makeKeyDownEvent(
                key: "g",
                modifiers: [.command, .shift],
                keyCode: 5,
                windowNumber: 0
            ) else {
                XCTFail("Failed to construct Cmd+Shift+G event")
                return
            }

#if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

            XCTAssertEqual(handlerCallCount, 1)
        }
    }

    func testWindowPerformKeyEquivalentForwardsBrowserReloadShortcutToTerminalWhenRenameTabIsUnbound() {
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
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command],
            keyCode: 15,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+R event")
            return
        }

        KeyboardShortcutSettings.setShortcut(.unbound, for: .renameTab)
        KeyboardShortcutSettings.resetShortcut(for: .browserReload)

        XCTAssertTrue(
            probeWindow.performKeyEquivalent(with: event),
            "Browser reload shortcut should pass to the focused terminal when rename tab no longer owns Cmd+R"
        )

        XCTAssertEqual(menuProbe.callCount, 0, "Reload Page menu item must not consume terminal Cmd+R")
        XCTAssertEqual(probeView.afterMenuMissCallCount, 1, "Terminal Cmd+R should enter Ghostty's command path")
        XCTAssertEqual(probeView.lastAfterMenuMissCharactersIgnoringModifiers, "r")
        XCTAssertEqual(probeView.keyDownCallCount, 0, "Handled Ghostty command equivalents should not fall through to keyDown")
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

    private func closeBrowserPanel(_ panel: BrowserPanel) {
        BrowserWindowPortalRegistry.detach(webView: panel.webView)
        panel.close()
        panel.webView.removeFromSuperview()
    }

    private func withShortcutAppDelegate(
        browserPanel: BrowserPanel? = nil,
        _ body: (AppDelegate) -> Void
    ) {
        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        appDelegate.debugShortcutEventFocusContextOverride = ShortcutEventFocusContext(
            browserPanel: browserPanel,
            markdownPanel: nil,
            rightSidebarFocused: false
        )
        defer {
            appDelegate.debugResetShortcutRoutingStateForTesting()
            AppDelegate.shared = previousShared
        }
        body(appDelegate)
    }
}
