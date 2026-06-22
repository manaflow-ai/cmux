import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PortalHitTestingPerformanceTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class CountingTabBarBackgroundNSView: NSView {
        private(set) var pointConversionCount = 0

        override func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
            pointConversionCount += 1
            return super.convert(point, from: view)
        }
    }

    private final class CountingSplitView: NSSplitView {
        private(set) var pointConversionCount = 0
        private(set) var rectConversionCount = 0

        override func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
            pointConversionCount += 1
            return super.convert(point, from: view)
        }

        override func convert(_ rect: NSRect, to view: NSView?) -> NSRect {
            rectConversionCount += 1
            return super.convert(rect, to: view)
        }
    }

    private final class SplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeMouseEvent(type: NSEvent.EventType, at locationInWindow: NSPoint, window: NSWindow) -> NSEvent {
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

    func testMouseMovedTabBarPassThroughUsesOnlyRegisteredRegions() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        let container = try XCTUnwrap(contentView.superview)
        let tabStrip = CountingTabBarBackgroundNSView(
            frame: NSRect(x: 0, y: contentView.bounds.maxY - 44, width: contentView.bounds.width, height: 44)
        )
        contentView.addSubview(tabStrip)

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInWindow = contentView.convert(NSPoint(x: contentView.bounds.midX, y: tabStrip.frame.midY), to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let decision = try XCTUnwrap(BonsplitTabBarPassThrough.passThroughDecision(
            at: pointInHost,
            in: host,
            eventType: .mouseMoved
        ))

        XCTAssertFalse(
            decision.result,
            "High-frequency hover routing should rely on registered Bonsplit tab-bar geometry."
        )
        XCTAssertEqual(
            tabStrip.pointConversionCount,
            0,
            "A registry miss during mouseMoved should not recurse into TabBarBackgroundNSView descendants."
        )
    }

    func testTerminalSplitDividerHitTestingReusesCachedRegionsForPointerMoves() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        let splitView = CountingSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = SplitDelegate()
        splitView.delegate = splitDelegate
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.setPosition(120, ofDividerAt: 0)
        splitView.adjustSubviews()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(CapturingView(frame: host.bounds))
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let event = makeMouseEvent(type: .mouseMoved, at: dividerPointInWindow, window: window)
        let initialRectConversionCount = splitView.rectConversionCount

        XCTAssertNil(host.performHitTest(at: dividerPointInHost, currentEvent: event))
        XCTAssertNil(host.performHitTest(at: dividerPointInHost, currentEvent: event))
        XCTAssertEqual(
            splitView.rectConversionCount - initialRectConversionCount,
            2,
            "The first pointer move should collect the split bounds and divider rect once."
        )
        XCTAssertEqual(
            splitView.pointConversionCount,
            0,
            "Repeated pointer moves should hit cached divider rectangles instead of converting through each split view."
        )
    }

    func testTerminalSplitDividerCacheIgnoresRemovedSplitView() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        let splitView = CountingSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = SplitDelegate()
        splitView.delegate = splitDelegate
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.setPosition(120, ofDividerAt: 0)
        splitView.adjustSubviews()

        let hostedView = CapturingView(frame: contentView.bounds)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let event = makeMouseEvent(type: .mouseMoved, at: dividerPointInWindow, window: window)

        XCTAssertNil(host.performHitTest(at: dividerPointInHost, currentEvent: event))

        splitView.removeFromSuperview()

        let hitView = host.performHitTest(at: dividerPointInHost, currentEvent: event)
        XCTAssertTrue(
            hitView === hostedView,
            "Removed split views must not leave stale cached divider strips that steal portal hits."
        )
    }

    func testTerminalSplitDividerCacheRefreshesAfterRootSubviewInsertion() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        let splitView = CountingSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        let splitDelegate = SplitDelegate()
        splitView.delegate = splitDelegate
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 80, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 81, y: 0, width: 239, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.setPosition(80, ofDividerAt: 0)
        splitView.adjustSubviews()

        let hostedView = CapturingView(frame: contentView.bounds)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let firstDividerPointInWindow = splitView.convert(
            NSPoint(x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5), y: splitView.bounds.midY),
            to: nil
        )
        let firstEvent = makeMouseEvent(type: .mouseMoved, at: firstDividerPointInWindow, window: window)
        XCTAssertNil(host.performHitTest(at: host.convert(firstDividerPointInWindow, from: nil), currentEvent: firstEvent))

        let insertedSplitView = CountingSplitView(frame: contentView.bounds)
        insertedSplitView.isVertical = true
        let insertedSplitDelegate = SplitDelegate()
        insertedSplitView.delegate = insertedSplitDelegate
        insertedSplitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 220, height: contentView.bounds.height)))
        insertedSplitView.addSubview(NSView(frame: NSRect(x: 221, y: 0, width: 99, height: contentView.bounds.height)))
        insertedSplitView.setPosition(220, ofDividerAt: 0)
        insertedSplitView.adjustSubviews()
        contentView.addSubview(insertedSplitView, positioned: .below, relativeTo: host)

        let insertedDividerPointInWindow = insertedSplitView.convert(
            NSPoint(x: insertedSplitView.arrangedSubviews[0].frame.maxX + (insertedSplitView.dividerThickness * 0.5), y: insertedSplitView.bounds.midY),
            to: nil
        )
        let insertedEvent = makeMouseEvent(type: .mouseMoved, at: insertedDividerPointInWindow, window: window)
        XCTAssertNil(host.performHitTest(at: host.convert(insertedDividerPointInWindow, from: nil), currentEvent: insertedEvent))
    }
}
