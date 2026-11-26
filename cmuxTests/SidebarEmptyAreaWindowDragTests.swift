import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar empty-area window drag")
struct SidebarEmptyAreaWindowDragTests {
    private final class RecordingDragWindow: NSWindow {
        var performDragCallCount = 0
        var isMovableDuringPerformDrag: Bool?

        /// Records drag invocation and the movability state visible to AppKit.
        override func performDrag(with event: NSEvent) {
            performDragCallCount += 1
            isMovableDuringPerformDrag = isMovable
        }
    }

    /// Creates a synthetic pointer event associated with the supplied window.
    private static func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Expected to create sidebar empty-area mouse event")
        }
        return event
    }

    /// Creates a window whose explicit drag calls can be inspected.
    private static func makeWindow() -> RecordingDragWindow {
        _ = NSApplication.shared
        let window = RecordingDragWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        return window
    }

    /// Feeds a fixed script in place of the real tracking pump so the loop is
    /// exercised without a run loop.
    private static func pump(
        _ events: [SidebarEmptyAreaWindowDragTrackingEvent]
    ) -> @MainActor (NSWindow) -> SidebarEmptyAreaWindowDragTrackingEvent? {
        var remaining = events
        return { _ in remaining.isEmpty ? nil : remaining.removeFirst() }
    }

    /// Verifies that AppKit replays the same mouse-up payload after queueing it.
    private static func expectReplayedMouseUp(in window: NSWindow, matches original: NSEvent) throws {
        let replayed = try #require(
            window.nextEvent(
                matching: [.leftMouseUp],
                until: .now,
                inMode: .eventTracking,
                dequeue: true
            )
        )

        // postEvent may reconstitute the NSEvent, so compare the event identity
        // fields instead of requiring the dequeued object to be pointer-identical.
        #expect(replayed.type == .leftMouseUp)
        #expect(replayed.windowNumber == original.windowNumber)
        #expect(replayed.eventNumber == original.eventNumber)
        // AppKit can round the event timestamp while rebuilding the queued
        // NSEvent, so compare at microsecond precision instead of bit-for-bit.
        #expect(abs(replayed.timestamp - original.timestamp) < 0.000_001)
        // AppKit may reconstruct the queued point relative to the window's
        // current screen origin; that display geometry is not part of replay
        // identity and varies across macOS versions and window placement.
        #expect(replayed.clickCount == original.clickCount)
        #expect(replayed.modifierFlags == original.modifierFlags)
    }

    /// A threshold-crossing press invokes AppKit exactly once and restores window state.
    @Test func dragPastThresholdMovesWindowAndRestoresMovability() throws {
        let window = Self.makeWindow()
        defer { window.orderOut(nil) }
        window.isMovable = false
        let view = try #require(window.contentView)

        let down = Self.makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 40, y: 80), window: window)
        let dragged = Self.makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 60, y: 100), window: window)

        let controller = SidebarEmptyAreaWindowDragController(
            nextEvent: Self.pump([.dragged(location: dragged.locationInWindow)])
        )
        let outcome = controller.perform(with: down, in: view)

        #expect(outcome == .dragged)
        #expect(window.performDragCallCount == 1)
        #expect(window.isMovableDuringPerformDrag == true)
        #expect(!window.isMovable)
    }

    /// A stationary click remains unhandled and replays its terminating mouse-up.
    @Test func pressWithoutMovementIsNotADrag() throws {
        let window = Self.makeWindow()
        defer { window.orderOut(nil) }
        let view = try #require(window.contentView)

        let down = Self.makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 40, y: 80), window: window)
        let up = Self.makeMouseEvent(type: .leftMouseUp, location: NSPoint(x: 40, y: 80), window: window)

        let controller = SidebarEmptyAreaWindowDragController(nextEvent: Self.pump([.mouseUp(up)]))
        let outcome = controller.perform(with: down, in: view)

        #expect(outcome == .passThrough)
        #expect(window.performDragCallCount == 0)
        try Self.expectReplayedMouseUp(in: window, matches: up)
    }

    /// Sub-threshold pointer jitter remains a click and replays its mouse-up.
    @Test func movementBelowThresholdStaysAClick() throws {
        let window = Self.makeWindow()
        defer { window.orderOut(nil) }
        let view = try #require(window.contentView)

        let down = Self.makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 40, y: 80), window: window)
        let jitter = Self.makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 41, y: 81), window: window)
        let up = Self.makeMouseEvent(type: .leftMouseUp, location: NSPoint(x: 41, y: 81), window: window)

        let controller = SidebarEmptyAreaWindowDragController(
            nextEvent: Self.pump([
                .dragged(location: jitter.locationInWindow),
                .mouseUp(up),
            ])
        )
        let outcome = controller.perform(with: down, in: view)

        #expect(outcome == .passThrough)
        #expect(window.performDragCallCount == 0)
        try Self.expectReplayedMouseUp(in: window, matches: up)
    }

    /// A detached view declines the drag without consulting the injected event source.
    @Test func viewWithoutWindowIsNotADrag() {
        _ = NSApplication.shared
        let window = Self.makeWindow()
        defer { window.orderOut(nil) }
        let detached = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

        let down = Self.makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 4, y: 4), window: window)

        var nextEventCallCount = 0
        let controller = SidebarEmptyAreaWindowDragController(
            nextEvent: { _ in
                nextEventCallCount += 1
                return nil
            }
        )
        let outcome = controller.perform(with: down, in: detached)

        #expect(outcome == .passThrough)
        #expect(window.performDragCallCount == 0)
        #expect(nextEventCallCount == 0)
    }

    /// A system cancellation consumes the sequence without starting a drag.
    @Test func cancelledSequenceDoesNotFallThrough() throws {
        let window = Self.makeWindow()
        defer { window.orderOut(nil) }
        let view = try #require(window.contentView)

        let down = Self.makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 40, y: 80), window: window)
        let controller = SidebarEmptyAreaWindowDragController(nextEvent: Self.pump([.cancelled]))

        let outcome = controller.perform(with: down, in: view)

        #expect(outcome == .cancelled)
        #expect(window.performDragCallCount == 0)
    }

    /// Both native empty-area owners receive the initial press in an inactive window.
    @Test func nativeEmptyAreaOwnersAcceptFirstMouse() {
        _ = NSApplication.shared

        let clipView = SidebarWorkspaceTableClipView()
        let tableView = SidebarWorkspaceTableViewImpl()

        #expect(clipView.acceptsFirstMouse(for: nil))
        // NSTableView already accepts click-through via NSControl; retain that
        // policy for rows while the clip view opts in for empty viewport space.
        #expect(tableView.acceptsFirstMouse(for: nil))
    }
}
