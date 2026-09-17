import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateTerminalTypingShortcutFastPathTests {
#if DEBUG
    @Test
    func plainTerminalTextDoesNotResolveAppShortcutContext() throws {
        let appDelegate = try #require(AppDelegate.shared)
        appDelegate.debugResetShortcutRoutingStateForTesting()
        NotificationsPopoverVisibilityState.shared.resetForTesting()

        let windowId = appDelegate.createMainWindow()
        defer {
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            closeWindow(withId: windowId)
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        let terminalWindow = try #require(findMainWindow(withId: windowId))
        appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(terminalWindow)
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

        terminalWindow.makeKeyAndOrderFront(nil)
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        terminalWindow.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        #expect(
            terminalWindow.firstResponder === terminalPanel.hostedView.surfaceView,
            "The regression must exercise a terminal-owned key event"
        )

        var resolvedActions: [KeyboardShortcutSettings.Action] = []
        KeyboardShortcutSettings.shortcutLookupObserver = { action in
            resolvedActions.append(action)
        }

        let event = try keyEvent(characters: "a", keyCode: 0)

        #expect(
            event.window == nil,
            "The regression must match the nil-window event shape from the local monitor"
        )
        #expect(!appDelegate.debugHandleCustomShortcut(event: event))
        #expect(
            resolvedActions.isEmpty,
            "Plain terminal text must bypass browser, palette, workspace, and app-wide shortcut resolution"
        )
    }

    @Test
    func plainTerminalTextDisarmsSecondEscapeTextBoxHide() throws {
        let appDelegate = try #require(AppDelegate.shared)
        appDelegate.debugResetShortcutRoutingStateForTesting()

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        let terminalWindow = try #require(findMainWindow(withId: windowId))
        let contentView = try #require(terminalWindow.contentView)
        appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(terminalWindow)
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
        let textBoxView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 30)
        )
        let textBoxScrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 30)
        )
        textBoxScrollView.documentView = textBoxView
        contentView.addSubview(textBoxScrollView)
        defer { textBoxScrollView.removeFromSuperview() }

        terminalWindow.makeKeyAndOrderFront(nil)
        terminalWindow.displayIfNeeded()
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        terminalPanel.registerTextBoxInputView(textBoxView)
        #expect(terminalPanel.toggleTextBoxInput())
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        #expect(terminalWindow.firstResponder === textBoxView)

        terminalPanel.handleTextBoxEscape()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        #expect(terminalPanel.hostedView.isSurfaceViewFirstResponder())
        #expect(terminalPanel.debugHasTextBoxHideEscapeArm)

        #expect(!appDelegate.debugHandleCustomShortcut(
            event: try keyEvent(characters: "a", keyCode: 0)
        ))
        #expect(
            !terminalPanel.debugHasTextBoxHideEscapeArm,
            "Ordinary terminal typing must break the consecutive-Escape sequence"
        )

        #expect(!appDelegate.debugHandleCustomShortcut(
            event: try keyEvent(characters: "\u{1B}", keyCode: 53)
        ))
        #expect(
            terminalPanel.isTextBoxActive,
            "Escape after intervening terminal text must not hide the text box"
        )
    }

    private func keyEvent(characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                // Local CGEvent monitors synthesize key events without an
                // attached NSWindow, even when a cmux terminal is key.
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func findMainWindow(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = findMainWindow(withId: windowId) else { return }
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
#endif
}
