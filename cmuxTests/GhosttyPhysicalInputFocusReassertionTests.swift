import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct GhosttyPhysicalInputFocusReassertionTests {
    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    private final class OverlayResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test
    func printableKeyDownReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        #expect(
            !terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        GhosttyNSView.debugTextInputEventHandler = { _, _ in true }
        var forwardedText: String?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 0,
                  let text = keyEvent.text else { return }
            forwardedText = String(cString: text)
        }

        let event = try makeKeyDownEvent(
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0,
            window: terminal.window
        )
        terminal.surfaceView.keyDown(with: event)

        #expect(forwardedText == "a", "Regression setup should exercise the printable Ghostty key path")
        #expect(
            terminal.surface.debugDesiredFocusState(),
            "Physical printable input should restore Ghostty focus before sending the key"
        )
    }

    @Test
    func directCommittedTextReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        #expect(
            !terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        var forwardedText: String?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 0,
                  let text = keyEvent.text else { return }
            forwardedText = String(cString: text)
        }

        terminal.surfaceView.insertText(
            "committed",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(forwardedText == "committed", "Regression setup should exercise direct NSTextInputClient commit")
        #expect(
            terminal.surface.debugDesiredFocusState(),
            "Direct committed text should restore Ghostty focus before sending text"
        )
    }

    @Test
    func directCommittedTextDoesNotReassertGhosttyFocusWhenDescendantOverlayOwnsFirstResponder() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)

        let overlayResponder = OverlayResponderView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        terminal.surfaceView.addSubview(overlayResponder)
        defer { overlayResponder.removeFromSuperview() }

        #expect(terminal.window.makeFirstResponder(overlayResponder))
        #expect(overlayResponder.isDescendant(of: terminal.surfaceView))
        #expect(
            !terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate an overlay keeping Ghostty focus false while it owns AppKit focus"
        )

        terminal.surfaceView.insertText(
            "overlay-owned",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(
            !terminal.surface.debugDesiredFocusState(),
            "Input readiness should not restore Ghostty focus for descendant overlay responders"
        )
    }

    private func makeHostedTerminal() throws -> HostedTerminal {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return HostedTerminal(
            surface: surface,
            hostedView: hostedView,
            surfaceView: try #require(findGhosttyNSView(in: hostedView)),
            window: window
        )
    }

    private func focusTerminal(_ terminal: HostedTerminal) throws {
        try #require(
            terminal.surface.surface != nil,
            "Headless runner did not create a live Ghostty surface"
        )
        #expect(terminal.window.makeFirstResponder(terminal.surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(terminal.hostedView.isSurfaceViewFirstResponder())
        #expect(
            terminal.surface.debugDesiredFocusState(),
            "Focused terminal should start with desired Ghostty focus"
        )
    }

    private func makeKeyDownEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
#endif
