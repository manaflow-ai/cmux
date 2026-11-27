import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A selected terminal in a foreground window, independent of the test host's activation.
/// Keyboard interactions require a key window; an inactive app-host's ordinary
/// NSWindow models a background window and correctly refuses deferred focus.
@MainActor
final class TerminalFocusTestFixture {
    let owner: TerminalPortalTestWorkspace
    let window: KeyStatusTestWindow
    let panel: TerminalPanel

    init() throws {
        let owner = TerminalPortalTestWorkspace()
        self.owner = owner
        let window = KeyStatusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        self.window = window
        var ready = false
        defer {
            if !ready {
                owner.tearDown()
                window.close()
            }
        }
        panel = try #require(owner.workspace.focusedTerminalPanel)
        owner.bind(to: window)
        let contentView = try #require(window.contentView)
        panel.hostedView.frame = contentView.bounds
        contentView.addSubview(panel.hostedView)
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        try #require(panel.hostedView.surfaceView.window === window)
        try #require(window.makeFirstResponder(panel.hostedView.surfaceView))
        ready = true
    }

    func tearDown() {
        window.makeFirstResponder(nil)
        owner.tearDown()
        window.close()
    }

    func startSurface() async throws {
        panel.surface.requestInputDemandSurfaceStartIfNeeded()
        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            panel.surface.hasLiveSurface
        }, "The key-delivery assertion requires a live terminal runtime")
    }
}
