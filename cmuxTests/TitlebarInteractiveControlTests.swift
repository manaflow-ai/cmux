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
    private final class RecordingDragWindow: NSWindow {
        var performDragCallCount = 0
        var isMovableDuringPerformDrag: Bool?

        override func performDrag(with event: NSEvent) {
            performDragCallCount += 1
            isMovableDuringPerformDrag = isMovable
        }
    }

    private static func makeLeftMouseDownEvent(location: NSPoint, window: NSWindow, clickCount: Int = 1) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1.0
        ) else {
            fatalError("Expected to create titlebar accessory mouse-down event")
        }
        return event
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

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
            minimalModeTitlebarDoubleClickShouldDefer(window: window, locationInWindow: insideControl),
            "A double-click on a titlebarInteractiveControl must register as a control hit so the synthetic titlebar double-click (zoom/minimize) is suppressed."
        )

        let emptyTitlebar = NSPoint(x: 220, y: 24)
        #expect(
            !minimalModeTitlebarDoubleClickShouldDefer(window: window, locationInWindow: emptyTitlebar),
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

    @Test func emptyAccessoryChromeUsesExplicitWindowDragPath() {
        _ = NSApplication.shared

        let window = RecordingDragWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.isMovable = false

        let controller = TitlebarControlsAccessoryViewController(notificationStore: TerminalNotificationStore.shared, settingsRuntime: nil)
        let container = controller.view
        container.frame = NSRect(x: 0, y: 0, width: 180, height: 44)
        window.contentView = container

        let emptyTopRightPoint = NSPoint(x: container.bounds.maxX - 4, y: container.bounds.maxY - 4)
        guard let hitView = container.hitTest(emptyTopRightPoint) else {
            Issue.record("Expected empty titlebar accessory chrome to receive the drag mouse-down")
            return
        }

        #expect(hitView === container)
        #expect(
            !hitView.mouseDownCanMoveWindow,
            "Empty accessory chrome must not rely on native AppKit window dragging because main windows are normally immovable."
        )

        let event = Self.makeLeftMouseDownEvent(location: emptyTopRightPoint, window: window)
        hitView.mouseDown(with: event)

        #expect(window.performDragCallCount == 1)
        #expect(
            window.isMovableDuringPerformDrag == true,
            "Empty accessory chrome should temporarily enable main-window movement before calling performDrag(with:)."
        )
        #expect(
            !window.isMovable,
            "Explicit accessory dragging must restore the main window to its normal immovable state."
        )
    }

    @Test func accessoryControlsRemainNonDraggable() {
        _ = NSApplication.shared

        let controller = TitlebarControlsAccessoryViewController(notificationStore: TerminalNotificationStore.shared, settingsRuntime: nil)
        let container = controller.view
        container.frame = NSRect(x: 0, y: 0, width: 180, height: 44)

        let button = NSButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
        button.isBordered = false
        container.addSubview(button)

        guard let hitView = container.hitTest(NSPoint(x: 20, y: 20)) else {
            Issue.record("Expected the accessory button to receive its own hit")
            return
        }

        #expect(hitView === button)
        #expect(
            !hitView.mouseDownCanMoveWindow,
            "Actual titlebar controls must keep owning clicks instead of starting a window drag."
        )
    }

    @Test func registeredSwiftUIAccessoryControlRegionIsNonDraggable() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = TitlebarAccessoryContainerView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
        window.contentView = container

        let hostingView = NonDraggableHostingView(rootView: Color.clear)
        hostingView.frame = container.bounds
        container.addSubview(hostingView)

        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 130, y: 8, width: 24, height: 24)
        )
        hostingView.addSubview(region)

        guard let hitView = container.hitTest(NSPoint(x: region.frame.midX, y: region.frame.midY)) else {
            Issue.record("Expected registered SwiftUI titlebar control chrome to receive a non-draggable hit")
            return
        }
        #expect(
            !hitView.mouseDownCanMoveWindow,
            "Registered SwiftUI titlebar controls must not degrade into hosting-view drag hits."
        )
    }

    @Test func accessoryButtonRoutingSurvivesLostSwiftUIMarkerRegistration() throws {
        _ = NSApplication.shared

        let window = RecordingDragWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let controller = TitlebarControlsAccessoryViewController(
            notificationStore: TerminalNotificationStore.shared,
            settingsRuntime: nil
        )
        let container = controller.view
        let contentSize = TitlebarControlsLayoutMetrics.contentSize(
            config: TitlebarControlsStyle.stored().config
        )
        container.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = container

        let hostingView = try #require(
            container.subviews.compactMap { $0 as? NonDraggableHostingView<AnyView> }.first
        )
        hostingView.frame = container.bounds
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let markers = Self.descendants(of: hostingView)
            .compactMap { $0 as? TitlebarInteractiveControlRegion.RegisteredView }
            .filter { !$0.bounds.isEmpty }
        let marker = try #require(markers.first)
        let buttonPoint = container.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            from: marker
        )

        markers.forEach(MinimalModeTitlebarControlHitRegionRegistry.unregister)

        let buttonHit = try #require(container.hitTest(buttonPoint))
        #expect(
            buttonHit !== container,
            "A visible titlebar button must keep the mouse-down instead of degrading into the accessory's window-drag path."
        )

        let trailingPoint = NSPoint(x: hostingView.bounds.maxX - 1, y: hostingView.bounds.midY)
        let markerFrames = markers.map { hostingView.convert($0.bounds, from: $0) }
        #expect(!markerFrames.contains { $0.contains(trailingPoint) })
        #expect(
            container.hitTest(container.convert(trailingPoint, from: hostingView)) === container,
            "Empty trailing titlebar chrome must remain on the explicit window-drag path."
        )
    }
}
