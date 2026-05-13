import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyCommandShiftForwardingTests: XCTestCase {
    private static let keyCodeANSIH: UInt16 = 4
    private static let keyCodeANSIK: UInt16 = 40

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

    func testDeadTerminalPaneKeyDownDoesNotForwardInputToGhostty() throws {
        let hostedTerminal = try makeHostedTerminal()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(surfaceView), "Expected Ghostty surface view to accept first responder")
        XCTAssertNotNil(surfaceView.terminalSurface)

        let observedKeyCode = UInt32(Self.keyCodeANSIH)
        var forwardedPressCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == observedKeyCode else { return }
            forwardedPressCount += 1
        }
        defer { GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver }

        hostedTerminal.surface.markChildProcessExitedForTesting(reason: "unit-test-child-exited")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "h",
            charactersIgnoringModifiers: "h",
            isARepeat: false,
            keyCode: Self.keyCodeANSIH
        ))

        withExtendedLifetime(hostedTerminal.surface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertEqual(forwardedPressCount, 0, "Dead terminal panes must discard key input before it reaches Ghostty")
    }
}
