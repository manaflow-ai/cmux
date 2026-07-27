import AppKit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private struct CapturedGhosttyKeyIdentityEvent {
    let action: ghostty_input_action_e
    let text: String?
    let consumedModifiers: UInt32
}

@MainActor
final class GhosttyConsumedModifierLifecycleTests: XCTestCase {
    func testRepeatAndReleaseKeepConsumedModifiersFromInitialPress() throws {
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

        let view = try XCTUnwrap(findGhosttyNSView(in: hostedView))
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === view,
                  let text = events.first?.characters else {
                return false
            }
            candidateView.insertText(
                text,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var capturedEvents: [CapturedGhosttyKeyIdentityEvent] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 0 else { return }
            capturedEvents.append(CapturedGhosttyKeyIdentityEvent(
                action: keyEvent.action,
                text: keyEvent.text.map { String(cString: $0) },
                consumedModifiers: keyEvent.consumed_mods.rawValue
            ))
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "A",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        let repeatEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.1,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: true,
            keyCode: 0
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.2,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        window.makeFirstResponder(view)
        withExtendedLifetime(surface) {
            view.keyDown(with: press)
            view.keyDown(with: repeatEvent)
            view.keyUp(with: release)
        }

        XCTAssertEqual(capturedEvents.count, 3)
        guard capturedEvents.count == 3 else { return }
        XCTAssertEqual(capturedEvents[0].action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(capturedEvents[0].text, "A")
        XCTAssertEqual(capturedEvents[0].consumedModifiers, GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(capturedEvents[1].action, GHOSTTY_ACTION_REPEAT)
        XCTAssertEqual(
            capturedEvents[1].text,
            "A",
            "A repeat must keep the initial press text after translation changes"
        )
        XCTAssertEqual(
            capturedEvents[1].consumedModifiers,
            GHOSTTY_MODS_SHIFT.rawValue,
            "A repeat must keep the modifiers that produced its retained text"
        )
        XCTAssertEqual(capturedEvents[2].action, GHOSTTY_ACTION_RELEASE)
        XCTAssertNil(capturedEvents[2].text)
        XCTAssertEqual(
            capturedEvents[2].consumedModifiers,
            GHOSTTY_MODS_SHIFT.rawValue,
            "A release must carry the same physical-key identity as its press"
        )
    }
}
