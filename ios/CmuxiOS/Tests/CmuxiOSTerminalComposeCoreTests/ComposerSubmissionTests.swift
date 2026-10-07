import CmuxiOSTerminalComposeCore
import Testing

@Suite struct ComposerSubmissionTests {
    @Test func unifiesLineEndingsAndTrims() throws {
        let submission = try #require(ComposerSubmission(draft: "\n  \nfirst\r\nsecond\rthird  \n\n"))
        #expect(submission.text == "first\nsecond\nthird")
        #expect(submission.isMultiline)
        #expect(submission.submits)
    }

    @Test func removesControlCharactersButKeepsTabs() throws {
        let draft = "a\u{1B}[201~b\tc\u{07}d\u{7F}e\u{9B}f"
        let submission = try #require(ComposerSubmission(draft: draft))
        #expect(submission.text == "a[201~b\tcdef")
        #expect(!submission.text.unicodeScalars.contains("\u{1B}"))
    }

    @Test func keepsLeadingIndentOfFirstContentLine() throws {
        let submission = try #require(ComposerSubmission(draft: "\n    indented code"))
        #expect(submission.text == "    indented code")
    }

    @Test func emptyOrWhitespaceIsNothing() {
        #expect(ComposerSubmission(draft: "") == nil)
        #expect(ComposerSubmission(draft: " \n\t\r\n ") == nil)
        #expect(ComposerSubmission(draft: "\u{1B}\u{1B}") == nil)
    }

    @Test func insertOnlyDoesNotSubmit() throws {
        let submission = try #require(ComposerSubmission(draft: "ls", submits: false))
        #expect(!submission.submits)
        #expect(!submission.isMultiline)
    }

    @Test func keepsUnicode() throws {
        let submission = try #require(ComposerSubmission(draft: "日本語 👋🏽\n"))
        #expect(submission.text == "日本語 👋🏽")
    }
}

@Suite struct ComposerReturnRuleTests {
    @Test func softwareKeyboardReturnIsNewline() {
        let rule = ComposerReturnRule(hardwareKeyboard: false)
        #expect(rule.action(for: []) == .newline)
        #expect(rule.action(for: .command) == .newline)
    }

    @Test func hardwareKeyboardRules() {
        let rule = ComposerReturnRule(hardwareKeyboard: true)
        #expect(rule.action(for: []) == .send)
        #expect(rule.action(for: .shift) == .newline)
        #expect(rule.action(for: .option) == .newline)
        #expect(rule.action(for: .command) == .send)
        #expect(rule.action(for: [.command, .shift]) == .send)
    }
}

@Suite struct ComposerPathInsertionTests {
    @Test func quotesUnsafePaths() {
        #expect(ComposerPathInsertion(path: "/Users/me/Downloads/cmux-phone/a.png").quoted
            == "/Users/me/Downloads/cmux-phone/a.png")
        #expect(ComposerPathInsertion(path: "/tmp/my shot.png").quoted == "'/tmp/my shot.png'")
        #expect(ComposerPathInsertion(path: "/tmp/it's.png").quoted == "'/tmp/it'\\''s.png'")
        #expect(ComposerPathInsertion(path: "").quoted == "''")
    }

    @Test func insertsWithSingleSpaces() {
        let insertion = ComposerPathInsertion(path: "/a b")
        let empty = insertion.inserting(into: "", atUTF16Offset: 0)
        #expect(empty.text == "'/a b' ")
        #expect(empty.caret == 7)

        let end = insertion.inserting(into: "look at", atUTF16Offset: .max)
        #expect(end.text == "look at '/a b' ")
        #expect(end.caret == end.text.utf16.count)

        let middle = insertion.inserting(into: "see here", atUTF16Offset: 4)
        #expect(middle.text == "see '/a b' here")
        #expect(middle.caret == 11)

        let beforeWord = insertion.inserting(into: "seehere", atUTF16Offset: 3)
        #expect(beforeWord.text == "see '/a b' here")
    }

    @Test func neverSplitsACharacter() {
        let insertion = ComposerPathInsertion(path: "/p")
        // 👋🏽 is four UTF-16 units; an offset inside it snaps before it.
        let result = insertion.inserting(into: "a👋🏽", atUTF16Offset: 2)
        #expect(result.text == "a /p 👋🏽")
    }
}
