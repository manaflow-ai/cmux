import AppKit
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
            let menu = try rightClickMenu(on: view, in: window)
            #expect(menu == nil)
        }
    }

    @Test
    func contextMenuActionOpensMenu() async throws {
        try await withTerminal(rightClickAction: "context-menu") { view, window in
            let menu = try rightClickMenu(on: view, in: window)
            #expect(menu != nil)
        }
    }

    /// Matches upstream Ghostty, which keeps the menu on control-click.
    @Test
    func controlClickOpensMenuWhenActionIsConsumed() async throws {
        try await withTerminal(rightClickAction: "ignore") { view, window in
            let menu = try rightClickMenu(on: view, in: window, controlClick: true)
            #expect(menu != nil)
        }
    }

    /// Pane chrome never sends the press to Ghostty, so its menu ignores the action.
    @Test
    func paneChromeOpensMenuWhenActionIsConsumed() async throws {
        try await withTerminal(rightClickAction: "ignore") { view, window in
            let menu = try rightClickMenu(on: view, in: window, fromPaneChrome: true)
            #expect(menu != nil)
        }
    }

    private func withTerminal(
        rightClickAction: String,
        _ body: @MainActor (GhosttyNSView, NSWindow) throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let surface = try await harness.startTerminal()
            try harness.configure(surface, contents: "right-click-action = \(rightClickAction)")
            try body(surface.hostedView.surfaceView, harness.window)
        }
    }

    /// Releases the right button after asking for the menu, as a real click would.
    private func rightClickMenu(
        on view: GhosttyNSView,
        in window: NSWindow,
        controlClick: Bool = false,
        fromPaneChrome: Bool = false
    ) throws -> NSMenu? {
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
        view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: point, modifierFlags: [], window: window))
        return menu
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
