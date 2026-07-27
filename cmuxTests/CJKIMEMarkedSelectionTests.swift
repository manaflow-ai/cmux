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

}
