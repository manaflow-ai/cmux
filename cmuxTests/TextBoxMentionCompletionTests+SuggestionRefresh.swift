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


// MARK: - Suggestion refresh and row lifecycle
extension TextBoxMentionCompletionTests {
    @Test
    func testTextBoxMentionRefreshClearsRowsWhenSameTriggerQueryBecomesNonEmpty() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/agent-browser/SKILL.md",
            title: "$agent-browser",
            subtitle: "/tmp/agent-browser/SKILL.md",
            insertionText: "$agent-browser",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "$"
            ),
            suggestions: [staleSuggestion]
        )
        #expect(textView.debugMentionSuggestionCount() == 1)

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionCount() == 0)
        #expect(textView.debugMentionCompletionsShouldShowPopover())
        #expect(!(textView.debugAcceptMentionCompletion()))
        #expect(!(textView.debugAcceptMentionCompletion(suggestion: staleSuggestion)))
    }

    @Test
    func testTextBoxMentionDidChangeTextRefreshesRowsWithoutDelegateNotification() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/agent-browser/SKILL.md",
            title: "$agent-browser",
            subtitle: "/tmp/agent-browser/SKILL.md",
            insertionText: "$agent-browser",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "$"
            ),
            suggestions: [staleSuggestion]
        )

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.didChangeText()

        #expect(textView.debugMentionSuggestionCount() == 0)
        #expect(textView.debugMentionCompletionsShouldShowPopover())
        #expect(!textView.debugAcceptMentionCompletion(suggestion: staleSuggestion))
    }

    @Test
    func testTextBoxMentionRefreshKeepsRowsWhenSameTriggerQueryStaysNonEmpty() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$it"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let currentSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/iterate-pr/SKILL.md",
            title: "$iterate-pr",
            subtitle: "/tmp/iterate-pr/SKILL.md",
            insertionText: "$iterate-pr",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 3),
                query: "it",
                trigger: "$"
            ),
            suggestions: [currentSuggestion]
        )
        #expect(textView.debugMentionSuggestionCount() == 1)

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionCount() == 1)
        #expect(!textView.debugMentionSuggestionsAreCurrent())
        #expect(!textView.debugAcceptMentionCompletion())
    }

    @Test
    func testTextBoxMentionRefreshFiltersStaleRowsWhenSameTriggerQueryNarrows() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$it"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/agent-browser/SKILL.md",
            title: "$agent-browser",
            subtitle: "/tmp/agent-browser/SKILL.md",
            insertionText: "$agent-browser",
            systemImageName: "sparkle.magnifyingglass"
        )
        let currentSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/iterate-pr/SKILL.md",
            title: "$iterate-pr",
            subtitle: "/tmp/iterate-pr/SKILL.md",
            insertionText: "$iterate-pr",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 3),
                query: "it",
                trigger: "$"
            ),
            suggestions: [staleSuggestion, currentSuggestion]
        )

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.refreshMentionCompletions()

        #expect(textView.debugMentionSuggestionTitles() == ["$iterate-pr"])
        #expect(!textView.debugMentionSuggestionsAreCurrent())
        #expect(!textView.debugAcceptMentionCompletion(suggestion: staleSuggestion))
    }

    @Test
    func testTextBoxMentionFilteredRowsStayNonCurrentWhenQueryReturnsToPreviousValue() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$it"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/agent-browser/SKILL.md",
            title: "$agent-browser",
            subtitle: "/tmp/agent-browser/SKILL.md",
            insertionText: "$agent-browser",
            systemImageName: "sparkle.magnifyingglass"
        )
        let currentSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/iterate-pr/SKILL.md",
            title: "$iterate-pr",
            subtitle: "/tmp/iterate-pr/SKILL.md",
            insertionText: "$iterate-pr",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 3),
                query: "it",
                trigger: "$"
            ),
            suggestions: [staleSuggestion, currentSuggestion]
        )

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionTitles() == ["$iterate-pr"])
        #expect(!textView.debugMentionSuggestionsAreCurrent())

        textView.string = "$it"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionTitles() == ["$iterate-pr"])
        #expect(!textView.debugMentionSuggestionsAreCurrent())
        #expect(!textView.debugAcceptMentionCompletion())
    }

    @Test
    func testTextBoxMentionRefreshClearsFilteredRowsWhenQueryReturnsToBareTrigger() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "$it"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/agent-browser/SKILL.md",
            title: "$agent-browser",
            subtitle: "/tmp/agent-browser/SKILL.md",
            insertionText: "$agent-browser",
            systemImageName: "sparkle.magnifyingglass"
        )
        let currentSuggestion = TextBoxMentionSuggestion(
            id: "$:/tmp/iterate-pr/SKILL.md",
            title: "$iterate-pr",
            subtitle: "/tmp/iterate-pr/SKILL.md",
            insertionText: "$iterate-pr",
            systemImageName: "sparkle.magnifyingglass"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 3),
                query: "it",
                trigger: "$"
            ),
            suggestions: [staleSuggestion, currentSuggestion]
        )

        textView.string = "$iterate-pr"
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionTitles() == ["$iterate-pr"])

        textView.string = "$"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.refreshMentionCompletions()
        #expect(textView.debugMentionSuggestionCount() == 0)
        #expect(textView.debugMentionCompletionsShouldShowPopover())
        #expect(!textView.debugAcceptMentionCompletion())
    }

    @Test
    func testTextBoxMentionRefreshOpensPopoverImmediatelyForBareFileTrigger() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-loading-file-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "notes".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.completionRootDirectory = root.path
        textView.string = "@"
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.refreshMentionCompletions()

        #expect(textView.debugMentionCompletionsShouldShowPopover())
        #expect(textView.debugMentionSuggestionCount() == 0)
    }

}
