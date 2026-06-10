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
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class FakeTabBarBackgroundNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
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

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

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

    private func isInspectorOwnedHit(_ hit: NSView?, inspectorView: NSView, pageView: NSView) -> Bool {
        guard let hit else { return false }
        if hit === pageView || hit.isDescendant(of: pageView) {
            return false
        }
        if hit === inspectorView || hit.isDescendant(of: inspectorView) {
            return true
        }
        return inspectorView.isDescendant(of: hit) && !(pageView === hit || pageView.isDescendant(of: hit))
    }

    private struct TabStripPassThroughFixture {
        let host: WindowBrowserHostView
        let pointInHost: NSPoint
    }

    private func installTabStripPassThroughFixture(in window: NSWindow) -> TabStripPassThroughFixture? {
        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected window content container")
            return nil
        }

        let tabStripHeight: CGFloat = 44
        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(
                x: 0,
                y: contentView.bounds.maxY - tabStripHeight,
                width: contentView.bounds.width,
                height: tabStripHeight
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let titlebarBandHeight = max(28, min(72, window.frame.height - window.contentLayoutRect.height))
        let pointInContent = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY - titlebarBandHeight - 8
        )
        let pointInWindow = contentView.convert(pointInContent, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        return TabStripPassThroughFixture(host: host, pointInHost: pointInHost)
    }

    func testHostViewPassesThroughUnderlyingTabStripInSecondWindowBelowTitlebarBand() {
        // The reported regression (#3193) was that the original window kept
        // working but later-created windows did not. Set up two windows and
        // assert the pass-through holds in BOTH to lock in per-instance wiring.
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 32, y: 32, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            secondWindow.orderOut(nil)
            firstWindow.orderOut(nil)
        }

        guard let firstFixture = installTabStripPassThroughFixture(in: firstWindow),
              let secondFixture = installTabStripPassThroughFixture(in: secondWindow) else {
            return
        }

        XCTAssertNil(
            firstFixture.host.hitTest(firstFixture.pointInHost),
            "Browser portal should defer to the minimal tab strip in the original window just below the titlebar interaction band"
        )
        XCTAssertNil(
            secondFixture.host.hitTest(secondFixture.pointInHost),
            "Browser portal should defer to the minimal tab strip in later-created windows just below the titlebar interaction band"
        )
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }

    func testWindowBrowserPortalIgnoresHostedInspectorSplitResizeNotifications() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        appSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: contentView.bounds.height)))
        contentView.addSubview(appSplit)

        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)))
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: host.bounds.height)))
        host.addSubview(inspectorSplit)

        XCTAssertTrue(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                appSplit,
                window: window,
                hostView: host
            ),
            "App layout splits should still trigger browser portal geometry sync"
        )
        XCTAssertFalse(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                inspectorSplit,
                window: window,
                hostView: host
            ),
            "Hosted DevTools/internal splits should not trigger browser portal geometry sync"
        )
    }

    func testDragHoverEventsPassThroughForTabTransferOnBrowserHoverEvents() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .mouseEntered
            )
        )
    }

    func testDragHoverEventsPassThroughForSidebarReorderWithoutMouseButtonState() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.sidebarTabReorderType],
                eventType: .cursorUpdate
            )
        )
    }

    func testDragHoverEventsDoNotPassThroughForUnrelatedPasteboardTypes() {
        let externalPayloads: [[NSPasteboard.PasteboardType]] = [
            [.fileURL],
            [.URL],
            [.png],
            [.tiff],
            [.html],
            [.string],
            [.fileURL, .png],
        ]

        for pasteboardTypes in externalPayloads {
            XCTAssertFalse(
                WindowBrowserHostView.shouldPassThroughToDragTargets(
                    pasteboardTypes: pasteboardTypes,
                    eventType: .cursorUpdate
                ),
                "Browser host should keep external drag payload in WebKit: \(pasteboardTypes)"
            )
        }
        XCTAssertFalse(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .mouseMoved
            )
        )
    }

    func testHostViewKeepsHostedInspectorDividerInteractive() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        // Underlying app layout split that should still be pass-through.
        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.dividerStyle = .thin
        let appSplitDelegate = BonsplitMockSplitDelegate()
        appSplit.delegate = appSplitDelegate
        let leading = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: contentView.bounds.height))
        let trailing = NSView(frame: NSRect(x: 211, y: 0, width: 209, height: contentView.bounds.height))
        appSplit.addSubview(leading)
        appSplit.addSubview(trailing)
        contentView.addSubview(appSplit)
        appSplit.adjustSubviews()

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        // WebKit inspector uses an internal split (page + console). Divider drags
        // here must stay in hosted content, not pass through to appSplit behind it.
        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = false
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 160))
        let consoleView = CapturingView(frame: NSRect(x: 0, y: 161, width: host.bounds.width, height: 99))
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(consoleView)
        host.addSubview(inspectorSplit)
        inspectorSplit.setPosition(160, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let appDividerPointInSplit = NSPoint(
            x: appSplit.arrangedSubviews[0].frame.maxX + (appSplit.dividerThickness * 0.5),
            y: appSplit.bounds.midY
        )
        let appDividerPointInWindow = appSplit.convert(appDividerPointInSplit, to: nil)
        let appDividerPointInHost = host.convert(appDividerPointInWindow, from: nil)
        XCTAssertNil(
            host.hitTest(appDividerPointInHost),
            "Underlying app split divider should still pass through with a hosted inspector split present"
        )

        let dividerPointInInspector = NSPoint(
            x: inspectorSplit.bounds.midX,
            y: inspectorSplit.arrangedSubviews[0].frame.maxY + (inspectorSplit.dividerThickness * 0.5)
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInInspector, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let hit = host.hitTest(dividerPointInHost)

        XCTAssertNotNil(
            hit,
            "Inspector divider should receive hit-testing in hosted content, not pass through"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside inspector split subtree"
            )
        }
    }

    func testHostViewKeepsHostedVerticalInspectorDividerInteractiveAtSlotLeadingEdge() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorSplit = NSSplitView(frame: slot.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: 1, height: slot.bounds.height))
        let inspectorView = CapturingView(
            frame: NSRect(x: 2, y: 0, width: slot.bounds.width - 2, height: slot.bounds.height)
        )
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(inspectorView)
        slot.addSubview(inspectorSplit)
        inspectorSplit.setPosition(1, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: inspectorSplit.arrangedSubviews[0].frame.maxX + (inspectorSplit.dividerThickness * 0.5),
            y: inspectorSplit.bounds.midY
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(inspectorSplit.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertTrue(
            abs(dividerPointInHost.x - slot.frame.minX) <= 2,
            "Expected collapsed hosted divider to overlap the browser slot leading-edge resizer zone"
        )

        let hit = host.hitTest(dividerPointInHost)
        XCTAssertNotNil(
            hit,
            "Hosted vertical inspector divider should stay interactive even when collapsed onto the slot edge"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside hosted inspector split subtree at the slot edge"
            )
        }
    }

    func testHostViewPrefersNativeHostedInspectorSiblingDividerHit() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorView.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Hosted right-docked inspector divider should stay on the native WebKit hit path when WebKit exposes a hittable inspector-side view. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewPrefersNativeNestedHostedInspectorSiblingDividerHit() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: wrapper.bounds.width - 92, height: wrapper.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Portal host should prefer the native nested WebKit hit target on the right-docked divider when available. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior nested inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewReappliesStoredHostedInspectorWidthAfterSlotLayoutReset() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: wrapper.bounds.width - 92,
            height: wrapper.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)

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
        slot.needsLayout = true
        slot.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testHostViewFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            dividerHit === host,
            "Host should only take the manual fallback path when the right-docked divider edge is not natively hittable. actual=\(String(describing: dividerHit))"
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
        XCTAssertGreaterThan(inspectorView.frame.minX, 92)
    }

    func testHostViewFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorView = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(inspectorView)
        slot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.maxX - 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
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

        XCTAssertGreaterThan(inspectorView.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testHostViewClaimsCollapsedHostedInspectorSiblingDividerAtSlotLeadingEdge() {
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
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(frame: slot.bounds)
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(dividerPointInHost.x - slot.frame.minX, 2)
        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Collapsed right-docked hosted inspector divider should stay on the native WebKit hit path while still beating the sidebar-resizer overlap zone. actual=\(String(describing: dividerHit))"
        )
    }
}


