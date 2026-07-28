import AppKit
import CmuxControlSocket
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A socket focus request naming a main-area surface silently did nothing while
/// the right sidebar owned the keyboard-focus intent, and still answered
/// `.focused` — so callers could not detect the failure.
///
/// `allowsTerminalFocus` refuses every main-area panel under `.rightSidebar`
/// intent and `TerminalPanel.focus()` bails on that gate, while no socket path
/// cleared the intent. Asserting the resolution alone is worthless here: that
/// return value was already lying. Each test asserts the terminal actually owns
/// first responder afterwards.
@MainActor
@Suite(.serialized)
struct SocketSurfaceFocusIntentTests {
    @Test func v2SurfaceFocusTakesKeyboardBackFromRightSidebar() throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }

        harness.giveRightSidebarTheKeyboard()

        let resolution = TerminalController.shared.controlSurfaceFocus(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: harness.windowId,
                groupID: nil,
                workspaceID: harness.workspace.id,
                surfaceID: harness.panelId,
                paneID: nil
            ),
            surfaceID: harness.panelId
        )

        #expect(resolution == .focused(
            windowID: harness.windowId,
            workspaceID: harness.workspace.id,
            surfaceID: harness.panelId
        ))
        harness.expectTerminalOwnsKeyboard(entrypoint: "surface.focus")
    }

    @Test func v1FocusSurfaceByPanelTakesKeyboardBackFromRightSidebar() throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }

        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(harness.manager)
        defer { TerminalController.shared.setActiveTabManager(previousActiveManager) }

        harness.giveRightSidebarTheKeyboard()

        #expect(TerminalController.shared.controlSidebarFocusSurfaceByPanel(panelID: harness.panelId))
        harness.expectTerminalOwnsKeyboard(entrypoint: "focus_surface_by_panel")
    }

    /// A real main window with a real Ghostty surface, so first-responder
    /// assertions exercise the actual focus gate rather than a stub.
    @MainActor
    private struct FocusHarness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let window: NSWindow
        let manager: TabManager
        let workspace: Workspace
        let panelId: UUID
        let terminalPanel: TerminalPanel
        let terminalView: GhosttyNSView
        let sidebarResponder = RightSidebarKeyboardFocusView(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            window = try #require(appDelegate.windowForMainWindowId(windowId))
            manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            panelId = try #require(workspace.focusedPanelId)
            terminalPanel = try #require(workspace.terminalPanel(for: panelId))
            terminalView = try #require(Self.surfaceView(in: terminalPanel.hostedView))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            terminalPanel.hostedView.moveFocus()
            Self.waitUntil(timeout: 1.0) { terminalPanel.hostedView.isSurfaceViewFirstResponder() }
            #expect(
                terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                "Expected the main terminal to own first responder before the sidebar takes it"
            )
        }

        /// Mirrors clicking into the Dock: a real sidebar responder takes first
        /// responder and the sidebar becomes the focus-intent owner.
        ///
        /// The responder has to genuinely own the keyboard. Merely clearing first
        /// responder would let the terminal back in through
        /// `respectForeignFirstResponder`, a path the live app never takes, and the
        /// test would pass against a fix that does not actually work.
        func giveRightSidebarTheKeyboard() {
            (window.contentView?.superview ?? window.contentView)?.addSubview(sidebarResponder)
            sidebarResponder.registerWithKeyboardFocusCoordinatorIfNeeded()
            #expect(window.makeFirstResponder(sidebarResponder), "Expected the sidebar responder to take the keyboard")
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)

            #expect(
                !appDelegate.allowsTerminalKeyboardFocus(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    in: window
                ),
                "Precondition: the right sidebar must own the focus intent"
            )
            #expect(!terminalPanel.hostedView.isSurfaceViewFirstResponder())
        }

        func expectTerminalOwnsKeyboard(entrypoint: String) {
            #expect(
                appDelegate.allowsTerminalKeyboardFocus(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    in: window
                ),
                "\(entrypoint) must hand the keyboard-focus intent back to the main panel"
            )
            Self.waitUntil(timeout: 1.0) {
                terminalPanel.hostedView.isSurfaceViewFirstResponder() && window.firstResponder === terminalView
            }
            #expect(
                window.firstResponder === terminalView,
                "\(entrypoint) reported success, so the terminal must actually own first responder"
            )
        }

        func tearDown() {
            sidebarResponder.removeFromSuperview()
            let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
            appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
            defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
            Self.waitUntil(timeout: 1.0) {
                AppDelegate.shared?.windowForMainWindowId(windowId) == nil || !window.isVisible
            }
        }

        private static func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
            var stack: [NSView] = [hostedView]
            while let current = stack.popLast() {
                if let surfaceView = current as? GhosttyNSView {
                    return surfaceView
                }
                stack.append(contentsOf: current.subviews)
            }
            return nil
        }

        private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
    }
}
