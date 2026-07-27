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
    let unshiftedCodepoint: UInt32
}

@MainActor
final class GhosttyConsumedModifierLifecycleTests: XCTestCase {
    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    func testRepeatUsesCurrentTextAndStableBindingIdentity() throws {
        let terminal = try makeHostedTerminal()
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            terminal.window.orderOut(nil)
        }

        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === terminal.surfaceView,
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
                consumedModifiers: keyEvent.consumed_mods.rawValue,
                unshiftedCodepoint: keyEvent.unshifted_codepoint
            ))
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
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
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "ф",
            charactersIgnoringModifiers: "ф",
            isARepeat: true,
            keyCode: 0
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.2,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: press)
            terminal.surfaceView.keyDown(with: repeatEvent)
            terminal.surfaceView.keyUp(with: release)
        }

        XCTAssertEqual(capturedEvents.count, 3)
        guard capturedEvents.count == 3 else { return }
        XCTAssertEqual(capturedEvents[0].action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(capturedEvents[0].text, "A")
        XCTAssertEqual(capturedEvents[0].consumedModifiers, GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(capturedEvents[0].unshiftedCodepoint, 0x61)
        XCTAssertEqual(capturedEvents[1].action, GHOSTTY_ACTION_REPEAT)
        XCTAssertEqual(
            capturedEvents[1].text,
            "ф",
            "A repeat must use the current AppKit text after translation changes"
        )
        XCTAssertEqual(
            capturedEvents[1].consumedModifiers,
            GHOSTTY_MODS_NONE.rawValue,
            "A repeat must use the modifiers that produced its current text"
        )
        XCTAssertEqual(
            capturedEvents[1].unshiftedCodepoint,
            capturedEvents[0].unshiftedCodepoint,
            "A repeat must keep the binding identity established by its press"
        )
        XCTAssertEqual(capturedEvents[2].action, GHOSTTY_ACTION_RELEASE)
        XCTAssertNil(capturedEvents[2].text)
        XCTAssertEqual(
            capturedEvents[2].consumedModifiers,
            GHOSTTY_MODS_NONE.rawValue,
            "Consumed modifiers are event-local text metadata, not release identity"
        )
        XCTAssertEqual(
            capturedEvents[2].unshiftedCodepoint,
            capturedEvents[0].unshiftedCodepoint,
            "A release must carry the same binding identity as its press and repeats"
        )
    }

    func testComposingPressForwardsMatchingRelease() throws {
        let terminal = try makeHostedTerminal()
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            terminal.window.orderOut(nil)
        }

        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            candidateView === terminal.surfaceView
        }
        terminal.surfaceView.setMarkedText(
            "ᄒ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var capturedActions: [ghostty_input_action_e] = []
        var capturedComposingStates: [Bool] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 4 else { return }
            capturedActions.append(keyEvent.action)
            capturedComposingStates.append(keyEvent.composing)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "h",
            charactersIgnoringModifiers: "h",
            isARepeat: false,
            keyCode: 4
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "h",
            charactersIgnoringModifiers: "h",
            isARepeat: false,
            keyCode: 4
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: press)
            terminal.surfaceView.keyUp(with: release)
        }

        XCTAssertEqual(capturedActions, [
            GHOSTTY_ACTION_PRESS,
            GHOSTTY_ACTION_RELEASE,
        ])
        XCTAssertEqual(capturedComposingStates, [true, false])
    }

    func testCommittedPreeditTextDoesNotInventPhysicalKey() throws {
        let terminal = try makeHostedTerminal()
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            terminal.window.orderOut(nil)
        }

        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === terminal.surfaceView else { return false }
            candidateView.insertText(
                "日本",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }
        terminal.surfaceView.setMarkedText(
            "にほん",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var committedTextKeycodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.text.map({ String(cString: $0) }) == "日本" else {
                return
            }
            committedTextKeycodes.append(keyEvent.keycode)
        }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: event)
        }

        XCTAssertTrue(
            committedTextKeycodes.isEmpty,
            "Text committed from preedit must use Ghostty's nonphysical text-input API, not a synthetic native keycode"
        )
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
            hostedView: hostedView,
            surfaceView: try XCTUnwrap(findGhosttyNSView(in: hostedView)),
            window: window
        )
    }
}
