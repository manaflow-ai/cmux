import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateShortcutRoutingTests: XCTestCase {
    func testCmdNUsesEventWindowContextWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        XCTAssertTrue(appDelegate.focusMainWindow(windowId: firstWindowId))

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not add workspace to stale active window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should add workspace to the event's window")
    }

    func testAddWorkspaceInPreferredMainWindowIgnoresStaleTabManagerPointer() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force a stale app-level pointer to a different manager.
        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Stale pointer must not receive menu-driven workspace creation")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Workspace creation should target key/main window context")
    }

    func testCmdNResolvesEventWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Ensure stale active-manager pointer does not mask routing errors.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondWindow.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Cmd+N should not route to another window when object-key lookup misses")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Cmd+N should still route by event window metadata when object-key lookup misses")
    }

    func testAddWorkspaceInPreferredMainWindowUsesKeyWindowWhenObjectKeyLookupIsMismatched() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

#if DEBUG
        XCTAssertTrue(appDelegate.debugInjectWindowContextKeyMismatch(windowId: secondWindowId))
#else
        XCTFail("debugInjectWindowContextKeyMismatch is only available in DEBUG")
#endif

        // Stale pointer should not receive the new workspace.
        appDelegate.tabManager = firstManager

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count

        _ = appDelegate.addWorkspaceInPreferredMainWindow()

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Menu-driven add workspace should not route to stale window")
        XCTAssertEqual(secondManager.tabs.count, secondCount + 1, "Menu-driven add workspace should still route to key window context when object-key lookup misses")
    }

    func testCmdDigitRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)

        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }
        guard let secondFirstTabId = secondManager.tabs.first?.id else {
            XCTFail("Expected at least one tab in second window")
            return
        }

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18, // kVK_ANSI_1
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Cmd+1 must not select a tab in stale active window")
        XCTAssertNotEqual(secondManager.selectedTabId, secondSelectedBefore, "Cmd+1 should change tab selection in event window")
        XCTAssertEqual(secondManager.selectedTabId, secondFirstTabId, "Cmd+1 should select first tab in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdTRoutesToEventWindowWhenActiveManagerIsStale() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId),
              let firstWorkspace = firstManager.selectedWorkspace,
              let secondWorkspace = secondManager.selectedWorkspace else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        let firstSurfaceCount = firstWorkspace.panels.count
        let secondSurfaceCount = secondWorkspace.panels.count

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        guard let event = makeKeyDownEvent(
            key: "t",
            modifiers: [.command],
            keyCode: 17, // kVK_ANSI_T
            windowNumber: secondWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+T event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(firstWorkspace.panels.count, firstSurfaceCount, "Cmd+T must not create a surface in stale active window")
        XCTAssertEqual(secondWorkspace.panels.count, secondSurfaceCount + 1, "Cmd+T should create a surface in the event window")
        XCTAssertTrue(appDelegate.tabManager === secondManager, "Shortcut routing should retarget active manager to event window")
    }

    func testCmdPhysicalIWithDvorakCharactersDoesNotTriggerShowNotifications() {
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

        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .showNotifications)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: .showNotifications) }
        KeyboardShortcutSettings.setShortcut(KeyboardShortcutSettings.Action.showNotifications.defaultShortcut, for: .showNotifications)

        // Dvorak: physical ANSI "I" key can produce the character "c".
        // This should behave like Cmd+C (copy), not match the Cmd+I app shortcut.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 34 // kVK_ANSI_I
        ) else {
            XCTFail("Failed to construct Dvorak Cmd+C event on physical ANSI I key")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdIStillTriggersShowNotificationsShortcut() {
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

        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .showNotifications)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: .showNotifications) }
        KeyboardShortcutSettings.setShortcut(KeyboardShortcutSettings.Action.showNotifications.defaultShortcut, for: .showNotifications)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: 34 // kVK_ANSI_I
        ) else {
            XCTFail("Failed to construct Cmd+I event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdUnshiftedSymbolDoesNotMatchDigitShortcut() {
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

        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .showNotifications)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: .showNotifications) }
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "8", command: true, shift: false, option: false, control: false),
            for: .showNotifications
        )

        // Some non-US layouts can produce "*" without Shift.
        // This must not be coerced into "8" for a Cmd+8 shortcut match.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "*",
            charactersIgnoringModifiers: "*",
            isARepeat: false,
            keyCode: 30 // kVK_ANSI_RightBracket
        ) else {
            XCTFail("Failed to construct Cmd+* event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftQuestionMarkMatchesSlashShortcut() {
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

        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .triggerFlash)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: .triggerFlash) }
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "/", command: true, shift: true, option: false, control: false),
            for: .triggerFlash
        )

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "?",
            charactersIgnoringModifiers: "?",
            isARepeat: false,
            keyCode: 44 // kVK_ANSI_Slash
        ) else {
            XCTFail("Failed to construct Cmd+Shift+/ event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftRightBracketCanFallbackByKeyCodeOnNonUSLayouts() {
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

        let originalShortcut = KeyboardShortcutSettings.shortcut(for: .nextSurface)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: .nextSurface) }
        KeyboardShortcutSettings.setShortcut(
            KeyboardShortcutSettings.Action.nextSurface.defaultShortcut,
            for: .nextSurface
        )

        // Non-US layouts can report "*" (or other symbols) for kVK_ANSI_RightBracket with Shift.
        // Shortcut matching should still allow Cmd+Shift+] via keyCode fallback.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "*",
            charactersIgnoringModifiers: "*",
            isARepeat: false,
            keyCode: 30 // kVK_ANSI_RightBracket
        ) else {
            XCTFail("Failed to construct non-US Cmd+Shift+] event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testCmdShiftRRequestsRenameWorkspaceInCommandPalette() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        let workspaceExpectation = expectation(description: "Expected command palette rename workspace notification")
        var observedWorkspaceWindow: NSWindow?
        let workspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedWorkspaceWindow = notification.object as? NSWindow
            workspaceExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(workspaceToken) }

        let renameTabExpectation = expectation(description: "Rename tab notification should not fire for Cmd+Shift+R")
        renameTabExpectation.isInverted = true
        let renameTabToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { _ in
            renameTabExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(renameTabToken) }

        guard let event = makeKeyDownEvent(
            key: "r",
            modifiers: [.command, .shift],
            keyCode: 15, // kVK_ANSI_R
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+R event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [workspaceExpectation, renameTabExpectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceWindow?.windowNumber, window.windowNumber)
    }

    func testCmdDigitDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        _ = firstManager.addTab(select: true)
        _ = secondManager.addTab(select: true)
        guard let firstSelectedBefore = firstManager.selectedTabId,
              let secondSelectedBefore = secondManager.selectedTabId else {
            XCTFail("Expected selected tabs in both windows")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Force stale app-level manager to first window while keyboard event
        // references no known window.
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "1",
            modifiers: [.command],
            keyCode: 18,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+1 event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.selectedTabId, firstSelectedBefore, "Unresolved event window must not route Cmd+1 into stale manager")
        XCTAssertEqual(secondManager.selectedTabId, secondSelectedBefore, "Unresolved event window must not route Cmd+1 into key/main fallback manager")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testCmdNDoesNotFallbackToOtherWindowWhenEventWindowContextIsMissing() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let firstWindowId = appDelegate.createMainWindow()
        let secondWindowId = appDelegate.createMainWindow()

        defer {
            closeWindow(withId: firstWindowId)
            closeWindow(withId: secondWindowId)
        }

        guard let firstManager = appDelegate.tabManagerFor(windowId: firstWindowId),
              let secondManager = appDelegate.tabManagerFor(windowId: secondWindowId),
              let secondWindow = window(withId: secondWindowId) else {
            XCTFail("Expected both window contexts to exist")
            return
        }

        secondWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let firstCount = firstManager.tabs.count
        let secondCount = secondManager.tabs.count
        appDelegate.tabManager = firstManager

        guard let event = makeKeyDownEvent(
            key: "n",
            modifiers: [.command],
            keyCode: 45,
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+N event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(firstManager.tabs.count, firstCount, "Unresolved event window must not create workspace in stale manager")
        XCTAssertEqual(secondManager.tabs.count, secondCount, "Unresolved event window must not create workspace in fallback window")
        XCTAssertTrue(appDelegate.tabManager === firstManager, "Unresolved event window should not retarget active manager")
    }

    func testPresentPreferencesWindowShowsCustomSettingsWindowAndActivates() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: {
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 1)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    func testPresentPreferencesWindowSupportsRepeatedCalls() {
        var showFallbackSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: {
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            showFallbackSettingsWindow: {
                showFallbackSettingsWindowCallCount += 1
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(showFallbackSettingsWindowCallCount, 2)
        XCTAssertEqual(activateApplicationCallCount, 2)
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
