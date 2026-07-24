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
    func plainTerminalTextDoesNotResolveAppShortcuts() throws {
        let appDelegate = try #require(AppDelegate.shared)
        appDelegate.debugResetShortcutRoutingStateForTesting()
        NotificationsPopoverVisibilityState.shared.resetForTesting()

        let windowId = appDelegate.createMainWindow()
        defer {
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            closeWindow(withId: windowId)
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        let window = try #require(window(withId: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

        window.makeKeyAndOrderFront(nil)
        terminalPanel.hostedView.setVisibleInUI(true)
        terminalPanel.hostedView.setActive(true)
        terminalPanel.hostedView.moveFocus()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        #expect(
            window.firstResponder === terminalPanel.hostedView.surfaceView,
            "The regression must exercise a terminal-owned key event"
        )

        var resolvedActions: [KeyboardShortcutSettings.Action] = []
        KeyboardShortcutSettings.shortcutLookupObserver = { action in
            resolvedActions.append(action)
        }

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                // Local CGEvent monitors synthesize key events without an
                // attached NSWindow, even when a cmux terminal is key.
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        #expect(
            event.window == nil,
            "The regression must match the nil-window event shape from the local monitor"
        )
        #expect(!appDelegate.debugHandleCustomShortcut(event: event))
        #expect(
            resolvedActions.isEmpty,
            "Plain terminal text must bypass app-wide shortcut resolution"
        )
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
#endif
}
