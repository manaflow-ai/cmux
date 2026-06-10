import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class AccessibilityInsertTextRegressionTests: XCTestCase {
    func testDirectInsertTextUsesTypedInputSemantics() {
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

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.insertText("dictated line\n", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(pressedText, ["dictated line"])
        XCTAssertEqual(pressedKeycodes, [36], "Trailing newline should be delivered as Return, not pasted text")
    }

    func testDirectInsertTextPreservesLeadingEscapeForAutomation() {
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

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.insertText("\u{1B}[A", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(pressedText, ["\u{1B}[A"])
        XCTAssertEqual(pressedKeycodes, [], "Direct NSTextInputClient insertText should preserve raw ESC bytes")
    }

    func testAccessibilityValueSanitizesLeadingEscapeSequence() {
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

        var pressedText: [String] = []
        var pressedKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                pressedText.append(String(cString: text))
            } else {
                pressedKeycodes.append(keyEvent.keycode)
            }
        }

        view.setAccessibilityValue("\u{1B}[Adictated line\n")

        XCTAssertEqual(pressedText, ["dictated line"])
        XCTAssertEqual(pressedKeycodes, [36], "AX value insertion should sanitize injected ESC prefixes before sending text")
    }
}

