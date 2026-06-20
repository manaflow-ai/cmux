import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateSurfaceShortcutRoutingTests: XCTestCase {
    func testRightSidebarModeShortcutsDoNotFallThroughWhenResponderTemporarilyClears() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)

        let rawModeEvents: [(mode: RightSidebarMode, event: NSEvent?)] = [
            (.files, makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber)),
            (.find, makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: window.windowNumber)),
            (.sessions, makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: window.windowNumber))
        ]
        let modeEvents = rawModeEvents.compactMap { entry -> (mode: RightSidebarMode, event: NSEvent)? in
            guard let event = entry.event else { return nil }
            return (entry.mode, event)
        }
        XCTAssertEqual(modeEvents.count, 3, "Failed to construct Ctrl+1/2/3 events")

        for cycle in 0..<10 {
            for (mode, event) in modeEvents {
                _ = window.makeFirstResponder(nil)
#if DEBUG
                XCTAssertTrue(
                    appDelegate.debugHandleCustomShortcut(event: event),
                    "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should be handled on cycle \(cycle)"
                )
#else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
                XCTAssertEqual(
                    appDelegate.fileExplorerState?.mode,
                    mode,
                    "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should keep routing as a right-sidebar mode shortcut on cycle \(cycle)"
                )
                XCTAssertFalse(
                    terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                    "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should not refocus the terminal on cycle \(cycle)"
                )
            }
        }
    }

    func testSurfaceNumberShortcutsCycleInEventWindowWhenActiveManagerIsStale() {
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
              let secondWorkspace = secondManager.selectedWorkspace,
              secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true) != nil,
              secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true) != nil else {
            XCTFail("Expected two window contexts and three surfaces in the event window")
            return
        }

        let expectedSurfaceIds = Array(secondWorkspace.orderedPanelIds.prefix(3))
        XCTAssertEqual(expectedSurfaceIds.count, 3, "Test needs three ordered surfaces")
        XCTAssertNotEqual(firstWorkspace.id, secondWorkspace.id)

        appDelegate.tabManager = firstManager
        XCTAssertTrue(appDelegate.tabManager === firstManager)

        let rawDigitEvents: [(digit: Int, event: NSEvent?)] = [
            (1, makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: secondWindow.windowNumber)),
            (2, makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: secondWindow.windowNumber)),
            (3, makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: secondWindow.windowNumber))
        ]
        let digitEvents = rawDigitEvents.compactMap { entry -> (digit: Int, event: NSEvent)? in
            guard let event = entry.event else { return nil }
            return (entry.digit, event)
        }
        XCTAssertEqual(digitEvents.count, 3, "Failed to construct Ctrl+1/2/3 events")

        withTemporaryShortcut(action: .selectSurfaceByNumber) {
            for cycle in 0..<10 {
                for (digit, event) in digitEvents {
#if DEBUG
                    XCTAssertTrue(
                        appDelegate.debugHandleCustomShortcut(event: event),
                        "Ctrl+\(digit) should be handled on cycle \(cycle)"
                    )
#else
                    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
                    XCTAssertEqual(
                        secondWorkspace.focusedPanelId,
                        expectedSurfaceIds[digit - 1],
                        "Ctrl+\(digit) should focus surface \(digit) in the event window on cycle \(cycle)"
                    )
                }
            }
        }
    }

    private func makeKeyDownEvent(key: String, keyCode: UInt16, windowNumber: Int) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(action: KeyboardShortcutSettings.Action, _ body: () -> Void) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        body()
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.close()
    }
}
