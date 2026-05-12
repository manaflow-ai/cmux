import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TraditionalChineseIMENumpadRegressionTests: XCTestCase {
    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
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

        let surfaceView = try XCTUnwrap(findGhosttyNSView(in: hostedView))
        return HostedTerminalWindow(
            surface: surface,
            window: window,
            surfaceView: surfaceView
        )
    }

    private func keypadEvent(
        text: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [.numericPad],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func mouseMovedEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
    }

    func testDeduplicatorRecordsOnlyRawNumpadFallbacks() throws {
        var deduplicator = NumpadIMECommitDeduplicator()

        let plainKeyboardEvent = try keypadEvent(text: "1", keyCode: 83)
        deduplicator.recordFallback(
            text: "1",
            event: plainKeyboardEvent,
            sourceId: "com.apple.keylayout.US"
        )
        XCTAssertFalse(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.keylayout.US",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))

        let shiftedEvent = try keypadEvent(
            text: "1",
            keyCode: 83,
            modifierFlags: [.numericPad, .shift]
        )
        deduplicator.recordFallback(
            text: "1",
            event: shiftedEvent,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )
        XCTAssertFalse(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))

        let rawEvent = try keypadEvent(text: "1", keyCode: 83)
        deduplicator.recordFallback(
            text: "1",
            event: rawEvent,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )
        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
    }

    func testDeduplicatorPreservesPendingFallbackAfterUnmatchedCommit() throws {
        var deduplicator = NumpadIMECommitDeduplicator()
        let event = try keypadEvent(text: "1", keyCode: 83)
        deduplicator.recordFallback(
            text: "1",
            event: event,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )

        XCTAssertFalse(deduplicator.shouldSuppressCommit(
            "2",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
    }

    func testDeduplicatorClearsOnlyMatchedFallbackAfterKeyMismatch() throws {
        var deduplicator = NumpadIMECommitDeduplicator()
        deduplicator.recordFallback(
            text: "1",
            event: try keypadEvent(text: "1", keyCode: 83),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )
        deduplicator.recordFallback(
            text: "2",
            event: try keypadEvent(text: "2", keyCode: 84),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )

        XCTAssertFalse(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: try keypadEvent(text: "1", keyCode: 84),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
        XCTAssertFalse(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "2",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
    }

    func testDeduplicatorIgnoresUnrelatedNonKeyDownCurrentEvent() throws {
        var deduplicator = NumpadIMECommitDeduplicator()
        deduplicator.recordFallback(
            text: "1",
            event: try keypadEvent(text: "1", keyCode: 83),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )

        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: try mouseMovedEvent(),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
    }

    func testDeduplicatorKeepsRapidNumpadFallbacksIndependent() throws {
        var deduplicator = NumpadIMECommitDeduplicator()
        deduplicator.recordFallback(
            text: "1",
            event: try keypadEvent(text: "1", keyCode: 83),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )
        deduplicator.recordFallback(
            text: "2",
            event: try keypadEvent(text: "2", keyCode: 84),
            sourceId: "com.apple.inputmethod.TCIM.Pinyin"
        )

        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "1",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
        XCTAssertTrue(deduplicator.shouldSuppressCommit(
            "2",
            currentEvent: nil,
            sourceId: "com.apple.inputmethod.TCIM.Pinyin",
            externalCommittedTextDepth: 0,
            keyTextAccumulatorIsActive: false
        ))
    }

    func testKeypadDigitDoesNotDuplicateWhenTraditionalChineseIMECommitsAfterKeyDown() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Pinyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            DispatchQueue.main.async {
                candidateView.insertText("1", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return true
        }

        var pressedText: [String] = []
        let firstPress = expectation(description: "raw keypad fallback is sent once")
        let duplicatePress = expectation(description: "deferred IME duplicate is not sent")
        duplicatePress.isInverted = true
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, let text = keyEvent.text else { return }
            let value = String(cString: text)
            pressedText.append(value)
            if value == "1", pressedText.count == 1 {
                firstPress.fulfill()
            } else if value == "1" {
                duplicatePress.fulfill()
            }
        }

        let event = try keypadEvent(text: "1", keyCode: 83, windowNumber: window.windowNumber)

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
            wait(for: [firstPress, duplicatePress], timeout: 1.0)
        }

        XCTAssertEqual(
            pressedText,
            ["1"],
            "Traditional Chinese IME numpad commits should not double-dispatch a keypad digit after keyDown fallback"
        )
    }
}
