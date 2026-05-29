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
    @Test func dragHandleYieldsToSwiftUITitlebarControlButton() {
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

        let config = TitlebarControlsStyle.classic.config
        let button = TitlebarControlButton(
            config: config,
            foregroundColor: .primary,
            accessibilityIdentifier: "titlebarControl.test",
            accessibilityLabel: "Test",
            action: {}
        ) {
            Image(systemName: "sidebar.leading")
        }
        let buttonHost = NSHostingView(rootView: button)
        buttonHost.frame = NSRect(x: 12, y: 14, width: config.buttonSize, height: config.buttonSize)
        container.addSubview(buttonHost)
        buttonHost.layoutSubtreeIfNeeded()

        let buttonPoint = NSPoint(x: buttonHost.frame.midX, y: buttonHost.frame.midY)
        #expect(
            !windowDragHandleShouldCaptureHit(
                dragHandle.convert(buttonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "SwiftUI titlebar controls must block explicit titlebar dragging at their button hit region."
        )

        #expect(
            windowDragHandleShouldCaptureHit(
                NSPoint(x: 220, y: 24),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar chrome outside the interactive button should remain draggable."
        )
    }
}
