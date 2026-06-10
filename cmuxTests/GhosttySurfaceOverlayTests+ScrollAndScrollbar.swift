import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Scroll routing and scrollbar overlay
extension GhosttySurfaceOverlayTests {
    func testTrackpadScrollRoutesToTerminalSurfaceAndPreservesKeyboardFocusPath() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surfaceView = ScrollProbeSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }
        XCTAssertFalse(
            scrollView.acceptsFirstResponder,
            "Host scroll view should not become first responder and steal terminal shortcuts"
        )

        _ = window.makeFirstResponder(nil)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -12,
            wheel3: 0
        ), let scrollEvent = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Expected scroll wheel event")
            return
        }

        scrollView.scrollWheel(with: scrollEvent)

        XCTAssertEqual(
            surfaceView.scrollWheelCallCount,
            1,
            "Trackpad wheel events should be forwarded directly to Ghostty surface scrolling"
        )
        XCTAssertTrue(
            window.firstResponder === surfaceView,
            "Scroll wheel handling should keep keyboard focus on terminal surface"
        )
    }

    func testExplicitWheelScrollKeepsScrollbackPinnedAgainstLaterBottomPacket() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surfaceView = ScrollbarPostingSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        surfaceView.cellSize = CGSize(width: 10, height: 10)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }

        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: makeScrollbar(total: 100, offset: 90, len: 10)]
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        surfaceView.nextScrollbar = makeScrollbar(total: 100, offset: 40, len: 10)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -12,
            wheel3: 0
        ), let scrollEvent = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Expected scroll wheel event")
            return
        }

        scrollView.scrollWheel(with: scrollEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 500, accuracy: 0.01)

        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: makeScrollbar(total: 100, offset: 90, len: 10)]
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            500,
            accuracy: 0.01,
            "A passive bottom packet should not yank the viewport after an explicit wheel scroll into scrollback"
        )
    }

    func testInactiveOverlayVisibilityTracksRequestedState() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        )

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: true)
        var state = hostedView.debugInactiveOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.alpha, 0.35, accuracy: 0.01)

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: false)
        state = hostedView.debugInactiveOverlayState()
        XCTAssertTrue(state.isHidden)
    }

    func testPreferredScrollerStyleChangeRestoresOverlayScrollbarWidth() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }
        guard let initialSurfaceSize = hostedView.debugPendingSurfaceSize() else {
            XCTFail("Expected an initial terminal surface size")
            return
        }

        func assertPendingSurfaceWidth(
            _ expectedWidth: CGFloat,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let pendingSurfaceWidth = hostedView.debugPendingSurfaceSize()?.width else {
                XCTFail("Expected a pending terminal surface size", file: file, line: line)
                return
            }

            XCTAssertEqual(
                pendingSurfaceWidth,
                expectedWidth,
                accuracy: 0.5,
                message,
                file: file,
                line: line
            )
        }

        let initialContentWidth = scrollView.contentSize.width
        XCTAssertEqual(initialSurfaceSize.width, initialContentWidth, accuracy: 0.5)

        scrollView.scrollerStyle = .legacy
        scrollView.layoutSubtreeIfNeeded()
        let legacyContentWidth = scrollView.contentSize.width
        XCTAssertEqual(scrollView.scrollerStyle, .legacy)
        assertPendingSurfaceWidth(
            initialSurfaceSize.width,
            "Changing the scroll view style alone should leave the terminal grid unchanged until the scroller-style observer runs"
        )

        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let restoredContentWidth = scrollView.contentSize.width
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertGreaterThanOrEqual(
            restoredContentWidth,
            legacyContentWidth,
            "Preferred scroller style changes should not shrink terminal content when overlay scrollbars return"
        )
        XCTAssertEqual(
            restoredContentWidth,
            initialContentWidth,
            accuracy: 0.5,
            "Preferred scroller style changes should restore Ghostty's overlay scrollbar behavior so terminal content is not occluded by a persistent gutter"
        )
        assertPendingSurfaceWidth(
            restoredContentWidth,
            "Preferred scroller style changes should restore the wider terminal grid when overlay scrollbars return"
        )
    }

}
