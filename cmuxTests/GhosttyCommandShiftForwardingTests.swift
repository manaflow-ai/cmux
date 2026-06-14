import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyCommandShiftForwardingTests: XCTestCase {
    private static let keyCodeANSIK: UInt16 = 40
    private static let keyCodeLeftArrow: UInt16 = 123
    private static let keyCodeUpArrow: UInt16 = 126

    private struct HostedTerminal {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
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
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return HostedTerminal(
            surface: surface,
            window: window,
            surfaceView: try XCTUnwrap(findGhosttyNSView(in: hostedView))
        )
    }

    private func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
        if let ghosttyView = view as? GhosttyNSView {
            return ghosttyView
        }
        for subview in view.subviews {
            if let found = findGhosttyNSView(in: subview) {
                return found
            }
        }
        return nil
    }

    func testUnboundCommandShiftKeyAfterMenuMissForwardsToGhosttyKeyDown() throws {
        let hostedTerminal = try makeHostedTerminal()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        // Headless CI runners can't initialize a Metal-backed Ghostty surface
        // (embedded_window logs error.OutOfMemory). Skip rather than report a
        // misleading key-forwarding failure; the same test still exercises
        // the real path on developer machines and CI environments with a
        // logged-in GUI session.
        try XCTSkipUnless(
            hostedTerminal.surface.hasLiveSurface,
            "Ghostty surface failed to initialize on this host; Metal/embedded_window unavailable."
        )

        XCTAssertTrue(window.makeFirstResponder(surfaceView), "Expected Ghostty surface view to accept first responder")
        XCTAssertNotNil(surfaceView.terminalSurface)

        var forwardedKeyEvent: ghostty_input_key_s?
        var forwardedPressCount = 0
        let observedKeyCode = UInt32(Self.keyCodeANSIK)
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == observedKeyCode else { return }
            forwardedPressCount += 1
            if forwardedKeyEvent == nil {
                forwardedKeyEvent = keyEvent
            }
        }
        defer { GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: Self.keyCodeANSIK
        ))

        withExtendedLifetime(hostedTerminal.surface) {
            XCTAssertTrue(surfaceView.performKeyEquivalentAfterMenuMiss(with: event))
        }

        let keyEvent = try XCTUnwrap(forwardedKeyEvent)
        XCTAssertEqual(forwardedPressCount, 1)
        XCTAssertEqual(keyEvent.keycode, observedKeyCode)
        XCTAssertEqual(keyEvent.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, GHOSTTY_MODS_SUPER.rawValue)
        XCTAssertEqual(keyEvent.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(keyEvent.unshifted_codepoint, "k".unicodeScalars.first?.value)
    }

    func testCommandShiftLeftAfterMenuMissStartsTerminalSelectionInsteadOfForwardingToShell() throws {
        try assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
            keyCode: Self.keyCodeLeftArrow,
            charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
    }

    func testCommandShiftUpAfterMenuMissStartsTerminalSelectionInsteadOfForwardingToShell() throws {
        try assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
            keyCode: Self.keyCodeUpArrow,
            charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
    }

    private func assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
        keyCode: UInt16,
        charactersIgnoringModifiers: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let hostedTerminal = try makeHostedTerminal()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(surfaceView), "Expected Ghostty surface view to accept first responder")
        XCTAssertNotNil(surfaceView.terminalSurface)

        var forwardedPressCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == UInt32(keyCode) else { return }
            forwardedPressCount += 1
        }
        defer { GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))

        withExtendedLifetime(hostedTerminal.surface) {
            XCTAssertTrue(surfaceView.performKeyEquivalentAfterMenuMiss(with: event), file: file, line: line)
        }

        XCTAssertEqual(
            forwardedPressCount,
            0,
            "Cmd+Shift+Arrow should not reach the shell as a Super+Shift+Arrow sequence",
            file: file,
            line: line
        )
        XCTAssertTrue(
            hostedTerminal.surface.keyboardCopyModeActive,
            "Cmd+Shift+Arrow should enter terminal keyboard selection mode",
            file: file,
            line: line
        )
        XCTAssertTrue(
            hostedTerminal.surface.hasSelection(),
            "Cmd+Shift+Arrow should create a terminal selection",
            file: file,
            line: line
        )
    }
}
