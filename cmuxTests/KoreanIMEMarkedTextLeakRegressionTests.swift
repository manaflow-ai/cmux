import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class KoreanIMEMarkedTextLeakRegressionTests: XCTestCase {
    func testKeyDownDoesNotLeakJamoWhileMarkedTextIsActive() {
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
            KeyboardLayout.debugInputSourceIdOverride = nil
            cjkIMEInterpretKeyEventsHook = nil
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

        view.setMarkedText(
            "하",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.Korean.2SetKorean"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === view else { return false }
            return true
        }

        var capturedEvent: ghostty_input_key_s?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == 45 else { return }
            capturedEvent = keyEvent
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "ㄴ",
            charactersIgnoringModifiers: "ㄴ",
            isARepeat: false,
            keyCode: 45
        ) else {
            XCTFail("Failed to create Hangul jamo event")
            return
        }

        window.makeFirstResponder(view)
        view.keyDown(with: event)

        guard let capturedEvent else {
            XCTFail(
                "Expected a composing key event to be forwarded to Ghostty with text=nil; no event was received"
            )
            return
        }

        XCTAssertTrue(capturedEvent.composing, "Hangul composition keyDown should stay in composing mode")
        XCTAssertNil(capturedEvent.text, "Uncommitted Hangul jamo must not be encoded into the terminal surface")
        XCTAssertTrue(view.hasMarkedText(), "Composition should remain active until the IME commits or cancels")
    }
}

