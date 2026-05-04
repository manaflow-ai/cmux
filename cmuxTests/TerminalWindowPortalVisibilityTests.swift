import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalWindowPortalVisibilityTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testEntryVisibilityUpdateHidesHostedTerminalImmediately() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 260, height: 180))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)

        XCTAssertFalse(hosted.isHidden, "Precondition failed: visible portal entry should start unhidden")
        XCTAssertTrue(hosted.debugPortalVisibleInUI, "Precondition failed: hosted view should start visible in UI")

        portal.updateEntryVisibility(forHostedId: ObjectIdentifier(hosted), visibleInUI: false)

        XCTAssertTrue(
            hosted.isHidden,
            "A retiring terminal portal entry must hide immediately, even before the next geometry sync"
        )
        XCTAssertFalse(
            hosted.debugPortalVisibleInUI,
            "A retiring terminal portal entry must update Ghostty focus/occlusion visibility immediately"
        )
    }
}
