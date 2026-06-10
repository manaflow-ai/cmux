import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Text box mention completion and IME composition tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxMentionCompletionDetectsFileAndSkillTokens() {
        let filePrompt = "open @Sources/TextBox"
        let fileQuery = TextBoxMentionCompletionDetector.query(
            in: filePrompt,
            selectedRange: NSRange(location: (filePrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(fileQuery?.kind, .file)
        XCTAssertEqual(fileQuery?.trigger, "@")
        XCTAssertEqual(fileQuery?.query, "Sources/TextBox")
        XCTAssertEqual(fileQuery?.range, NSRange(location: 5, length: 16))

        let skillPrompt = "use /swift-guidance before editing"
        let cursor = (skillPrompt as NSString).range(of: " before").location
        let skillQuery = TextBoxMentionCompletionDetector.query(
            in: skillPrompt,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        XCTAssertEqual(skillQuery?.kind, .skill)
        XCTAssertEqual(skillQuery?.trigger, "/")
        XCTAssertEqual(skillQuery?.query, "swift-guidance")
        XCTAssertEqual(skillQuery?.range, NSRange(location: 4, length: 15))

        let dollarSkillPrompt = "use $axiom-swift now"
        let dollarCursor = (dollarSkillPrompt as NSString).range(of: " now").location
        let dollarSkillQuery = TextBoxMentionCompletionDetector.query(
            in: dollarSkillPrompt,
            selectedRange: NSRange(location: dollarCursor, length: 0)
        )
        XCTAssertEqual(dollarSkillQuery?.kind, .skill)
        XCTAssertEqual(dollarSkillQuery?.trigger, "$")
        XCTAssertEqual(dollarSkillQuery?.query, "axiom-swift")
        XCTAssertEqual(dollarSkillQuery?.range, NSRange(location: 4, length: 12))

        let bareSlashPrompt = "cd /"
        let bareSlashQuery = TextBoxMentionCompletionDetector.query(
            in: bareSlashPrompt,
            selectedRange: NSRange(location: (bareSlashPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareSlashQuery?.kind, .skill)
        XCTAssertEqual(bareSlashQuery?.trigger, "/")
        XCTAssertEqual(bareSlashQuery?.query, "")

        let bareDollarPrompt = "echo $"
        let bareDollarQuery = TextBoxMentionCompletionDetector.query(
            in: bareDollarPrompt,
            selectedRange: NSRange(location: (bareDollarPrompt as NSString).length, length: 0)
        )
        XCTAssertEqual(bareDollarQuery?.kind, .skill)
        XCTAssertEqual(bareDollarQuery?.trigger, "$")
        XCTAssertEqual(bareDollarQuery?.query, "")

        let emailPrompt = "mail lawrence@example.com"
        XCTAssertNil(TextBoxMentionCompletionDetector.query(
            in: emailPrompt,
            selectedRange: NSRange(location: (emailPrompt as NSString).length, length: 0)
        ))
    }

    func testTextBoxMentionFileSuggestionsUseCommandPaletteSearchIndex() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "struct TextBoxInput {}".write(
            to: sourceDirectory.appendingPathComponent("TextBoxInput.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "notes".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 13),
                query: "TextBoxInput",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        XCTAssertEqual(suggestions.first?.title, "@Sources/TextBoxInput.swift")
        XCTAssertEqual(suggestions.first?.systemImageName, "doc")
        XCTAssertTrue(suggestions.first?.insertionText.hasPrefix("[@Sources/TextBoxInput.swift](") == true)
    }

    func testTextBoxMentionFileSuggestionsRefreshCachedMisses() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-mentions-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "old".write(
            to: root.appendingPathComponent("old-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let oldSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "old-file",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        XCTAssertEqual(oldSuggestions.first?.title, "@old-file.txt")

        try "new".write(
            to: root.appendingPathComponent("new-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let newSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 8),
                query: "new-file",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        XCTAssertEqual(newSuggestions.first?.title, "@new-file.txt")
    }

    func testTextBoxMentionSkillSuggestionsUseTypedDollarTrigger() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sample-dollar-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: sample-dollar-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 20),
                query: "sample-dollar",
                trigger: "$"
            ),
            rootDirectory: root.path
        )

        XCTAssertEqual(suggestions.first?.title, "$sample-dollar-skill")
        XCTAssertEqual(suggestions.first?.systemImageName, "sparkle.magnifyingglass")
        XCTAssertEqual(suggestions.first?.insertionText, "$sample-dollar-skill")
    }

    func testTextBoxMentionRefreshKeepsRowsOnSameTriggerEditButClearsOnTriggerChange() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let staleSuggestion = TextBoxMentionSuggestion(
            id: "alpha",
            title: "@alpha.txt",
            subtitle: "alpha.txt",
            insertionText: "[@alpha.txt](/tmp/alpha.txt)",
            systemImageName: "doc"
        )

        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [staleSuggestion]
        )
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 1)

        textView.string = "@z"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 1)
        XCTAssertFalse(textView.debugMentionSuggestionsAreCurrent())
        XCTAssertFalse(textView.debugAcceptMentionCompletion())
        XCTAssertFalse(textView.debugAcceptMentionCompletion(suggestion: staleSuggestion))
        XCTAssertEqual(textView.string, "@z")
        var submitCount = 0
        textView.onSubmit = { submitCount += 1 }
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(textView.string, "@z")

        textView.string = "/z"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.refreshMentionCompletions()
        XCTAssertEqual(textView.debugMentionSuggestionCount(), 0)
    }

    func testTextBoxArrowMovementUsesComposedCharacters() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "a🙂b"
        textView.setSelectedRange(NSRange(location: ("a🙂" as NSString).length, length: 0))

        guard let leftEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_LeftArrow),
            windowNumber: 0
        ), let rightEvent = makeKeyDownEvent(
            key: "",
            modifiers: [],
            keyCode: UInt16(kVK_RightArrow),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct arrow events")
            return
        }

        textView.keyDown(with: leftEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a" as NSString).length, length: 0))

        textView.keyDown(with: rightEvent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ("a🙂" as NSString).length, length: 0))
    }

    func testTextBoxPlainArrowsDeferDuringIMEComposition() {
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: true,
            flags: []
        ))
        XCTAssertTrue(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: []
        ))
        XCTAssertFalse(shouldHandleTextBoxPlainArrowLocally(
            keyCode: UInt16(kVK_LeftArrow),
            firstResponderHasMarkedText: false,
            flags: [.command]
        ))
    }

    func testTextBoxReturnDoesNotSubmitWhileIMEHasMarkedText() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0, "Return should let the input method commit marked text")

        textView.unmarkText()
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1, "Return should submit after marked text is committed")
    }

    func testTextBoxReturnDoesNotSubmitWhileAttachmentUploadPending() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxReturnDoesNotSubmitEmptyContent() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)

        textView.string = "  \n\t  "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)

        textView.string = "hello"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 1)
    }

    func testTextBoxEscapeDoesNotLeaveIMEComposition() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        var escapeCount = 0
        textView.onEscape = {
            escapeCount += 1
        }

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let escapeEvent = makeKeyDownEvent(
            key: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Escape event")
            return
        }

        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 0, "Escape should stay inside active IME composition")

        textView.unmarkText()
        textView.keyDown(with: escapeEvent)
        XCTAssertEqual(escapeCount, 1, "Escape should leave TextBox only after IME composition is gone")
    }

    func testTextBoxMentionCompletionDoesNotConsumeIMECommands() {
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
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        guard let returnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: [],
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Return event")
            return
        }

        textView.keyDown(with: returnEvent)
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))

        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitCount, 0)
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

    func testTextBoxShiftReturnInsertsNewlineWhenMentionCompletionOpen() {
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
                )
            ]
        )

        var submitCount = 0
        textView.onSubmit = {
            submitCount += 1
        }

        guard let shiftReturnEvent = makeKeyDownEvent(
            key: "\r",
            modifiers: .shift,
            keyCode: UInt16(kVK_Return),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Shift-Return event")
            return
        }

        textView.keyDown(with: shiftReturnEvent)

        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(textView.attributedString().string, "@a\n")
        XCTAssertFalse(textView.submissionText().contains("alpha.txt"))
    }

}
