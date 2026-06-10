import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Key event routing, shortcuts, and popover key handling
extension TextBoxMentionCompletionTests {
    @Test
    func testTextBoxControlNavigationRoutingUsesTranslatedCharacters() {
        #expect(shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "n",
            firstResponderIsTextBoxInput: true,
            flags: [.control]
        ))
        #expect(shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "p",
            firstResponderIsTextBoxInput: true,
            flags: [.control]
        ))
        #expect(!(shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "b",
            firstResponderIsTextBoxInput: true,
            flags: [.control]
        )))
        #expect(!(shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "n",
            firstResponderIsTextBoxInput: true,
            flags: [.control, .command]
        )))
    }

    @Test
    func testTextBoxMentionControlNavigationUsesTranslatedCharacters() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](/tmp/alpha.txt)",
                    systemImageName: "doc"
                ),
                TextBoxMentionSuggestion(
                    id: "beta",
                    title: "@beta.txt",
                    subtitle: "beta.txt",
                    insertionText: "[@beta.txt](/tmp/beta.txt)",
                    systemImageName: "doc"
                )
            ]
        )

        guard let controlNEvent = makeKeyDownEvent(
            key: "n",
            modifiers: [.control],
            keyCode: UInt16(kVK_ANSI_B),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct Control-N event")
            return
        }

        textView.keyDown(with: controlNEvent)

        #expect(textView.debugMentionSelectionIndex() == 1)
    }

    @Test
    func testTextBoxControlForwardingKeepsPhysicalControlKeyRouting() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        guard let event = makeKeyDownEvent(
            key: "N",
            modifiers: [.control],
            keyCode: UInt16(kVK_ANSI_G),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct remapped Control-N event")
            return
        }

        #expect(textView.debugMentionCompletionControlNavigationKey(for: event) == "n")
        #expect(textView.debugControlKey(for: event) == "g")

        var forwardedControls: [String] = []
        textView.onForwardControl = { forwardedControls.append($0) }
        textView.keyDown(with: event)

        #expect(forwardedControls == ["g"])
    }

    @Test
    func testTextBoxStandardEditShortcutUsesTranslatedCommandCharacter() {
        guard let event = makeKeyDownEvent(
            key: "c",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_B),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct translated Command-C event")
            return
        }

        var translatedKeyCode: UInt16?
        var translatedFlags: NSEvent.ModifierFlags?

        let shortcutKey = textBoxCommandShortcutKey(
            for: event,
            translateKey: { keyCode, flags in
                translatedKeyCode = keyCode
                translatedFlags = flags
                return "c"
            },
            normalizedCharacters: { _ in "b" }
        )

        #expect(shortcutKey == "c")
        #expect(translatedKeyCode == UInt16(kVK_ANSI_B))
        #expect(translatedFlags?.contains(.command) == true)
    }

    @Test
    func testTextBoxUndoShortcutUsesTranslatedCommandCharacter() {
        guard let event = makeKeyDownEvent(
            key: "z",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_Y),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct translated Command-Z event")
            return
        }

        var translatedKeyCode: UInt16?
        var translatedFlags: NSEvent.ModifierFlags?

        let shortcutKey = textBoxCommandShortcutKey(
            for: event,
            translateKey: { keyCode, flags in
                translatedKeyCode = keyCode
                translatedFlags = flags
                return "z"
            },
            normalizedCharacters: { _ in "y" }
        )

        #expect(shortcutKey == "z")
        #expect(translatedKeyCode == UInt16(kVK_ANSI_Y))
        #expect(translatedFlags?.contains(.command) == true)
    }

    @Test
    func testTextBoxMentionEscapeFallsThroughWhenQueryHasNoSuggestions() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@missing"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 8), query: "missing"),
            suggestions: []
        )
        var escapeCount = 0
        textView.onEscape = { escapeCount += 1 }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct Escape event")
            return
        }

        textView.keyDown(with: escapeEvent)
        #expect(escapeCount == 1)
    }

    @Test
    func testTextBoxMentionEscapeDismissesLoadingPopover() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 1), query: ""),
            suggestions: [],
            isLoading: true
        )
        var escapeCount = 0
        textView.onEscape = { escapeCount += 1 }

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: 0
        ) else {
            #expect(Bool(false), "Failed to construct Escape event")
            return
        }

        textView.keyDown(with: escapeEvent)
        #expect(escapeCount == 0)
        #expect(!(textView.debugMentionCompletionsShouldShowPopover()))
    }

    @Test
    func testTextBoxMentionBareSkillTriggerReturnSubmitsInsteadOfAcceptingFirstSuggestion() {
        let scenarios: [(text: String, range: NSRange, trigger: Character, insertionText: String)] = [
            ("cd /", NSRange(location: 3, length: 1), "/", "[/sample-skill](/tmp/sample-skill/SKILL.md)"),
            ("echo $", NSRange(location: 5, length: 1), "$", "$sample-skill")
        ]

        for scenario in scenarios {
            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.string = scenario.text
            textView.setSelectedRange(NSRange(location: (scenario.text as NSString).length, length: 0))
            textView.debugSetMentionCompletionState(
                query: TextBoxMentionQuery(
                    kind: .skill,
                    range: scenario.range,
                    query: "",
                    trigger: scenario.trigger
                ),
                suggestions: [
                    TextBoxMentionSuggestion(
                        id: "\(scenario.trigger):/tmp/sample-skill/SKILL.md",
                        title: "\(scenario.trigger)sample-skill",
                        subtitle: "/tmp/sample-skill/SKILL.md",
                        insertionText: scenario.insertionText,
                        systemImageName: "sparkle.magnifyingglass"
                    )
                ]
            )
            var submitCount = 0
            textView.onSubmit = { submitCount += 1 }

            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            #expect(submitCount == 1)
            #expect(textView.string == scenario.text)
            #expect(textView.debugMentionSuggestionCount() == 0)
        }
    }

    @Test
    func testTextBoxMentionBareSkillTriggerTabAcceptsFirstSuggestion() {
        let scenarios: [(text: String, range: NSRange, trigger: Character, insertionText: String, expected: String)] = [
            (
                "cd /",
                NSRange(location: 3, length: 1),
                "/",
                "[/sample-skill](/tmp/sample-skill/SKILL.md)",
                "cd [/sample-skill](/tmp/sample-skill/SKILL.md) "
            ),
            (
                "echo $",
                NSRange(location: 5, length: 1),
                "$",
                "$sample-skill",
                "echo $sample-skill "
            )
        ]

        for scenario in scenarios {
            let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
            textView.string = scenario.text
            textView.setSelectedRange(NSRange(location: (scenario.text as NSString).length, length: 0))
            textView.debugSetMentionCompletionState(
                query: TextBoxMentionQuery(
                    kind: .skill,
                    range: scenario.range,
                    query: "",
                    trigger: scenario.trigger
                ),
                suggestions: [
                    TextBoxMentionSuggestion(
                        id: "\(scenario.trigger):/tmp/sample-skill/SKILL.md",
                        title: "\(scenario.trigger)sample-skill",
                        subtitle: "/tmp/sample-skill/SKILL.md",
                        insertionText: scenario.insertionText,
                        systemImageName: "sparkle.magnifyingglass"
                    )
                ]
            )

            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))

            #expect(textView.string == scenario.expected)
            #expect(textView.debugMentionSuggestionCount() == 0)
        }
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }
}
