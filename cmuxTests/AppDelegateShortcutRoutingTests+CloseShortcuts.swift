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

// MARK: - Close window/tab/panel shortcut tests
extension AppDelegateShortcutRoutingTests {
    private func ghosttyConfigKeyIsBinding(
        _ config: ghostty_config_t,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt32
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keyCode
        keyEvent.mods = ghosttyMods(from: modifiers)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = key.unicodeScalars.first.map { UInt32($0.value) } ?? 0
        keyEvent.composing = false

        return key.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_config_key_is_binding(config, keyEvent)
        }
    }

    private func ghosttyMods(from modifiers: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue
        if modifiers.contains(.shift) { rawValue |= GHOSTTY_MODS_SHIFT.rawValue }
        if modifiers.contains(.control) { rawValue |= GHOSTTY_MODS_CTRL.rawValue }
        if modifiers.contains(.option) { rawValue |= GHOSTTY_MODS_ALT.rawValue }
        if modifiers.contains(.command) { rawValue |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: rawValue)
    }

    func testCmdCtrlWPromptsBeforeClosingWindow() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }

        var promptedWindow: NSWindow?
        appDelegate.debugCloseMainWindowConfirmationHandler = { candidate in
            promptedWindow = candidate
            return false
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(promptedWindow === targetWindow, "Cmd+Ctrl+W should prompt for the target main window")
        XCTAssertNotNil(self.window(withId: windowId), "Cancelling the confirmation should keep the window open")
    }

    func testCmdCtrlWClosesWindowAfterConfirmation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        guard let targetWindow = window(withId: windowId) else {
            XCTFail("Expected test window")
            return
        }
        targetWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = nil }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command, .control],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+Ctrl+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            self.window(withId: windowId)?.isVisible != true
        }

        XCTAssertFalse(
            self.window(withId: windowId)?.isVisible == true,
            "Confirming Cmd+Ctrl+W should close the window"
        )
    }

    func testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        // Auto-confirm window close to avoid a modal dialog that blocks the RunLoop.
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = nil }

        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defaults.set(true, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            restoreDefaultsValue(originalSetting, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey, defaults: defaults)
        }

        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let targetWindow = makeRegisteredShortcutRoutingWindow(id: windowId)
        appDelegate.registerMainWindow(
            targetWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer { closeRegisteredShortcutRoutingWindow(targetWindow, id: windowId) }

        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected test workspace")
            return
        }

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        targetWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        waitUntil(timeout: 1.0) {
            self.window(withId: windowId)?.isVisible != true
        }

        XCTAssertFalse(
            self.window(withId: windowId)?.isVisible == true,
            "Cmd+W on the last surface in the last workspace should close the window"
        )
    }

    func testCmdWKeepsLastSurfaceWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }

        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let targetWindow = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected test window, manager, workspace, and focused panel")
            return
        }

        // This test exercises keep-workspace-open semantics, not close-confirm heuristics.
        // Mark the shell idle so Cmd+W routes through the immediate close path deterministically.
        workspace.updatePanelShellActivityState(panelId: initialPanelId, state: .promptIdle)

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: targetWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNotNil(
            self.window(withId: windowId),
            "Cmd+W should keep the window open when the keep-workspace-open preference is enabled"
        )
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCmdWTargetsFocusedWindowWhenEventWindowMetadataIsStale() {
        assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
            actionName: "Cmd+W",
            modifiers: [.command],
            expectedAction: .closeTab
        )
    }

    func testCmdShiftWTargetsFocusedWindowWhenEventWindowMetadataIsStale() {
        assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
            actionName: "Cmd+Shift+W",
            modifiers: [.command, .shift],
            expectedAction: .closeWorkspace
        )
    }

    func testRemappedCloseTabDoesNotLetCmdWReachGhosttyCloseSurfaceFallback() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let mainWindow = window(withId: windowId) else {
            XCTFail("Expected test main window")
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let previousMainMenu = NSApp.mainMenu
        let probeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        probeWindow.isReleasedWhenClosed = false
        probeWindow.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
        let contentView = NSView(frame: probeWindow.contentRect(forFrameRect: probeWindow.frame))
        let probeView = GhosttyCommandEquivalentProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let menuProbe = MenuActionProbe()

        defer {
            NSApp.mainMenu = previousMainMenu
            probeWindow.orderOut(nil)
            probeWindow.close()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
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

        probeWindow.contentView = contentView
        contentView.addSubview(probeView)
        probeWindow.makeKeyAndOrderFront(nil)
        probeWindow.displayIfNeeded()
        XCTAssertTrue(probeWindow.makeFirstResponder(probeView), "Expected probe Ghostty view to own first responder")

        guard let ghosttyConfig = GhosttyApp.shared.config else {
            XCTFail("Expected loaded Ghostty config")
            return
        }

        let remappedCloseTab = StoredShortcut(
            key: "w",
            command: true,
            shift: false,
            option: true,
            control: false
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            guard let staleCmdW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command],
                keyCode: 13,
                windowNumber: probeWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+W event")
                return
            }

            XCTAssertFalse(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: staleCmdW),
                "After Close Tab is remapped, Cmd+W must not match the cmux Close Tab action"
            )
            if ghosttyConfigKeyIsBinding(ghosttyConfig, key: "w", modifiers: [.command], keyCode: 13) {
                XCTFail("After Close Tab is remapped, Ghostty must not retain its super+w close_surface fallback")
                return
            }

            XCTAssertTrue(
                probeWindow.performKeyEquivalent(with: staleCmdW),
                "Remapped-away Cmd+W should be handled only by forwarding it to the focused terminal"
            )
            XCTAssertEqual(
                menuProbe.callCount,
                0,
                "A stale Close Tab menu equivalent must not keep consuming Cmd+W after remap"
            )
            XCTAssertEqual(
                probeView.keyDownCallCount,
                1,
                "Remapped-away Cmd+W should reach the terminal as input instead of closing through cmux"
            )
            XCTAssertEqual(probeView.lastKeyDownCharactersIgnoringModifiers, "w")

            guard let remappedCmdOptionW = makeKeyDownEvent(
                key: "w",
                modifiers: [.command, .option],
                keyCode: 13,
                windowNumber: probeWindow.windowNumber
            ) else {
                XCTFail("Failed to construct Cmd+Option+W event")
                return
            }

            XCTAssertTrue(
                KeyboardShortcutSettings.shortcut(for: .closeTab).matches(event: remappedCmdOptionW),
                "The remapped Cmd+Option+W shortcut should match the cmux Close Tab action"
            )
#if DEBUG
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: remappedCmdOptionW),
                "The remapped Cmd+Option+W shortcut should trigger the cmux Close Tab action"
            )
#else
            XCTFail("debugHandleShortcutMonitorEvent is only available in DEBUG")
#endif
        }
    }

    func testBrowserPopupPanelCloseShortcutFollowsCloseTabRemap() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        let previousMainMenu = NSApp.mainMenu
        let menuProbe = MenuActionProbe()
        let staleMenu = NSMenu(title: "Stale Close Tab")
        let staleCloseItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: defaultCloseTab.menuItemKeyEquivalent ?? ""
        )
        staleCloseItem.keyEquivalentModifierMask = defaultCloseTab.modifierFlags
        staleCloseItem.target = menuProbe
        staleMenu.addItem(staleCloseItem)
        NSApp.mainMenu = staleMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let remappedCloseTab = StoredShortcut(
            key: defaultCloseTab.key,
            command: defaultCloseTab.command,
            shift: defaultCloseTab.shift,
            option: !defaultCloseTab.option,
            control: defaultCloseTab.control,
            keyCode: defaultCloseTab.keyCode
        )

        withTemporaryShortcut(action: .closeTab, shortcut: remappedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let staleDefaultCloseTab = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: staleDefaultCloseTab),
                "After Close Tab is remapped, the default Close Tab shortcut should be consumed without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Remapped-away default Close Tab shortcut should leave the browser popup open")
            XCTAssertEqual(menuProbe.callCount, 0, "Stale Close Tab menu items must not close the parent browser tab")

            guard let remappedCloseTabEvent = makeKeyDownEvent(
                shortcut: remappedCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct remapped Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: remappedCloseTabEvent),
                "The configured Close Tab shortcut should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Remapped Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelCloseShortcutSupportsChordedCloseTabRemap() throws {
        guard AppDelegate.shared != nil else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let chordedCloseTab = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            keyCode: 11,
            chordKey: "n",
            chordCommand: false,
            chordShift: false,
            chordOption: false,
            chordControl: false,
            chordKeyCode: 45
        )

        withTemporaryShortcut(action: .closeTab, shortcut: chordedCloseTab) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let prefixEvent = makeKeyDownEvent(
                key: "b",
                modifiers: [.control],
                keyCode: 11,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct Ctrl+B prefix event")
                return
            }

            guard let suffixEvent = makeKeyDownEvent(
                key: "n",
                modifiers: [],
                keyCode: 45,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct N suffix event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: prefixEvent),
                "A chorded Close Tab prefix should be consumed without closing the browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Chord prefix alone should leave the browser popup open")

            XCTAssertTrue(
                panel.performKeyEquivalent(with: suffixEvent),
                "The chorded Close Tab suffix should close the browser popup"
            )
            XCTAssertFalse(panel.isVisible, "Chorded Close Tab shortcut should close the browser popup")
        }
    }

    func testBrowserPopupPanelLeavesDefaultCloseTabShortcutAloneWhenCloseTabIsUnbound() throws {
        let defaultCloseTab = KeyboardShortcutSettings.Action.closeTab.defaultShortcut
        withTemporaryShortcut(action: .closeTab, shortcut: .unbound) {
            let panel = BrowserPopupPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("cmux.browser-popup")
            panel.orderFront(nil)
            defer { panel.orderOut(nil) }

            guard let defaultCloseTabEvent = makeKeyDownEvent(
                shortcut: defaultCloseTab,
                windowNumber: panel.windowNumber
            ) else {
                XCTFail("Failed to construct default Close Tab event")
                return
            }

            XCTAssertTrue(
                panel.performKeyEquivalent(with: defaultCloseTabEvent),
                "Unbinding Close Tab should consume the default Close Tab shortcut without closing a browser popup"
            )
            XCTAssertTrue(panel.isVisible, "Unbound Close Tab should leave the browser popup open")
        }
    }

    func testCmdWClosesAuxiliaryWindowInsteadOfMainTerminalPanel() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        XCTAssertNotNil(window(withId: windowId), "Expected test window")

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected test manager")
            return
        }

        let mainWorkspaceCount = manager.tabs.count
        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        auxiliaryWindow.isReleasedWhenClosed = false
        auxiliaryWindow.animationBehavior = .none
        auxiliaryWindow.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        auxiliaryWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(auxiliaryWindow.isVisible, "Expected auxiliary window to be visible before Cmd+W")

        defer {
            if auxiliaryWindow.isVisible {
                closeTestWindow(auxiliaryWindow)
            }
        }

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: [.command],
            keyCode: 13,
            windowNumber: auxiliaryWindow.windowNumber
        ) else {
            XCTFail("Failed to construct Cmd+W event")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
#else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(auxiliaryWindow.isVisible, "Cmd+W should close the auxiliary window")
        XCTAssertNotNil(self.window(withId: windowId), "Cmd+W in auxiliary window should not close the main window")
        XCTAssertEqual(manager.tabs.count, mainWorkspaceCount, "Cmd+W in auxiliary window should not close a terminal panel")
        XCTAssertNotEqual(NSApp.keyWindow?.identifier?.rawValue, "cmux.about", "Closed auxiliary window should not remain key")
    }

    private func assertCloseShortcutTargetsFocusedWindowWhenEventWindowMetadataIsStale(
        actionName: String,
        modifiers: NSEvent.ModifierFlags,
        expectedAction: KeyboardShortcutSettings.Action,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared", file: file, line: line)
            return
        }

        let defaults = UserDefaults.standard
        let originalLastSurfaceCloseSetting = defaults.object(forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        let previousTabManager = appDelegate.tabManager
        defaults.set(true, forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey)
        defer {
            appDelegate.tabManager = previousTabManager
            restoreDefaultsValue(
                originalLastSurfaceCloseSetting,
                forKey: appDelegateLastSurfaceCloseShortcutDefaultsKey,
                defaults: defaults
            )
        }

        let originalWindowId = UUID()
        let focusedWindowId = UUID()
        let originalManager = TabManager(autoWelcomeIfNeeded: false)
        let focusedManager = TabManager(autoWelcomeIfNeeded: false)
        let originalWindow = makeRegisteredShortcutRoutingWindow(id: originalWindowId)
        let focusedWindow = makeRegisteredShortcutRoutingWindow(id: focusedWindowId)

        appDelegate.registerMainWindow(
            originalWindow,
            windowId: originalWindowId,
            tabManager: originalManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.registerMainWindow(
            focusedWindow,
            windowId: focusedWindowId,
            tabManager: focusedManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        defer {
            closeRegisteredShortcutRoutingWindow(originalWindow, id: originalWindowId)
            closeRegisteredShortcutRoutingWindow(focusedWindow, id: focusedWindowId)
        }

        let originalWorkspace = originalManager.addWorkspace(title: "original target", select: true, autoWelcomeIfNeeded: false)
        let focusedWorkspace = focusedManager.addWorkspace(title: "focused target", select: true, autoWelcomeIfNeeded: false)

        switch expectedAction {
        case .closeTab:
            guard let originalPanelId = originalWorkspace.focusedPanelId,
                  originalWorkspace.newTerminalSplit(from: originalPanelId, orientation: .horizontal) != nil,
                  let focusedPanelId = focusedWorkspace.focusedPanelId,
                  focusedWorkspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) != nil else {
                XCTFail("Expected split panels for \(actionName)", file: file, line: line)
                return
            }
        case .closeWorkspace:
            originalManager.addWorkspace(title: "original survivor", select: false, autoWelcomeIfNeeded: false)
            focusedManager.addWorkspace(title: "focused survivor", select: false, autoWelcomeIfNeeded: false)
        default:
            XCTFail("Unexpected close shortcut action \(expectedAction)", file: file, line: line)
            return
        }

        originalWindow.orderFront(nil)
        focusedWindow.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Model the observed bug: the user-visible focused window is the new window,
        // but the key event still carries the original window number.
        appDelegate.tabManager = originalManager

        let originalTabCountBefore = originalManager.tabs.count
        let focusedTabCountBefore = focusedManager.tabs.count
        let originalPanelCountBefore = originalWorkspace.panels.count
        let focusedPanelCountBefore = focusedWorkspace.panels.count

        guard let event = makeKeyDownEvent(
            key: "w",
            modifiers: modifiers,
            keyCode: 13,
            windowNumber: originalWindow.windowNumber
        ) else {
            XCTFail("Failed to construct \(actionName) event", file: file, line: line)
            return
        }

        XCTAssertTrue(
            KeyboardShortcutSettings.shortcut(for: expectedAction).matches(event: event),
            "\(actionName) should match \(expectedAction)",
            file: file,
            line: line
        )

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), file: file, line: line)
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG", file: file, line: line)
#endif

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            originalManager.tabs.count,
            originalTabCountBefore,
            "\(actionName) must not close a workspace in the original window when another window is focused",
            file: file,
            line: line
        )

        switch expectedAction {
        case .closeTab:
            XCTAssertEqual(
                originalWorkspace.panels.count,
                originalPanelCountBefore,
                "\(actionName) must not close a panel in the original window when another window is focused",
                file: file,
                line: line
            )
            XCTAssertEqual(
                focusedManager.tabs.count,
                focusedTabCountBefore,
                "\(actionName) should keep the focused workspace open when closing one of multiple panels",
                file: file,
                line: line
            )
            XCTAssertEqual(
                focusedWorkspace.panels.count,
                focusedPanelCountBefore - 1,
                "\(actionName) should close the selected panel in the focused window",
                file: file,
                line: line
            )
        case .closeWorkspace:
            XCTAssertEqual(
                focusedManager.tabs.count,
                focusedTabCountBefore - 1,
                "\(actionName) should close the selected workspace in the focused window",
                file: file,
                line: line
            )
            XCTAssertFalse(
                focusedManager.tabs.contains { $0.id == focusedWorkspace.id },
                "\(actionName) should remove the selected workspace in the focused window",
                file: file,
                line: line
            )
        default:
            break
        }
    }

    private func closeTestWindow(_ window: NSWindow) {
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }

}
