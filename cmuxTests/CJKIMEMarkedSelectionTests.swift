import XCTest
import AppKit
import Carbon.HIToolbox
import CmuxTerminal

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

    private func keyEvent(text: String, keyCode: UInt16, windowNumber: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
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

    private struct KoreanArrowProbe {
        let text: String
        let keyCode: UInt16
        let selectionBefore: NSRange
        let selectionAfter: NSRange
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
}
