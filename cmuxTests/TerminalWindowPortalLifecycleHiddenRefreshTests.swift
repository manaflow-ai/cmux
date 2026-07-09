@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    @MainActor
    func testPortalSkipsSynchronousRefreshForHiddenSurfaces() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = WindowTerminalPortal(window: window)
        let visibleAnchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let hiddenAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(visibleAnchor)
        contentView.addSubview(hiddenAnchor)

        let visibleSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hiddenSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        portal.bind(hostedView: visibleSurface.hostedView, to: visibleAnchor, visibleInUI: true)
        portal.bind(hostedView: hiddenSurface.hostedView, to: hiddenAnchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        visibleSurface.resetDebugForceRefreshCount()
        hiddenSurface.resetDebugForceRefreshCount()

        // Move BOTH anchors: both hosted views get geometry bookkeeping, but
        // only the visible one may pay for the synchronous redraw — one
        // layout pass syncs every hosted view in the window, and a mirror
        // workspace parks 20+ surfaces on unselected tabs.
        visibleAnchor.setFrameSize(NSSize(width: 220, height: 150))
        hiddenAnchor.setFrameSize(NSSize(width: 220, height: 150))
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()

        XCTAssertEqual(
            hiddenSurface.debugForceRefreshCount(),
            0,
            "A hidden (unselected-tab) surface must not receive the synchronous GPU-blocking refresh on geometry sync"
        )
        withExtendedLifetime((visibleSurface, hiddenSurface)) {}
    }
}
