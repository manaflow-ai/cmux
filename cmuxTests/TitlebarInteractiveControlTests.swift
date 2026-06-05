import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Titlebar interactive controls")
struct TitlebarInteractiveControlTests {
    /// `titlebarInteractiveControl()` registers the control's region (without
    /// reparenting it). The explicit `WindowDragHandleView` must yield to that
    /// registered region so a click toggles the control instead of starting a
    /// window drag/resize, while empty titlebar chrome stays draggable.
    @Test func dragHandleYieldsToRegisteredTitlebarControl() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        window.contentView = container

        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        // Mirror how `titlebarInteractiveControl()` marks a control: a transparent
        // region view sized to the control that registers itself with the registry.
        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 12, y: 14, width: 24, height: 24)
        )
        container.addSubview(region)

        let buttonPoint = NSPoint(x: region.frame.midX, y: region.frame.midY)
        #expect(
            !windowDragHandleShouldCaptureHit(
                dragHandle.convert(buttonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "A registered titlebar control region must block explicit titlebar dragging so its click reaches the control."
        )

        #expect(
            windowDragHandleShouldCaptureHit(
                NSPoint(x: 220, y: 24),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar chrome outside any interactive control should remain draggable."
        )
    }

    /// A registered titlebar control region must read as a control hit so the
    /// synthetic titlebar double-click (zoom/minimize) is suppressed over it,
    /// while empty chrome still triggers the standard double-click action.
    @Test func registeredTitlebarControlSuppressesSyntheticDoubleClick() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        window.contentView = container

        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 12, y: 14, width: 24, height: 24)
        )
        container.addSubview(region)

        let insideControl = NSPoint(x: region.frame.midX, y: region.frame.midY)
        #expect(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: insideControl),
            "A double-click on a titlebarInteractiveControl must register as a control hit so the synthetic titlebar double-click (zoom/minimize) is suppressed."
        )

        let emptyTitlebar = NSPoint(x: 220, y: 24)
        #expect(
            !isMinimalModeTitlebarControlHit(window: window, locationInWindow: emptyTitlebar),
            "Empty titlebar chrome away from any interactive control must still trigger the standard titlebar double-click action."
        )
    }

    /// The region marker must never intercept clicks itself; it is a registry
    /// marker only, so the control it backs keeps receiving its own mouse-downs.
    @Test func regionMarkerIsTransparentToHitTesting() {
        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )
        #expect(
            region.hitTest(NSPoint(x: 12, y: 12)) == nil,
            "The interactive-control region marker must be transparent to hit-testing so the hosted control receives clicks."
        )
        #expect(
            !region.mouseDownCanMoveWindow,
            "The region marker must not let a stray mouse-down move the window."
        )
    }
}
