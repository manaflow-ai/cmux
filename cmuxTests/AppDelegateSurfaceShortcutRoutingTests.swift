import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ShortcutUnrelatedResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite(.serialized)
struct AppDelegateSurfaceShortcutRoutingTests {
    @Test func rightSidebarModeShortcutsDoNotFallThroughWhenResponderTemporarilyClears() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)

            let modeEvents: [(mode: RightSidebarMode, event: NSEvent)] = [
                (.files, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))),
                (.find, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: window.windowNumber))),
                (.sessions, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: window.windowNumber)))
            ]

            for cycle in 0..<10 {
                for (mode, event) in modeEvents {
                    _ = window.makeFirstResponder(nil)
#if DEBUG
                    #expect(
                        appDelegate.debugHandleCustomShortcut(event: event),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should be handled on cycle \(cycle)"
                    )
#else
                    Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                    #expect(
                        appDelegate.fileExplorerState?.mode == mode,
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should keep routing as a right-sidebar mode shortcut on cycle \(cycle)"
                    )
                    #expect(
                        !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should not refocus the terminal on cycle \(cycle)"
                    )
                }
            }
        }
    }

    @Test func rightSidebarModeShortcutsDoNotUseStaleIntentForUnrelatedResponder() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
            let fileExplorerState = try #require(appDelegate.fileExplorerState)
            fileExplorerState.mode = .sessions

            let unrelatedResponder = ShortcutUnrelatedResponderView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            window.contentView?.addSubview(unrelatedResponder)
            defer { unrelatedResponder.removeFromSuperview() }
            #expect(window.makeFirstResponder(unrelatedResponder))
            #expect(window.firstResponder === unrelatedResponder)

            KeyboardShortcutSettings.clearShortcut(for: .selectSurfaceByNumber)
#if DEBUG
            appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif

            let event = try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))
#if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(
                fileExplorerState.mode == .sessions,
                "Ctrl+1 should not switch right-sidebar mode when a non-sidebar responder owns focus"
            )
            #expect(
                window.firstResponder === unrelatedResponder,
                "Ctrl+1 should not move focus away from the unrelated responder"
            )
        }
    }

    @Test func surfaceNumberShortcutsCycleInEventWindowWhenActiveManagerIsStale() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let firstWindowId = appDelegate.createMainWindow()
            let secondWindowId = appDelegate.createMainWindow()
            defer {
                closeWindow(withId: firstWindowId)
                closeWindow(withId: secondWindowId)
            }

            let firstManager = try #require(appDelegate.tabManagerFor(windowId: firstWindowId))
            let secondManager = try #require(appDelegate.tabManagerFor(windowId: secondWindowId))
            let secondWindow = try #require(mainWindow(for: secondWindowId))
            let firstWorkspace = try #require(firstManager.selectedWorkspace)
            let secondWorkspace = try #require(secondManager.selectedWorkspace)
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))

            let expectedSurfaceIds = Array(secondWorkspace.orderedPanelIds.prefix(3))
            #expect(expectedSurfaceIds.count == 3, "Test needs three ordered surfaces")
            #expect(firstWorkspace.id != secondWorkspace.id)

            appDelegate.tabManager = firstManager
            #expect(appDelegate.tabManager === firstManager)

            let digitEvents: [(digit: Int, event: NSEvent)] = [
                (1, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: secondWindow.windowNumber))),
                (2, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: secondWindow.windowNumber))),
                (3, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: secondWindow.windowNumber)))
            ]

            try withTemporaryShortcut(action: .selectSurfaceByNumber) {
                for cycle in 0..<10 {
                    for (digit, event) in digitEvents {
#if DEBUG
                        #expect(
                            appDelegate.debugHandleCustomShortcut(event: event),
                            "Ctrl+\(digit) should be handled on cycle \(cycle)"
                        )
#else
                        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                        #expect(
                            secondWorkspace.focusedPanelId == expectedSurfaceIds[digit - 1],
                            "Ctrl+\(digit) should focus surface \(digit) in the event window on cycle \(cycle)"
                        )
                    }
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

    private func withTemporaryShortcut(action: KeyboardShortcutSettings.Action, _ body: () throws -> Void) rethrows {
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
        try body()
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-surface-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try body()
    }

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        window.close()
    }
}
