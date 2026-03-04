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
        var didObserveWorkspaceNotification = false
        let workspaceToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteRenameWorkspaceRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard !didObserveWorkspaceNotification else { return }
            didObserveWorkspaceNotification = true
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

    func testEscapeDismissesVisibleCommandPaletteAndIsConsumed() {
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
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
        }

        let dismissExpectation = expectation(description: "Expected command palette toggle notification for Escape dismiss")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let event = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53, // kVK_Escape
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

        wait(for: [dismissExpectation], timeout: 1.0)
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDoesNotDismissCommandPaletteWhenInputHasMarkedText() {
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

        let fieldEditor = CommandPaletteMarkedTextFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        fieldEditor.hasMarkedTextForTesting = true
        window.contentView?.addSubview(fieldEditor)
        XCTAssertTrue(window.makeFirstResponder(fieldEditor))

        appDelegate.setCommandPaletteVisible(true, for: window)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
            fieldEditor.removeFromSuperview()
        }

        let dismissExpectation = expectation(
            description: "Escape should not dismiss command palette while IME marked text is active"
        )
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            guard let dismissWindow = notification.object as? NSWindow,
                  dismissWindow.windowNumber == window.windowNumber else { return }
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should pass through to IME composition instead of dismissing command palette"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilitySyncLagsAfterOpenRequest() {
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

        let dismissExpectation = expectation(description: "Expected command palette dismiss notification for Escape")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Simulate a visibility sync lag/race where AppDelegate does not yet know the palette is open.
        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
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
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateStaysStalePastInitialPendingWindow() {
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

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping.
        appDelegate.setCommandPaletteVisible(false, for: window)
        // Reproduce the log-backed failure mode where the user presses Escape after a brief delay.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.25))

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
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
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesCommandPaletteWhenVisibilityStateRemainsStaleForExtendedDelay() {
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

#if DEBUG
        appDelegate.debugMarkCommandPaletteOpenPending(window: window)
#else
        XCTFail("debugMarkCommandPaletteOpenPending is only available in DEBUG")
#endif

        // Simulate stale app-level visibility bookkeeping for a longer user delay.
        appDelegate.setCommandPaletteVisible(false, for: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6.25))

        let dismissExpectation = expectation(description: "Escape should dismiss stale-state command palette after extended delay")
        var observedDismissWindow: NSWindow?
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { notification in
            observedDismissWindow = notification.object as? NSWindow
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
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
        XCTAssertEqual(observedDismissWindow?.windowNumber, window.windowNumber)
    }

    func testEscapeDismissesMenuTriggeredCommandPaletteWhenVisibilitySyncIsStale() {
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

        // Reproduce the menu-command path (Cmd+Shift+P/Cmd+P) routed via AppDelegate.
        appDelegate.requestCommandPaletteCommands(
            preferredWindow: window,
            source: "test.menuCommandPalette"
        )
        // Simulate delayed/stale visibility sync from SwiftUI overlay state.
        appDelegate.setCommandPaletteVisible(false, for: window)

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should still be consumed for menu-triggered command palette opens"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeRepeatIsConsumedImmediatelyAfterPaletteDismiss() {
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

        guard let firstEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct first Escape event")
            return
        }

        guard let repeatedEscape = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber,
            isARepeat: true
        ) else {
            XCTFail("Failed to construct repeated Escape event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: firstEscape))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state while the Escape key is still held.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: repeatedEscape),
            "Repeated Escape immediately after dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterPaletteDismissToPreventTerminalLeak() {
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

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyDown event")
            return
        }

        guard let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape keyUp event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown))
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif

        // Simulate the palette overlay synchronizing to closed state before Escape key-up arrives.
        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp after palette dismiss should be consumed to prevent terminal passthrough"
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
    }

    func testEscapeKeyUpIsConsumedAfterCmdPSwitcherDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteSwitcher(
                preferredWindow: window,
                source: "test.cmdP"
            )
        }
    }

    func testEscapeKeyUpIsConsumedAfterCmdShiftPCommandsDismiss() {
        assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest { appDelegate, window in
            appDelegate.requestCommandPaletteCommands(
                preferredWindow: window,
                source: "test.cmdShiftP"
            )
        }
    }

    func testEscapeDoesNotDismissPaletteInDifferentWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let paletteWindowId = appDelegate.createMainWindow()
        let eventWindowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: paletteWindowId)
            closeWindow(withId: eventWindowId)
        }

        guard let paletteWindow = window(withId: paletteWindowId),
              let eventWindow = window(withId: eventWindowId) else {
            XCTFail("Expected both test windows")
            return
        }

        appDelegate.setCommandPaletteVisible(true, for: paletteWindow)
        defer {
            appDelegate.setCommandPaletteVisible(false, for: paletteWindow)
        }

        let dismissExpectation = expectation(description: "Escape in another window should not dismiss palette")
        dismissExpectation.isInverted = true
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .commandPaletteToggleRequested,
            object: nil,
            queue: nil
        ) { _ in
            dismissExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(dismissToken) }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: eventWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: escapeEvent),
            "Escape should remain scoped to the event window"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        wait(for: [dismissExpectation], timeout: 0.2)
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

    func testCmdShiftMReturnsFalseWhenNoFocusedTerminalCanHandle() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Force unresolved shortcut routing context and no active manager.
        appDelegate.tabManager = nil

        guard let event = makeKeyDownEvent(
            key: "m",
            modifiers: [.command, .shift],
            keyCode: 46, // kVK_ANSI_M
            windowNumber: Int.max
        ) else {
            XCTFail("Failed to construct Cmd+Shift+M event")
            return
        }

#if DEBUG
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: event),
            "Cmd+Shift+M should not be consumed when no terminal can toggle copy mode"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
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
        makeKeyEvent(
            type: .keyDown,
            key: key,
            modifiers: modifiers,
            keyCode: keyCode,
            windowNumber: windowNumber,
            isARepeat: isARepeat
        )
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
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

    private func assertEscapeKeyUpIsConsumedAfterCommandPaletteOpenRequest(
        _ openRequest: (_ appDelegate: AppDelegate, _ window: NSWindow) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected test window", file: file, line: line)
            return
        }

        openRequest(appDelegate, window)
        appDelegate.setCommandPaletteVisible(true, for: window)

        guard let escapeKeyDown = makeKeyEvent(
            type: .keyDown,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ), let escapeKeyUp = makeKeyEvent(
            type: .keyUp,
            key: "\u{1b}",
            modifiers: [],
            keyCode: 53,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Escape key events", file: file, line: line)
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyDown), file: file, line: line)
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif

        appDelegate.setCommandPaletteVisible(false, for: window)

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleShortcutMonitorEvent(event: escapeKeyUp),
            "Escape keyUp should be consumed after dismiss for command palette open requests",
            file: file,
            line: line
        )
#else
        XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG", file: file, line: line)
#endif
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

private final class CommandPaletteMarkedTextFieldEditor: NSTextView {
    var hasMarkedTextForTesting = false

    override func hasMarkedText() -> Bool {
        hasMarkedTextForTesting
    }
}
