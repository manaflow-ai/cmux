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
