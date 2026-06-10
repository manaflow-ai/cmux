import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Inspector-managed web view frames
extension BrowserWindowPortalLifecycleTests {
    func testPortalSlotPinPreservesSideDockedInspectorManagedWebViewFrameOnRehost() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 132, height: 160), configuration: WKWebViewConfiguration())
        let inspectorContainer = NSView(frame: NSRect(x: 132, y: 0, width: 108, height: 160))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(webView)
        slot.addSubview(inspectorContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.autoresizingMask = []
        slot.pinHostedWebView(webView)

        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Rehosting a portal-managed browser should preserve the WebKit-owned side inspector split"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "The page frame should stay narrower than the full slot while a side-docked inspector is present"
        )
    }

    func testPortalResizePreservesSideDockedInspectorManagedWebViewFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialInspectorWidth: CGFloat = 110
        let inspectorContainer = NSView(
            frame: NSRect(
                x: slot.bounds.width - initialInspectorWidth,
                y: 0,
                width: initialInspectorWidth,
                height: slot.bounds.height
            )
        )
        inspectorContainer.autoresizingMask = [.minXMargin, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: 0,
            width: slot.bounds.width - initialInspectorWidth,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Resizing the browser pane should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Portal sync should preserve the side-docked inspector split instead of stretching the page back over the inspector"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "Side-docked inspector should still own part of the slot after pane resize"
        )
    }

    func testPortalAnchorResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        anchor.frame = NSRect(x: 52, y: 30, width: 248, height: 178)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "Anchor resize should keep the portal-hosted browser visible")
        XCTAssertEqual(slot.frame.origin.x, 52, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 248, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 178, accuracy: 0.5)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "Pure anchor geometry updates should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "Pure anchor geometry updates should not trigger the WebKit reattach path"
        )
    }

    func testExternalSplitResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true

        let leadingPane = NSView(
            frame: NSRect(x: 0, y: 0, width: 220, height: contentView.bounds.height)
        )
        leadingPane.autoresizingMask = [.height]
        let trailingPane = NSView(
            frame: NSRect(
                x: 221,
                y: 0,
                width: contentView.bounds.width - 221,
                height: contentView.bounds.height
            )
        )
        trailingPane.autoresizingMask = [.width, .height]
        splitView.addSubview(leadingPane)
        splitView.addSubview(trailingPane)
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let anchor = NSView(frame: trailingPane.bounds.insetBy(dx: 12, dy: 12))
        anchor.autoresizingMask = [.width, .height]
        trailingPane.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount
        let initialWidth = slot.frame.width

        splitView.setPosition(280, ofDividerAt: 0)
        contentView.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "App split resize should keep the browser slot visible")
        XCTAssertLessThan(
            slot.frame.width,
            initialWidth,
            "Moving the app split divider should shrink the hosted browser slot"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            initialDisplayCount,
            "External split resize should still repaint the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "External split resize should not trigger the WebKit reattach path"
        )
    }

    func testPortalSyncRepairsBottomDockedInspectorOverflowedPageFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let inspectorHeight: CGFloat = 84
        let inspectorContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: inspectorHeight)
        )
        inspectorContainer.autoresizingMask = [.width]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: inspectorHeight,
            width: slot.bounds.width,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Portal sync should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.minY,
            inspectorHeight,
            accuracy: 0.5,
            "Portal sync should keep the page viewport below a bottom-docked inspector instead of shifting the page upward"
        )
        XCTAssertEqual(
            webView.frame.height,
            slot.bounds.height - inspectorHeight,
            accuracy: 0.5,
            "Portal sync should shrink the page viewport to the space above a bottom-docked inspector"
        )
        XCTAssertEqual(
            webView.frame.maxY,
            slot.bounds.maxY,
            accuracy: 0.5,
            "The repaired page viewport should stay flush with the top edge of the slot"
        )
    }

    func testHidingBrowserSlotYieldsOwnedInspectorFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let slot = WindowBrowserSlotView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(slot)

        let inspectorContainer = NSView(frame: slot.bounds)
        inspectorContainer.autoresizingMask = [.width, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            window.makeFirstResponder(inspectorView),
            "Precondition failed: inspector probe should become first responder"
        )
        XCTAssertTrue(window.firstResponder === inspectorView)

        slot.isHidden = true

        XCTAssertFalse(
            window.firstResponder === inspectorView,
            "Hiding a browser slot should yield any owned inspector responder before it goes off-screen"
        )
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(
                firstResponderView === slot || firstResponderView.isDescendant(of: slot),
                "Hiding a browser slot should not leave first responder inside the hidden slot"
            )
        }
    }

    func testHiddenPortalSyncDoesNotStealLocallyHostedDevToolsWebViewDuringResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let hiddenPortalSlot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(hiddenPortalSlot.isHidden, "Hidden portal entry should keep its slot hidden")

        let localInlineSlot = WindowBrowserSlotView(frame: anchor.frame)
        contentView.addSubview(localInlineSlot)

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: localInlineSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        localInlineSlot.addSubview(inspectorView)

        localInlineSlot.addSubview(webView)
        webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: localInlineSlot.bounds.width,
            height: localInlineSlot.bounds.height - inspectorView.frame.height
        )
        localInlineSlot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        localInlineSlot.frame = anchor.frame
        contentView.layoutSubtreeIfNeeded()
        localInlineSlot.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertTrue(
            webView.superview === localInlineSlot,
            "Hidden portal sync should not steal a DevTools-hosted web view back out of local inline hosting during pane resize"
        )
        XCTAssertTrue(
            inspectorView.superview === localInlineSlot,
            "Hidden portal sync should leave local DevTools companion views in the local inline host"
        )
        XCTAssertTrue(hiddenPortalSlot.isHidden, "The retiring hidden portal slot should stay hidden during local inline hosting")
    }

}
