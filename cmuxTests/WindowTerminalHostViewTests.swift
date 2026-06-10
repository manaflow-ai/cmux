import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class WindowTerminalHostViewTests: XCTestCase {
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

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
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

        XCTAssertTrue(
            hitView === hostedView || hitView.isDescendant(of: hostedView),
            message,
            file: file,
            line: line
        )
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

        // Terminal hitTest is on the typing-latency hot path and gates the
        // tab-strip pass-through behind a real pointer event. Provide one
        // explicitly via the test seam.
        let firstEvent = makeMouseDownEvent(at: firstFixture.pointInWindow, window: firstWindow)
        let secondEvent = makeMouseDownEvent(at: secondFixture.pointInWindow, window: secondWindow)

        XCTAssertNil(
            firstFixture.host.performHitTest(at: firstFixture.pointInHost, currentEvent: firstEvent),
            "Terminal portal should defer to the minimal tab strip in the original window just below the titlebar interaction band"
        )
        XCTAssertNil(
            secondFixture.host.performHitTest(at: secondFixture.pointInHost, currentEvent: secondEvent),
            "Terminal portal should defer to the minimal tab strip in later-created windows just below the titlebar interaction band"
        )
    }

    func testHostViewKeepsTerminalTopRowClickableWhenTabStripRegionOverlapsContent() {
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

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowTerminalHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]

        let terminalFrame = host.bounds.insetBy(dx: 0, dy: 32)
        let hostedView = makeHostedTerminalView(frame: terminalFrame)
        host.addSubview(hostedView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let tabStripOverlap: CGFloat = 2
        let terminalTopInContent = contentView.convert(hostedView.frame, from: host).maxY
        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(
                x: 0,
                y: terminalTopInContent - tabStripOverlap,
                width: contentView.bounds.width,
                height: 44
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = makeMouseDownEvent(at: pointInWindow, window: window)

        assertHitFallsInsideHostedTerminal(
            host.performHitTest(at: pointInHost, currentEvent: event),
            hostedView: hostedView,
            message: "The absolute top row of terminal content should own mouse-down hit-testing even if chrome hit regions overlap it"
        )
    }

    func testHostViewPassesThroughWhenNoTerminalSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHostViewReturnsSubviewWhenSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = CapturingView(frame: NSRect(x: 20, y: 15, width: 40, height: 30))
        host.addSubview(child)

        XCTAssertTrue(host.hitTest(NSPoint(x: 25, y: 20)) === child)
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 100)))
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

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Host view must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        assertHitFallsInsideHostedTerminal(
            host.hitTest(contentPointInHost),
            hostedView: hostedView,
            message: "Terminal content should keep receiving hits after the divider region"
        )
    }

    func testHostViewStopsSidebarPassThroughJustInsideTerminalContent() {
        let terminalSideOverlapWidth: CGFloat = 2
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

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let resizeBandPoint = NSPoint(
            x: dividerPointInHost.x + terminalSideOverlapWidth,
            y: dividerPointInHost.y
        )
        XCTAssertNil(
            host.hitTest(resizeBandPoint),
            "The narrow terminal-side overlap should still pass through to the sidebar resizer"
        )

        let textSelectionPoint = NSPoint(
            x: dividerPointInHost.x + terminalSideOverlapWidth + 1,
            y: dividerPointInHost.y
        )
        assertHitFallsInsideHostedTerminal(
            host.hitTest(textSelectionPoint),
            hostedView: hostedView,
            message: "Once the pointer moves past the reduced terminal-side overlap, terminal content should win hit-testing"
        )
    }
}


