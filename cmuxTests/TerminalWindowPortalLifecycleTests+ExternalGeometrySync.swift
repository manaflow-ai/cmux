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


// MARK: - Scheduled external geometry sync
extension TerminalWindowPortalLifecycleTests {
    func testScheduledExternalGeometrySyncRefreshesAncestorLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
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

        let shiftedContainer = NSView(frame: NSRect(x: 120, y: 60, width: 220, height: 160))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 24, y: 28, width: 72, height: 56))
        shiftedContainer.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "The stale portal position should be cleared after the scheduled external geometry sync"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The scheduled external geometry sync should move the portal-hosted terminal to the anchor's new window position"
        )
    }

    func testScheduledExternalGeometrySyncWaitsForQueuedLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
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
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        DispatchQueue.main.async {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.minX,
            originalAnchorFrameInWindow.minX + 1,
            "The queued layout shift should move the anchor to the right"
        )
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.maxX,
            originalAnchorFrameInWindow.maxX + 1,
            "The shifted anchor should expose a new trailing region outside the stale portal frame"
        )
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "The queued external sync should wait until the later layout shift settles, clearing the stale portal location"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The delayed external sync should move the portal-hosted terminal to the queued layout shift position"
        )
    }

    func testScheduledExternalGeometrySyncKeepsDragDrivenResizeResponsive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        do {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        }

        drainMainQueue()

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertGreaterThan(
            shiftedWindowPoint.x,
            originalWindowPoint.x + 1,
            "The drag handler should shift the anchor to the right"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "Drag-driven geometry sync should clear the stale portal location on the next main-queue turn"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Drag-driven geometry sync should update the portal-hosted terminal without waiting an extra queue turn"
        )
    }

    func testDragDrivenSidebarResizeDoesNotScheduleLateSecondTerminalResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: shiftedContainer.bounds)
        anchor.autoresizingMask = [.width, .height]
        shiftedContainer.addSubview(anchor)

        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)
        let originalHostedFrame = hosted.frame

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        shiftedContainer.frame.origin.x += 72
        shiftedContainer.frame.size.width -= 72
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)

        drainMainQueue()

        let firstPassHostedFrame = hosted.frame
        XCTAssertGreaterThan(
            firstPassHostedFrame.minX,
            originalHostedFrame.minX + 1,
            "The sidebar drag should shift the hosted terminal on the first window-scoped sync pass"
        )
        XCTAssertLessThan(
            firstPassHostedFrame.width,
            originalHostedFrame.width - 1,
            "The sidebar drag should resize the hosted terminal on the first window-scoped sync pass"
        )

        drainMainQueue()

        let secondPassHostedFrame = hosted.frame
        XCTAssertEqual(
            secondPassHostedFrame.minX,
            firstPassHostedFrame.minX,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed horizontal terminal shift on the next queue turn"
        )
        XCTAssertEqual(
            secondPassHostedFrame.width,
            firstPassHostedFrame.width,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed terminal resize on the next queue turn"
        )
    }

    func testWindowScopedExternalGeometrySyncDoesNotRefreshOtherWindows() {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
            firstWindow.orderOut(nil)
        }

        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: secondWindow)
            secondWindow.orderOut(nil)
        }

        let firstSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let secondSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )

        guard let firstContentView = firstWindow.contentView,
              let secondContentView = secondWindow.contentView else {
            XCTFail("Expected content views")
            return
        }

        let firstContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        firstContentView.addSubview(firstContainer)
        let firstAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        firstContainer.addSubview(firstAnchor)

        let secondContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        secondContentView.addSubview(secondContainer)
        let secondAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        secondContainer.addSubview(secondAnchor)

        TerminalWindowPortalRegistry.bind(
            hostedView: firstSurface.hostedView,
            to: firstAnchor,
            visibleInUI: true,
            expectedSurfaceId: firstSurface.id,
            expectedGeneration: firstSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: secondSurface.hostedView,
            to: secondAnchor,
            visibleInUI: true,
            expectedSurfaceId: secondSurface.id,
            expectedGeneration: secondSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(firstAnchor)
        TerminalWindowPortalRegistry.synchronizeForAnchor(secondAnchor)
        realizeWindowLayout(firstWindow)
        realizeWindowLayout(secondWindow)

        let originalFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let originalSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)

        firstContainer.frame.origin.x += 72
        secondContainer.frame.origin.x += 88
        firstContentView.layoutSubtreeIfNeeded()
        secondContentView.layoutSubtreeIfNeeded()
        firstWindow.displayIfNeeded()
        secondWindow.displayIfNeeded()

        let shiftedFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let shiftedSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)
        let retiredFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.minX + shiftedFirstFrameInWindow.minX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let shiftedFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.maxX + shiftedFirstFrameInWindow.maxX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let retiredSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.minX + shiftedSecondFrameInWindow.minX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        let shiftedSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.maxX + shiftedSecondFrameInWindow.maxX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "First window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Second window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Before syncing, unrelated windows should still report the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: firstWindow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredFirstPoint, in: firstWindow),
            "Window-scoped sync should clear the stale location in the requested window"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "Window-scoped sync should refresh the requested window"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Window-scoped sync should not refresh unrelated windows"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Unrelated windows should retain their stale geometry until their own sync runs"
        )
    }
}
