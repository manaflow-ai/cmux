import XCTest
import Foundation
import AppKit
import CoreGraphics

/// Tests for the niri canvas demo's tab bar drag-to-reorder functionality.
///
/// The niri canvas opens via Cmd+Ctrl+N and creates terminal panels with a
/// NiriTabBarView at the top of each panel. This test exercises tab creation
/// (Cmd+T) and drag-to-reorder within a single panel's tab bar.
final class NiriCanvasUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 20.0
    private let surfaceTimeout: TimeInterval = 15.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Launch the app, open the niri canvas (Cmd+Ctrl+N), wait for terminal
    /// surfaces to appear, create extra tabs with Cmd+T, then attempt to
    /// drag-reorder tabs in the first panel's tab bar.
    func testNiriCanvasTabBarDragReorder() {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch in foreground. state=\(app.state.rawValue)"
        )

        // Wait briefly for the initial window to settle
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // Open the niri canvas with Cmd+Ctrl+N
        app.typeKey("n", modifierFlags: [.command, .control])
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        // Look for the "Terminal Canvas" window
        let canvasWindow = app.windows["Terminal Canvas"]
        XCTAssertTrue(
            canvasWindow.waitForExistence(timeout: 5.0),
            "Expected 'Terminal Canvas' window to appear after Cmd+Ctrl+N. windows=\(app.windows.debugDescription)"
        )

        // Wait for terminal surfaces to initialize
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))

        // The canvas starts with 3 panels, each with 1 tab. Focus is on the first panel.
        // Create 2 more tabs in the focused panel with Cmd+T
        app.typeKey("t", modifierFlags: [.command])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.typeKey("t", modifierFlags: [.command])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // Now the focused panel should have 3 tabs.
        // The tab bar is at the top of each panel container.
        // Since NiriTabBarView is a raw NSView (not accessibility-enabled), we need
        // to use coordinate-based interaction to test drag.

        let windowFrame = canvasWindow.frame

        // The tab bar sits at the top of the first panel. In the layout:
        //   - peekWidth = 60, panelGap = 12
        //   - Panel starts at x = peekWidth + panelGap = 72 from the window's content area
        //   - Tab bar height = 30, positioned at y = ph - tabH (top of panel in bottom-up coords)
        //   - Panel height ph = max(300, viewH - 20)
        //
        // In screen coordinates (Accessibility uses top-left origin):
        //   - Tab bar Y is near the top of the window content area
        //   - Tab bar X starts at ~72pt from the left edge of the window

        // Target the tab bar area: roughly 100pt from the left of the window, 20pt from the top
        // (accounting for titlebar). We'll click and drag horizontally within this region.

        // First, let's just try clicking in the tab bar area to see if it responds
        let tabBarY = windowFrame.minY + 40  // near top of window (below titlebar)
        let tabBarStartX = windowFrame.minX + 100  // first panel's tab bar region

        // Click on what should be the second tab (roughly 1 tab-width to the right)
        let tab1Center = CGPoint(x: tabBarStartX + 50, y: tabBarY)
        let tab2Center = CGPoint(x: tabBarStartX + 150, y: tabBarY)
        let tab3Center = CGPoint(x: tabBarStartX + 250, y: tabBarY)

        // Try clicking tab 2 to select it
        let coordTab2 = canvasWindow.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: tab2Center.x - windowFrame.minX, dy: tab2Center.y - windowFrame.minY)
        )
        coordTab2.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Try clicking tab 3 to select it
        let coordTab3 = canvasWindow.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: tab3Center.x - windowFrame.minX, dy: tab3Center.y - windowFrame.minY)
        )
        coordTab3.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Now attempt a drag from tab 3's position to tab 1's position
        // This should trigger the NSPanGestureRecognizer on NiriTabBarView
        guard let dragSession = beginMouseDrag(
            fromAccessibilityPoint: tab3Center,
            holdDuration: 0.20
        ) else {
            XCTFail("Expected raw mouse drag session to start for niri tab bar drag")
            return
        }

        continueMouseDrag(
            dragSession,
            toAccessibilityPoint: tab1Center,
            steps: 20,
            dragDuration: 0.40
        )

        // Hold briefly at the destination
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        endMouseDrag(dragSession, atAccessibilityPoint: tab1Center)

        // Wait for any reorder animation
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Since NiriTabBarView doesn't expose accessibility elements for individual tabs,
        // we can't directly verify the reorder through the accessibility hierarchy.
        // This test primarily verifies that:
        // 1. The canvas opens successfully
        // 2. Cmd+T creates tabs
        // 3. Click and drag in the tab bar area doesn't crash
        // 4. The gesture recognizer path is exercised
        //
        // A more robust test would require adding accessibility identifiers to the
        // NiriTabBarView tabs or using a data file exchange mechanism like the
        // BonsplitTabDragUITests use.

        // Verify the window is still alive and not crashed
        XCTAssertTrue(canvasWindow.exists, "Expected canvas window to still exist after tab drag attempt")
    }

    // MARK: - Helpers

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private struct RawMouseDragSession {
        let source: CGEventSource
    }

    private func beginMouseDrag(
        fromAccessibilityPoint start: CGPoint,
        holdDuration: TimeInterval = 0.15
    ) -> RawMouseDragSession? {
        let source = CGEventSource(stateID: .hidSystemState)
        XCTAssertNotNil(source, "Expected CGEventSource for raw mouse drag")
        guard let source else { return nil }

        let quartzStart = quartzPoint(fromAccessibilityPoint: start)

        postMouseEvent(type: .mouseMoved, at: quartzStart, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        postMouseEvent(type: .leftMouseDown, at: quartzStart, source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(holdDuration))
        return RawMouseDragSession(source: source)
    }

    private func continueMouseDrag(
        _ session: RawMouseDragSession,
        toAccessibilityPoint end: CGPoint,
        steps: Int = 20,
        dragDuration: TimeInterval = 0.30
    ) {
        let currentLocation = NSEvent.mouseLocation
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        let clampedSteps = max(2, steps)
        for step in 1...clampedSteps {
            let progress = CGFloat(step) / CGFloat(clampedSteps)
            let point = CGPoint(
                x: currentLocation.x + ((quartzEnd.x - currentLocation.x) * progress),
                y: currentLocation.y + ((quartzEnd.y - currentLocation.y) * progress)
            )
            postMouseEvent(type: .leftMouseDragged, at: point, source: session.source)
            RunLoop.current.run(until: Date().addingTimeInterval(dragDuration / Double(clampedSteps)))
        }
    }

    private func endMouseDrag(
        _ session: RawMouseDragSession,
        atAccessibilityPoint end: CGPoint
    ) {
        let quartzEnd = quartzPoint(fromAccessibilityPoint: end)
        postMouseEvent(type: .leftMouseUp, at: quartzEnd, source: session.source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func postMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        source: CGEventSource
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            XCTFail("Expected CGEvent for mouse type \(type.rawValue) at \(point)")
            return
        }

        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func quartzPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
        XCTAssertFalse(desktopBounds.isNull, "Expected at least one screen when converting raw mouse coordinates")
        guard !desktopBounds.isNull else { return point }
        return CGPoint(x: point.x, y: desktopBounds.maxY - point.y)
    }
}
