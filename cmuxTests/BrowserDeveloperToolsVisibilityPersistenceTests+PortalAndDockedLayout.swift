import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Portal-hosted attachment and docked inspector layout
extension BrowserDeveloperToolsVisibilityPersistenceTests {
    func testWebViewDismantleKeepsPortalHostedWebViewAttachedWhenDeveloperToolsIntentIsVisible() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let paneId = PaneID(id: UUID())
        XCTAssertTrue(panel.showDeveloperTools())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { closeWindow(window) }
        let anchor = NSView(frame: NSRect(x: 30, y: 30, width: 180, height: 140))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        XCTAssertNotNil(panel.webView.superview)

        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: true,
            useLocalInlineHosting: false,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            omnibarSuggestions: nil,
            paneTopChromeHeight: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        WebViewRepresentable.dismantleNSView(anchor, coordinator: coordinator)

        XCTAssertNotNil(panel.webView.superview)
    }

    func testWebViewDismantleKeepsPortalHostedWebViewAttachedWhenDeveloperToolsIntentIsHidden() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let paneId = PaneID(id: UUID())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { closeWindow(window) }
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 150))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        XCTAssertNotNil(panel.webView.superview)

        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: true,
            useLocalInlineHosting: false,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            omnibarSuggestions: nil,
            paneTopChromeHeight: 0
        )
        let coordinator = representable.makeCoordinator()
        coordinator.webView = panel.webView
        WebViewRepresentable.dismantleNSView(anchor, coordinator: coordinator)

        XCTAssertNotNil(panel.webView.superview)
    }

    func testPortalBindDoesNotMoveInspectorFrontendOutOfDetachedWindowOwner() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            closeWindow(window)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let sourceSlot = WindowBrowserSlotView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        contentView.addSubview(sourceSlot)
        let anchor = NSView(frame: NSRect(x: 280, y: 20, width: 220, height: 180))
        contentView.addSubview(anchor)

        panel.webView.frame = sourceSlot.bounds
        sourceSlot.addSubview(panel.webView)
        let frontendWebView = WKInspectorProbeWebView(
            frame: NSRect(x: 0, y: 0, width: sourceSlot.bounds.width, height: 72),
            configuration: WKWebViewConfiguration()
        )
        sourceSlot.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true, zPriority: 1)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        XCTAssertFalse(
            panel.webView.superview === sourceSlot,
            "The page web view should move to the portal host for this regression setup"
        )
        XCTAssertTrue(
            frontendWebView.superview === sourceSlot,
            "The portal must not reparent WKInspector frontend views; WebKit owns their window/controller lifecycle"
        )
    }

    func testTransientHideAttachmentPreserveDisablesForSideDockedInspectorLayout() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        XCTAssertTrue(panel.showDeveloperTools())

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        panel.webView.frame = NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)
        host.addSubview(panel.webView)

        let inspectorContainer = NSView(
            frame: NSRect(x: 120, y: 0, width: host.bounds.width - 120, height: host.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        host.addSubview(inspectorContainer)

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testTransientHideAttachmentPreserveStaysEnabledForBottomDockedInspectorLayout() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        XCTAssertTrue(panel.showDeveloperTools())

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        panel.webView.frame = NSRect(x: 0, y: 80, width: host.bounds.width, height: host.bounds.height - 80)
        host.addSubview(panel.webView)

        let inspectorContainer = NSView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 80))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        host.addSubview(inspectorContainer)

        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

    func testOffWindowReplacementLocalHostDoesNotStealVisibleDevToolsWebView() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        XCTAssertTrue(panel.showDeveloperTools())

        let paneId = PaneID(id: UUID())
        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: false,
            useLocalInlineHosting: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            omnibarSuggestions: nil,
            paneTopChromeHeight: 0
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            closeWindow(window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let visibleHosting = NSHostingView(rootView: representable)
        visibleHosting.frame = contentView.bounds
        visibleHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(visibleHosting)
        defer { visibleHosting.removeFromSuperview() }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        visibleHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let visibleHost = findHostContainerView(in: visibleHosting) else {
            XCTFail("Expected visible local host")
            return
        }
        guard let visibleSlot = panel.webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected visible local inline slot")
            return
        }

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: visibleSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        visibleSlot.addSubview(inspectorView)
        defer { inspectorView.removeFromSuperview() }
        panel.webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: visibleSlot.bounds.width,
            height: visibleSlot.bounds.height - inspectorView.frame.height
        )
        visibleSlot.layoutSubtreeIfNeeded()

        let detachedRoot = NSView(frame: visibleHosting.frame)
        let offWindowHosting = NSHostingView(rootView: representable)
        offWindowHosting.frame = detachedRoot.bounds
        offWindowHosting.autoresizingMask = [.width, .height]
        detachedRoot.addSubview(offWindowHosting)
        defer { offWindowHosting.removeFromSuperview() }
        detachedRoot.layoutSubtreeIfNeeded()
        offWindowHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(findHostContainerView(in: offWindowHosting), "Expected off-window replacement host")
        XCTAssertTrue(visibleHost.window === window)
        XCTAssertTrue(
            panel.webView.superview === visibleSlot,
            "An off-window replacement host should not steal a visible DevTools-hosted web view during split zoom churn"
        )
        XCTAssertTrue(
            inspectorView.superview === visibleSlot,
            "An off-window replacement host should leave DevTools companion views in the visible local host"
        )
    }

    func testVisibleReplacementLocalHostNormalizesBottomDockedInspectorFrames() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }
        XCTAssertTrue(panel.showDeveloperTools())

        let paneId = PaneID(id: UUID())
        let representable = WebViewRepresentable(
            panel: panel,
            paneId: paneId,
            shouldAttachWebView: false,
            useLocalInlineHosting: true,
            shouldFocusWebView: false,
            isPanelFocused: true,
            portalZPriority: 0,
            paneDropZone: nil,
            searchOverlay: nil,
            omnibarSuggestions: nil,
            paneTopChromeHeight: 0
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { closeWindow(window) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let narrowHosting = NSHostingView(rootView: representable)
        narrowHosting.frame = NSRect(x: 180, y: 0, width: 180, height: 240)
        contentView.addSubview(narrowHosting)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        narrowHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let initialSlot = panel.webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected initial local inline slot")
            return
        }

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: initialSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        initialSlot.addSubview(inspectorView)
        panel.webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: initialSlot.bounds.width,
            height: initialSlot.bounds.height - inspectorView.frame.height
        )
        initialSlot.layoutSubtreeIfNeeded()

        let replacementHosting = NSHostingView(rootView: representable)
        replacementHosting.frame = contentView.bounds
        replacementHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(replacementHosting, positioned: .above, relativeTo: narrowHosting)
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        replacementHosting.rootView = representable
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        narrowHosting.removeFromSuperview()
        contentView.layoutSubtreeIfNeeded()
        replacementHosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let replacementHost = findHostContainerView(in: replacementHosting),
              let replacementSlot = findWindowBrowserSlotView(in: replacementHost) else {
            XCTFail("Expected replacement local inline host")
            return
        }

        XCTAssertTrue(
            panel.webView.superview === replacementSlot,
            "A visible replacement local host should take over the hosted page"
        )
        XCTAssertTrue(
            inspectorView.superview === replacementSlot,
            "A visible replacement local host should move the DevTools companion views with the page"
        )
        XCTAssertEqual(inspectorView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.width, replacementSlot.bounds.width, accuracy: 0.5)
        XCTAssertEqual(inspectorView.frame.height, 72, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.minY, 72, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.width, replacementSlot.bounds.width, accuracy: 0.5)
        XCTAssertEqual(panel.webView.frame.height, replacementSlot.bounds.height - 72, accuracy: 0.5)
    }
}
