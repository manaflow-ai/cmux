import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyPhysicalInputFocusReassertionTests: XCTestCase {
    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    func testPrintableKeyDownReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
#if DEBUG
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(terminal.surface) {}
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

        XCTAssertEqual(forwardedText, "a", "Regression setup should exercise the printable Ghostty key path")
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Physical printable input should restore Ghostty focus before sending the key"
        )
#else
        throw XCTSkip("DEBUG-only desired Ghostty focus assertion")
#endif
    }

    func testDirectCommittedTextReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
#if DEBUG
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(terminal.surface) {}
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

        XCTAssertEqual(forwardedText, "committed", "Regression setup should exercise direct NSTextInputClient commit")
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Direct committed text should restore Ghostty focus before sending text"
        )
#else
        throw XCTSkip("DEBUG-only desired Ghostty focus assertion")
#endif
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

        let contentView = try XCTUnwrap(window.contentView)
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
            surfaceView: try XCTUnwrap(findGhosttyNSView(in: hostedView)),
            window: window
        )
    }

    private func focusTerminal(_ terminal: HostedTerminal) throws {
#if DEBUG
        guard terminal.surface.surface != nil else {
            throw XCTSkip("Headless runner did not create a live Ghostty surface")
        }
        XCTAssertTrue(terminal.window.makeFirstResponder(terminal.surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(terminal.hostedView.isSurfaceViewFirstResponder())
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Focused terminal should start with desired Ghostty focus"
        )
#else
        throw XCTSkip("DEBUG-only desired Ghostty focus assertion")
#endif
    }

    private func makeKeyDownEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
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
