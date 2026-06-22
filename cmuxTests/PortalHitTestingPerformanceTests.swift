import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct PortalHitTestingPerformanceTests {
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

    @Test
    func mouseMovedTabBarPassThroughUsesOnlyRegisteredRegions() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        let container = try #require(contentView.superview)
        let tabStrip = CountingTabBarBackgroundNSView(
            frame: NSRect(x: 0, y: contentView.bounds.maxY - 44, width: contentView.bounds.width, height: 44)
        )
        contentView.addSubview(tabStrip)

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInWindow = contentView.convert(NSPoint(x: contentView.bounds.midX, y: tabStrip.frame.midY), to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let decision = try #require(BonsplitTabBarPassThrough.passThroughDecision(
            at: pointInHost,
            in: host,
            eventType: .mouseMoved
        ))

        #expect(
            !decision.result,
            "High-frequency hover routing should rely on registered Bonsplit tab-bar geometry."
        )
        #expect(
            tabStrip.pointConversionCount == 0,
            "A registry miss during mouseMoved should not recurse into TabBarBackgroundNSView descendants."
        )
    }

    @Test
    func terminalSplitDividerHitTestingReusesCachedRegionsForPointerMoves() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
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

        let unrelatedContainer = NSView(frame: contentView.bounds)
        let unrelatedMiddle = NSView(frame: contentView.bounds)
        let unrelatedLeaf = NSView(frame: contentView.bounds)
        unrelatedMiddle.addSubview(unrelatedLeaf)
        unrelatedContainer.addSubview(unrelatedMiddle)
        contentView.addSubview(unrelatedContainer)

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

        #expect(host.performHitTest(at: dividerPointInHost, currentEvent: event) == nil)
        #expect(host.performHitTest(at: dividerPointInHost, currentEvent: event) == nil)
        #expect(
            splitView.rectConversionCount - initialRectConversionCount == 2,
            "The first pointer move should collect the split bounds and divider rect once."
        )
        #expect(
            splitView.pointConversionCount == 0,
            "Repeated pointer moves should hit cached divider rectangles instead of converting through each split view."
        )
        unrelatedLeaf.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(host.performHitTest(at: dividerPointInHost, currentEvent: event) == nil)
        #expect(
            splitView.rectConversionCount - initialRectConversionCount == 2,
            "Unrelated deep subtree mutations should not rebuild the cached divider geometry."
        )
    }

    @Test
    func terminalSplitDividerCacheIgnoresRemovedSplitView() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
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

        #expect(host.performHitTest(at: dividerPointInHost, currentEvent: event) == nil)

        splitView.removeFromSuperview()

        let hitView = host.performHitTest(at: dividerPointInHost, currentEvent: event)
        #expect(
            hitView === hostedView,
            "Removed split views must not leave stale cached divider strips that steal portal hits."
        )
    }

    @Test
    func terminalSplitDividerCacheRefreshesAfterRootSubviewInsertion() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
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
        #expect(host.performHitTest(at: host.convert(firstDividerPointInWindow, from: nil), currentEvent: firstEvent) == nil)

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
        #expect(host.performHitTest(at: host.convert(insertedDividerPointInWindow, from: nil), currentEvent: insertedEvent) == nil)
    }

    @Test
    func terminalSplitDividerCacheRefreshesAfterNestedSubviewInsertion() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)

        let hostedView = CapturingView(frame: contentView.bounds)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let warmPointInWindow = contentView.convert(NSPoint(x: 20, y: 20), to: nil)
        let warmEvent = makeMouseEvent(type: .mouseMoved, at: warmPointInWindow, window: window)
        #expect(host.performHitTest(at: host.convert(warmPointInWindow, from: nil), currentEvent: warmEvent) === hostedView)

        let insertedSplitView = CountingSplitView(frame: container.bounds)
        insertedSplitView.isVertical = true
        let insertedSplitDelegate = SplitDelegate()
        insertedSplitView.delegate = insertedSplitDelegate
        insertedSplitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: container.bounds.height)))
        insertedSplitView.addSubview(NSView(frame: NSRect(x: 201, y: 0, width: 119, height: container.bounds.height)))
        container.addSubview(insertedSplitView)

        let insertedDividerPointInWindow = insertedSplitView.convert(
            NSPoint(x: insertedSplitView.arrangedSubviews[0].frame.maxX + (insertedSplitView.dividerThickness * 0.5), y: insertedSplitView.bounds.midY),
            to: nil
        )
        let insertedEvent = makeMouseEvent(type: .mouseMoved, at: insertedDividerPointInWindow, window: window)
        #expect(host.performHitTest(at: host.convert(insertedDividerPointInWindow, from: nil), currentEvent: insertedEvent) == nil)
    }

    @Test
    func terminalSplitDividerCacheRefreshesWhenNestedSplitBecomesVisible() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        let container = NSView(frame: contentView.bounds)
        container.isHidden = true
        let splitView = CountingSplitView(frame: container.bounds)
        splitView.isVertical = true
        let splitDelegate = SplitDelegate()
        splitView.delegate = splitDelegate
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 180, height: container.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 181, y: 0, width: 139, height: container.bounds.height)))
        splitView.setPosition(180, ofDividerAt: 0)
        splitView.adjustSubviews()
        container.addSubview(splitView)
        contentView.addSubview(container)

        let hostedView = CapturingView(frame: contentView.bounds)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInWindow = splitView.convert(
            NSPoint(x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5), y: splitView.bounds.midY),
            to: nil
        )
        let event = makeMouseEvent(type: .mouseMoved, at: dividerPointInWindow, window: window)
        #expect(host.performHitTest(at: host.convert(dividerPointInWindow, from: nil), currentEvent: event) === hostedView)

        container.isHidden = false

        #expect(host.performHitTest(at: host.convert(dividerPointInWindow, from: nil), currentEvent: event) == nil)
    }

    @Test
    func terminalSplitDividerCacheRefreshesAfterContainerMoves() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try #require(window.contentView)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: contentView.bounds.height))
        let splitView = CountingSplitView(frame: container.bounds)
        splitView.isVertical = true
        let splitDelegate = SplitDelegate()
        splitView.delegate = splitDelegate
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 160, height: container.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 161, y: 0, width: 159, height: container.bounds.height)))
        splitView.setPosition(160, ofDividerAt: 0)
        splitView.adjustSubviews()
        container.addSubview(splitView)
        contentView.addSubview(container)

        let hostedView = CapturingView(frame: contentView.bounds)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let oldDividerPointInWindow = splitView.convert(
            NSPoint(x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5), y: splitView.bounds.midY),
            to: nil
        )
        let oldEvent = makeMouseEvent(type: .mouseMoved, at: oldDividerPointInWindow, window: window)
        #expect(host.performHitTest(at: host.convert(oldDividerPointInWindow, from: nil), currentEvent: oldEvent) == nil)

        container.setFrameOrigin(NSPoint(x: 40, y: 0))
        let newDividerPointInWindow = splitView.convert(
            NSPoint(x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5), y: splitView.bounds.midY),
            to: nil
        )
        let newEvent = makeMouseEvent(type: .mouseMoved, at: newDividerPointInWindow, window: window)
        #expect(host.performHitTest(at: host.convert(oldDividerPointInWindow, from: nil), currentEvent: oldEvent) === hostedView)
        #expect(host.performHitTest(at: host.convert(newDividerPointInWindow, from: nil), currentEvent: newEvent) == nil)
    }
}
