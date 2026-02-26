import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class EscapeTrackingSheetPanel: NSPanel {
    private(set) var performKeyEquivalentCallCount = 0

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performKeyEquivalentCallCount += 1
        return true
    }
}

private final class EscapeTrackingCloseConfirmationPanel: NSPanel {
    private(set) var performKeyEquivalentCallCount = 0

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performKeyEquivalentCallCount += 1
        return true
    }
}

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

    func testEscapeDismissesVisibleCommandPaletteAndConsumesEvent() {
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

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let dismissExpectation = expectation(description: "Expected command palette dismiss request on Escape")
        var observedWindow: NSWindow?
        let token = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let toggleExpectation = expectation(description: "Escape should not route through toggle notification")
        toggleExpectation.isInverted = true
        let toggleToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { _ in
            toggleExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(toggleToken) }

        guard let event = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation, toggleExpectation], timeout: 1.0)
        XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeIsForwardedToAttachedSheetAndConsumed() {
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

        let sheet = EscapeTrackingSheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.beginSheet(sheet)
        defer {
            if sheet.sheetParent != nil {
                window.endSheet(sheet)
            }
            sheet.orderOut(nil)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let event = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: sheet.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(sheet.performKeyEquivalentCallCount, 1)
    }

    func testEscapeImmediatelyAfterCmdPSwitcherRequestConsumesBeforeVisibilitySync() {
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
        appDelegate.setCommandPaletteVisible(false, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let switcherExpectation = expectation(description: "Expected command palette switcher request")
        var switcherWindow: NSWindow?
        let switcherToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteSwitcherRequested,
            object: nil,
            queue: nil
        ) { notification in
            switcherWindow = notification.object as? NSWindow
            switcherExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(switcherToken) }

        guard let commandPEvent = makeKeyDownEvent(
            key: "p",
            modifiers: [.command],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: commandPEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        wait(for: [switcherExpectation], timeout: 1.0)
        XCTAssertEqual(switcherWindow?.windowNumber, window.windowNumber)

        // Simulate the race where palette visibility has not yet synced when Escape arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Expected command palette dismiss request on immediate Escape")
        var dismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            dismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(dismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeImmediatelyAfterCmdShiftPRequestConsumesBeforeVisibilitySync() {
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
        appDelegate.setCommandPaletteVisible(false, for: window)
        defer { appDelegate.setCommandPaletteVisible(false, for: window) }

        let requestExpectation = expectation(description: "Expected command palette request")
        var requestWindow: NSWindow?
        let requestToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: nil
        ) { notification in
            requestWindow = notification.object as? NSWindow
            requestExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(requestToken) }

        guard let commandShiftPEvent = makeKeyDownEvent(
            key: "p",
            modifiers: [.command, .shift],
            keyCode: 35,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Shift+P event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: commandShiftPEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        wait(for: [requestExpectation], timeout: 1.0)
        XCTAssertEqual(requestWindow?.windowNumber, window.windowNumber)

        // Simulate the race where palette visibility has not yet synced when Escape arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

        let dismissExpectation = expectation(description: "Expected command palette dismiss request on immediate Escape")
        var dismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteDismissRequested,
            object: nil,
            queue: nil
        ) { notification in
            dismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: escapeEvent))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(dismissWindow?.windowNumber, window.windowNumber)
    }

    func testRepeatedEscapeAfterCommandPaletteDismissIsConsumed() {
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

        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let initialEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct initial Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: initialEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testNonRepeatedFollowupEscapeAfterCommandPaletteDismissIsConsumed() {
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

        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let initialEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct initial Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: initialEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let followupEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct follow-up Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: followupEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testRepeatedEscapeAfterConsumedFollowupEscapeIsConsumed() {
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

        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let initialEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct initial Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: initialEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let followupEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct follow-up Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: followupEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: repeatedEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testRepeatedEscapeWithoutOverlayStillFallsThrough() {
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

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct first Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: firstEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: repeatedEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeIsForwardedToCloseConfirmationPanelAndConsumed() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let panel = EscapeTrackingCloseConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        let label = NSTextField(labelWithString: "Close tab?")
        label.frame = NSRect(x: 16, y: 90, width: 200, height: 24)
        contentView.addSubview(label)
        panel.contentView = contentView
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let event = makeKeyDownEvent(
            key: "\u{1B}",
            modifiers: [],
            keyCode: 53,
            windowNumber: panel.windowNumber,
            isARepeat: false
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertEqual(panel.performKeyEquivalentCallCount, 1)
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
        windowNumber: Int,
        isARepeat: Bool = false
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
            isARepeat: isARepeat,
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
