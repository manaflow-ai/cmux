import AppKit
import Carbon.HIToolbox
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CJKIMEMarkedSelectionTests {
    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
    }

    private struct RecordedKey: Equatable {
        let keyCode: UInt32
        let text: String?
        let composing: Bool
    }

    @Test func selectedRangeTracksMarkedTextSelection() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 2, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(view.selectedRange() == NSRange(location: 2, length: 1))
        view.unmarkText()
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test(arguments: [
        ("とうきょう", NSRange(location: 2, length: 2), "きょ"),
        ("ㄓㄨ", NSRange(location: 0, length: 2), "ㄓㄨ"),
        ("안녕하세요", NSRange(location: 2, length: 2), "하세"),
    ])
    func attributedSubstringUsesMarkedText(
        markedText: String,
        range: NSRange,
        expected: String
    ) {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            markedText,
            selectedRange: NSRange(location: range.location, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: range,
            actualRange: &actualRange
        )

        #expect(actualRange == range)
        #expect(substring?.string == expected)
    }

    @Test func keyDownThatStartsPreeditIsOwnedByTextInput() throws {
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
            candidateView.setMarkedText(
                "ㄓ",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var recordedKeys: [RecordedKey] = []
        var releasedKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                recordedKeys.append(RecordedKey(
                    keyCode: keyEvent.keycode,
                    text: keyEvent.text.map(String.init(cString:)),
                    composing: keyEvent.composing
                ))
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                releasedKeyCodes.append(keyEvent.keycode)
            }
        }

        let event = try keyEvent(
            text: "5",
            keyCode: UInt16(kVK_ANSI_5),
            windowNumber: hostedTerminal.window.windowNumber
        )
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)
        let keyUp = try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp + 0.01,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: false,
            keyCode: event.keyCode
        ))
        hostedTerminal.surfaceView.keyUp(with: keyUp)

        #expect(hostedTerminal.surfaceView.hasMarkedText())
        #expect(recordedKeys.isEmpty)
        #expect(releasedKeyCodes.isEmpty)
    }

    @Test func textInputConsumptionWithoutCallbacksDoesNotSynthesizeFallback() throws {
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
            candidateView === hostedTerminal.surfaceView
        }

        var pressedKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            pressedKeyCodes.append(keyEvent.keycode)
        }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hostedTerminal.window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: UInt16(kVK_Space)
        ))
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)

        #expect(pressedKeyCodes.isEmpty)
    }

    @Test func textInputCommandAfterPreeditCommitDoesNotReplayPhysicalKey() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            hostedTerminal.window.orderOut(nil)
            withExtendedLifetime(hostedTerminal.surface) {}
        }

        hostedTerminal.surfaceView.setMarkedText(
            "preedit",
            selectedRange: NSRange(location: 7, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === hostedTerminal.surfaceView else { return false }
            candidateView.insertText(
                "committed",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            candidateView.doCommand(by: NSSelectorFromString("insertNewline:"))
            return true
        }

        var recordedKeys: [RecordedKey] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            recordedKeys.append(RecordedKey(
                keyCode: keyEvent.keycode,
                text: keyEvent.text.map(String.init(cString:)),
                composing: keyEvent.composing
            ))
        }

        let event = try keyEvent(
            text: "\r",
            keyCode: UInt16(kVK_Return),
            windowNumber: hostedTerminal.window.windowNumber
        )
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)

        #expect(recordedKeys == [
            RecordedKey(keyCode: 0, text: "committed", composing: false),
        ])
    }

    @Test func committedPreeditTextPrecedesReplayedNavigationKey() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            hostedTerminal.window.orderOut(nil)
            withExtendedLifetime(hostedTerminal.surface) {}
        }

        hostedTerminal.surfaceView.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === hostedTerminal.surfaceView else { return false }
            candidateView.insertText(
                "한",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var recordedKeys: [RecordedKey] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            recordedKeys.append(RecordedKey(
                keyCode: keyEvent.keycode,
                text: keyEvent.text.map(String.init(cString:)),
                composing: keyEvent.composing
            ))
        }

        let event = try keyEvent(
            text: "\u{F703}",
            keyCode: UInt16(kVK_RightArrow),
            windowNumber: hostedTerminal.window.windowNumber
        )
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)

        #expect(recordedKeys == [
            RecordedKey(keyCode: 0, text: "한", composing: false),
            RecordedKey(keyCode: UInt32(kVK_RightArrow), text: nil, composing: false),
        ])
    }

    @Test func postCommitReplayPolicyMatchesGhosttyNavigationSemantics() throws {
        let view = GhosttyNSView(frame: .zero)
        let probes: [(UInt16, NSEvent.ModifierFlags, Bool)] = [
            (UInt16(kVK_DownArrow), [], true),
            (UInt16(kVK_RightArrow), [], true),
            (UInt16(kVK_UpArrow), [], true),
            (UInt16(kVK_LeftArrow), [], false),
            (UInt16(kVK_LeftArrow), [.shift], true),
            (UInt16(kVK_Return), [], false),
        ]

        for (keyCode, modifiers, expected) in probes {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))

            #expect(
                view.replaysPhysicalKeyAfterPreeditCommit(event) == expected,
                "keyCode=\(keyCode) modifiers=\(modifiers.rawValue)"
            )
        }
    }

    @Test(arguments: [
        "你",
        "臺",
        "한",
        "日本",
        "ф",
        "ع",
        "ש",
        "क",
        "ก",
        "a\u{301}",
        "👨🏽‍💻",
    ])
    func insertTextCommitsWithoutInspectingLanguage(_ text: String) {
        let view = GhosttyNSView(frame: .zero)
        defer { view.setKeyTextAccumulatorForTesting(nil) }

        view.setKeyTextAccumulatorForTesting([])
        view.setMarkedText(
            "preedit",
            selectedRange: NSRange(location: 7, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        view.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(!view.hasMarkedText())
        #expect(view.keyTextAccumulatorForTesting == [text])
    }

    @Test func insertTextCommitDoesNotInferStateFromReplacementRange() {
        let replacementRanges = [
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: 0, length: 0),
            NSRange(location: 0, length: 7),
            NSRange(location: 99, length: 99),
        ]

        for replacementRange in replacementRanges {
            let view = GhosttyNSView(frame: .zero)
            view.setKeyTextAccumulatorForTesting([])
            view.setMarkedText(
                "preedit",
                selectedRange: NSRange(location: 7, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )

            view.insertText("committed", replacementRange: replacementRange)

            #expect(!view.hasMarkedText())
            #expect(view.keyTextAccumulatorForTesting == ["committed"])
            view.setKeyTextAccumulatorForTesting(nil)
        }
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

        let surfaceView = try #require(findGhosttyNSView(in: hostedView))
        return HostedTerminalWindow(
            surface: surface,
            window: window,
            surfaceView: surfaceView
        )
    }

    private func keyEvent(
        text: String,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
