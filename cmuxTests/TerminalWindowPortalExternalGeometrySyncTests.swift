import AppKit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
    func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(waitUntil(timeout: 10.0) {
            window.displayIfNeeded()
            guard let content = window.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            return window.isVisible && content.window === window && content.superview != nil
                && content.bounds.width > 0 && content.bounds.height > 0 && !content.needsLayout
        }, "Expected an attached, visible, laid-out content hierarchy before portal setup")
    }

    // The shared app host may have unrelated queued work. Observe publication
    // itself instead of assuming the scheduled pass finishes within 50 ms.
    func testScheduledExternalGeometrySyncRefreshesAncestorLayoutShift() {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420)
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

        let shiftedContainer = NSView(frame: NSRect(x: 120, y: 60, width: 220, height: 160))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 24, y: 28, width: 72, height: 56))
        shiftedContainer.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        shiftedContainer.frame.origin.x += 96
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let shiftedWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotEqual(originalWindowPoint.x, shiftedWindowPoint.x, accuracy: 0.5)
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Ancestor-only layout shifts should leave the portal stale until an external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Before the external geometry sync, hit-testing should still point at the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        XCTAssertTrue(waitUntil(timeout: 10.0) {
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window) == nil &&
                TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window) != nil
        }, "Expected the scheduled sync to publish the shifted hit-test region")

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "The stale portal position should be cleared after the scheduled external geometry sync"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The scheduled external geometry sync should move the portal-hosted terminal to the anchor's new window position"
        )
    }
}
