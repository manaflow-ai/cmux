import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockSocketLifecycleTests {
    @Test("Explicit Dock focus transfers keyboard input from the host to its terminal")
    @MainActor
    func explicitDockFocusTransfersKeyboardInputToTerminal() throws {
#if DEBUG
        try withDockEnabled {
            try withDockShortcutHarness { appDelegate, _, _, windowDock, fileExplorerState, window in
                let rootPane = try #require(windowDock.resolvePane(requestedPaneID: nil))
                let panelId = try #require(
                    windowDock.newSurface(kind: .terminal, inPane: rootPane, focus: false)
                )
                let panel = try #require(windowDock.panels[panelId] as? TerminalPanel)
                let contentView = try #require(window.contentView)
                let dockHost = DockKeyboardFocusView(
                    frame: NSRect(x: 0, y: 0, width: 24, height: 24)
                )
                defer {
                    _ = window.makeFirstResponder(nil)
                    dockHost.removeFromSuperview()
                    panel.hostedView.removeFromSuperview()
                }

                panel.hostedView.frame = contentView.bounds
                contentView.addSubview(panel.hostedView)
                panel.hostedView.setVisibleInUI(true)
                panel.hostedView.setActive(true)
                contentView.addSubview(dockHost)
                appDelegate.keyboardFocusCoordinator(for: window)?.registerDockHost(dockHost)

                window.displayIfNeeded()
                contentView.layoutSubtreeIfNeeded()
                panel.hostedView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))

                fileExplorerState.setVisible(true)
                fileExplorerState.mode = .dock
                appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
                #expect(window.makeFirstResponder(dockHost))
                #expect(window.firstResponder === dockHost)
                #expect(!panel.hostedView.isSurfaceViewFirstResponder())

                #expect(windowDock.focusFirstControl())
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))

                #expect(
                    panel.hostedView.isSurfaceViewFirstResponder(),
                    "An explicit Dock focus request must transfer keyboard input from its host to the selected terminal"
                )
            }
        }
#endif
    }
}
