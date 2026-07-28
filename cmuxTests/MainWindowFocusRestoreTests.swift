import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class WindowKeyFocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite(.serialized)
struct MainWindowFocusRestoreTests {
    @Test func windowKeyRestoreRefocusesFocusedTerminalAfterResponderClears() throws {
        let appDelegate = try #require(AppDelegate.shared)

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
        let terminalView = try #require(surfaceView(in: terminalPanel.hostedView))
        let focusController = try #require(appDelegate.keyboardFocusCoordinator(for: window))

        focusHostedTerminal(window: window, hostedView: terminalPanel.hostedView)
        appDelegate.noteTerminalKeyboardFocusIntent(workspaceId: workspace.id, panelId: panelId, in: window)

        #expect(window.makeFirstResponder(nil), "Expected simulated window resign to clear first responder")
        #expect(
            !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before window-key restoration"
        )

        #expect(
            focusController.restoreTargetAfterWindowBecameKey(),
            "Window key restoration should reapply focused terminal first responder before the next keyDown"
        )
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
        }

        #expect(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Window key restoration should restore the focused terminal surface as first responder"
        )
        #expect(window.firstResponder === terminalView, "Expected Ghostty surface view to own first responder after restore")
    }

    @Test func windowKeyRestoreIgnoresSameWindowStrayResponderForFocusedTerminal() throws {
        let appDelegate = try #require(AppDelegate.shared)

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
        let terminalView = try #require(surfaceView(in: terminalPanel.hostedView))
        let focusController = try #require(appDelegate.keyboardFocusCoordinator(for: window))

        focusHostedTerminal(window: window, hostedView: terminalPanel.hostedView)

        let strayResponder = WindowKeyFocusableTestView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        (window.contentView?.superview ?? window.contentView)?.addSubview(strayResponder)
        defer { strayResponder.removeFromSuperview() }

        #expect(window.makeFirstResponder(strayResponder), "Expected same-window stray responder to take focus")
        #expect(window.firstResponder === strayResponder)
        #expect(
            !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before stray-responder restoration"
        )

        appDelegate.noteTerminalKeyboardFocusIntent(workspaceId: workspace.id, panelId: panelId, in: window)
        #expect(
            appDelegate.allowsTerminalKeyboardFocus(workspaceId: workspace.id, panelId: panelId, in: window),
            "Main-panel intent should allow terminal focus before window-key restoration"
        )

        #expect(
            focusController.restoreTargetAfterWindowBecameKey(),
            "Window key restoration should ignore same-window stray responders and restore the focused terminal"
        )
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
        }

        #expect(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "A same-window stray responder must not block terminal first-responder restoration"
        )
        #expect(window.firstResponder === terminalView, "Expected Ghostty surface view to own first responder after restore")
    }

    @Test func windowKeyRestoreIgnoresStrandedRightSidebarResponderForFocusedTerminal() throws {
        let appDelegate = try #require(AppDelegate.shared)

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
        let terminalView = try #require(surfaceView(in: terminalPanel.hostedView))
        let focusController = try #require(appDelegate.keyboardFocusCoordinator(for: window))

        focusHostedTerminal(window: window, hostedView: terminalPanel.hostedView)

        let staleSidebarResponder = RightSidebarKeyboardFocusView(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )
        (window.contentView?.superview ?? window.contentView)?.addSubview(staleSidebarResponder)
        staleSidebarResponder.registerWithKeyboardFocusCoordinatorIfNeeded()
        #expect(window.makeFirstResponder(staleSidebarResponder), "Expected right-sidebar responder to take focus")
        #expect(window.firstResponder === staleSidebarResponder)
        staleSidebarResponder.removeFromSuperview()
        #expect(staleSidebarResponder.window == nil, "Expected a stranded right-sidebar responder")
        #expect(
            !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before stranded-responder restoration"
        )

        appDelegate.noteTerminalKeyboardFocusIntent(workspaceId: workspace.id, panelId: panelId, in: window)
        #expect(
            appDelegate.allowsTerminalKeyboardFocus(workspaceId: workspace.id, panelId: panelId, in: window),
            "Main-panel intent should allow terminal focus before window-key restoration"
        )

        #expect(
            focusController.restoreTargetAfterWindowBecameKey(),
            "Window key restoration should ignore stranded right-sidebar responders and restore the focused terminal"
        )
        waitUntil(timeout: 1.0) {
            terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
        }

        #expect(
            terminalPanel.hostedView.isSurfaceViewFirstResponder(),
            "A stranded right-sidebar responder must not block terminal first-responder restoration"
        )
        #expect(window.firstResponder === terminalView, "Expected Ghostty surface view to own first responder after restore")
    }

    private func focusHostedTerminal(window: NSWindow, hostedView: GhosttySurfaceScrollView) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        waitUntil(timeout: 1.0) {
            hostedView.isSurfaceViewFirstResponder()
        }
        #expect(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before restore test"
        )
    }

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        let appDelegate = AppDelegate.shared
        let originalConfirmationHandler = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        waitUntil(timeout: 1.0) {
            mainWindow(for: windowId) == nil || !window.isVisible
        }
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
