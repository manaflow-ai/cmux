import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WindowTerminalHostViewTitlebarHitTests: XCTestCase {
    func testHostViewKeepsTerminalTopRowClickableInsideTitlebarBand() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView, let container = contentView.superview else {
            XCTFail("Expected window content container")
            return
        }

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = makeMouseDownEvent(at: pointInWindow, window: window)

        XCTAssertGreaterThanOrEqual(
            pointInWindow.y,
            BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The regression point must exercise the fixed-height titlebar pass-through band"
        )
        assertHitFallsInsideHostedTerminal(
            host.performHitTest(at: pointInHost, currentEvent: event),
            hostedView: hostedView,
            message: "Terminal content inside the titlebar band should keep receiving top-row mouse-downs"
        )
    }

    func testHostViewPassesThroughRegisteredTitlebarControlsAboveTerminal() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView, let container = contentView.superview else {
            XCTFail("Expected window content container")
            return
        }

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        host.addSubview(makeHostedTerminalView(frame: host.bounds))
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 24, y: contentView.bounds.maxY - 24, width: 18, height: 18)
        )
        contentView.addSubview(region)

        let pointInWindow = contentView.convert(NSPoint(x: region.frame.midX, y: region.frame.midY), to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = makeMouseDownEvent(at: pointInWindow, window: window)

        XCTAssertGreaterThanOrEqual(
            pointInWindow.y,
            BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The control point must sit inside the fixed titlebar interaction band"
        )
        XCTAssertNil(
            host.performHitTest(at: pointInHost, currentEvent: event),
            "Registered titlebar controls must keep receiving clicks even when terminal content underlaps them"
        )
    }

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
    }

    private func makeMouseDownEvent(at locationInWindow: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create leftMouseDown event")
        }
        return event
    }

    private func assertHitFallsInsideHostedTerminal(
        _ hitView: NSView?,
        hostedView: GhosttySurfaceScrollView,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let hitView else {
            XCTFail(message, file: file, line: line)
            return
        }
        XCTAssertTrue(hitView === hostedView || hitView.isDescendant(of: hostedView), message, file: file, line: line)
    }
}
