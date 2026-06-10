import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class KoreanIMEReturnCommitRegressionTests: XCTestCase {
    func testReturnAfterKoreanCommitAlsoSendsReturnToSurface() {
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
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let view = findGhosttyNSView(in: hostedView) else {
            XCTFail("Expected hosted GhosttyNSView")
            return
        }

        view.setMarkedText("한", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))

        // Simulate Korean input source so shouldSendCommittedIMEConfirmKey fires
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.Korean.2SetKorean"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === view else { return false }
            candidateView.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        defer {
            KeyboardLayout.debugInputSourceIdOverride = nil
            cjkIMEInterpretKeyEventsHook = nil
        }

        var sawReturnPress = false
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 36,
                  keyEvent.text == nil else { return }
            sawReturnPress = true
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to create Return event")
            return
        }

        window.makeFirstResponder(view)
        view.keyDown(with: event)

        XCTAssertFalse(view.hasMarkedText(), "Return should commit the active Hangul composition")
        XCTAssertTrue(sawReturnPress, "Return should still be forwarded after IME commit so the command executes once")
    }
}

