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


@MainActor
final class BrowserPanelHostContainerViewTests: XCTestCase {
    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class TrackingInspectorFrontendWebView: WKWebView {
        private(set) var evaluatedJavaScript: [String] = []

        @MainActor override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            evaluatedJavaScript.append(javaScriptString)
            completionHandler?(nil, nil)
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testBrowserPanelHostPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let bodyPointInHost = NSPoint(x: inspectorContainer.frame.minX + 18, y: host.bounds.midY)
        let interiorHit = host.hitTest(bodyPointInHost)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should claim the right-docked divider edge for the manual resize path"
        )
        XCTAssertTrue(
            interiorHit == nil || interiorHit !== host,
            "Only the divider edge should be claimed; interior inspector hits should not be stolen by the host. actual=\(String(describing: interiorHit))"
        )
    }

    func testBrowserPanelHostClaimsCollapsedHostedInspectorSiblingDividerAtLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(frame: webViewRoot.bounds)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Collapsed right-docked divider should stay on the manual browser-panel resize path while beating the sidebar-resizer overlap"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 36, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 0)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 0)
    }

    func testBrowserPanelHostClaimsHostedInspectorDividerAcrossFullHeight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 20, width: 92, height: webViewRoot.bounds.height - 40))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 20, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height - 40)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "The custom DevTools divider should remain draggable at the top edge of the browser pane"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "The custom DevTools divider should remain draggable at the bottom edge of the browser pane"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should only take the manual fallback path when the divider edge is not natively hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 92)
    }

    func testBrowserPanelHostKeepsInspectorResizableAfterShrinkingToMinimumWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 220, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThanOrEqual(
            inspectorContainer.frame.width,
            120,
            "Shrinking the DevTools pane should clamp to a recoverable minimum width"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the top edge"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the bottom edge"
        )
    }

    func testBrowserPanelHostPromotesVisibleRightDockedInspectorIntoManagedSideDock() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height + 180))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "A visible right-docked inspector should not wait on async dock-configuration JS before entering the managed side-dock path"
        )
        XCTAssertTrue(
            pageView.superview === inspectorView.superview && pageView.superview !== slotView,
            "Promotion should move both hosted inspector siblings into the managed side-dock container"
        )
        XCTAssertEqual(
            pageView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize stale page heights to the host height so the page layer stops covering the divider"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize the inspector height to the host height"
        )
    }

    func testBrowserPanelHostAllowsRightDockedInspectorToExpandLeftAfterPromotion() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "The managed side-dock path should be active before drag assertions run"
        )

        let initialPageWidth = pageView.frame.width
        let initialInspectorWidth = inspectorView.frame.width
        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(
            inspectorView.frame.width,
            initialInspectorWidth,
            "Right-docked DevTools should expand when the divider is dragged left"
        )
        XCTAssertLessThan(
            pageView.frame.width,
            initialPageWidth,
            "Expanding right-docked DevTools should shrink the page width"
        )
    }

    func testBrowserPanelHostKeepsAutomaticRightDockedWidthAboveMinimumWhileShrinking() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 140, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 132, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 132, y: 0, width: slotView.bounds.width - 132, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setPreferredHostedInspectorWidth(width: 80, widthFraction: nil)
        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            inspectorView.frame.width,
            120,
            "Automatic pane resize should honor the same minimum hosted inspector width as manual dragging"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Automatic shrink should keep the inspector vertically normalized to the host height"
        )
    }

    func testBrowserPanelHostRequestsBottomDockWhenSideDockLeavesTooLittlePageWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height))
        let inspectorView = TrackingInspectorFrontendWebView(
            frame: NSRect(x: 120, y: 0, width: slotView.bounds.width - 120, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("WI._dockBottom()") }),
            "Narrow pane widths should request bottom-docked DevTools instead of leaving the side-docked inspector in an unstable layout"
        )
        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("const allowSideDock = false;") }),
            "Once a narrow pane proves it cannot safely side-dock DevTools, the inspector frontend should hide and disable left/right dock controls"
        )
    }

    func testBrowserPanelManagedSideDockDoesNotAutoresizeDraggedFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)
        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 30, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        guard let managedContainer = pageView.superview else {
            XCTFail("Expected managed side-dock container")
            return
        }
        let draggedPageFrame = pageView.frame
        let draggedInspectorFrame = inspectorView.frame

        managedContainer.setFrameSize(
            NSSize(width: managedContainer.frame.width, height: managedContainer.frame.height + 24)
        )

        XCTAssertEqual(
            pageView.frame.origin.x,
            draggedPageFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should not autoresize the page back to a stale divider position"
        )
        XCTAssertEqual(
            pageView.frame.width,
            draggedPageFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged page width until the host explicitly reapplies layout"
        )
        XCTAssertEqual(
            inspectorView.frame.origin.x,
            draggedInspectorFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector origin"
        )
        XCTAssertEqual(
            inspectorView.frame.width,
            draggedInspectorFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector width"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let inspectorContainer = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(inspectorContainer)
        webViewRoot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.maxX - 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorContainer.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testBrowserPanelHostReappliesStoredHostedInspectorWidthAfterLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(
            frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height)
        )
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: webViewRoot.bounds.width - 92,
            height: webViewRoot.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testWindowBrowserSlotPinsHostedWebViewWithAutoresizingForAttachedInspector() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)

        slot.pinHostedWebView(webView)
        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        slot.layoutSubtreeIfNeeded()

        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(webView.autoresizingMask, [.width, .height])
        XCTAssertEqual(webView.frame, slot.bounds)
    }

    func testWindowBrowserSlotReattachesPlainWebViewAtFullBoundsAfterHiddenHostResize() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        XCTAssertEqual(webView.frame, slot.bounds)

        let externalHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        webView.removeFromSuperview()
        externalHost.addSubview(webView)
        webView.frame = externalHost.bounds
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        slot.addSubview(webView)
        slot.pinHostedWebView(webView)

        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        slot.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            webView.frame,
            slot.bounds,
            "Reattaching a plain web view should restore full-bounds hosting instead of preserving a stale inset frame from a hidden host"
        )
    }
}


