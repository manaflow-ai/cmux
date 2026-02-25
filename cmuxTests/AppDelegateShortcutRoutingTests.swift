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

    func testCmdShiftRAliasesToRenameTabCommandPaletteRequest() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
            KeyboardShortcutSettings.resetShortcut(for: .renameWorkspace)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "r", command: true, shift: false, option: true, control: false),
            for: .renameWorkspace
        )

        let expectation = expectation(description: "Expected rename tab command palette notification")
        var observedWindow: NSWindow?
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameTabRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedWindow = notification.object as? NSWindow
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

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

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
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
