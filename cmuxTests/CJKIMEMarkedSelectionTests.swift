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

    func testArrowNavigationStaysInsideZhuyinCandidateWindowDuringComposition() throws {
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

        surfaceView.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            return true
        }

        var forwardedPressKeyCodes: [UInt32] = []
        var forwardedReleaseKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressKeyCodes.append(keyEvent.keycode)
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseKeyCodes.append(keyEvent.keycode)
            }
        }

        let keyDown = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: keyDown)
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertTrue(surfaceView.hasMarkedText(), "Candidate navigation should leave composition active")
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [],
            "Arrow keys consumed by the Zhuyin candidate window must not move the terminal cursor"
        )
        XCTAssertEqual(
            forwardedReleaseKeyCodes,
            [],
            "A suppressed IME arrow keyDown should not be followed by an unmatched Ghostty keyUp"
        )
    }

    func testDownArrowCanOpenZhuyinCandidatesBeforeMarkedTextIsMirrored() throws {
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
            return true
        }

        var forwardedPressKeyCodes: [UInt32] = []
        var forwardedReleaseKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressKeyCodes.append(keyEvent.keycode)
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseKeyCodes.append(keyEvent.keycode)
            }
        }

        let keyDown = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: keyDown)
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertFalse(
            surfaceView.hasMarkedText(),
            "Opening Zhuyin candidates can be handled by the IME before it mirrors marked text"
        )
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [],
            "A Zhuyin-handled Down arrow must stay with AppKit so it can open the candidate list"
        )
        XCTAssertEqual(
            forwardedReleaseKeyCodes,
            [],
            "A Zhuyin-handled Down arrow keyUp must not leave an unmatched terminal release"
        )
    }

    func testWindowKeyEquivalentRoutesInputMethodArrowThroughKeyDownBeforeMarkedText() throws {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()

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

        var sawDownInTextInput = false
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === surfaceView, let event = events.first else { return false }
            guard Int(event.keyCode) == kVK_DownArrow else { return false }
            sawDownInTextInput = true
            return true
        }

        var forwardedPressKeyCodes: [UInt32] = []
        var forwardedReleaseKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressKeyCodes.append(keyEvent.keycode)
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseKeyCodes.append(keyEvent.keycode)
            }
        }

        let keyDown = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            XCTAssertTrue(
                window.performKeyEquivalent(with: keyDown),
                "A window-level IME arrow key equivalent should be handled by routing it through terminal keyDown"
            )
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertTrue(
            sawDownInTextInput,
            "The window key-equivalent path must deliver Bopomofo candidate arrows to NSTextInputContext"
        )
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [],
            "A Down arrow handled by the input method must not move the terminal cursor"
        )
        XCTAssertEqual(
            forwardedReleaseKeyCodes,
            [],
            "A suppressed IME keyDown must also suppress the paired keyUp"
        )
    }

    func testArrowStillForwardsToTerminalWhenNoCompositionIsActive() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        var forwardedPressKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressKeyCodes.append(keyEvent.keycode)
        }

        let event = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertFalse(surfaceView.hasMarkedText())
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [UInt32(kVK_DownArrow)],
            "Plain arrows should keep moving the terminal cursor when no IME composition is active"
        )
    }

    func testDownArrowRequestsZhuyinCandidatesViaSpaceCommandFallback() throws {
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

        surfaceView.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()

        var sawDownCommand = false
        var syntheticSpaceCount = 0
        cjkIMEInterpretKeyEventsHook = { candidateView, events in
            guard candidateView === surfaceView, let event = events.first else { return false }
            if Int(event.keyCode) == kVK_DownArrow {
                sawDownCommand = true
                candidateView.doCommand(by: #selector(NSResponder.moveDown(_:)))
                return false
            }
            if Int(event.keyCode) == kVK_Space {
                syntheticSpaceCount += 1
                return true
            }
            return false
        }

        var forwardedPressKeyCodes: [UInt32] = []
        var forwardedReleaseKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            if keyEvent.action == GHOSTTY_ACTION_PRESS {
                forwardedPressKeyCodes.append(keyEvent.keycode)
            } else if keyEvent.action == GHOSTTY_ACTION_RELEASE {
                forwardedReleaseKeyCodes.append(keyEvent.keycode)
            }
        }

        let keyDown = try keyEvent(
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            text: "\u{F701}",
            keyCode: UInt16(kVK_DownArrow),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: keyDown)
            surfaceView.keyUp(with: keyUp)
        }

        XCTAssertTrue(sawDownCommand)
        XCTAssertEqual(
            syntheticSpaceCount,
            1,
            "A Zhuyin Down command that AppKit does not otherwise resolve should ask the IME to open candidates"
        )
        XCTAssertTrue(surfaceView.hasMarkedText())
        XCTAssertEqual(forwardedPressKeyCodes, [])
        XCTAssertEqual(forwardedReleaseKeyCodes, [])
    }

    func testNumberCandidateSelectionStillCommitsTextDuringZhuyinComposition() throws {
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

        surfaceView.setMarkedText(
            "ㄓㄨ",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            candidateView.insertText("注", replacementRange: NSRange(location: NSNotFound, length: 0))
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
            text: "1",
            keyCode: UInt16(kVK_ANSI_1),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertFalse(surfaceView.hasMarkedText(), "Number candidate selection should commit the chosen text")
        XCTAssertEqual(forwardedText, ["注"])
        XCTAssertEqual(
            forwardedPressKeyCodes,
            [],
            "Candidate number selection should not also send the raw number key to the terminal"
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

    func testKoreanInputSourceDoesNotSwallowArrowKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.Korean.2SetKorean"
        )
    }

    func testJapaneseInputSourceDoesNotSwallowArrowKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.Kotoeri.Japanese"
        )
    }

    func testSimplifiedChinesePinyinDoesNotSwallowArrowKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.SCIM.ITABC"
        )
    }

    func testCangjieDoesNotSwallowArrowKeysWithoutComposition() throws {
        try assertInputSourceDoesNotSwallowNoMarkedIMECommandKeys(
            "com.apple.inputmethod.TCIM.Cangjie"
        )
    }

    func testUnmarkTextPreservesSuppressedKeyUpStateWithoutMarkedText() {
        let view = GhosttyNSView(frame: .zero)
        view.setIMETransientStateForTesting(
            suppressedKeyUpKeyCodes: [UInt16(kVK_DownArrow)],
            zhuyinCandidateOpenRequested: true
        )

        view.unmarkText()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.imeSuppressedKeyUpKeyCodesForTesting, [UInt16(kVK_DownArrow)])
        XCTAssertFalse(view.zhuyinCandidateOpenRequestedForTesting)
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

    func testAllowsDeferredNumpadFallbackWithoutMarkedText() throws {
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
                inputSourceId: "com.apple.inputmethod.TCIM.Pinyin"
            )
        )
    }
}
