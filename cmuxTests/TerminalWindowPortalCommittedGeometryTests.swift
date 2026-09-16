@preconcurrency import XCTest
import AppKit
import CmuxTerminal
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The portal is the only writer of a hosted terminal's pane geometry, and it
/// writes only from a settled layout pass or a drag tick. These tests pin the
/// invariant that produced #12657: a frame the user cannot see (a bind seed,
/// a hidden entry, a mid-layout clip) never reaches the surface.
extension TerminalWindowPortalLifecycleTests {

    /// Pumps queued portal passes until the surface has a committed size or
    /// the budget runs out.
    @MainActor
    private func pumpUntilCommitted(_ surface: TerminalSurface, passes: Int = 8) {
        for _ in 0..<passes {
            if surface.committedPaneGeometry != nil { return }
            drainMainQueue()
        }
    }

    @MainActor
    func testBindPublishesOnlyAfterSettledPass() throws {
        let window = makeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340))
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()

        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(surface.hostedView.paneGeometryIsPortalOwned)
        XCTAssertNil(
            surface.committedPaneGeometry,
            "A bind seeds the frame but must not publish it; the anchor may not be laid out yet"
        )

        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertNil(
            surface.committedPaneGeometry,
            "An anchor callback outside a drag must wait for the settled pass"
        )

        pumpUntilCommitted(surface)
        let committed = try XCTUnwrap(surface.committedPaneGeometry)
        XCTAssertEqual(committed.phase, .settled)
        XCTAssertEqual(committed.size.width, 240, accuracy: 0.5)
        XCTAssertEqual(committed.size.height, 160, accuracy: 0.5)
        XCTAssertTrue(
            surface.hostedView.commitPortalGeometry(phase: .settled),
            "A settled commit is successful even when the renderer size is already current"
        )
    }

    @MainActor
    func testHiddenEntryNeverPublishes() throws {
        let window = makeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340))
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()

        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(anchor)
        anchor.setFrameSize(NSSize(width: 17, height: 19))
        portal.synchronizeHostedViewForAnchor(anchor)
        for _ in 0..<6 { drainMainQueue() }

        XCTAssertNil(
            surface.committedPaneGeometry,
            "An entry the user cannot see has no publishable size, whatever frame the portal holds for it"
        )
    }

    @MainActor
    func testHidingAnEntryDoesNotPublishItsLastFrame() throws {
        let window = makeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340))
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        pumpUntilCommitted(surface)
        XCTAssertNotNil(surface.committedPaneGeometry)

        // Leaving a workspace shrinks its anchors as SwiftUI tears the layout
        // down. That frame belongs to a pane nobody sees.
        anchor.setFrameSize(NSSize(width: 17, height: 19))
        _ = portal.updateEntryVisibility(
            forHostedId: ObjectIdentifier(surface.hostedView), visibleInUI: false
        )
        portal.synchronizeHostedViewForAnchor(anchor)
        for _ in 0..<6 { drainMainQueue() }

        XCTAssertNil(
            surface.committedPaneGeometry,
            "Hiding forgets the committed size instead of publishing the collapsed frame"
        )
    }

    @MainActor
    func testDragTicksPublishInteractivelyThenSettle() throws {
        let window = makeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340))
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        pumpUntilCommitted(surface)

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: window)
        anchor.setFrameSize(NSSize(width: 200, height: 150))
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        let tick = try XCTUnwrap(surface.committedPaneGeometry)
        XCTAssertEqual(tick.phase, .interactive, "Every drag tick is on screen and publishes at once")
        XCTAssertEqual(tick.size.width, 200, accuracy: 0.5)

        TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
        for _ in 0..<6 {
            if surface.committedPaneGeometry?.phase == .settled { break }
            drainMainQueue()
        }
        let rest = try XCTUnwrap(surface.committedPaneGeometry)
        XCTAssertEqual(rest.phase, .settled, "The drag end publishes the resting size exactly")
        XCTAssertEqual(rest.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(rest.size.height, 150, accuracy: 0.5)
    }

    @MainActor
    func testVisibleRuntimeCreationWaitsForCommittedGeometry() throws {
        let window = makeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340))
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()
        surface.hostedView.setVisibleInUI(true)

        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        XCTAssertNil(
            surface.surface,
            "A visible pane must not spawn its PTY from a frame the portal has not committed"
        )

        portal.synchronizeHostedViewForAnchor(anchor)
        pumpUntilCommitted(surface)
        let committed = try XCTUnwrap(surface.committedPaneGeometry)
        let runtime = try XCTUnwrap(surface.surface, "The first commit resumes the parked creation")
        let size = ghostty_surface_size(runtime)
        XCTAssertEqual(
            CGFloat(size.width_px), committed.backingSize.width, accuracy: 1,
            "The PTY's first window size is the committed pane size"
        )
    }
}
