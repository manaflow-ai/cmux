import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PortalTabDragRoutingTests: XCTestCase {
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

    private struct TabStripPassThroughFixture {
        let host: WindowTerminalHostView
        let pointInHost: NSPoint
        let pointInWindow: NSPoint
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
        let host = WindowTerminalHostView(frame: hostFrame)
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
        return TabStripPassThroughFixture(host: host, pointInHost: pointInHost, pointInWindow: pointInWindow)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        at locationInWindow: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) event")
        }
        return event
    }

    func testHostViewPassesThroughUnderlyingTabStripDuringMouseDrag() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let fixture = installTabStripPassThroughFixture(in: window) else {
            return
        }

        let event = makeMouseEvent(
            type: .leftMouseDragged,
            at: fixture.pointInWindow,
            window: window
        )

        XCTAssertNil(
            fixture.host.performHitTest(at: fixture.pointInHost, currentEvent: event),
            "Terminal portal should defer to the minimal tab strip while a Bonsplit tab is being dragged"
        )
    }

    func testHostViewPassesThroughUnderlyingTabStripWithoutCurrentEvent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let fixture = installTabStripPassThroughFixture(in: window) else {
            return
        }

        XCTAssertNil(
            fixture.host.performHitTest(at: fixture.pointInHost, currentEvent: nil),
            "Terminal portal should keep the shared no-event tab-strip pass-through path"
        )
    }

    func testTabStripPassThroughTreatsAppKitDragRoutingAsPointerEvents() {
        XCTAssertTrue(BonsplitTabBarPassThrough.isPassThroughPointerEvent(.appKitDefined))
        XCTAssertTrue(BonsplitTabBarPassThrough.isPassThroughPointerEvent(.applicationDefined))
        XCTAssertTrue(BonsplitTabBarPassThrough.isPassThroughPointerEvent(.systemDefined))
        XCTAssertTrue(BonsplitTabBarPassThrough.isPassThroughPointerEvent(.periodic))
    }

    func testTerminalPaneDropTargetDefersToUnderlyingTabStrip() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected window content view")
            return
        }

        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(x: 0, y: contentView.bounds.maxY - 44, width: contentView.bounds.width, height: 44)
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let dropTarget = TerminalPaneDropTargetView(frame: contentView.bounds)
        dropTarget.autoresizingMask = [.width, .height]
        contentView.addSubview(dropTarget, positioned: .above, relativeTo: tabStrip)

        let point = NSPoint(x: contentView.bounds.midX, y: tabStrip.frame.midY)
        XCTAssertTrue(
            dropTarget.shouldDeferToPaneTabBar(at: point),
            "Terminal pane drop target should not steal Bonsplit tab-strip drags"
        )
    }

    func testTerminalPaneDropTargetIgnoresExternalFileImageAndBrowserDrags() {
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
                TerminalPaneDropTargetView.shouldCaptureHitTesting(
                    pasteboardTypes: pasteboardTypes,
                    eventType: .leftMouseDragged
                ),
                "Terminal pane drop target should not capture external drag payload: \(pasteboardTypes)"
            )
        }
    }
}
