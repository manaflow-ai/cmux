import XCTest
import AppKit
import SwiftUI
@testable import Bonsplit

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

    private final class CountingTabBarBackgroundNSView: NSView {
        private(set) var pointConversionCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
            pointConversionCount += 1
            return super.convert(point, from: view)
        }
    }

    func testCompactPaneTabChromeStaysBelowDragHitMinimum() throws {
        let appearance = BonsplitConfiguration.Appearance(
            tabMinWidth: 140,
            tabMaxWidth: 220,
            splitButtons: []
        )
        let measuredWidth = try XCTUnwrap(
            renderedSelectedPaneTabIndicatorWidth(
                title: "~",
                icon: "terminal.fill",
                appearance: appearance
            )
        )

        XCTAssertGreaterThan(
            measuredWidth,
            40,
            "The regression measurement must prove the selected tab indicator actually rendered"
        )
        XCTAssertLessThanOrEqual(
            measuredWidth,
            80,
            "Short pane-tab visible chrome should stay compact; drag affordance must come from hit testing, not a wider rendered tab"
        )
    }

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
    }

    private func renderedSelectedPaneTabIndicatorWidth(
        title: String,
        icon: String?,
        appearance: BonsplitConfiguration.Appearance
    ) -> CGFloat? {
        let controller = BonsplitController(configuration: BonsplitConfiguration(appearance: appearance))
        guard let pane = controller.internalController.rootNode.allPanes.first else { return nil }
        let tab = TabItem(title: title, icon: icon)
        pane.tabs = [tab]
        pane.selectedTabId = tab.id

        let size = NSSize(width: 180, height: appearance.tabBarHeight)
        let hostingView = NSHostingView(
            rootView: TabBarView(pane: pane, isFocused: true, showSplitButtons: false)
                .environment(controller)
                .environment(controller.internalController)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else { return nil }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        let sampleRect = NSRect(x: 0, y: 0, width: size.width, height: 4)
        return waitForHighSaturationWidth(
            in: hostingView,
            sampleRect: sampleRect
        )
    }

    private func waitForHighSaturationWidth(
        in view: NSView,
        sampleRect: NSRect,
        timeout: TimeInterval = 10.0
    ) -> CGFloat? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let width = highSaturationWidth(in: view, sampleRect: sampleRect) {
                return width
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return highSaturationWidth(in: view, sampleRect: sampleRect)
    }

    private func highSaturationWidth(in view: NSView, sampleRect: NSRect) -> CGFloat? {
        let integralBounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: integralBounds) else { return nil }
        bitmap.size = integralBounds.size
        view.cacheDisplay(in: integralBounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, integralBounds.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, integralBounds.height)
        let minX = max(0, Int(floor(sampleRect.minX * scaleX)))
        let maxX = min(bitmap.pixelsWide, Int(ceil(sampleRect.maxX * scaleX)))
        let minY = max(0, Int(floor(sampleRect.minY * scaleY)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil(sampleRect.maxY * scaleY)))

        var activeColumnCount = 0
        for x in minX..<maxX {
            var hasIndicatorPixel = false
            for y in minY..<maxY {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.05 else { continue }
                let alpha = min(max(rgb.alphaComponent, 0), 1)
                let red = rgb.redComponent * alpha
                let green = rgb.greenComponent * alpha
                let blue = rgb.blueComponent * alpha
                let high = max(red, green, blue)
                guard high > 0.01 else { continue }
                let low = min(red, green, blue)
                if (high - low) / high > 0.4 {
                    hasIndicatorPixel = true
                    break
                }
            }
            if hasIndicatorPixel {
                activeColumnCount += 1
            }
        }
        guard activeColumnCount > 0 else { return nil }
        return CGFloat(activeColumnCount) / scaleX
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

    func testHostViewTrustsRegisteredTabStripRegionAboveHostedTerminal() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected window content container")
            return
        }

        let tabStripHeight: CGFloat = 44
        let tabStrip = NSView(
            frame: NSRect(
                x: 0,
                y: contentView.bounds.maxY - tabStripHeight,
                width: contentView.bounds.width,
                height: tabStripHeight
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)
        BonsplitTabBarHitRegionRegistry.register(tabStrip)
        defer { BonsplitTabBarHitRegionRegistry.unregister(tabStrip) }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowTerminalHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let hostedTerminal = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedTerminal)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let titlebarBandHeight = max(28, min(72, window.frame.height - window.contentLayoutRect.height))
        let pointInContent = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY - titlebarBandHeight - 8
        )
        let pointInWindow = contentView.convert(pointInContent, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = makeMouseEvent(type: .leftMouseDown, at: pointInWindow, window: window)

        XCTAssertNil(
            host.performHitTest(at: pointInHost, currentEvent: event),
            "Terminal portal should defer to the registered minimal tab strip even when a hosted terminal view overlaps it"
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
        XCTAssertFalse(BonsplitTabBarPassThrough.isPassThroughPointerEvent(.scrollWheel))
    }

    func testBrowserPortalDragRoutingKeepsAppKitEventsOutOfPassThrough() {
        let context = WindowInputRoutingContext(eventType: .appKitDefined)

        XCTAssertTrue(context.allowsTabBarPassThroughHitTesting)
        XCTAssertTrue(context.allowsPaneDropHitTesting)
        XCTAssertFalse(context.allowsBrowserPortalDragRouting)
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .appKitDefined
            )
        )
    }

    func testWindowInputRoutingContextRejectsKeyboardForPointerOnlyRoutes() {
        let context = WindowInputRoutingContext(eventType: .keyDown)

        XCTAssertFalse(context.allowsFirstResponderHitTesting)
        XCTAssertFalse(context.allowsPortalPointerHitTesting)
        XCTAssertFalse(context.allowsPaneDropHitTesting)
        XCTAssertFalse(context.allowsFileDropOverlayHitTesting)
        XCTAssertFalse(context.allowsWorkspaceDropOverlayHitTesting)
        XCTAssertFalse(context.allowsBrowserPortalDragRouting)
        XCTAssertFalse(context.allowsTerminalPortalDragRouting)
    }

    func testWindowInputRoutingContextKeepsScrollOutOfTabBarPassThrough() {
        let context = WindowInputRoutingContext(eventType: .scrollWheel)

        XCTAssertTrue(context.allowsPortalPointerHitTesting)
        XCTAssertFalse(context.allowsTabBarPassThroughHitTesting)
    }

    func testWindowInputRoutingContextPreservesNoEventWorkspaceDropHitTesting() {
        let context = WindowInputRoutingContext(eventType: nil)

        XCTAssertTrue(context.allowsWorkspaceDropOverlayHitTesting)
        XCTAssertFalse(context.allowsPaneDropHitTesting)
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

    func testTerminalPaneDropTargetKeyDownSkipsOverlayRoutingPaths() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        dragPasteboard.declareTypes([.fileURL], owner: nil)
        defer { dragPasteboard.clearContents() }

        let contentView = try XCTUnwrap(window.contentView)
        let tabStrip = CountingTabBarBackgroundNSView(
            frame: NSRect(x: 0, y: contentView.bounds.maxY - 44, width: contentView.bounds.width, height: 44)
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let dropTarget = TerminalPaneDropTargetView(frame: contentView.bounds)
        dropTarget.autoresizingMask = [.width, .height]
        dropTarget.dropContext = PaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        )
        contentView.addSubview(dropTarget, positioned: .above, relativeTo: tabStrip)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: NSPoint(x: contentView.bounds.midX, y: tabStrip.frame.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        let hit = dropTarget.performHitTest(
            at: NSPoint(x: contentView.bounds.midX, y: tabStrip.frame.midY),
            currentEvent: event
        )
        XCTAssertNil(hit)
        XCTAssertEqual(
            tabStrip.pointConversionCount,
            0,
            "Keyboard events should not scan tab-strip or drag-overlay hit-test paths."
        )
    }

    func testTerminalPaneDropTargetCapturesFinderFilesButIgnoresBrowserPayloads() {
        XCTAssertTrue(
            TerminalPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertTrue(
            TerminalPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseUp
            )
        )
        XCTAssertTrue(
            TerminalPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL, .png],
                eventType: .leftMouseDragged
            )
        )
        XCTAssertTrue(
            TerminalPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.filePreviewTransferType, DragOverlayRoutingPolicy.bonsplitTabTransferType, .fileURL],
                eventType: .leftMouseUp
            )
        )

        let externalPayloads: [[NSPasteboard.PasteboardType]] = [
            [.URL],
            [.png],
            [.tiff],
            [.html],
            [.string],
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

    func testPaneDropRoutingMapsFileDropsToSharedBonsplitDestinations() {
        let paneId = PaneID()

        if case let .insert(targetPane, targetIndex) = PaneDropRouting.filePreviewDestination(
            targetPane: paneId,
            zone: .center
        ) {
            XCTAssertEqual(targetPane, paneId)
            XCTAssertNil(targetIndex)
        } else {
            XCTFail("Center drops should insert into the hovered pane")
        }

        if case let .split(targetPane, orientation, insertFirst) = PaneDropRouting.filePreviewDestination(
            targetPane: paneId,
            zone: .left
        ) {
            XCTAssertEqual(targetPane, paneId)
            XCTAssertEqual(orientation, .horizontal)
            XCTAssertTrue(insertFirst)
        } else {
            XCTFail("Left drops should use Bonsplit horizontal split routing")
        }

        if case let .split(targetPane, orientation, insertFirst) = PaneDropRouting.filePreviewDestination(
            targetPane: paneId,
            zone: .bottom
        ) {
            XCTAssertEqual(targetPane, paneId)
            XCTAssertEqual(orientation, .vertical)
            XCTAssertFalse(insertFirst)
        } else {
            XCTFail("Bottom drops should use Bonsplit vertical split routing")
        }
    }

    func testPaneDropRoutingKeepsStandaloneOverlayFrames() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertEqual(
            PaneDropRouting.overlayFrame(for: .center, in: bounds),
            CGRect(x: 10, y: 10, width: 180, height: 80)
        )
        XCTAssertEqual(
            PaneDropRouting.overlayFrame(for: .left, in: bounds),
            CGRect(x: 8, y: 8, width: 88, height: 84)
        )
        XCTAssertEqual(
            PaneDropRouting.overlayFrame(for: .right, in: bounds),
            CGRect(x: 104, y: 8, width: 88, height: 84)
        )
        XCTAssertEqual(
            PaneDropRouting.overlayFrame(for: .top, in: bounds),
            CGRect(x: 8, y: 54, width: 184, height: 38)
        )
        XCTAssertEqual(
            PaneDropRouting.overlayFrame(for: .bottom, in: bounds),
            CGRect(x: 8, y: 8, width: 184, height: 38)
        )
    }

    func testPaneDropRoutingKeepsCompactInlineOverlayFrames() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertEqual(
            PaneDropRouting.compactOverlayFrame(for: .center, in: bounds),
            CGRect(x: 4, y: 4, width: 192, height: 92)
        )
        XCTAssertEqual(
            PaneDropRouting.compactOverlayFrame(for: .left, in: bounds),
            CGRect(x: 4, y: 4, width: 96, height: 92)
        )
        XCTAssertEqual(
            PaneDropRouting.compactOverlayFrame(for: .right, in: bounds),
            CGRect(x: 100, y: 4, width: 96, height: 92)
        )
        XCTAssertEqual(
            PaneDropRouting.compactOverlayFrame(for: .top, in: bounds),
            CGRect(x: 4, y: 50, width: 192, height: 46)
        )
        XCTAssertEqual(
            PaneDropRouting.compactOverlayFrame(for: .bottom, in: bounds),
            CGRect(x: 4, y: 4, width: 192, height: 46)
        )
    }
}
