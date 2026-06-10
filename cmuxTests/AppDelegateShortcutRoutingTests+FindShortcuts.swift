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

// MARK: - Find shortcut focus routing tests
extension AppDelegateShortcutRoutingTests {
    func testTerminalFirstResponderGuardBlocksMoveFocusWhenRightSidebarOwnsKeyboardFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let strayView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(strayView)
        defer { strayView.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)

        XCTAssertTrue(window.makeFirstResponder(strayView), "Expected a foreign responder before blocking terminal focus")
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .feed, in: window)

        XCTAssertFalse(
            window.makeFirstResponder(terminalView),
            "Coordinator-owned sidebar focus should block direct terminal first-responder requests"
        )

        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(window.firstResponder === strayView, "Blocked terminal moveFocus should keep the existing responder intact")
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Blocked terminal moveFocus must not leave the Ghostty surface as first responder"
        )
    }

    func testFindShortcutFromFileTreeOpensRightSidebarFind() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let sidebarResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(sidebarResponder)
        defer { sidebarResponder.removeFromSuperview() }

        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected right sidebar responder to take focus")
        appDelegate.fileExplorerState?.mode = .files
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .files, in: window)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertNil(terminalPanel.searchState, "Cmd+F from the file tree should not create terminal search state")
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, .find)
    }

    func testFindShortcutFromTerminalOpensTerminalFind() {
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
        terminalPanel.hostedView.moveFocus()
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder()
        }
        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before Cmd+F"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        appDelegate.noteTerminalKeyboardFocusIntent(workspaceId: workspace.id, panelId: terminalPanel.id, in: window)

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            terminalPanel.searchState != nil
        }
        XCTAssertNotNil(terminalPanel.searchState, "Cmd+F from terminal focus should create terminal search state")
    }

    func testFindShortcutFromOtherRightSidebarModeDoesNotStealFocus() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView,
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let sidebarResponder = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        contentView.addSubview(sidebarResponder)
        defer { sidebarResponder.removeFromSuperview() }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(window.makeFirstResponder(sidebarResponder), "Expected right sidebar responder to take focus")
        appDelegate.fileExplorerState?.mode = .feed
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .feed, in: window)
        XCTAssertFalse(
            appDelegate.allowsTerminalKeyboardFocus(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                in: window
            ),
            "Right sidebar ownership should block direct terminal focus before Cmd+F"
        )

        guard let event = makeKeyDownEvent(
            key: "f",
            modifiers: [.command],
            keyCode: 3,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+F event")
            return
        }

#if DEBUG
        XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        XCTAssertFalse(
            appDelegate.allowsTerminalKeyboardFocus(
                workspaceId: workspace.id,
                panelId: terminalPanel.id,
                in: window
            ),
            "Cmd+F should keep keyboard ownership in the existing right sidebar section"
        )
        XCTAssertNil(terminalPanel.searchState, "Cmd+F should not create terminal search state")
        XCTAssertEqual(appDelegate.fileExplorerState?.mode, .feed)
        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Cmd+F from a non-file right sidebar mode should not refocus the terminal responder"
        )
    }

}
