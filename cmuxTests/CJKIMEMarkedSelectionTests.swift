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

    deinit {}

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

    private struct NoMarkedIMEKeyProbe {
        let name: String
        let text: String
        let keyCode: UInt16
    }

    private var noMarkedNavigationKeyProbes: [NoMarkedIMEKeyProbe] {
        [
            NoMarkedIMEKeyProbe(name: "Left", text: "\u{F702}", keyCode: UInt16(kVK_LeftArrow)),
            NoMarkedIMEKeyProbe(name: "Right", text: "\u{F703}", keyCode: UInt16(kVK_RightArrow)),
            NoMarkedIMEKeyProbe(name: "Up", text: "\u{F700}", keyCode: UInt16(kVK_UpArrow)),
            NoMarkedIMEKeyProbe(name: "Down", text: "\u{F701}", keyCode: UInt16(kVK_DownArrow)),
            NoMarkedIMEKeyProbe(name: "Home", text: "\u{F729}", keyCode: UInt16(kVK_Home)),
            NoMarkedIMEKeyProbe(name: "End", text: "\u{F72B}", keyCode: UInt16(kVK_End)),
            NoMarkedIMEKeyProbe(name: "PageUp", text: "\u{F72C}", keyCode: UInt16(kVK_PageUp)),
            NoMarkedIMEKeyProbe(name: "PageDown", text: "\u{F72D}", keyCode: UInt16(kVK_PageDown)),
            NoMarkedIMEKeyProbe(name: "Space", text: " ", keyCode: UInt16(kVK_Space)),
        ]
    }

    private func assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
        _ inputSourceId: String,
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
                    textInputHandledEvent: true,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) should forward \(probe.name) to Ghostty when no composition is active",
                file: file,
                line: line
            )
        }
    }

    private func assertInputSourceForwardsUnhandledNoMarkedIMECommandKeys(
        _ inputSourceId: String,
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
                    textInputHandledEvent: false,
                    inputSourceId: inputSourceId
                ),
                "\(inputSourceId) should forward unhandled \(probe.name) to Ghostty when no composition is active",
                file: file,
                line: line
            )
        }
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

    func testSimplifiedChinesePinyinForwardsUnhandledNavigationAndSpaceKeysWithoutComposition() throws {
        try assertInputSourceForwardsUnhandledNoMarkedIMECommandKeys(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testSimplifiedChinesePinyinHandledCandidateArrowStaysInTextInputWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)

        for probe in noMarkedNavigationKeyProbes where ["Left", "Right", "Up", "Down"].contains(probe.name) {
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
                    inputSourceId: "com.apple.inputmethod.SCIM.ITABC"
                ),
                "Simplified Chinese Pinyin candidate \(probe.name) handled by NSTextInputContext must not leak to Ghostty"
            )
        }
    }

    func testRoutesSimplifiedChinesePinyinCandidateArrowKeyEquivalentThroughKeyDownWithoutMarkedText() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

        XCTAssertTrue(
            view.shouldRouteTextInputKeyEquivalentToKeyDown(
                event,
                inputSourceId: "com.apple.inputmethod.SCIM.ITABC"
            ),
            "Simplified Chinese Pinyin candidate arrows should reach NSTextInputContext before terminal routing"
        )
    }

    func testCangjieDoesNotSwallowNavigationAndSpaceKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.TCIM.Cangjie"
        )
    }

    func testZhuyinPreCompositionStillUsesNoMarkedTextSuppression() throws {
        let view = GhosttyNSView(frame: .zero)
        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: 0
        )

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
            )
        )
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
        surfaceView.setIMETransientStateForTesting(suppressedKeyUpKeyCodes: [keyCode])
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
            surfaceView.imeSuppressedKeyUpKeyCodesForTesting.contains(keyCode),
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
            surfaceView.imeSuppressedKeyUpKeyCodesForTesting.contains(keyCode),
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
        XCTAssertFalse(surfaceView.imeSuppressedKeyUpKeyCodesForTesting.contains(keyCode))
    }
}
