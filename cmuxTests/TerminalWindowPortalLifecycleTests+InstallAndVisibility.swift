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


// MARK: - Portal install, registry pruning, and visibility
extension TerminalWindowPortalLifecycleTests {
    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        _ = portal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Portal host must remain above content view so portal-hosted terminals stay visible"
        )
    }

    func testTerminalPortalHostStaysBelowBrowserPortalHostWhenBothAreInstalled() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
                  let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertLessThan(
                terminalHostIndex,
                browserHostIndex,
                message
            )
        }

        assertHostOrder("Terminal portal host should start below browser portal host")

        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 220, height: 150))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(anchor)

        assertHostOrder("Terminal portal bind/sync should not rise above the browser portal host")
    }

    func testRegistryPrunesPortalWhenWindowCloses() {
        let baseline = TerminalWindowPortalRegistry.debugPortalCount()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        _ = TerminalWindowPortalRegistry.viewAtWindowPoint(NSPoint(x: 1, y: 1), in: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline)
    }

    func testPruneDeadEntriesDetachesAnchorlessHostedView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hosted1 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )

        var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor1!)
        portal.bind(hostedView: hosted1, to: anchor1!, visibleInUI: true)

        anchor1?.removeFromSuperview()
        anchor1 = nil

        let hosted2 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor2)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(portal.debugEntryCount(), 1, "Only the live anchored hosted view should remain tracked")
        XCTAssertEqual(portal.debugHostedSubviewCount(), 1, "Stale anchorless hosted views should be detached from hostView")
    }

    func testDeferredSyncHidesVisibleHostedViewAfterAnchorDisappears() {
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

        var retiredAnchor: NSView? = NSView(frame: NSRect(x: 24, y: 28, width: 96, height: 180))
        contentView.addSubview(retiredAnchor!)

        let retiredTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 96, height: 180))
        let retiredHosted = GhosttySurfaceScrollView(surfaceView: retiredTerminal)
        portal.bind(hostedView: retiredHosted, to: retiredAnchor!, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(retiredAnchor!)

        let retiredWindowPoint = retiredAnchor!.convert(
            NSPoint(x: retiredAnchor!.bounds.midX, y: retiredAnchor!.bounds.midY),
            to: nil
        )
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(retiredWindowPoint) === retiredTerminal,
            "Initial hit-testing should resolve the first hosted terminal at its anchor"
        )

        retiredAnchor?.removeFromSuperview()
        retiredAnchor = nil

        let activeAnchor = NSView(frame: NSRect(x: 184, y: 28, width: 280, height: 180))
        contentView.addSubview(activeAnchor)

        let activeTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        let activeHosted = GhosttySurfaceScrollView(surfaceView: activeTerminal)
        portal.bind(hostedView: activeHosted, to: activeAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(activeAnchor)

        XCTAssertTrue(
            retiredHosted.isHidden,
            "A visible hosted terminal whose anchor vanished should hide as soon as the replacement anchor sync runs"
        )
        // Drain the queued full-sync turn so the portal clears any stale hit-test region left by the rebind.
        drainMainQueue()

        let activeWindowPoint = activeAnchor.convert(
            NSPoint(x: activeAnchor.bounds.midX, y: activeAnchor.bounds.midY),
            to: nil
        )
        XCTAssertNil(
            portal.terminalViewAtWindowPoint(retiredWindowPoint),
            "Restore-like rebinds should clear stale portal hit regions on the queued portal resync"
        )
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(activeWindowPoint) === activeTerminal,
            "The active terminal should remain visible after the stale hosted view is hidden"
        )
    }

    func testSynchronizeReusesInstalledTargetWithoutRepeatedContentViewLookup() {
        let window = ContentViewCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let baselineReads = window.contentViewReadCount
        for _ in 0..<25 {
            portal.synchronizeHostedViewForAnchor(anchor)
        }

        XCTAssertEqual(
            window.contentViewReadCount,
            baselineReads,
            "Repeated synchronize calls should reuse installed target instead of repeatedly reading window.contentView"
        )
    }

    func testTerminalViewAtWindowPointResolvesPortalHostedSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let windowPoint = anchor.convert(center, to: nil)
        XCTAssertNotNil(
            portal.terminalViewAtWindowPoint(windowPoint),
            "Portal hit-testing should resolve the terminal view for Finder file drops"
        )
    }

    func testVisibilityTransitionBringsHostedViewToFront() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Latest bind should be top-most before visibility transition"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: false)
        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Becoming visible should refresh z-order for already-hosted view"
        )
    }

    func testPriorityIncreaseBringsHostedViewToFrontWithoutVisibilityToggle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true, zPriority: 2)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Higher-priority terminal should initially be top-most"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 2)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Promoting z-priority should bring an already-visible terminal to front"
        )
    }

    func testHiddenPortalDefersRevealUntilFrameHasUsableSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let portal = WindowTerminalPortal(window: window)
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 280, height: 220))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        XCTAssertFalse(hosted.isHidden, "Healthy geometry should be visible")

        // Collapse to a tiny frame first.
        anchor.frame = NSRect(x: 160.5, y: 1037.0, width: 79.0, height: 0.0)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(hosted.isHidden, "Tiny geometry should hide the portal-hosted terminal")

        // Then restore to a non-zero but still too-small frame. It should remain hidden.
        anchor.frame = NSRect(x: 160.9, y: 1026.5, width: 93.6, height: 10.3)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(
            hosted.isHidden,
            "Portal should defer reveal until geometry reaches a usable size"
        )

        // Once the frame is large enough again, reveal should resume.
        anchor.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertFalse(hosted.isHidden, "Portal should unhide after geometry is usable")
    }

}
