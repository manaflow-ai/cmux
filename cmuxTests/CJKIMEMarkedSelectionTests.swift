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
        text: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private struct ForwardedKeyCase {
        let name: String
        let keyCode: UInt16
        let text: String
        let modifiers: NSEvent.ModifierFlags

        init(
            name: String,
            keyCode: UInt16,
            text: String,
            modifiers: NSEvent.ModifierFlags = []
        ) {
            self.name = name
            self.keyCode = keyCode
            self.text = text
            self.modifiers = modifiers
        }
    }

    private var terminalNavigationKeyCases: [ForwardedKeyCase] {
        [
            ForwardedKeyCase(name: "Left", keyCode: UInt16(kVK_LeftArrow), text: "\u{F702}", modifiers: [.numericPad]),
            ForwardedKeyCase(name: "Right", keyCode: UInt16(kVK_RightArrow), text: "\u{F703}", modifiers: [.numericPad]),
            ForwardedKeyCase(name: "Up", keyCode: UInt16(kVK_UpArrow), text: "\u{F700}", modifiers: [.numericPad]),
            ForwardedKeyCase(name: "Down", keyCode: UInt16(kVK_DownArrow), text: "\u{F701}", modifiers: [.numericPad]),
            ForwardedKeyCase(name: "PageUp", keyCode: UInt16(kVK_PageUp), text: "\u{F72C}"),
            ForwardedKeyCase(name: "PageDown", keyCode: UInt16(kVK_PageDown), text: "\u{F72D}"),
            ForwardedKeyCase(name: "Home", keyCode: UInt16(kVK_Home), text: "\u{F729}"),
            ForwardedKeyCase(name: "End", keyCode: UInt16(kVK_End), text: "\u{F72B}"),
            ForwardedKeyCase(name: "Space", keyCode: UInt16(kVK_Space), text: " "),
        ]
    }

    private func navigationKeyText(for keyCode: UInt16) -> String {
        terminalNavigationKeyCases.first { $0.keyCode == keyCode }?.text ?? ""
    }

    private func navigationKeyModifiers(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        terminalNavigationKeyCases.first { $0.keyCode == keyCode }?.modifiers ?? []
    }

    private func assertPlainNavigationKeysReachShell(
        inputSourceId: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        let previousCandidateExpansionHandler = GhosttyNSView.debugZhuyinCandidateExpansionEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = previousCandidateExpansionHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = inputSourceId
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            return true
        }

        var forwardedPressKeyCodes: [UInt16] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressKeyCodes.append(UInt16(keyEvent.keycode))
        }

        window.makeFirstResponder(surfaceView)
        for keyCase in terminalNavigationKeyCases {
            surfaceView.unmarkText()
            forwardedPressKeyCodes.removeAll()

            let event = try keyEvent(
                text: keyCase.text,
                keyCode: keyCase.keyCode,
                modifiers: keyCase.modifiers,
                windowNumber: window.windowNumber
            )

            withExtendedLifetime(terminalSurface) {
                surfaceView.keyDown(with: event)
            }

            XCTAssertTrue(
                forwardedPressKeyCodes.contains(keyCase.keyCode),
                "\(keyCase.name) should reach Ghostty for input source \(inputSourceId ?? "nil")",
                file: file,
                line: line
            )
        }
    }

    private func assertZhuyinCandidateArrowDoesNotReachShell(
        keyCode: UInt16,
        expectCandidateExpansion: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        let previousCandidateExpansionHandler = GhosttyNSView.debugZhuyinCandidateExpansionEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = previousCandidateExpansionHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()

        var forwardedPressKeyCodes: [UInt16] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressKeyCodes.append(UInt16(keyEvent.keycode))
        }

        surfaceView.setMarkedText(
            "ㄋ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let event = try keyEvent(
            text: navigationKeyText(for: keyCode),
            keyCode: keyCode,
            modifiers: navigationKeyModifiers(for: keyCode),
            windowNumber: window.windowNumber
        )
        var interpretedKeyCodes: [UInt16] = []
        var interpretedOriginalEvent = false
        var candidateExpansionKeyCodes: [UInt16] = []
        GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = { candidateView, expansionEvent in
            guard candidateView === surfaceView else { return false }
            candidateExpansionKeyCodes.append(UInt16(expansionEvent.keyCode))
            return true
        }
        cjkIMEInterpretKeyEventsHook = { candidateView, eventArray in
            guard candidateView === surfaceView else { return false }
            interpretedKeyCodes.append(contentsOf: eventArray.map { UInt16($0.keyCode) })
            interpretedOriginalEvent = eventArray.count == 1 && eventArray.first === event
            switch keyCode {
            case UInt16(kVK_DownArrow):
                candidateView.doCommand(by: #selector(NSResponder.moveDown(_:)))
            case UInt16(kVK_UpArrow):
                candidateView.doCommand(by: #selector(NSResponder.moveUp(_:)))
            default:
                break
            }
            return true
        }

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertTrue(surfaceView.hasMarkedText(), "Zhuyin composition should remain active", file: file, line: line)
        XCTAssertEqual(
            interpretedKeyCodes,
            [keyCode],
            "Zhuyin candidate arrow must be handed to interpretKeyEvents so AppKit can open or navigate the candidate UI",
            file: file,
            line: line
        )
        XCTAssertTrue(
            interpretedOriginalEvent,
            "Zhuyin candidate arrow should use the original key event for AppKit text input",
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidateExpansionKeyCodes,
            expectCandidateExpansion ? [UInt16(kVK_Space)] : [],
            "Only plain Zhuyin Down should ask the input context to expand the candidate list",
            file: file,
            line: line
        )
        XCTAssertFalse(
            forwardedPressKeyCodes.contains(keyCode),
            "Zhuyin candidate arrow must stay in AppKit text input instead of reaching Ghostty",
            file: file,
            line: line
        )
    }

    private func assertModifiedZhuyinCandidateArrowReachesShell(
        keyCode: UInt16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        let previousCandidateExpansionHandler = GhosttyNSView.debugZhuyinCandidateExpansionEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = previousCandidateExpansionHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            return true
        }

        var forwardedPressKeyCodes: [UInt16] = []
        var candidateExpansionKeyCodes: [UInt16] = []
        GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = { candidateView, expansionEvent in
            guard candidateView === surfaceView else { return false }
            candidateExpansionKeyCodes.append(UInt16(expansionEvent.keyCode))
            return true
        }
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressKeyCodes.append(UInt16(keyEvent.keycode))
        }

        surfaceView.setMarkedText(
            "ㄋ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let event = try keyEvent(
            text: navigationKeyText(for: keyCode),
            keyCode: keyCode,
            modifiers: navigationKeyModifiers(for: keyCode).union(.shift),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertTrue(surfaceView.hasMarkedText(), "Zhuyin composition should remain active", file: file, line: line)
        XCTAssertTrue(
            forwardedPressKeyCodes.contains(keyCode),
            "Modified Zhuyin arrows should keep reaching Ghostty",
            file: file,
            line: line
        )
        XCTAssertEqual(
            candidateExpansionKeyCodes,
            [],
            "Modified Zhuyin arrows must not open the candidate list",
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
        let previousCandidateExpansionHandler = GhosttyNSView.debugZhuyinCandidateExpansionEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = previousCandidateExpansionHandler
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

    func testKoreanInputSourceArrowKeysAlwaysReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.inputmethod.Korean.2SetKorean")
    }

    func testJapaneseInputSourceArrowKeysAlwaysReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.inputmethod.Kotoeri.Japanese")
    }

    func testSimplifiedChinesePinyinArrowKeysAlwaysReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.inputmethod.SCIM.ITABC")
    }

    func testCangjieArrowKeysAlwaysReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.inputmethod.TCIM.Cangjie")
    }

    func testNonIMELayoutArrowKeysAlwaysReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.keylayout.ABC")
    }

    func testZhuyinArrowKeysOutsideCompositionReachShell() throws {
        try assertPlainNavigationKeysReachShell(inputSourceId: "com.apple.inputmethod.TCIM.Zhuyin")
    }

    func testZhuyinDownArrowDuringCompositionOpensCandidates() throws {
        try assertZhuyinCandidateArrowDoesNotReachShell(
            keyCode: UInt16(kVK_DownArrow),
            expectCandidateExpansion: true
        )
    }

    func testZhuyinUpArrowDuringCompositionMovesCandidateSelection() throws {
        try assertZhuyinCandidateArrowDoesNotReachShell(
            keyCode: UInt16(kVK_UpArrow),
            expectCandidateExpansion: false
        )
    }

    func testZhuyinCandidateArrowCommitFromInterpretKeyEventsReachesShell() throws {
        let hostedTerminal = try makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        let previousCandidateExpansionHandler = GhosttyNSView.debugZhuyinCandidateExpansionEventHandler
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = previousCandidateExpansionHandler
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        let keyCode = UInt16(kVK_DownArrow)
        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.TCIM.Zhuyin"
        installCJKIMEInterpretKeyEventsSwizzle()
        var interpretedKeyCodes: [UInt16] = []
        cjkIMEInterpretKeyEventsHook = { candidateView, eventArray in
            guard candidateView === surfaceView else { return false }
            interpretedKeyCodes.append(contentsOf: eventArray.map { UInt16($0.keyCode) })
            guard eventArray.count == 1, UInt16(eventArray[0].keyCode) == keyCode else { return false }
            surfaceView.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        var forwardedText: [String] = []
        var forwardedBareArrow = false
        var candidateExpansionKeyCodes: [UInt16] = []
        GhosttyNSView.debugZhuyinCandidateExpansionEventHandler = { candidateView, expansionEvent in
            guard candidateView === surfaceView else { return false }
            candidateExpansionKeyCodes.append(UInt16(expansionEvent.keyCode))
            return true
        }
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            if let text = keyEvent.text {
                forwardedText.append(String(cString: text))
            } else if UInt16(keyEvent.keycode) == keyCode {
                forwardedBareArrow = true
            }
        }

        surfaceView.setMarkedText(
            "ㄋ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let event = try keyEvent(
            text: navigationKeyText(for: keyCode),
            keyCode: keyCode,
            modifiers: navigationKeyModifiers(for: keyCode),
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        XCTAssertFalse(surfaceView.hasMarkedText(), "Committed text should clear Zhuyin composition")
        XCTAssertEqual(interpretedKeyCodes, [keyCode])
        XCTAssertEqual(forwardedText, ["你"])
        XCTAssertFalse(forwardedBareArrow, "Committed candidate text must not also leak a bare Down arrow")
        XCTAssertEqual(candidateExpansionKeyCodes, [], "Committed candidate text must not also expand the candidate list")
    }

    func testZhuyinModifiedCandidateArrowsDuringCompositionReachShell() throws {
        try assertModifiedZhuyinCandidateArrowReachesShell(keyCode: UInt16(kVK_DownArrow))
        try assertModifiedZhuyinCandidateArrowReachesShell(keyCode: UInt16(kVK_UpArrow))
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
