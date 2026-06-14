import AppKit
import CmuxTerminal
import CmuxTerminalCopyMode
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GhosttyCommandShiftSelectionTests {
    private static let keyCodeLeftArrow: UInt16 = 123
    private static let keyCodeUpArrow: UInt16 = 126

    @Test
    func commandShiftArrowsMapToNativeSelectionMoves() {
        let cases: [(UInt16, TerminalKeyboardCopyModeSelectionMove)] = [
            (123, .beginningOfLine),
            (124, .endOfLine),
            (126, .home),
            (125, .end),
        ]
        for (keyCode, expectedMove) in cases {
            #expect(
                terminalKeyboardSelectionMoveForCommandEquivalent(
                    keyCode: keyCode,
                    modifierFlags: [.command, .shift]
                ) == expectedMove
            )
        }
        #expect(
            terminalKeyboardSelectionMoveForCommandEquivalent(
                keyCode: Self.keyCodeLeftArrow,
                modifierFlags: [.shift]
            ) == nil
        )
    }

    @Test
    func commandShiftLeftAfterMenuMissStartsTerminalSelectionInsteadOfForwardingToShell() throws {
        try assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
            keyCode: Self.keyCodeLeftArrow,
            charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
    }

    @Test
    func commandShiftUpAfterMenuMissStartsTerminalSelectionInsteadOfForwardingToShell() throws {
        try assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
            keyCode: Self.keyCodeUpArrow,
            charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
    }

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
        let contentView = try #require(window.contentView)
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
            surfaceView: try #require(findGhosttyNSView(in: hostedView))
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

    private func assertCommandShiftArrowStartsSelectionInsteadOfForwardingToShell(
        keyCode: UInt16,
        charactersIgnoringModifiers: String
    ) throws {
        let hostedTerminal = try makeHostedTerminal()
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        defer { window.orderOut(nil) }

        let hasLiveSurface = hostedTerminal.surface.hasLiveSurface
        #expect(
            hasLiveSurface,
            Comment(rawValue: "Ghostty surface failed to initialize on this host; Metal/embedded_window unavailable.")
        )
        guard hasLiveSurface else {
            return
        }

        #expect(
            window.makeFirstResponder(surfaceView),
            Comment(rawValue: "Expected Ghostty surface view to accept first responder")
        )
        #expect(surfaceView.terminalSurface != nil)

        var forwardedPressCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == UInt32(keyCode) else { return }
            forwardedPressCount += 1
        }
        defer { GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver }

        let event = try #require(NSEvent.keyEvent(
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
            #expect(
                surfaceView.performKeyEquivalentAfterMenuMiss(with: event),
                Comment(rawValue: "Cmd+Shift+Arrow should be consumed by terminal selection handling")
            )
        }

        #expect(
            forwardedPressCount == 0,
            Comment(rawValue: "Cmd+Shift+Arrow should not reach the shell as a Super+Shift+Arrow sequence")
        )
        #expect(
            hostedTerminal.surface.keyboardCopyModeActive,
            Comment(rawValue: "Cmd+Shift+Arrow should enter terminal keyboard selection mode")
        )
        #expect(
            hostedTerminal.surface.hasSelection(),
            Comment(rawValue: "Cmd+Shift+Arrow should create a terminal selection")
        )
    }
}
