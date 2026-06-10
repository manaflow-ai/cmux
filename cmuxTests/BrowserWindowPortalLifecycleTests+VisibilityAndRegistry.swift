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


// MARK: - Portal visibility and registry lifecycle
extension BrowserWindowPortalLifecycleTests {
    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testPortalDropZoneOverlayPersistsAcrossVisibilityChanges() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let overlay = dropZoneOverlay(in: slot, excluding: webView) else {
            XCTFail("Expected browser slot overlay")
            return
        }

        XCTAssertTrue(overlay.isHidden, "Overlay should start hidden without an active drop zone")

        portal.updateDropZoneOverlay(forWebViewId: ObjectIdentifier(webView), zone: .right)
        slot.layoutSubtreeIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(slot.superview?.subviews.last === overlay, "Overlay should remain above the hosted web view")
        XCTAssertEqual(overlay.frame.origin.x, slot.frame.origin.x + 110, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, slot.frame.origin.y + 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 106, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 152, accuracy: 0.5)

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Invisible browser entries should hide the overlay")

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertFalse(overlay.isHidden, "Restoring visibility should restore the active drop-zone overlay")
    }

    func testPortalRevealRefreshesHostedWebViewWithoutFrameDelta() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let initialDisplayCount = webView.displayIfNeededCount
        let initialReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let hiddenDisplayCount = webView.displayIfNeededCount
        let hiddenReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertGreaterThanOrEqual(hiddenDisplayCount, initialDisplayCount)
        XCTAssertEqual(
            hiddenReattachCount,
            initialReattachCount,
            "Hiding a portal-hosted browser should not itself trigger the WebKit reattach path"
        )
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            hiddenDisplayCount,
            "Revealing an existing portal-hosted browser should refresh WebKit presentation immediately"
        )
        XCTAssertGreaterThan(
            webView.reattachRenderingStateCount,
            hiddenReattachCount,
            "Revealing an existing portal-hosted browser should trigger the WebKit reattach path"
        )
    }

    func testVisiblePortalEntryHidesWithoutDetachingDuringTransientAnchorRemovalUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor1 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor1)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        anchor1.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Visible browser entries should not detach during transient anchor removal")
        XCTAssertTrue(
            slot.isHidden,
            "Transient anchor churn should hide the stale browser slot instead of rendering in the wrong pane"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let anchor2 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor2)
        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor2)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after transient anchor removal should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Anchor rebinds should refresh hosted browser presentation even when geometry is unchanged"
        )
    }

    func testVisiblePortalEntryStaysVisibleDuringOffWindowAnchorReparentUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor = NSView(frame: anchorFrame)
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let offWindowContainer = NSView(frame: anchorFrame)
        anchor.removeFromSuperview()
        offWindowContainer.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Off-window anchor reparent should preserve the hosted browser slot during drag churn"
        )
        XCTAssertFalse(
            slot.isHidden,
            "Off-window anchor reparent should keep the visible browser portal alive until the anchor returns"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        contentView.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after off-window reparent should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
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

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }

    func testRegistryHideKeepsPortalHostedWebViewAttachedButHidden() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
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

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }
        XCTAssertFalse(slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Hiding should preserve the hosted WKWebView attachment")
        XCTAssertTrue(slot.isHidden, "Hiding should immediately hide the existing portal slot")
    }

    func testHiddenPortalEntrySurvivesAnchorRemovalUntilWorkspaceRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let oldAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(oldAnchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: oldAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()
        XCTAssertTrue(slot.isHidden, "Workspace handoff should hide the retiring browser before unmount")

        oldAnchor.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Hidden workspace browsers should stay attached while their SwiftUI anchor is temporarily unmounted"
        )
        XCTAssertTrue(slot.isHidden, "Unmounted hidden workspace browser should remain hidden until rebound")
        XCTAssertEqual(portal.debugEntryCount(), 1, "Workspace handoff should keep the hidden browser portal entry alive")

        let displayCountBeforeRebind = webView.displayIfNeededCount
        let newAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(newAnchor)
        portal.bind(webView: webView, to: newAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(newAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Selecting the workspace again should reuse the existing hidden browser portal slot"
        )
        XCTAssertFalse(slot.isHidden, "Rebinding the workspace browser should reveal the existing portal slot")
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayIfNeededCount,
            displayCountBeforeRebind,
            "Workspace rebind should refresh the preserved browser without recreating its portal slot"
        )
    }
}
