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
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
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
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let renameTabExpectation = expectation(description: "Rename tab notification should fire for default Cmd+R")
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        let renameWorkspaceExpectation = expectation(description: "Rename workspace notification should not fire for default Cmd+R")
        renameWorkspaceExpectation.isInverted = true
        let renameWorkspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameWorkspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

        guard let cmdR = makeKeyDownEvent(
            key: "r",
            modifiers: [.command],
            keyCode: 15,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: cmdR))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [renameTabExpectation, renameWorkspaceExpectation], timeout: 1.0)
    }

    func testDefaultCmdShiftRRequestsRenameWorkspaceOnlyWhenBrowserNotFocused() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let renameWorkspaceExpectation = expectation(description: "Rename workspace notification should fire for default Cmd+Shift+R")
        let renameWorkspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameWorkspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

        let renameTabExpectation = expectation(description: "Rename tab notification should not fire for default Cmd+Shift+R")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        guard let cmdShiftR = makeKeyDownEvent(
            key: "r",
            modifiers: [.command, .shift],
            keyCode: 15,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: cmdShiftR))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [renameWorkspaceExpectation, renameTabExpectation], timeout: 1.0)
    }

    func testFocusedBrowserCmdRUsesReloadInsteadOfRenameTabDefault() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected focused browser panel")
            return
        }

        guard manager.focusedBrowserPanel != nil else {
            XCTFail("Expected openBrowser to focus the browser panel")
            return
        }

        let renameTabExpectation = expectation(description: "Focused browser Cmd+R should not request rename tab")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        let browserReloadExpectation = expectation(description: "Focused browser Cmd+R should invoke browser reload")
        let browserReloadToken = NotificationCenter.default.addObserver(
            forName: .debugBrowserReloadShortcutInvoked,
            object: browserPanel,
            queue: nil
        ) { _ in
            browserReloadExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(browserReloadToken) }

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command],
            keyCode: 15,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [renameTabExpectation, browserReloadExpectation], timeout: 1.0)
    }

    func testFocusedBrowserCmdShiftRDoesNotRequestRenameWorkspaceDefault() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              manager.openBrowser(inWorkspace: workspace.id) != nil else {
            XCTFail("Expected focused browser panel")
            return
        }

        guard manager.focusedBrowserPanel != nil else {
            XCTFail("Expected openBrowser to focus the browser panel")
            return
        }

        let renameWorkspaceExpectation = expectation(description: "Focused browser Cmd+Shift+R should not request rename workspace")
        renameWorkspaceExpectation.isInverted = true
        let renameWorkspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameWorkspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command, .shift],
            keyCode: 15,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+R event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [renameWorkspaceExpectation], timeout: 1.0)
    }

    func testReactGrabShortcutRoutesFromFocusedTerminalToSingleBrowserPane() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected terminal plus one browser panel")
            return
        }

        workspace.focusPanel(terminalPanelId)
        XCTAssertNil(manager.focusedBrowserPanel)
        XCTAssertEqual(workspace.focusedPanelId, terminalPanelId)

        guard let event = makeKeyDownEvent(
            key: "g",
            modifiers: [.command, .shift],
            keyCode: 5,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+G event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(workspace.focusedPanelId, browserPanelId)
        XCTAssertEqual(browserPanel.pendingReactGrabReturnTargetPanelId, terminalPanelId)
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

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
