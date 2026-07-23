import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TraditionalChineseIMENumpadRegressionTests {
    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
    }

    @Test func keypadCommitDuringTextInterpretationSendsOneKey() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            hostedTerminal.window.orderOut(nil)
            withExtendedLifetime(hostedTerminal.surface) {}
        }

        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === hostedTerminal.surfaceView else { return false }
            candidateView.insertText(
                "1",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var pressedText: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  let text = keyEvent.text else {
                return
            }
            pressedText.append(String(cString: text))
        }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.numericPad],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hostedTerminal.window.windowNumber,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 83
        ))
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)

        #expect(pressedText == ["1"])
    }

    private func makeHostedTerminalWindow() throws -> HostedTerminalWindow {
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

        return HostedTerminalWindow(
            surface: surface,
            window: window,
            surfaceView: try #require(findGhosttyNSView(in: hostedView))
        )
    }
}
