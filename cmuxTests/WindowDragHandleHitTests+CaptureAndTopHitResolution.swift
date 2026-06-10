import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Drag handle capture and top-hit resolution
extension WindowDragHandleHitTests {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class BlockingTopHitContainerView: NSView {
        var hitCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            hitCount += 1
            return bounds.contains(point) ? self : nil
        }
    }
    private final class PassThroughProbeView: NSView {
        var onHitTest: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            onHitTest?()
            return nil
        }
    }
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    private final class MutatingSiblingView: NSView {
        weak var container: NSView?
        private var didMutate = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard !didMutate, let container else { return nil }
            didMutate = true
            let transient = NSView(frame: .zero)
            container.addSubview(transient)
            transient.removeFromSuperview()
            return nil
        }
    }

    private final class ReentrantDragHandleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let shouldCapture = windowDragHandleShouldCaptureHit(point, in: self, eventType: .leftMouseDown, eventWindow: self.window)
            return shouldCapture ? self : nil
        }
    }

    /// A sibling view whose hitTest re-enters windowDragHandleShouldCaptureHit,
    /// simulating the crash path where sibling.hitTest triggers a SwiftUI layout
    /// pass that calls back into the drag handle's hit resolution.
    private final class ReentrantSiblingView: NSView {
        weak var dragHandle: NSView?
        var reenteredResult: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let dragHandle else { return nil }
            // Simulate the re-entry: during sibling hit test, SwiftUI layout
            // calls windowDragHandleShouldCaptureHit on the drag handle again.
            reenteredResult = windowDragHandleShouldCaptureHit(
                point, in: dragHandle, eventType: .leftMouseDown, eventWindow: dragHandle.window
            )
            return nil
        }
    }

    func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Empty titlebar space should drag the window"
        )
    }

    func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleSkipsCaptureForPassivePointerEvents() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let point = NSPoint(x: 180, y: 18)
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .mouseMoved))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .cursorUpdate))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: nil))
        XCTAssertTrue(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleNeverCapturesRegisteredBonsplitPaneTab() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 82, width: 220, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        container.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let tabWindowPoint = tabRegion.convert(NSPoint(x: 48, y: 15), to: nil)
        let tabDragHandlePoint = dragHandle.convert(tabWindowPoint, from: nil)
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                tabDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "A visible pane tab must own its mouse-down; the titlebar drag handle must not turn it into a window drag"
        )

        let emptyWindowPoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let emptyDragHandlePoint = dragHandle.convert(emptyWindowPoint, from: nil)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                emptyDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty tab-strip chrome should remain available for app-window dragging"
        )
    }

    func testTabBarEmptyChromeOverlayNeverCapturesRegisteredBonsplitPaneTabWhenFrameCacheIsEmpty() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragZone = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 72, width: 320, height: 30))
        dragZone.hitRegion = .trailingEmptyChrome(tabFrames: [], reservedTrailingWidth: 48)
        dragZone.hitTestEventTypeOverride = .leftMouseDown
        contentView.addSubview(dragZone)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 10, y: 72, width: 90, height: 30))
        tabRegion.tabFrames = [tabRegion.bounds]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        XCTAssertNil(
            dragZone.hitTest(NSPoint(x: 40, y: 15)),
            "The empty-chrome overlay must not turn a pane-tab mouse-down into an app-window drag while tab frames are still populating"
        )
        XCTAssertIdentical(
            dragZone.hitTest(NSPoint(x: 140, y: 15)),
            dragZone,
            "Empty tab-strip chrome after the registered tab should still be available for app-window dragging"
        )
    }

    func testDragHandleSkipsForeignLeftMouseDownDuringLaunch() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { foreignWindow.orderOut(nil) }

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: nil
            ),
            "Launch activation events without a matching window should not trigger drag-handle hierarchy walk"
        )

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: foreignWindow
            ),
            "Left mouse-down events for a different window should be treated as passive"
        )

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Left mouse-down events for this window should still capture empty titlebar space"
        )
    }

    func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }

    func testTopHitResolutionStateIsScopedPerWindow() {
        let point = NSPoint(x: 100, y: 18)

        let outerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { outerWindow.orderOut(nil) }
        guard let outerContentView = outerWindow.contentView else {
            XCTFail("Expected outer content view")
            return
        }
        let outerContainer = NSView(frame: outerContentView.bounds)
        outerContainer.autoresizingMask = [.width, .height]
        outerContentView.addSubview(outerContainer)
        let outerDragHandle = NSView(frame: outerContainer.bounds)
        outerDragHandle.autoresizingMask = [.width, .height]
        outerContainer.addSubview(outerDragHandle)

        let nestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { nestedWindow.orderOut(nil) }
        guard let nestedContentView = nestedWindow.contentView else {
            XCTFail("Expected nested content view")
            return
        }
        let nestedContainer = NSView(frame: nestedContentView.bounds)
        nestedContainer.autoresizingMask = [.width, .height]
        nestedContentView.addSubview(nestedContainer)
        let nestedDragHandle = NSView(frame: nestedContainer.bounds)
        nestedDragHandle.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedDragHandle)
        let nestedBlockingOverlay = BlockingTopHitContainerView(frame: nestedContainer.bounds)
        nestedBlockingOverlay.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedBlockingOverlay)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow),
            "Nested window drag handle should be blocked by top-hit titlebar container"
        )
        XCTAssertEqual(nestedBlockingOverlay.hitCount, 1)

        var nestedCaptureResult: Bool?
        let probe = PassThroughProbeView(frame: outerContainer.bounds)
        probe.autoresizingMask = [.width, .height]
        probe.onHitTest = {
            nestedCaptureResult = windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow)
        }
        outerContainer.addSubview(probe)

        _ = windowDragHandleShouldCaptureHit(point, in: outerDragHandle, eventType: .leftMouseDown, eventWindow: outerWindow)

        XCTAssertEqual(
            nestedCaptureResult,
            false,
            "Top-hit recursion in one window must not disable top-hit resolution in another window"
        )
        XCTAssertEqual(
            nestedBlockingOverlay.hitCount,
            2,
            "Nested window should resolve its own blocking sibling while another window is resolving hits"
        )
    }

    func testDragHandleRemainsStableWhenSiblingMutatesSubviewsDuringHitTest() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let mutatingSibling = MutatingSiblingView(frame: container.bounds)
        mutatingSibling.container = container
        container.addSubview(mutatingSibling)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Subview mutations during hit testing should not crash or break drag-handle capture"
        )
    }

    func testDragHandleSiblingHitTestReentrancyDoesNotCrash() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let reentrantSibling = ReentrantSiblingView(frame: container.bounds)
        reentrantSibling.dragHandle = dragHandle
        container.addSubview(reentrantSibling)

        // The outer call enters the sibling walk, which calls
        // reentrantSibling.hitTest(), which re-enters
        // windowDragHandleShouldCaptureHit. Without the re-entrancy guard
        // this would trigger a Swift exclusive-access violation (SIGABRT).
        let outerResult = windowDragHandleShouldCaptureHit(
            NSPoint(x: 110, y: 18), in: dragHandle, eventType: .leftMouseDown
        )
        XCTAssertTrue(outerResult, "Outer call should still capture when sibling returns nil")
        XCTAssertEqual(
            reentrantSibling.reenteredResult, false,
            "Re-entrant call should bail out (return false) instead of crashing"
        )
    }

    func testDragHandleTopHitResolutionSurvivesSameWindowReentrancy() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = ReentrantDragHandleView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown, eventWindow: window),
            "Reentrant same-window top-hit resolution should not trigger exclusivity crashes"
        )
    }

}
