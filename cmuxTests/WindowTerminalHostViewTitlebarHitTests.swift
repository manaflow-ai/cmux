import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Window terminal host titlebar hit testing")
struct WindowTerminalHostViewTitlebarHitTests {
    @Test func hostViewKeepsTerminalTopRowClickableInsideTitlebarBand() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected window content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = try makeMouseDownEvent(at: pointInWindow, window: window)

        try #require(
            pointInWindow.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The regression point must exercise the fixed-height titlebar pass-through band"
        )
        assertHitFallsInsideHostedTerminal(
            host.performHitTest(at: pointInHost, currentEvent: event),
            hostedView: hostedView,
            message: "Terminal content inside the titlebar band should keep receiving top-row mouse-downs"
        )
    }

    @Test func titlebarDoubleClickMonitorDefersToTerminalTopRowInsideTitlebarBand() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected window content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        let wrapperView = NSView(frame: host.bounds)
        wrapperView.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        wrapperView.addSubview(hostedView)
        host.addSubview(wrapperView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)

        try #require(
            pointInWindow.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The regression point must exercise the fixed-height titlebar pass-through band"
        )
        #expect(
            minimalModeTitlebarDoubleClickShouldDefer(window: window, locationInWindow: pointInWindow),
            "Synthetic titlebar double-click handling must yield to hosted terminal content in the top row"
        )
    }

    @Test func windowDecorationsDoubleClickHandlerDefersToTerminalTopRowInsideTitlebarBand() throws {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            if let savedMode {
                defaults.set(savedMode, forKey: WorkspacePresentationModeSettings.modeKey)
            } else {
                defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected window content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)
        let event = try makeMouseDownEvent(at: pointInWindow, window: window, clickCount: 2)

        try #require(
            pointInWindow.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The regression point must exercise the fixed-height titlebar pass-through band"
        )
        #expect(
            !WindowDecorationsController().handleMinimalModeTitlebarDoubleClickMouseDown(event: event),
            "The app-level titlebar double-click handler must not consume terminal top-row double-clicks"
        )
    }

    @Test func hostViewPassesThroughRegisteredTitlebarControlsAboveTerminal() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected window content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let host = WindowTerminalHostView(frame: container.convert(contentView.bounds, from: contentView))
        host.addSubview(makeHostedTerminalView(frame: host.bounds))
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let region = TitlebarInteractiveControlRegion.RegisteredView(
            frame: NSRect(x: 24, y: contentView.bounds.maxY - 24, width: 18, height: 18)
        )
        contentView.addSubview(region)

        let pointInWindow = contentView.convert(NSPoint(x: region.frame.midX, y: region.frame.midY), to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = try makeMouseDownEvent(at: pointInWindow, window: window)

        try #require(
            pointInWindow.y >= BonsplitTabBarPassThrough.titlebarInteractionBandMinY(in: window),
            "The control point must sit inside the fixed titlebar interaction band"
        )
        #expect(
            host.performHitTest(at: pointInHost, currentEvent: event) == nil,
            "Registered titlebar controls must keep receiving clicks even when terminal content underlaps them"
        )
    }

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
    }

    private func makeMouseDownEvent(
        at locationInWindow: NSPoint,
        window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        ), "Failed to create leftMouseDown event")
    }

    private func assertHitFallsInsideHostedTerminal(
        _ hitView: NSView?,
        hostedView: GhosttySurfaceScrollView,
        message: String
    ) {
        guard let hitView else {
            Issue.record(Comment(rawValue: message))
            return
        }
        #expect(hitView === hostedView || hitView.isDescendant(of: hostedView), Comment(rawValue: message))
    }
}
