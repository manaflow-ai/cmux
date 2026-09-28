import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Hidden workspace title interactions", .serialized)
struct WorkspaceTitlebarInteractionTests {
    @Test(arguments: [CGFloat(0), CGFloat(120)])
    func dragHitTestUsesSuperviewCoordinates(offset: CGFloat) throws {
        let window = makeWindow()
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 20, y: 30, width: 300, height: 140))
        try #require(window.contentView).addSubview(container)
        let dragView = WorkspaceTitlebarDragView(frame: NSRect(x: offset, y: 0, width: 80, height: 28))
        container.addSubview(dragView)
        let local = NSPoint(x: 40, y: 14)
        let down = try event(window: window, point: dragView.convert(local, to: nil))
        let previousEvent = NSApp.currentEvent
        defer {
            if let previousEvent {
                NSApp.postEvent(previousEvent, atStart: true)
                _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
            }
        }
        // AppKit exposes its last dequeued event during view hit testing.
        NSApp.postEvent(down, atStart: true)
        let dequeued = try #require(NSApp.nextEvent(
            matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true
        ))
        try #require(NSApp.currentEvent === dequeued)
        #expect(dragView.hitTest(dragView.convert(local, to: container)) === dragView)
        #expect(dragView.hitTest(NSPoint(x: offset + 90, y: 14)) == nil)
    }

    @Test
    func standardPaneDoubleClicksBypassMinimalModeWindowActions() throws {
        let suite = "WorkspaceTitlebarInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let window = makeWindow()
        defer { window.close() }
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(UUID().uuidString)")
        let bounds = try #require(window.contentView).bounds
        let down = try event(window: window, point: NSPoint(x: 200, y: bounds.maxY - 10), clickCount: 2)
        #expect(!shouldHandleMinimalModeWindowTitlebarDoubleClick(window: window, event: down, defaults: defaults))
        #expect(!isMinimalModeWindowTitlebarClickCandidate(window: window, event: down, defaults: defaults))
        defaults.set("minimal", forKey: WorkspacePresentationModeSettings.modeKey)
        #expect(shouldHandleMinimalModeWindowTitlebarDoubleClick(window: window, event: down, defaults: defaults))
    }

    @Test
    func reservedAreaDragsImmovableWindowAndRestoresItsPolicy() throws {
        let window = makeWindow()
        defer { window.close() }
        window.isMovable = false
        let dragView = WorkspaceTitlebarDragView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        try #require(window.contentView).addSubview(dragView)
        let local = NSPoint(x: 40, y: 14)
        let down = try event(window: window, point: dragView.convert(local, to: nil))
        #expect(dragView.capturesMouseDown(at: local, event: down))
        dragView.mouseDown(with: down)
        #expect(window.dragCount == 1)
        #expect(window.wasMovableDuringDrag)
        #expect(!window.isMovable)
        let doubleClick = try event(window: window, point: down.locationInWindow, clickCount: 2)
        #expect(!dragView.capturesMouseDown(at: local, event: doubleClick))
        let scroll = try event(window: window, point: down.locationInWindow, type: .rightMouseDown)
        #expect(!dragView.capturesMouseDown(at: local, event: scroll))
    }

    @Test
    func dragSurfaceYieldsToActualPaneTabHitRegions() async throws {
        let fixture = try WorkspaceTitlebarLayoutFixture(tabCount: 2, split: true)
        defer { fixture.close() }
        fixture.defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        await fixture.layout()
        let content = try #require(fixture.window.contentView)
        let windowPoints = stride(from: CGFloat(10), through: 800, by: 10).map {
            content.convert(NSPoint(x: $0, y: 14), to: nil)
        }
        let tabPoint = try #require(windowPoints.first {
            BonsplitTabItemHitRegionRegistry.containsWindowPoint($0, in: fixture.window)
        })
        // Deliberately overlap a tab as can happen for one layout pass while
        // the reserved inset updates. Live tab geometry must still win.
        let dragView = WorkspaceTitlebarDragView(frame: content.bounds)
        content.addSubview(dragView)
        defer { dragView.removeFromSuperview() }
        let down = try event(window: fixture.window, point: tabPoint)
        #expect(!dragView.capturesMouseDown(at: dragView.convert(tabPoint, from: nil), event: down))
    }

    @Test
    func dragSurfaceYieldsToNativeWindowButtons() throws {
        let window = makeWindow(style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        defer { window.close() }
        let content = try #require(window.contentView)
        let view = WorkspaceTitlebarDragView(frame: content.bounds)
        content.addSubview(view)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let down = try event(window: window, point: point)
            #expect(!view.capturesMouseDown(at: view.convert(point, from: nil), event: down))
        }
    }

    private func makeWindow(style: NSWindow.StyleMask = [.borderless]) -> WorkspaceTitlebarDragTestWindow {
        let window = WorkspaceTitlebarDragTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: style, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(
        window: NSWindow, point: NSPoint, type: NSEvent.EventType = .leftMouseDown, clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: clickCount, pressure: 1
        ))
    }
}
