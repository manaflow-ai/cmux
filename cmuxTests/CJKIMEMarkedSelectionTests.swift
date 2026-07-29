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
    private final class ReplacementEditingSurfaceView: GhosttyNSView {
        var textInputEventHandler: ((NSEvent) -> Bool)?

        override func handleTextInputEvent(_ event: NSEvent) -> Bool {
            textInputEventHandler?(event) ?? super.handleTextInputEvent(event)
        }

        override func currentTextInputSourceKind()
            -> TerminalTextInputSourceKind {
            .inputMethod
        }
    }

    private struct ReplacementEditingSurfaceViewFactory: TerminalSurfaceViewProviding {
        func makeSurfaceViews(
            initialFrame: NSRect
        ) -> (
            surfaceView: any TerminalSurfaceNativeViewing,
            paneHost: any TerminalSurfacePaneHosting
        ) {
            let surfaceView = ReplacementEditingSurfaceView(frame: initialFrame)
            return (
                surfaceView,
                GhosttySurfaceScrollView(surfaceView: surfaceView)
            )
        }
    }

    private struct HostedReplacementEditingTerminal {
        let surface: TerminalSurface
        let surfaceView: ReplacementEditingSurfaceView
        let window: NSWindow
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

    @Test func consumedReplacementEditsStayProvisionalUntilFullRangeCommit() throws {
        let terminal = try makeHostedReplacementEditingTerminal()
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            terminal.window.orderOut(nil)
        }

        terminal.surfaceView.textInputEventHandler = { event in
            switch event.keyCode {
            case UInt16(kVK_ANSI_1):
                terminal.surfaceView.insertText(
                    "α",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            case UInt16(kVK_ANSI_2):
                terminal.surfaceView.insertText(
                    "β",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            case UInt16(kVK_ANSI_3):
                terminal.surfaceView.insertText(
                    "γ",
                    replacementRange: NSRange(location: 1, length: 1)
                )
            case UInt16(kVK_Return):
                terminal.surfaceView.insertText(
                    "Ω",
                    replacementRange: NSRange(location: 0, length: 2)
                )
            default:
                return false
            }
            return true
        }

        var forwardedPressText: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  let text = keyEvent.text else {
                return
            }
            forwardedPressText.append(String(cString: text))
        }

        try sendKey(
            text: "1",
            keyCode: UInt16(kVK_ANSI_1),
            to: terminal
        )
        #expect(terminal.surfaceView.attributedString().string == "α")
        #expect(terminal.surfaceView.hasMarkedText())
        #expect(forwardedPressText.isEmpty)

        try sendKey(
            text: "2",
            keyCode: UInt16(kVK_ANSI_2),
            to: terminal
        )
        #expect(terminal.surfaceView.attributedString().string == "αβ")
        #expect(forwardedPressText.isEmpty)

        try sendKey(
            text: "3",
            keyCode: UInt16(kVK_ANSI_3),
            to: terminal
        )
        #expect(terminal.surfaceView.attributedString().string == "αγ")
        #expect(forwardedPressText.isEmpty)

        try sendKey(
            text: "\r",
            keyCode: UInt16(kVK_Return),
            to: terminal
        )
        #expect(!terminal.surfaceView.hasMarkedText())
        #expect(forwardedPressText == ["Ω"])
    }

    private func makeHostedReplacementEditingTerminal() throws
        -> HostedReplacementEditingTerminal {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            dependencies: replacementEditingRuntimeDependencies()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return HostedReplacementEditingTerminal(
            surface: surface,
            surfaceView: try #require(
                findGhosttyNSView(in: hostedView)
                    as? ReplacementEditingSurfaceView
            ),
            window: window
        )
    }

    private func replacementEditingRuntimeDependencies()
        -> TerminalSurfaceRuntimeDependencies {
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        return TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: ReplacementEditingSurfaceViewFactory(),
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

    private func sendKey(
        text: String,
        keyCode: UInt16,
        to terminal: HostedReplacementEditingTerminal
    ) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: terminal.window.windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        ))
        #expect(terminal.window.makeFirstResponder(terminal.surfaceView))
        withExtendedLifetime(terminal.surface) {
            terminal.surfaceView.keyDown(with: event)
        }
    }

}
