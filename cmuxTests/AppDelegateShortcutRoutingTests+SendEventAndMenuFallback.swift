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

// MARK: - Window/application sendEvent and stale menu shortcut fallback tests
extension AppDelegateShortcutRoutingTests {
    func testWindowSendEventRepairsLostFirstResponderForFocusedTerminalTyping() {
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
              let terminalPanel = workspace.terminalPanel(for: panelId),
              let terminalView = surfaceView(in: terminalPanel.hostedView) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
        XCTAssertTrue(window.firstResponder == nil || window.firstResponder is NSWindow, "Expected a broken key-routing responder")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        // forwardedKeyDownCount is only observable through the DEBUG-only
        // GhosttyNSView.debugGhosttySurfaceKeyEventObserver seam; the first-
        // responder assertions above act as the Release-build proxy.
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
#endif
    }

    func testWindowPerformKeyEquivalentDefersTerminalPasteMenuMissToGhosttyBindingResolution() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let emptyMenu = NSMenu(title: "Test")
        emptyMenu.addItem(withTitle: "Placeholder", action: nil, keyEquivalent: "")
        NSApp.mainMenu = emptyMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "v",
            modifiers: [.command],
            keyCode: 9,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+V event")
            return
        }

        XCTAssertTrue(
            probeWindow.performKeyEquivalent(with: event),
            "Cmd+V menu miss should still route through Ghostty binding resolution"
        )
        XCTAssertEqual(probeView.afterMenuMissCallCount, 1, "Ghostty binding resolution should run after the menu miss")
        XCTAssertEqual(probeView.pasteCallCount, 0, "Window routing must not force paste before Ghostty inspects bindings")
        XCTAssertEqual(
            probeView.pasteAsPlainTextCallCount,
            0,
            "Window routing must not force plain-text paste before Ghostty inspects bindings"
        )
    }

    func testWindowPerformKeyEquivalentForwardsClearedCmdDPastStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight, shortcut: .unbound) {
            XCTAssertTrue(
                probeWindow.performKeyEquivalent(with: event),
                "Cleared Cmd+D should still be handled by forwarding it to the focused terminal"
            )
        }

        XCTAssertEqual(menuProbe.callCount, 0, "A stale menu equivalent must not keep consuming cleared Cmd+D")
        XCTAssertEqual(probeView.keyDownCallCount, 1, "Cleared Cmd+D should be forwarded into the terminal")
        XCTAssertEqual(probeView.lastKeyDownCharactersIgnoringModifiers, "d")
    }

    func testWindowPerformKeyEquivalentSuppressesRemappedCmdDStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(focusableView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(focusableView), "Expected probe view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            XCTAssertFalse(
                probeWindow.performKeyEquivalent(with: event),
                "Remapped Cmd+D should not be consumed by stale cmux menu equivalents"
            )
        }

        XCTAssertEqual(menuProbe.callCount, 0, "Cmd+D must not keep splitting after splitRight is remapped")
    }

    func testCurrentGlobalSearchShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedGlobalSearch = StoredShortcut(
            key: "d",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .globalSearch, shortcut: remappedGlobalSearch) {
            XCTAssertFalse(
                appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                "Current globalSearch remaps must not be treated as stale menu shortcuts"
            )
        }
    }

    func testCurrentNumberedDigitShortcutIsNotSuppressedAsStaleMenuShortcut() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        guard let event = makeKeyDownEvent(
            key: "2",
            modifiers: [.command],
            keyCode: 19,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Cmd+2 event")
            return
        }

        let remappedWorkspaceNumber = StoredShortcut(
            key: "1",
            command: false,
            shift: false,
            option: false,
            control: true
        )
        let currentSurfaceNumber = StoredShortcut(
            key: "1",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        withTemporaryShortcut(action: .selectWorkspaceByNumber, shortcut: remappedWorkspaceNumber) {
            withTemporaryShortcut(action: .selectSurfaceByNumber, shortcut: currentSurfaceNumber) {
                XCTAssertFalse(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "A current numbered-digit shortcut must own Cmd+2 before stale menu suppression"
                )
            }
        }
    }

    func testStaleCloseDefaultShortcutsSuppressMenuFallbackAfterReassignment() {
        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeTab,
            replacementAction: .newTab,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWorkspace,
            replacementAction: .newWindow,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: true, option: false, control: false),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: true, option: true, control: false)
        )

        assertStaleCloseDefaultShortcutSuppressesMenuFallback(
            staleAction: .closeWindow,
            replacementAction: .toggleFullScreen,
            replacementShortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: true),
            remappedStaleShortcut: StoredShortcut(key: "w", command: true, shift: false, option: true, control: true)
        )
    }

    func testApplicationSendEventRoutesReassignedCmdWBeforeStaleCloseTabMenuEquivalent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()

        let windowId = appDelegate.createMainWindow()
        guard let window = appDelegate.windowForMainWindowId(windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let initialSidebarVisible = appDelegate.sidebarVisibility(windowId: windowId) else {
            closeWindow(withId: windowId)
            XCTFail("Expected a main window context")
            return
        }

        let previousMainMenu = NSApp.mainMenu
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            closeWindow(withId: windowId)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "w"
        )
        staleCloseItem.keyEquivalentModifierMask = [.command]
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

        let initialWorkspaceCount = manager.tabs.count
        let remappedCloseTab = StoredShortcut(key: "w", command: true, shift: false, option: true, control: false)
        let reassignedSidebarToggle = StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            withTemporaryShortcut(action: .toggleSidebar, shortcut: reassignedSidebarToggle) {
                NSApp.sendEvent(event)
            }
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(menuProbe.callCount, 0, "A stale Cmd+W Close Tab menu item must not run after Cmd+W is reassigned")
        XCTAssertEqual(
            manager.tabs.count,
            initialWorkspaceCount,
            "Plain Cmd+W must not close a tab after Close Tab is remapped away"
        )
        XCTAssertEqual(
            appDelegate.sidebarVisibility(windowId: windowId),
            !initialSidebarVisible,
            "The action currently assigned to Cmd+W should run before stale Close Tab menu fallback"
        )
    }

    func testApplicationSendEventSuppressesRemappedCmdDStaleMenuShortcut() {
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let staleMenu = NSMenu(title: "Test")
        let staleSplitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        staleSplitItem.keyEquivalentModifierMask = [.command]
        staleSplitItem.target = menuProbe
        staleMenu.addItem(staleSplitItem)
        NSApp.mainMenu = staleMenu

        probeWindow.contentView = contentView
        contentView.addSubview(focusableView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(focusableView), "Expected probe view to own first responder")

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        let remappedSplitRight = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        withTemporaryShortcut(action: .splitRight, shortcut: remappedSplitRight) {
            NSApp.sendEvent(event)
        }

        XCTAssertEqual(menuProbe.callCount, 0, "App-level Cmd+D dispatch must not fire a stale split menu item after remap")
    }

    func testApplicationSendEventRoutesCmdDMenuEquivalentToActiveShortcutRecorder() {
#if DEBUG
        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let recorder = ShortcutRecorderNSButton(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        let menuProbe = MenuActionProbe()
        var recordedShortcut: StoredShortcut?

        defer {
            KeyboardShortcutRecorderActivity.stopAllRecording()
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
        }

        let menu = NSMenu(title: "Test")
        let splitItem = NSMenuItem(
            title: "Split Right",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "d"
        )
        splitItem.keyEquivalentModifierMask = [.command]
        splitItem.target = menuProbe
        menu.addItem(splitItem)
        NSApp.mainMenu = menu

        recorder.onShortcutRecorded = { recordedShortcut = $0 }
        probeWindow.contentView = contentView
        contentView.addSubview(recorder)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(recorder), "Expected shortcut recorder to own first responder")
        recorder.performClick(nil)
        XCTAssertTrue(recorder.debugIsRecording)

        guard let event = makeKeyDownEvent(
            key: "d",
            modifiers: [.command],
            keyCode: 2,
            windowNumber: probeWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+D event")
            return
        }

        withTemporaryShortcut(action: .splitRight) {
            NSApp.sendEvent(event)
        }

        XCTAssertEqual(
            recordedShortcut,
            StoredShortcut(key: "d", command: true, shift: false, option: false, control: false, keyCode: 2),
            "Cmd+D must remain recordable while the same menu equivalent is installed"
        )
        XCTAssertEqual(menuProbe.callCount, 0, "The menu equivalent must not fire while the recorder is capturing")
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testWindowSendEventRepairsVisibleSameWindowResponderDriftForFocusedTerminalTyping() {
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
        terminalPanel.hostedView.moveFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )

        XCTAssertTrue(window.makeFirstResponder(strayView), "Expected test to install a visible wrong first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
        XCTAssertTrue(window.firstResponder === strayView, "Expected a visible same-window responder drift")

#if DEBUG
        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 0 else { return }
            forwardedKeyDownCount += 1
        }
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }
#endif

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Typing should repair first responder back to the focused terminal surface"
        )
        XCTAssertTrue(window.firstResponder === terminalView, "Typing repair should restore the Ghostty surface view as first responder")
#if DEBUG
        XCTAssertGreaterThan(forwardedKeyDownCount, 0, "Typing repair should forward the keyDown into Ghostty")
#endif
    }

    func testWindowSendEventRepairsFocusedTerminalSearchTypingAfterResponderDrift() {
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let searchState = TerminalSurface.SearchState(needle: "")
        terminalPanel.surface.searchState = searchState
        terminalPanel.hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let searchField = findEditableTextField(in: terminalPanel.hostedView) else {
            XCTFail("Expected mounted terminal search field")
            return
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to own first responder before drift"
        )

        XCTAssertTrue(window.makeFirstResponder(nil), "Expected test to clear the window first responder")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to lose first responder before repaired typing"
        )

        guard let keyDown = makeKeyDownEvent(
            key: "a",
            modifiers: [],
            keyCode: 0,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct typing event")
            return
        }

        window.sendEvent(keyDown)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Typing should repair focus back to the terminal search field"
        )
        XCTAssertEqual(searchField.stringValue, "a", "Typing repair should preserve the first key in the search field")
    }

    private func assertStaleCloseDefaultShortcutSuppressesMenuFallback(
        staleAction: KeyboardShortcutSettings.Action,
        replacementAction: KeyboardShortcutSettings.Action,
        replacementShortcut: StoredShortcut,
        remappedStaleShortcut: StoredShortcut,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }
        guard let event = makeKeyDownEvent(shortcut: replacementShortcut, windowNumber: 0) else {
            XCTFail("Failed to construct reassigned close-default shortcut event", file: file, line: line)
            return
        }

        withTemporaryShortcut(action: staleAction, shortcut: remappedStaleShortcut) {
            withTemporaryShortcut(action: replacementAction, shortcut: replacementShortcut) {
                XCTAssertTrue(
                    appDelegate.shouldSuppressStaleCmuxMenuShortcut(event: event),
                    "\(staleAction.rawValue) should suppress its stale default menu fallback after that key is reassigned",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

}
