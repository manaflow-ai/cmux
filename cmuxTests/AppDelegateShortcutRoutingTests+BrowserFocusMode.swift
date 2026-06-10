import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Browser focus mode escape tests
extension AppDelegateShortcutRoutingTests {
    func testBrowserFocusModeEscapeArmsDisarmsAndSecondEscapeExits() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let inactiveEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let inactiveRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.015),
              let activeFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.04),
              let activeRepeatEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, isARepeat: true, timestamp: baseTimestamp + 0.045),
              let activeSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.05),
              let capsExitFirstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.08),
              let capsExitSecondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [.capsLock], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.09),
              let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode key events")
            return
        }

        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveEscape, webView: harness.webView, source: "unit.inactiveEscape"),
            .inactive
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(inactiveRepeatEscape, webView: harness.webView, source: "unit.inactiveRepeatEscape"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.escape", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.commandS"),
            .forwardToWebView
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeRepeatEscape, webView: harness.webView, source: "unit.activeRepeatEscape"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeFirstEscape, webView: harness.webView, source: "unit.firstEscapeAgain.duplicate"),
            .consume
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(activeSecondEscape, webView: harness.webView, source: "unit.secondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.capsEscape", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitFirstEscape, webView: harness.webView, source: "unit.capsExitFirstEscape"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(capsExitSecondEscape, webView: harness.webView, source: "unit.capsExitSecondEscape"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeStaleExitArmRearmsOnNextEscape() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        let baseTimestamp = ProcessInfo.processInfo.systemUptime
        guard let firstEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 0.01),
              let secondEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.0),
              let thirdEscape = makeKeyDownEvent(key: "\u{1b}", modifiers: [], keyCode: 53, windowNumber: harness.window.windowNumber, timestamp: baseTimestamp + 2.1) else {
            XCTFail("Failed to construct browser focus mode timeout Escape events")
            return
        }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleExitArm", focusWebView: false)
        )
        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(firstEscape, webView: harness.webView, source: "unit.staleExitArm.first"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(secondEscape, webView: harness.webView, source: "unit.staleExitArm.rearm"),
            .forwardToWebView
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        XCTAssertTrue(harness.panel.isBrowserFocusModeExitArmed)

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(thirdEscape, webView: harness.webView, source: "unit.staleExitArm.exit"),
            .consume
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeClearsWhenWebViewLeavesInteractiveHost() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.staleHost", focusWebView: false)
        )
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
        harness.webView.removeFromSuperview()

        guard let commandS = makeKeyDownEvent(key: "s", modifiers: [.command], keyCode: 1, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct Cmd+S event")
            return
        }

        XCTAssertEqual(
            appDelegate.handleBrowserFocusModeKeyEvent(commandS, webView: harness.webView, source: "unit.staleHost"),
            .inactive
        )
        XCTAssertFalse(harness.panel.isBrowserFocusModeActive)
        XCTAssertFalse(harness.panel.isBrowserFocusModeExitArmed)
    }

    func testBrowserFocusModeCommandEquivalentSkipsAppMenuFallback() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }
        guard let harness = makeBrowserFocusModeHarness() else { return }
        defer { closeWindow(withId: harness.windowId) }

        XCTAssertTrue(
            harness.panel.setBrowserFocusModeActive(true, reason: "unit.commandEquivalent", focusWebView: false)
        )

        let originalMainMenu = NSApp.mainMenu
        let probe = MenuActionProbe()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Find", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command]
        item.target = probe
        menu.addItem(item)
        let returnItem = NSMenuItem(title: "Run", action: #selector(MenuActionProbe.perform(_:)), keyEquivalent: "\r")
        returnItem.keyEquivalentModifierMask = [.command]
        returnItem.target = probe
        menu.addItem(returnItem)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMainMenu }

        guard let commandF = makeKeyDownEvent(key: "f", modifiers: [.command], keyCode: 3, windowNumber: harness.window.windowNumber),
              let commandReturn = makeKeyDownEvent(key: "\r", modifiers: [.command], keyCode: 36, windowNumber: harness.window.windowNumber) else {
            XCTFail("Failed to construct browser focus mode command-equivalent events")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: commandF))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandF))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must not replay unhandled page shortcuts into the app menu")
        XCTAssertTrue(harness.webView.performKeyEquivalent(with: commandReturn))
        XCTAssertEqual(probe.callCount, 0, "Focus mode must consume unhandled Cmd+Return instead of falling through to the app menu")
        XCTAssertTrue(harness.panel.isBrowserFocusModeActive)
    }

    private func makeBrowserFocusModeHarness(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (windowId: UUID, window: NSWindow, panel: BrowserPanel, webView: CmuxWebView)? {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return nil
        }

        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserURL = URL(string: "data:text/html;base64,PGh0bWw+PGJvZHk+Zm9jdXM8L2JvZHk+PC9odG1sPg=="),
              let browserPanelId = manager.openBrowser(inWorkspace: workspace.id, url: browserURL, preferSplitRight: true),
              let browserPanel = manager.selectedWorkspace?.browserPanel(for: browserPanelId) ?? workspace.browserPanel(for: browserPanelId),
              let webView = browserPanel.webView as? CmuxWebView else {
            closeWindow(withId: windowId)
            XCTFail("Expected attached browser focus mode harness", file: file, line: line)
            return nil
        }

        workspace.focusPanel(browserPanel.id)
        if webView.superview == nil {
            webView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(webView)
        }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(webView), file: file, line: line)
        return (windowId: windowId, window: window, panel: browserPanel, webView: webView)
    }

}
