import AppKit
import Carbon.HIToolbox
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
    private final class LifecycleSurfaceView: GhosttyNSView {
        var textInputEventHandler: ((NSEvent) -> Bool)?
        var unshiftedCodepointResolver: ((NSEvent) -> UInt32?)?

        override func handleTextInputEvent(_ event: NSEvent) -> Bool {
            guard let textInputEventHandler else {
                return super.handleTextInputEvent(event)
            }
            return textInputEventHandler(event)
        }

        override func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
            unshiftedCodepointResolver?(event)
                ?? super.unshiftedCodepointFromEvent(event)
        }
    }

    private struct LifecycleSurfaceViewFactory: TerminalSurfaceViewProviding {
        func makeSurfaceViews(
            initialFrame: NSRect
        ) -> (
            surfaceView: any TerminalSurfaceNativeViewing,
            paneHost: any TerminalSurfacePaneHosting
        ) {
            let surfaceView = LifecycleSurfaceView(frame: initialFrame)
            return (
                surfaceView,
                GhosttySurfaceScrollView(surfaceView: surfaceView)
            )
        }
    }

    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: LifecycleSurfaceView
        let window: NSWindow
    }

    func testRepeatUsesCurrentTextAndStableBindingIdentity() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.textInputEventHandler = { event in
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

    func testCommandReleaseFromAppMonitorKeepsConsumedMenuBindingIdentityAfterLayoutChange() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        terminal.surfaceView.unshiftedCodepointResolver = { event in
            event.type == .keyUp ? 0x0441 : nil
        }
        var capturedReleases: [CapturedGhosttyKeyIdentityEvent] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 8,
                  keyEvent.action == GHOSTTY_ACTION_RELEASE else {
                return
            }
            capturedReleases.append(CapturedGhosttyKeyIdentityEvent(
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
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "с",
            charactersIgnoringModifiers: "с",
            isARepeat: false,
            keyCode: 8
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            XCTAssertTrue(
                terminal.surfaceView.consumeUnavailableCopyMenuAction(press),
                "The default Ghostty Copy binding should be consumed after the native menu declines it"
            )
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "The app-local monitor must directly deliver a Command-modified release to its terminal owner"
            )
        }

        XCTAssertEqual(capturedReleases.count, 1)
        XCTAssertEqual(
            capturedReleases.first?.unshiftedCodepoint,
            "c".unicodeScalars.first?.value,
            "A Ghostty-consumed menu binding must release with the identity that was consumed, even after the layout changes"
        )
    }

    func testCommandReleaseFromAppMonitorDoesNotCreateOrphanTerminalRelease() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        var capturedReleaseCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 8,
                  keyEvent.action == GHOSTTY_ACTION_RELEASE else {
                return
            }
            capturedReleaseCount += 1
        }

        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            XCTAssertFalse(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "A Command release without recorded terminal ownership must remain outside the terminal"
            )
        }
        XCTAssertEqual(capturedReleaseCount, 0)
    }

    func testCommandReleaseFromAppMonitorUsesRecordedOwnerAfterEventWindowChanges() throws {
        let originalTerminal = try makeHostedTerminal()
        let eventWindowTerminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            originalTerminal.window.orderOut(nil)
            eventWindowTerminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        originalTerminal.surfaceView.unshiftedCodepointResolver = { event in
            event.type == .keyUp ? 0x0446 : nil
        }
        eventWindowTerminal.surfaceView.unshiftedCodepointResolver = { event in
            event.type == .keyUp ? 0x0441 : nil
        }

        var capturedReleaseIdentities: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 8,
                  keyEvent.action == GHOSTTY_ACTION_RELEASE else {
                return
            }
            capturedReleaseIdentities.append(keyEvent.unshifted_codepoint)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: originalTerminal.window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp + 0.1,
            windowNumber: eventWindowTerminal.window.windowNumber,
            context: nil,
            characters: "с",
            charactersIgnoringModifiers: "с",
            isARepeat: false,
            keyCode: 8
        ))

        originalTerminal.window.makeFirstResponder(originalTerminal.surfaceView)
        eventWindowTerminal.window.makeFirstResponder(eventWindowTerminal.surfaceView)
        withExtendedLifetime((originalTerminal.surface, eventWindowTerminal.surface)) {
            XCTAssertTrue(
                originalTerminal.surfaceView.consumeUnavailableCopyMenuAction(press),
                "The original terminal must record Ghostty's consumed Copy binding"
            )
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "The app-local monitor must deliver the release to the recorded terminal owner"
            )
        }

        XCTAssertEqual(
            capturedReleaseIdentities,
            ["c".unicodeScalars.first?.value].compactMap { $0 },
            "Release delivery must retain the original terminal's stable binding identity"
        )
    }

    func testCommandReleaseFromAppMonitorUsesTerminalThatSentPhysicalPress() throws {
        let originalTerminal = try makeHostedTerminal()
        let eventWindowTerminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            originalTerminal.window.orderOut(nil)
            eventWindowTerminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        originalTerminal.surfaceView.textInputEventHandler = { _ in false }
        originalTerminal.surfaceView.unshiftedCodepointResolver = { event in
            event.type == .keyUp ? 0x0446 : nil
        }
        eventWindowTerminal.surfaceView.unshiftedCodepointResolver = { event in
            event.type == .keyUp ? 0x0441 : nil
        }

        var capturedEvents: [CapturedGhosttyKeyIdentityEvent] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 7 else { return }
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
            modifierFlags: [.control],
            timestamp: timestamp,
            windowNumber: originalTerminal.window.windowNumber,
            context: nil,
            characters: "\u{18}",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp + 0.1,
            windowNumber: eventWindowTerminal.window.windowNumber,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))

        originalTerminal.window.makeFirstResponder(originalTerminal.surfaceView)
        eventWindowTerminal.window.makeFirstResponder(eventWindowTerminal.surfaceView)
        withExtendedLifetime((originalTerminal.surface, eventWindowTerminal.surface)) {
            originalTerminal.surfaceView.keyDown(with: press)
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "A physical terminal press must register its exact release owner"
            )
        }

        XCTAssertEqual(capturedEvents.map(\.action), [
            GHOSTTY_ACTION_PRESS,
            GHOSTTY_ACTION_RELEASE,
        ])
        XCTAssertEqual(
            capturedEvents.last?.unshiftedCodepoint,
            "x".unicodeScalars.first?.value,
            "The release must keep the sending terminal's physical identity when Command is pressed later"
        )
    }

    func testIgnoredGhosttyPressKeepsCommandReleaseOwner() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        terminal.surfaceView.textInputEventHandler = { _ in false }
        var capturedActions: [ghostty_input_action_e] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == UInt32(kVK_ANSI_Y) else { return }
            capturedActions.append(keyEvent.action)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Y)
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Y)
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: press)
            XCTAssertEqual(
                capturedActions,
                [GHOSTTY_ACTION_PRESS],
                "The unmatched physical press must still be submitted to Ghostty"
            )
            XCTAssertTrue(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "An ignored Ghostty result must not discard the exact terminal that owns Command key-up"
            )
        }

        XCTAssertEqual(capturedActions, [
            GHOSTTY_ACTION_PRESS,
            GHOSTTY_ACTION_RELEASE,
        ])
    }

    func testTerminalLifecycleResetClearsAppMonitorReleaseOwnership() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }
        let appDelegate = try XCTUnwrap(AppDelegate.shared)

        var capturedReleaseCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.keycode == 8,
                  keyEvent.action == GHOSTTY_ACTION_RELEASE else {
                return
            }
            capturedReleaseCount += 1
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp + 0.1,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        terminal.window.makeFirstResponder(terminal.surfaceView)
        withExtendedLifetime(terminal.surface) {
            XCTAssertTrue(terminal.surfaceView.consumeUnavailableCopyMenuAction(press))
            XCTAssertTrue(terminal.window.makeFirstResponder(nil))
            XCTAssertFalse(
                appDelegate.debugHandleShortcutMonitorEvent(event: release),
                "Focus loss must invalidate terminal release ownership before the monitor sees key-up"
            )
        }
        XCTAssertEqual(capturedReleaseCount, 0)
    }

    func testComposingPressForwardsMatchingRelease() throws {
        let terminal = try makeHostedTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.textInputEventHandler = { _ in false }
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
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.textInputEventHandler = { _ in
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
            terminal.window.orderOut(nil)
        }

        var callbackOrder: [String] = []
        terminal.surfaceView.textInputEventHandler = { event in
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
        var committedTextActions: [ghostty_input_action_e] = []
        var committedText: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            if keyEvent.keycode == 14 {
                physicalActions.append(keyEvent.action)
            } else if keyEvent.keycode == 0,
                      let text = keyEvent.text.map({ String(cString: $0) }) {
                committedTextActions.append(keyEvent.action)
                committedText.append(text)
            }
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
        XCTAssertEqual(committedTextActions, [GHOSTTY_ACTION_REPEAT])
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
            workingDirectory: nil,
            dependencies: runtimeDependencies()
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
            surfaceView: try XCTUnwrap(
                findGhosttyNSView(in: hostedView) as? LifecycleSurfaceView
            ),
            window: window
        )
    }

    private func runtimeDependencies() -> TerminalSurfaceRuntimeDependencies {
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        return TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: LifecycleSurfaceViewFactory(),
            spawnPolicy: live.spawnPolicy,
            byteTee: live.byteTee,
            rendererRealization: live.rendererRealization,
            hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown,
            restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: live.runtimeFilesystem,
            sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: live.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: live.globalFontMagnificationPercent
        )
    }
}
