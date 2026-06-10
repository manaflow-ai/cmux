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


// MARK: - Window focus and auxiliary overlay lifecycle
extension GhosttySurfaceOverlayTests {
    func testWindowResignKeyClearsFocusedTerminalFirstResponder() {
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

        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        )
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to be first responder before window blur"
        )

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Window blur should force terminal surface to resign first responder"
        )
    }

    @MainActor
    func testKeyboardCopyModeIndicatorMountsAndUnmounts() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: "vim")
        XCTAssertTrue(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: nil)
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())
    }

    @MainActor
    func testDropHoverOverlayAttachesToParentContainerInsteadOfHostedTerminalView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let surfaceView = GhosttyNSView(frame: .zero)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = container.bounds
        container.addSubview(hostedView)

        hostedView.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        let state = hostedView.debugDropZoneOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertFalse(
            state.isAttachedToHostedView,
            "Drop-hover overlay should be mounted outside the hosted terminal view"
        )
        XCTAssertTrue(
            state.isAttachedToParentContainer,
            "Drop-hover overlay should be mounted in the parent container so it cannot perturb terminal layout"
        )
        XCTAssertEqual(state.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(state.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.width, 116, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.height, 112, accuracy: 0.5)

        hostedView.setDropZoneOverlay(zone: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(hostedView.debugDropZoneOverlayState().isHidden)
    }

    func testForceRefreshNoopsAfterSurfaceReleaseDuringGeometryReconcile() throws {
#if DEBUG
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.reconcileGeometryNow()
        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Surface should be nil after test release helper")

        hostedView.reconcileGeometryNow()
        surface.forceRefresh()
        XCTAssertNil(surface.surface, "Force refresh should no-op when runtime surface is nil")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

}
