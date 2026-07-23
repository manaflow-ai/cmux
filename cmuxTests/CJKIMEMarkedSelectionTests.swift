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

    @Test func keyDownThatStartsPreeditStaysComposing() throws {
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
            text: "5",
            keyCode: UInt16(kVK_ANSI_5),
            windowNumber: hostedTerminal.window.windowNumber
        )
        hostedTerminal.window.makeFirstResponder(hostedTerminal.surfaceView)
        hostedTerminal.surfaceView.keyDown(with: event)

        #expect(hostedTerminal.surfaceView.hasMarkedText())
        #expect(recordedKeys == [
            RecordedKey(keyCode: UInt32(kVK_ANSI_5), text: "5", composing: true),
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
