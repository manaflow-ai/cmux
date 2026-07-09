import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Hosted inspector bottom dock divider")
struct HostedInspectorBottomDockDividerTests {
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

    @Test func portalHostClaimsBottomDockSeam() throws {
        let fixture = try makePortalFixture()
        defer { fixture.window.orderOut(nil) }

        let seamInSlot = NSPoint(x: fixture.slot.bounds.midX, y: fixture.inspectorView.frame.maxY)
        let seamInHost = fixture.host.convert(fixture.slot.convert(seamInSlot, to: nil), from: nil)

        #expect(fixture.host.hitTest(seamInHost) === fixture.host)
    }

    @Test func portalHostBottomDockDragResizesComplementaryFrames() throws {
        let fixture = try makePortalFixture()
        defer { fixture.window.orderOut(nil) }
        let initialHeight = fixture.inspectorView.frame.height
        let seamInWindow = fixture.slot.convert(
            NSPoint(x: fixture.slot.bounds.midX, y: fixture.inspectorView.frame.maxY),
            to: nil
        )

        fixture.host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: seamInWindow, window: fixture.window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: seamInWindow.x, y: seamInWindow.y + 36),
            window: fixture.window
        )
        fixture.host.mouseDragged(with: drag)
        fixture.host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: fixture.window))

        #expect(fixture.inspectorView.frame.height > initialHeight)
        #expect(abs(fixture.pageView.frame.minY - fixture.inspectorView.frame.maxY) <= 0.5)
        #expect(abs(fixture.pageView.frame.maxY - fixture.slot.bounds.maxY) <= 0.5)
    }

    @Test func localInlineHostClaimsBottomDockSeam() throws {
        let fixture = try makeLocalFixture()
        defer { fixture.window.orderOut(nil) }

        let seam = NSPoint(x: fixture.host.bounds.midX, y: fixture.inspectorView.frame.maxY)
        #expect(fixture.host.hitTest(seam) === fixture.host)
    }

    @Test func smallPaneSideDockDragMovesIntoDegradedRange() throws {
        let fixture = try makeLocalFixture(width: 160, pageFrame: NSRect(x: 0, y: 0, width: 100, height: 220), inspectorFrame: NSRect(x: 100, y: 0, width: 60, height: 220))
        defer { fixture.window.orderOut(nil) }
        let seam = NSPoint(x: fixture.inspectorView.frame.minX, y: fixture.host.bounds.midY)
        let seamInWindow = fixture.host.convert(seam, to: nil)

        fixture.host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: seamInWindow, window: fixture.window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: seamInWindow.x - 30, y: seamInWindow.y),
            window: fixture.window
        )
        fixture.host.mouseDragged(with: drag)
        fixture.host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: fixture.window))

        #expect(fixture.inspectorView.frame.width > 60)
        #expect(abs(fixture.pageView.frame.maxX - fixture.inspectorView.frame.minX) <= 0.5)
    }

    private struct PortalFixture {
        let window: NSWindow
        let host: WindowBrowserHostView
        let slot: WindowBrowserSlotView
        let pageView: NSView
        let inspectorView: NSView
    }

    private struct LocalFixture {
        let window: NSWindow
        let host: WebViewRepresentable.HostContainerView
        let pageView: NSView
        let inspectorView: NSView
    }

    private func makePortalFixture() throws -> PortalFixture {
        let window = makeWindow()
        let contentView = try #require(window.contentView)
        let container = try #require(contentView.superview)
        let host = WindowBrowserHostView(frame: container.convert(contentView.bounds, from: contentView))
        container.addSubview(host, positioned: .above, relativeTo: contentView)
        let slot = WindowBrowserSlotView(frame: NSRect(x: 80, y: 0, width: 280, height: 220))
        host.addSubview(slot)
        let inspectorView = WKInspectorProbeView(frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: 90))
        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 90, width: slot.bounds.width, height: slot.bounds.height - 90))
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        return PortalFixture(window: window, host: host, slot: slot, pageView: pageView, inspectorView: inspectorView)
    }

    private func makeLocalFixture(
        width: CGFloat = 280,
        pageFrame: NSRect = NSRect(x: 0, y: 90, width: 280, height: 130),
        inspectorFrame: NSRect = NSRect(x: 0, y: 0, width: 280, height: 90)
    ) throws -> LocalFixture {
        let window = makeWindow()
        let contentView = try #require(window.contentView)
        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 80, y: 0, width: width, height: 220))
        contentView.addSubview(host)
        let pageView = PrimaryPageProbeView(frame: pageFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorFrame)
        host.addSubview(pageView)
        host.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        return LocalFixture(window: window, host: host, pageView: pageView, inspectorView: inspectorView)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
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
            pressure: 1
        ) else {
            fatalError("Failed to create mouse event")
        }
        return event
    }
}
