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
final class WindowBrowserSlotViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func testDropZoneOverlayStaysAboveContentWithoutBlockingHits() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)
        let child = CapturingView(frame: slot.bounds)
        child.autoresizingMask = [.width, .height]
        slot.addSubview(child)

        slot.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            $0 !== slot && String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertTrue(container.subviews.last === overlay, "Overlay should stay above the hosted web view")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 96, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 92, accuracy: 0.5)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 120, y: 50)), "Overlay should never intercept pointer hits")
        XCTAssertTrue(slot.hitTest(NSPoint(x: 120, y: 50)) === child)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Clearing the drop zone should hide the overlay")
    }

    func testTopDropZoneOverlayUsesFullBrowserContentHeight() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)

        slot.setPaneTopChromeHeight(20)
        slot.setDropZoneOverlay(zone: .top)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 60, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 192, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 56, accuracy: 0.5)
        XCTAssertGreaterThan(overlay.frame.maxY, slot.frame.maxY)
        XCTAssertEqual(slot.layer?.masksToBounds, true)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertEqual(slot.layer?.masksToBounds, true)
    }
}


