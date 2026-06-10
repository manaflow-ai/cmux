import XCTest
import AppKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class DeadKeyCompositionRegressionTests: XCTestCase {
    func testOptionTildeDeadKeyUsesOriginalEventBeforeAltTranslation() {
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
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
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

        var deadKeyPrimed = false
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === view,
                  let event = events.first else { return false }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 45,
               flags.contains(.option),
               !flags.contains(.command),
               !flags.contains(.control),
               (event.characters ?? "").isEmpty {
                deadKeyPrimed = true
                candidateView.setMarkedText(
                    "~",
                    selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                return true
            }

            if event.keyCode == 0, deadKeyPrimed, candidateView.hasMarkedText() {
                candidateView.insertText("ã", replacementRange: NSRange(location: NSNotFound, length: 0))
                return true
            }

            return false
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

        guard let optionN = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ), let aKey = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to create dead-key events")
            return
        }

        window.makeFirstResponder(view)
        withExtendedLifetime(surface) {
            view.keyDown(with: optionN)
            view.keyDown(with: aKey)
        }

        XCTAssertEqual(pressedText, ["ã"])
        XCTAssertEqual(pressedKeycodes, [], "Dead-key composition should not leak raw Alt-N key events")
        XCTAssertFalse(view.hasMarkedText(), "Composition should clear after the composed character commits")
    }
}

