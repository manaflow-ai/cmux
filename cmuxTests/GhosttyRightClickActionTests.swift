import AppKit
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The cmux menu opens only when Ghostty leaves a right press unconsumed (#4177).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct GhosttyRightClickActionTests {
    @Test(arguments: ["ignore", "copy"])
    func consumedRightClickOpensNoMenu(action: String) async throws {
        try await withTerminal(rightClickAction: action) { view, window in
            let click = try rightClickMenu(on: view, in: window)
            #expect(click.menu == nil)
            // With no menu to track, the mouse-up must release Ghostty's press.
            #expect(click.pressPendingBeforeMouseUp)
            #expect(!view.debugHasPendingRightMouseReleaseForTesting())
        }
    }

    @Test
    func contextMenuActionOpensMenu() async throws {
        try await withTerminal(rightClickAction: "context-menu") { view, window in
            let click = try rightClickMenu(on: view, in: window)
            #expect(click.menu != nil)
        }
    }

    /// Matches upstream Ghostty, which keeps the menu on control-click.
    @Test
    func controlClickOpensMenuWhenActionIsConsumed() async throws {
        try await withTerminal(rightClickAction: "ignore") { view, window in
            let click = try rightClickMenu(on: view, in: window, controlClick: true)
            #expect(click.menu != nil)
        }
    }

    /// Control-click opens the menu without also running the action: Ghostty
    /// runs right-click-action on any right press, so none is sent.
    @Test(arguments: ["paste", "copy", "copy-or-paste"])
    func controlClickOpensMenuWithoutRunningAction(action: String) async throws {
        try await withTerminal(rightClickAction: action) { view, window in
            let click = try rightClickMenu(on: view, in: window, controlClick: true)
            #expect(click.menu != nil)
            #expect(!click.pressPendingBeforeMouseUp)
        }
    }

    /// The context-menu action still gets the press, for its word selection.
    @Test
    func controlClickSendsPressForContextMenuAction() async throws {
        try await withTerminal(rightClickAction: "context-menu") { view, window in
            let click = try rightClickMenu(on: view, in: window, controlClick: true)
            #expect(click.menu != nil)
            #expect(click.pressPendingBeforeMouseUp)
        }
    }

    /// Pane chrome never sends the press to Ghostty, so its menu ignores the action.
    @Test
    func paneChromeOpensMenuWhenActionIsConsumed() async throws {
        try await withTerminal(rightClickAction: "ignore") { view, window in
            let click = try rightClickMenu(on: view, in: window, fromPaneChrome: true)
            #expect(click.menu != nil)
        }
    }

    /// Applies the action to the surface and to the app config, which a
    /// control-click reads before deciding whether to send the press.
    private func withTerminal(
        rightClickAction: String,
        _ body: @MainActor (GhosttyNSView, NSWindow) throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let surface = try await harness.startTerminal()
            let contents = "right-click-action = \(rightClickAction)"
            try harness.configure(surface, contents: contents)
            let app = GhosttyApp.shared
            let baseConfig = try #require(app.config)
            let appConfig = try #require(ghostty_config_clone(baseConfig))
            contents.withCString { pointer in
                ghostty_config_load_string(appConfig, pointer, UInt(contents.utf8.count), "/__cmux_test__/4177.conf")
            }
            ghostty_config_finalize(appConfig)
            let previous = app.swapConfigForTesting(appConfig)
            defer {
                if let previous, let swapped = app.swapConfigForTesting(previous) {
                    ghostty_config_free(swapped)
                }
            }
            try #require(app.rightClickActionOpensContextMenu == (rightClickAction == "context-menu"))
            try body(surface.hostedView.surfaceView, harness.window)
        }
    }

    private struct RightClick {
        let menu: NSMenu?
        /// Whether Ghostty held a right press between the menu request and the mouse-up.
        let pressPendingBeforeMouseUp: Bool
    }

    /// Releases the right button after asking for the menu, as a real click would.
    private func rightClickMenu(
        on view: GhosttyNSView,
        in window: NSWindow,
        controlClick: Bool = false,
        fromPaneChrome: Bool = false
    ) throws -> RightClick {
        try #require(view.bounds.width > 24 && view.bounds.height > 24)
        // Near the top-left cell; the test window's grid does not span the whole view.
        let point = view.convert(NSPoint(x: 24, y: view.bounds.height - 24), to: nil)
        let down = try mouseEvent(
            controlClick ? .leftMouseDown : .rightMouseDown,
            at: point,
            modifierFlags: controlClick ? [.control] : [],
            window: window
        )
        let menu = fromPaneChrome ? view.paneContextMenu(for: down) : view.menu(for: down)
        let pending = view.debugHasPendingRightMouseReleaseForTesting()
        view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: point, modifierFlags: [], window: window))
        return RightClick(menu: menu, pressPendingBeforeMouseUp: pending)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
