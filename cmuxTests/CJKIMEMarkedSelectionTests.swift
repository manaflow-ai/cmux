import XCTest
import AppKit
import Carbon.HIToolbox

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CJKIMEMarkedSelectionTests: XCTestCase {
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
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))

        let surfaceView = try XCTUnwrap(findGhosttyNSView(in: hostedView))
        return HostedTerminalWindow(
            surface: surface,
            window: window,
            surfaceView: surfaceView
        )
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        text: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        windowNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
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

    private struct KoreanArrowProbe {
        let text: String
        let keyCode: UInt16
        let selectionBefore: NSRange
        let selectionAfter: NSRange
    }

    private struct NoMarkedIMEKeyProbe {
        let name: String
        let text: String
        let keyCode: UInt16
    }

    private let noMarkedNavigationKeyProbes: [NoMarkedIMEKeyProbe] = [
        NoMarkedIMEKeyProbe(name: "Left", text: "\u{F702}", keyCode: UInt16(kVK_LeftArrow)),
        NoMarkedIMEKeyProbe(name: "Right", text: "\u{F703}", keyCode: UInt16(kVK_RightArrow)),
        NoMarkedIMEKeyProbe(name: "Up", text: "\u{F700}", keyCode: UInt16(kVK_UpArrow)),
        NoMarkedIMEKeyProbe(name: "Down", text: "\u{F701}", keyCode: UInt16(kVK_DownArrow)),
        NoMarkedIMEKeyProbe(name: "Home", text: "\u{F729}", keyCode: UInt16(kVK_Home)),
        NoMarkedIMEKeyProbe(name: "End", text: "\u{F72B}", keyCode: UInt16(kVK_End)),
        NoMarkedIMEKeyProbe(name: "PageUp", text: "\u{F72C}", keyCode: UInt16(kVK_PageUp)),
        NoMarkedIMEKeyProbe(name: "PageDown", text: "\u{F72D}", keyCode: UInt16(kVK_PageDown)),
        NoMarkedIMEKeyProbe(name: "Tab", text: "\t", keyCode: UInt16(kVK_Tab)),
        NoMarkedIMEKeyProbe(name: "Space", text: " ", keyCode: UInt16(kVK_Space)),
    ]

    private let pinyinCandidateCommandProbeNames: Set<String> = [
        "Left", "Right", "Up", "Down", "PageUp", "PageDown", "Tab",
    ]

    private let pinyinNonCandidateCommandProbeNames: Set<String> = [
        "Home", "End", "Space",
    ]

    private let zhuyinCandidateCommandProbeNames: Set<String> = [
        "Left", "Right", "Up", "Down", "PageUp", "PageDown", "Space",
    ]

    private let zhuyinNonCandidateCommandProbeNames: Set<String> = [
        "Home", "End", "Tab",
    ]

    private let nonTextInputCommandModifierProbes: [(name: String, flags: NSEvent.ModifierFlags)] = [
        ("Command", [.command]),
        ("Control", [.control]),
        ("Option", [.option]),
    ]

    private func assertInputSourceForwardsNoMarkedIMECommandKeys(
        _ inputSourceId: String,
        textInputHandledEvent: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertFalse(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: textInputHandledEvent,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) should forward \(textInputHandledEvent ? "" : "unhandled ")\(probe.name) to Ghostty when no composition is active",
                file: file,
                line: line
            )
        }
    }

    private func assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertInputSourceForwardsNoMarkedIMECommandKeys(
            inputSourceId,
            textInputHandledEvent: true,
            file: file,
            line: line
        )
    }

    private func assertInputSourceForwardsUnhandledNoMarkedIMECommandKeys(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertInputSourceForwardsNoMarkedIMECommandKeys(
            inputSourceId,
            textInputHandledEvent: false,
            file: file,
            line: line
        )
    }

    func testSelectedRangeReturnsEmptyRangeWithoutSelectionOrMarkedText() {
        let view = GhosttyNSView(frame: .zero)
        let range = view.selectedRange()
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func testSelectedRangeTracksMarkedTextSelection() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 2, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(
            view.selectedRange(),
            NSRange(location: 2, length: 1),
            "selectedRange should mirror the IME caret/selection inside marked text"
        )
    }

    func testSelectedRangeReturnsEmptyRangeAfterCompositionEnds() {
        let view = GhosttyNSView(frame: .zero)

        view.setMarkedText(
            "東京",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        view.unmarkText()

        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testAttributedSubstringReturnsMarkedTextSegment() {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "とうきょう",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 2, length: 2),
            actualRange: &actualRange
        )

        XCTAssertEqual(actualRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(substring?.string, "きょ")
    }

    func testTraditionalChineseZhuyinMarkedTextSelectionAndSubstring() {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 2),
            actualRange: &actualRange
        )

        XCTAssertEqual(actualRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(substring?.string, "ㄓㄨ")
    }

    func testSuppressesTerminalForwardingWhenZhuyinStartsMarkedText() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertTrue(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "",
                markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                markedTextAfter: "ㄓ",
                markedSelectionAfter: NSRange(location: 1, length: 0),
                accumulatedText: []
            )
        )
    }

    func testKeyDownDoesNotForwardWhenZhuyinStartsMarkedText() throws {
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

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            candidateView.setMarkedText(
                "ㄓ",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var forwardedPressCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressCount += 1
        }

        let event = try keyEvent(text: "5", keyCode: 23, windowNumber: window.windowNumber)

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertTrue(surfaceView.hasMarkedText(), "Zhuyin keyDown should start marked text")
        XCTAssertEqual(
            forwardedPressCount,
            0,
            "AppKit-consumed Zhuyin marked-text changes must not forward a duplicate Ghostty key"
        )
    }

    func testKeyDownForKoreanPostCompositionHorizontalArrowsForwardsToTerminal() throws {
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

        let probes = [
            KoreanArrowProbe(
                text: "\u{F702}",
                keyCode: UInt16(kVK_LeftArrow),
                selectionBefore: NSRange(location: 5, length: 0),
                selectionAfter: NSRange(location: 4, length: 0)
            ),
            KoreanArrowProbe(
                text: "\u{F703}",
                keyCode: UInt16(kVK_RightArrow),
                selectionBefore: NSRange(location: 4, length: 0),
                selectionAfter: NSRange(location: 5, length: 0)
            ),
        ]
        var selectionAfterByKeyCode: [UInt16: NSRange] = [:]
        for probe in probes {
            selectionAfterByKeyCode[probe.keyCode] = probe.selectionAfter
        }

        AppDelegate.installWindowResponderSwizzlesForTesting()
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.Korean.2SetKorean"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === surfaceView,
                  let event = events.first,
                  let selectionAfter = selectionAfterByKeyCode[event.keyCode] else {
                return false
            }
            candidateView.setMarkedText(
                "안녕하세요",
                selectedRange: selectionAfter,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var forwardedPressKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressKeyCodes.append(keyEvent.keycode)
        }

        window.makeFirstResponder(surfaceView)
        try withExtendedLifetime(terminalSurface) {
            for probe in probes {
                surfaceView.setMarkedText(
                    "안녕하세요",
                    selectedRange: probe.selectionBefore,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                let event = try keyEvent(
                    text: probe.text,
                    keyCode: probe.keyCode,
                    windowNumber: window.windowNumber
                )
                window.sendEvent(event)
                XCTAssertEqual(
                    surfaceView.selectedRange(),
                    probe.selectionAfter,
                    "Korean 2-Set arrow handling should apply the IME marked-selection update"
                )
            }
        }

        XCTAssertEqual(
            forwardedPressKeyCodes,
            probes.map { UInt32($0.keyCode) },
            "Korean 2-Set Left/Right after Hangul composition should reach the terminal cursor path"
        )
    }

    func testSuppressesZhuyinMarkedTextDownArrowAfterTextInputHandling() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertTrue(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "ㄓㄨ",
                markedSelectionBefore: NSRange(location: 2, length: 0),
                markedTextAfter: "ㄓㄨ",
                markedSelectionAfter: NSRange(location: 2, length: 0),
                accumulatedText: [],
                event: event,
                inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
            ),
            "Zhuyin Down belongs to the IME candidate menu and should not also move the terminal cursor"
        )
    }

    func testDoesNotSuppressIdleZhuyinNavigationKeyWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)
        let probes: [(text: String, keyCode: UInt16)] = [
            ("\u{F701}", UInt16(kVK_DownArrow)),
            (" ", UInt16(kVK_Space)),
        ]

        for probe in probes {
            let event = try keyEvent(
                text: probe.text,
                keyCode: probe.keyCode,
                windowNumber: 0
            )

            XCTAssertFalse(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
                ),
                "Idle Zhuyin navigation keys should still reach the terminal when no composition is active"
            )
        }
    }

    func testBuffersZhuyinComponentInsertTextAsPreedit() {
        let view = GhosttyNSView(frame: .zero)
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        defer {
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            view.setKeyTextAccumulatorForTesting(nil)
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        view.setKeyTextAccumulatorForTesting([])

        view.insertText("ㄉ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("ㄚ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("ˋ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("ˊ", replacementRange: NSRange(location: 2, length: 1))

        XCTAssertTrue(view.hasMarkedText(), "Zhuyin components inserted by Apple IME should stay in editable preedit")
        XCTAssertEqual(view.attributedString().string, "ㄉㄚˊ")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(
            view.keyTextAccumulatorForTesting,
            [],
            "Raw Zhuyin components must not be committed to the terminal before candidate selection"
        )
    }

    func testBuffersZhuyinComponentInsertTextAtMarkedSelection() {
        let view = GhosttyNSView(frame: .zero)
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        defer {
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            view.setKeyTextAccumulatorForTesting(nil)
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        view.setKeyTextAccumulatorForTesting([])
        view.setMarkedText(
            "ㄉㄚ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.insertText("ㄅ", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.attributedString().string, "ㄉㄅㄚ")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(
            view.keyTextAccumulatorForTesting,
            [],
            "Raw Zhuyin insertion inside preedit should not commit to the terminal"
        )
    }

    func testCommittedZhuyinCandidateStillReachesTerminalAccumulator() {
        let view = GhosttyNSView(frame: .zero)
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        defer {
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            view.setKeyTextAccumulatorForTesting(nil)
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        view.setKeyTextAccumulatorForTesting([])
        view.setMarkedText(
            "ㄉㄚˋ",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.insertText("大", replacementRange: NSRange(location: 0, length: 3))

        XCTAssertFalse(view.hasMarkedText(), "Committed Zhuyin candidate should end preedit")
        XCTAssertEqual(view.keyTextAccumulatorForTesting, ["大"])
    }

    func testSuppressesTerminalForwardingWhenZhuyinMarkedTextChanges() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertTrue(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "ㄓ",
                markedSelectionBefore: NSRange(location: 1, length: 0),
                markedTextAfter: "ㄓㄨ",
                markedSelectionAfter: NSRange(location: 2, length: 0),
                accumulatedText: []
            )
        )
    }

    func testDoesNotSuppressCommittedIMEInsertText() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "ㄓㄨ",
                markedSelectionBefore: NSRange(location: 2, length: 0),
                markedTextAfter: "",
                markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                accumulatedText: ["注"]
            )
        )
    }

    func testDoesNotSuppressNormalTerminalKeyWhenIMEDidNothing() {
        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "",
                markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                markedTextAfter: "",
                markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                accumulatedText: []
            )
        )
    }
    func testZhuyinReturnForwardsToTerminalAfterCompositionIsCleared() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        surfaceView.setMarkedText(
            "ㄋ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        surfaceView.unmarkText()
        XCTAssertFalse(surfaceView.hasMarkedText())

        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === surfaceView,
                  let event = events.first,
                  Int(event.keyCode) == kVK_Return else {
                return false
            }
            return true
        }

        var forwardedText: [String] = []
        var forwardedPressKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                forwardedText.append(String(cString: text))
            } else {
                forwardedPressKeyCodes.append(keyEvent.keycode)
            }
        }

        let event = try keyEvent(
            text: "\r",
            keyCode: UInt16(kVK_Return),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertEqual(forwardedText, [])
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [UInt32(kVK_Return)],
            "Plain Return after Zhuyin composition is cleared must execute in the terminal"
        )
    }

    func testDoesNotSuppressNonInputMethodDeadKeyCommandWhenMarkedTextIsUnchanged() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertFalse(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "`",
                markedSelectionBefore: NSRange(location: 1, length: 0),
                markedTextAfter: "`",
                markedSelectionAfter: NSRange(location: 1, length: 0),
                accumulatedText: [],
                event: event,
                textInputHandledEvent: true,
                inputSourceId: "com.apple.keylayout.USInternational"
            )
        )
    }

    func testDoesNotRouteNonInputMethodDeadKeyMarkedTextThroughKeyDown() throws {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "`",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertFalse(
            view.shouldRouteTextInputKeyEquivalentToKeyDown(
                event,
                inputSourceId: "com.apple.keylayout.USInternational"
            ),
            "Dead-key marked text should keep normal AppKit key-equivalent dispatch"
        )
    }

    func testRoutesInputMethodMarkedTextCommandThroughKeyDown() throws {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertTrue(
            view.shouldRouteTextInputKeyEquivalentToKeyDown(
                event,
                inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
            ),
            "Input-method marked text should still route command keys through keyDown"
        )
    }

    func testSuppressesInputMethodCommandWhenMarkedTextIsUnchanged() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertTrue(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "ㄓㄨ",
                markedSelectionBefore: NSRange(location: 2, length: 0),
                markedTextAfter: "ㄓㄨ",
                markedSelectionAfter: NSRange(location: 2, length: 0),
                accumulatedText: [],
                event: event,
                textInputHandledEvent: false,
                inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
            )
        )
    }

    func testOtherInputMethodMarkedTextCommandStillRoutesThroughTextInput() throws {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )
        let inputSourceId = "com.apple.inputmethod.Kotoeri.Japanese"

        XCTAssertTrue(
            view.shouldRouteTextInputKeyEquivalentToKeyDown(
                event,
                inputSourceId: inputSourceId
            ),
            "Active marked text from non-Pinyin input methods should stay in NSTextInputContext"
        )

        XCTAssertTrue(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "かな",
                markedSelectionBefore: NSRange(location: 2, length: 0),
                markedTextAfter: "かな",
                markedSelectionAfter: NSRange(location: 2, length: 0),
                accumulatedText: [],
                event: event,
                textInputHandledEvent: false,
                inputSourceId: inputSourceId
            ),
            "Unchanged active marked text command should not leak to Ghostty for other input methods"
        )
    }

    func testKoreanInputSourceDoesNotSwallowNavigationAndSpaceKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.Korean.2SetKorean"
        )
    }

    func testJapaneseInputSourceDoesNotSwallowNavigationAndSpaceKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.Kotoeri.Japanese"
        )
    }

    private func assertApplePinyinInputSourceForwardsUnhandledNavigationAndSpaceKeysWithoutComposition(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertInputSourceForwardsUnhandledNoMarkedIMECommandKeys(
            inputSourceId,
            file: file,
            line: line
        )
    }

    private func assertApplePinyinInputSourceHandledCandidateCommandsStayInTextInputWithoutMarkedText(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where pinyinCandidateCommandProbeNames.contains(probe.name) {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertTrue(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: true,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) candidate \(probe.name) handled by NSTextInputContext must not leak to Ghostty",
                file: file,
                line: line
            )
        }
    }

    private func assertApplePinyinInputSourceHandledNonCandidateCommandsForwardWithoutMarkedText(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where pinyinNonCandidateCommandProbeNames.contains(probe.name) {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertFalse(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: true,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) handled non-candidate \(probe.name) should still forward to Ghostty",
                file: file,
                line: line
            )
        }
    }

    private func assertRoutesApplePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertTrue(
            view.shouldRouteTextInputKeyEquivalentToKeyDown(
                event,
                inputSourceId: inputSourceId
            ),
            "\(inputSourceId) candidate arrows should reach NSTextInputContext before terminal routing",
            file: file,
            line: line
        )
    }

    private func assertApplePinyinInputSourceModifiedCandidateCommandsDoNotStayInTextInputWithoutMarkedText(
        _ inputSourceId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = GhosttyNSView(frame: .zero)

        for modifierProbe in nonTextInputCommandModifierProbes {
            let event = try keyEvent(
                text: "\u{F701}",
                keyCode: UInt16(kVK_DownArrow),
                modifierFlags: modifierProbe.flags,
                windowNumber: 0
            )

            XCTAssertFalse(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: true,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) \(modifierProbe.name)-modified candidate key should not be suppressed as IME text input",
                file: file,
                line: line
            )

            XCTAssertFalse(
                view.shouldRouteTextInputKeyEquivalentToKeyDown(
                    event,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) \(modifierProbe.name)-modified candidate key should keep normal key-equivalent routing",
                file: file,
                line: line
            )
        }
    }

    func testSimplifiedChinesePinyinForwardsUnhandledNavigationAndSpaceKeysWithoutComposition() throws {
        try assertApplePinyinInputSourceForwardsUnhandledNavigationAndSpaceKeysWithoutComposition(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testTraditionalChinesePinyinForwardsUnhandledNavigationAndSpaceKeysWithoutComposition() throws {
        try assertApplePinyinInputSourceForwardsUnhandledNavigationAndSpaceKeysWithoutComposition(
            "com.apple.inputmethod.TCIM.Pinyin"
        )
    }

    func testSimplifiedChinesePinyinHandledCandidateCommandsStayInTextInputWithoutMarkedText() throws {
        try assertApplePinyinInputSourceHandledCandidateCommandsStayInTextInputWithoutMarkedText(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testTraditionalChinesePinyinHandledCandidateCommandsStayInTextInputWithoutMarkedText() throws {
        try assertApplePinyinInputSourceHandledCandidateCommandsStayInTextInputWithoutMarkedText(
            "com.apple.inputmethod.TCIM.Pinyin"
        )
    }

    func testSimplifiedChinesePinyinHandledNonCandidateCommandsForwardWithoutMarkedText() throws {
        try assertApplePinyinInputSourceHandledNonCandidateCommandsForwardWithoutMarkedText(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testTraditionalChinesePinyinHandledNonCandidateCommandsForwardWithoutMarkedText() throws {
        try assertApplePinyinInputSourceHandledNonCandidateCommandsForwardWithoutMarkedText(
            "com.apple.inputmethod.TCIM.Pinyin"
        )
    }

    func testSimplifiedChinesePinyinModifiedCandidateCommandsDoNotStayInTextInputWithoutMarkedText() throws {
        try assertApplePinyinInputSourceModifiedCandidateCommandsDoNotStayInTextInputWithoutMarkedText(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testTraditionalChinesePinyinModifiedCandidateCommandsDoNotStayInTextInputWithoutMarkedText() throws {
        try assertApplePinyinInputSourceModifiedCandidateCommandsDoNotStayInTextInputWithoutMarkedText(
            "com.apple.inputmethod.TCIM.Pinyin"
        )
    }

    func testRoutesSimplifiedChinesePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText() throws {
        try assertRoutesApplePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testRoutesTraditionalChinesePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText() throws {
        try assertRoutesApplePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText(
            "com.apple.inputmethod.TCIM.Pinyin"
        )
    }

    func testCangjieDoesNotSwallowNavigationAndSpaceKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.TCIM.Cangjie"
        )
    }

    func testZhuyinCandidateCommandsStayInTextInputWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where zhuyinCandidateCommandProbeNames.contains(probe.name) {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertTrue(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: true,
                    inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
                ),
                "Zhuyin candidate \(probe.name) handled by NSTextInputContext must not leak to Ghostty"
            )
        }
    }

    func testRoutesZhuyinCandidateCommandsThroughKeyDownWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where zhuyinCandidateCommandProbeNames.contains(probe.name) {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertTrue(
                view.shouldRouteTextInputKeyEquivalentToKeyDown(
                    event,
                    inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
                ),
                "Zhuyin candidate \(probe.name) should reach NSTextInputContext before terminal routing"
            )
        }
    }

    func testZhuyinHandledNonCandidateCommandsForwardWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where zhuyinNonCandidateCommandProbeNames.contains(probe.name) {
            let event = try keyEvent(text: probe.text, keyCode: probe.keyCode, windowNumber: 0)

            XCTAssertFalse(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "",
                    markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                    markedTextAfter: "",
                    markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                    accumulatedText: [],
                    event: event,
                    textInputHandledEvent: true,
                    inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
                ),
                "Zhuyin handled non-candidate \(probe.name) should still forward to Ghostty"
            )
        }
    }

    func testZhuyinNumpadInputForwardsWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "1",
            keyCode: UInt16(kVK_ANSI_Keypad1),
            modifierFlags: [.numericPad],
            windowNumber: 0
        )

        XCTAssertFalse(
            view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                markedTextBefore: "",
                markedSelectionBefore: NSRange(location: NSNotFound, length: 0),
                markedTextAfter: "",
                markedSelectionAfter: NSRange(location: NSNotFound, length: 0),
                accumulatedText: [],
                event: event,
                textInputHandledEvent: true,
                inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin"
            )
        )
    }

    func testForwardedKeyDownClearsStaleIMESuppressedKeyUpEntry() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        let keyCode = UInt16(kVK_DownArrow)
        surfaceView.setIMETransientStateForTesting(consumedKeyUps: [keyCode])
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        GhosttyNSView.debugTextInputEventHandler = { _, _ in false }

        var forwardedPressCount = 0
        var forwardedReleaseCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.keycode == UInt32(keyCode) else { return }
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressCount += 1
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseCount += 1
            }
        }

        let keyDown = try keyEvent(
            text: "\u{F701}",
            keyCode: keyCode,
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "\u{F701}",
            keyCode: keyCode,
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: keyDown)
        }

        XCTAssertEqual(forwardedPressCount, 1)
        XCTAssertFalse(
            surfaceView.imeConsumedKeyUpsForTesting.contains(keyCode),
            "Forwarded keyDown must clear stale IME keyUp suppression for the same key"
        )

        withExtendedLifetime(terminalSurface) {
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertEqual(
            forwardedReleaseCount,
            1,
            "The eventual keyUp must reach Ghostty after a forwarded keyDown clears stale suppression"
        )
    }

    func testLayoutChangeIMEHandledKeyDownSuppressesMatchingKeyUp() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        let keyCode = UInt16(kVK_ANSI_5)
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        GhosttyNSView.debugTextInputEventHandler = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            KeyboardLayout.debugInputSourceIdOverride = "com.apple.keylayout.US"
            return true
        }

        var forwardedPressCount = 0
        var forwardedReleaseCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.keycode == UInt32(keyCode) else { return }
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressCount += 1
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseCount += 1
            }
        }

        let keyDown = try keyEvent(
            text: "5",
            keyCode: keyCode,
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "5",
            keyCode: keyCode,
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: keyDown)
        }

        XCTAssertEqual(forwardedPressCount, 0)
        XCTAssertTrue(
            surfaceView.imeConsumedKeyUpsForTesting.contains(keyCode),
            "Layout-change IME handling consumes keyDown and must suppress the matching keyUp"
        )

        withExtendedLifetime(terminalSurface) {
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertEqual(
            forwardedReleaseCount,
            0,
            "IME-consumed layout-change keyDown must not leave Ghostty with an unmatched release"
        )
        XCTAssertFalse(surfaceView.imeConsumedKeyUpsForTesting.contains(keyCode))
    }
}
