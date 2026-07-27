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
    let keycode: UInt32
    let text: String?
    let modifiers: UInt32
    let consumedModifiers: UInt32
    let unshiftedCodepoint: UInt32
    let composing: Bool
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
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.surfaceView.setTextInputEventHandlerForTesting(nil)
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.setTextInputEventHandlerForTesting { event in
            guard let text = event.characters else {
                return false
            }
            terminal.surfaceView.insertText(
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
                keycode: keyEvent.keycode,
                text: keyEvent.text.map { String(cString: $0) },
                modifiers: keyEvent.mods.rawValue,
                consumedModifiers: keyEvent.consumed_mods.rawValue,
                unshiftedCodepoint: keyEvent.unshifted_codepoint,
                composing: keyEvent.composing
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
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.surfaceView.setTextInputEventHandlerForTesting(nil)
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.setTextInputEventHandlerForTesting { _ in false }
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

    func testCommittedPreeditTextUsesGhosttyNonphysicalKeyEvent() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            GhosttyNSView.debugGhosttySurfaceTextInputObserver = nil
            terminal.surfaceView.setTextInputEventHandlerForTesting(nil)
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.setTextInputEventHandlerForTesting { _ in
            terminal.surfaceView.insertText(
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

        var committedTextEvents: [CapturedGhosttyKeyIdentityEvent] = []
        var nonphysicalCommittedText: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.text.map({ String(cString: $0) }) == "日本" else {
                return
            }
            committedTextEvents.append(CapturedGhosttyKeyIdentityEvent(
                action: keyEvent.action,
                keycode: keyEvent.keycode,
                text: keyEvent.text.map { String(cString: $0) },
                modifiers: keyEvent.mods.rawValue,
                consumedModifiers: keyEvent.consumed_mods.rawValue,
                unshiftedCodepoint: keyEvent.unshifted_codepoint,
                composing: keyEvent.composing
            ))
        }
        GhosttyNSView.debugGhosttySurfaceTextInputObserver = {
            nonphysicalCommittedText.append($0)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: press)
            terminal.surfaceView.keyUp(with: release)
        }

        XCTAssertTrue(
            nonphysicalCommittedText.isEmpty,
            "Committed preedit text must not bypass Ghostty's key-binding state machine"
        )
        XCTAssertEqual(committedTextEvents.count, 1)
        guard let committedTextEvent = committedTextEvents.first else { return }
        XCTAssertEqual(committedTextEvent.action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(committedTextEvent.keycode, 0)
        XCTAssertEqual(committedTextEvent.text, "日本")
        XCTAssertEqual(committedTextEvent.modifiers, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(committedTextEvent.consumedModifiers, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(committedTextEvent.unshiftedCodepoint, 0)
        XCTAssertFalse(committedTextEvent.composing)
    }

    func testConsumedPreeditRepeatKeepsAppKitOwnershipThroughRelease() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            GhosttyNSView.debugGhosttySurfaceTextInputObserver = nil
            terminal.surfaceView.setTextInputEventHandlerForTesting(nil)
            terminal.window.orderOut(nil)
        }

        var callbackOrder: [String] = []
        terminal.surfaceView.setTextInputEventHandlerForTesting { event in
            if event.isARepeat {
                callbackOrder.append("repeat.insertText")
                terminal.surfaceView.insertText(
                    "é",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                callbackOrder.append("repeat.doCommand")
                terminal.surfaceView.doCommand(
                    by: #selector(NSResponder.insertNewline(_:))
                )
            } else {
                callbackOrder.append("press.setMarkedText")
                terminal.surfaceView.setMarkedText(
                    "´",
                    selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            return true
        }

        var physicalActions: [ghostty_input_action_e] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 14 else { return }
            physicalActions.append(keyEvent.action)
        }
        var committedText: [String] = []
        GhosttyNSView.debugGhosttySurfaceTextInputObserver = {
            committedText.append($0)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "´",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: 14
        ))
        let repeatEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: true,
            keyCode: 14
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.2,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: 14
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: press)
            terminal.surfaceView.keyDown(with: repeatEvent)
            terminal.surfaceView.keyUp(with: release)
        }

        XCTAssertEqual(callbackOrder, [
            "press.setMarkedText",
            "repeat.insertText",
            "repeat.doCommand",
        ])
        XCTAssertEqual(committedText, ["é"])
        XCTAssertTrue(
            physicalActions.isEmpty,
            "A key consumed by the native text-input handler must not leak a press, repeat, or release"
        )
        XCTAssertFalse(terminal.surfaceView.hasMarkedText())
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
