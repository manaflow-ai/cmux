import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
import CmuxShortcuts

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Text box mention completion")
@MainActor
struct TextBoxMentionCompletionTests {
    @Test
    func testTextBoxControlNavigationRoutingUsesTranslatedCharacters() {
        #expect(([.control] as NSEvent.ModifierFlags).shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "n",
            firstResponderIsTextBoxInput: true
        ))
        #expect(([.control] as NSEvent.ModifierFlags).shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "p",
            firstResponderIsTextBoxInput: true
        ))
        #expect(!(([.control] as NSEvent.ModifierFlags).shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "b",
            firstResponderIsTextBoxInput: true
        )))
        #expect(!(([.control, .command] as NSEvent.ModifierFlags).shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: "n",
            firstResponderIsTextBoxInput: true
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
    func testTextBoxExternalTextSyncDoesNotOverwriteActiveIMEMarkedText() {
        #expect(!TextBoxInputInteractionPolicy().shouldSynchronizeExternalText(
            inlineAttachmentCount: 0,
            plainText: "に",
            externalText: "",
            hasMarkedText: true
        ))
        #expect(TextBoxInputInteractionPolicy().shouldSynchronizeExternalText(
            inlineAttachmentCount: 0,
            plainText: "に",
            externalText: "",
            hasMarkedText: false
        ))
        #expect(!TextBoxInputInteractionPolicy().shouldSynchronizeExternalText(
            inlineAttachmentCount: 1,
            plainText: "に",
            externalText: "",
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxPlaceholderHidesDuringActiveIMEMarkedText() {
        #expect(!TextBoxInputInteractionPolicy().shouldShowPlaceholder(
            text: "",
            attachmentCount: 0,
            hasMarkedText: true
        ))
        #expect(TextBoxInputInteractionPolicy().shouldShowPlaceholder(
            text: "",
            attachmentCount: 0,
            hasMarkedText: false
        ))
        #expect(!TextBoxInputInteractionPolicy().shouldShowPlaceholder(
            text: "に",
            attachmentCount: 0,
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxSubmitIsDisabledDuringActiveIMEMarkedText() {
        #expect(!TextBoxInputInteractionPolicy().shouldEnableSubmit(
            text: "に",
            attachmentCount: 0,
            hasPendingAttachmentUpload: false,
            hasMarkedText: true
        ))
        #expect(!TextBoxInputInteractionPolicy().shouldSubmit(
            hasPendingAttachmentUpload: false,
            hasMarkedText: true
        ))
        #expect(TextBoxInputInteractionPolicy().shouldEnableSubmit(
            text: "send",
            attachmentCount: 0,
            hasPendingAttachmentUpload: false,
            hasMarkedText: false
        ))
        #expect(TextBoxInputInteractionPolicy().shouldSubmit(
            hasPendingAttachmentUpload: false,
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxPublishesCommittedIMETextBeforeClearingMarkedState() {
        var text = ""
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var markedTextEvents: [(hasMarkedText: Bool, text: String)] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onMarkedTextStateChanged: { hasMarkedText in
                markedTextEvents.append((hasMarkedText, text))
            },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.noteMarkedTextStateChanged(true, from: textView)
        textView.string = "日本語"
        coordinator.noteMarkedTextStateChanged(false, from: textView)

        #expect(text == "日本語")
        #expect(markedTextEvents.count == 2)
        #expect(markedTextEvents.last?.hasMarkedText == false)
        #expect(markedTextEvents.last?.text == "日本語")
    }

    @Test
    func testTextBoxLiveMarkedTextStateCancelsQueuedInitialSync() {
        var text = ""
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var markedTextEvents: [Bool] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onMarkedTextStateChanged: { markedTextEvents.append($0) },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.queuePendingMarkedTextStateSync(from: textView)
        coordinator.noteMarkedTextStateChanged(true, from: textView)
        coordinator.recalculateHeight(textView)

        #expect(markedTextEvents == [true])
    }

    @Test
    func testTextBoxRepeatedUnmarkedStateDoesNotRepublishContent() {
        var text = "ready"
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var contentChangeCount = 0
        var markedTextEvents: [Bool] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: { contentChangeCount += 1 },
            onMarkedTextStateChanged: { markedTextEvents.append($0) },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "changed without composition"
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.noteMarkedTextStateChanged(false, from: textView)
        coordinator.noteMarkedTextStateChanged(false, from: textView)

        #expect(text == "ready")
        #expect(contentChangeCount == 0)
        #expect(markedTextEvents == [false])
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

        let shortcutKey = TextBoxInputInteractionPolicy(
            translateKey: { keyCode, flags in
                translatedKeyCode = keyCode
                translatedFlags = flags
                return "c"
            },
            normalizedCharacters: { _ in "b" }
        ).commandShortcutKey(for: event)

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

        let shortcutKey = TextBoxInputInteractionPolicy(
            translateKey: { keyCode, flags in
                translatedKeyCode = keyCode
                translatedFlags = flags
                return "z"
            },
            normalizedCharacters: { _ in "y" }
        ).commandShortcutKey(for: event)

        #expect(shortcutKey == "z")
        #expect(translatedKeyCode == UInt16(kVK_ANSI_Y))
        #expect(translatedFlags?.contains(.command) == true)
    }

    @Test
    func testTextBoxMentionCompletionDetectsFileAndSkillTokens() {
        let filePrompt = "open @Sources/TextBox"
        let fileQuery = TextBoxMentionCompletionDetector.query(
            in: filePrompt,
            selectedRange: NSRange(location: (filePrompt as NSString).length, length: 0)
        )
        #expect(fileQuery?.kind == .file)
        #expect(fileQuery?.trigger == "@")
        #expect(fileQuery?.query == "Sources/TextBox")
        #expect(fileQuery?.range == NSRange(location: 5, length: 16))

        let skillPrompt = "use /swift-guidance before editing"
        let cursor = (skillPrompt as NSString).range(of: " before").location
        let skillQuery = TextBoxMentionCompletionDetector.query(
            in: skillPrompt,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        #expect(skillQuery?.kind == .skill)
        #expect(skillQuery?.trigger == "/")
        #expect(skillQuery?.query == "swift-guidance")
        #expect(skillQuery?.range == NSRange(location: 4, length: 15))

        let dollarSkillPrompt = "use $axiom-swift now"
        let dollarCursor = (dollarSkillPrompt as NSString).range(of: " now").location
        let dollarSkillQuery = TextBoxMentionCompletionDetector.query(
            in: dollarSkillPrompt,
            selectedRange: NSRange(location: dollarCursor, length: 0)
        )
        #expect(dollarSkillQuery?.kind == .skill)
        #expect(dollarSkillQuery?.trigger == "$")
        #expect(dollarSkillQuery?.query == "axiom-swift")
        #expect(dollarSkillQuery?.range == NSRange(location: 4, length: 12))

        let bareSlashPrompt = "cd /"
        let bareSlashQuery = TextBoxMentionCompletionDetector.query(
            in: bareSlashPrompt,
            selectedRange: NSRange(location: (bareSlashPrompt as NSString).length, length: 0)
        )
        #expect(bareSlashQuery?.kind == .skill)
        #expect(bareSlashQuery?.trigger == "/")
        #expect(bareSlashQuery?.query == "")

        let bareDollarPrompt = "echo $"
        let bareDollarQuery = TextBoxMentionCompletionDetector.query(
            in: bareDollarPrompt,
            selectedRange: NSRange(location: (bareDollarPrompt as NSString).length, length: 0)
        )
        #expect(bareDollarQuery?.kind == .skill)
        #expect(bareDollarQuery?.trigger == "$")
        #expect(bareDollarQuery?.query == "")

        let emailPrompt = "mail lawrence@example.com"
        #expect(TextBoxMentionCompletionDetector.query(
            in: emailPrompt,
            selectedRange: NSRange(location: (emailPrompt as NSString).length, length: 0)
        ) == nil)
    }

    @Test
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

        #expect(suggestions.first?.title == "@Sources/TextBoxInput.swift")
        #expect(suggestions.first?.systemImageName == "doc")
        #expect(suggestions.first?.insertionText.hasPrefix("[@Sources/TextBoxInput.swift](") == true)
    }

    @Test
    func testTextBoxMentionMarkdownEscapesAngleTargetDelimiters() {
        let link = TextBoxMentionMarkdown.link(
            label: "@Docs/[draft].md",
            path: "Docs/roadmap <draft>.md"
        )

        #expect(link == "[@Docs/\\[draft\\].md](<Docs/roadmap %3Cdraft%3E.md>)")
    }

    @Test
    func testTextBoxProcessTerminationStatusResumesMultipleWaiters() async {
        let status = TextBoxProcessTerminationStatus()

        async let firstWaiter: Int32 = status.wait()
        async let secondWaiter: Int32 = status.wait()
        await Task.yield()

        await status.finish(status: 7)

        let (firstStatus, secondStatus) = await (firstWaiter, secondWaiter)
        #expect(firstStatus == 7)
        #expect(secondStatus == 7)
        #expect(await status.wait() == 7)
    }

    @Test
    func testTextBoxMentionFileSuggestionsReturnRootFilesForEmptyQuery() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-empty-file-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "notes".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.first?.title == "@README.md")
        #expect(suggestions.first?.insertionText.hasPrefix("[@README.md](") == true)
    }

    @Test
    func testTextBoxMentionFileSuggestionsIncludeDirectoriesForEmptyQuery() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-empty-directory-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sourceDirectory.appendingPathComponent("Empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("ZEmpty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "nested".write(
            to: sourceDirectory.appendingPathComponent("Nested.swift"),
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
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        let sourcesDirectory = suggestions.first { $0.title == "@Sources/" }
        #expect(sourcesDirectory != nil)
        #expect(sourcesDirectory?.systemImageName == "folder")
        #expect(sourcesDirectory?.insertionText.hasPrefix("[@Sources/](") == true)
        #expect(suggestions.contains { $0.title == "@ZEmpty/" })
        #expect(suggestions.contains { $0.title == "@README.md" })

        let nestedFileSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 7),
                query: "Nested",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        #expect(nestedFileSuggestions.first?.title == "@Sources/Nested.swift")

        let warmedSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "@"
            ),
            rootDirectory: root.path
        )
        #expect(warmedSuggestions.contains { $0.title == "@Sources/Empty/" })
    }

    @Test
    func testTextBoxMentionFileSuggestionsFindNestedDirectoriesAndFilesWithFuzzyIndex() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-nested-file-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let componentsDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Components", isDirectory: true)
        let fixturesDirectory = root.appendingPathComponent("Fixtures", isDirectory: true)
        try fileManager.createDirectory(at: componentsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixturesDirectory, withIntermediateDirectories: true)
        try "struct NestedView {}".write(
            to: componentsDirectory.appendingPathComponent("NestedView.swift"),
            atomically: true,
            encoding: .utf8
        )
        for index in 0..<40 {
            try "fixture \(index)".write(
                to: fixturesDirectory.appendingPathComponent("Fixture\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let directorySuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 11),
                query: "Components",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(directorySuggestions.first?.title == "@Sources/Components/")
        #expect(directorySuggestions.first?.systemImageName == "folder")

        let nestedFileSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 10),
                query: "NestedView",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(nestedFileSuggestions.first?.title == "@Sources/Components/NestedView.swift")
        #expect(nestedFileSuggestions.first?.systemImageName == "doc")

        let missingSuggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 14),
                query: "MissingNeedle",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(missingSuggestions.isEmpty)
    }

    @Test
    func testTextBoxMentionFileSuggestionsSkipPackageContents() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-package-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let packageDirectory = root
            .appendingPathComponent("Dependencies", isDirectory: true)
            .appendingPathComponent("GhosttyKit.xcframework", isDirectory: true)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try "internal".write(
            to: packageDirectory.appendingPathComponent("InternalNeedle.swift"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 15),
                query: "InternalNeedle",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(!(suggestions.contains { $0.title.contains("InternalNeedle.swift") }))
    }

    @Test
    func testTextBoxMentionFileSuggestionsKeepCaseVariantProjectDirectories() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-library-mentions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let libraryDirectory = root.appendingPathComponent("library", isDirectory: true)
        try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try "valid".write(
            to: libraryDirectory.appendingPathComponent("VisibleNeedle.swift"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .file,
                range: NSRange(location: 0, length: 14),
                query: "VisibleNeedle",
                trigger: "@"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.contains { $0.title == "@library/VisibleNeedle.swift" })
    }

    @Test
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
        #expect(oldSuggestions.first?.title == "@old-file.txt")

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
        #expect(newSuggestions.first?.title == "@new-file.txt")
    }

    @Test
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

        #expect(suggestions.first?.title == "$sample-dollar-skill")
        #expect(suggestions.first?.systemImageName == "sparkle.magnifyingglass")
        // The $ trigger inserts the bare skill reference (not a markdown link),
        // unlike the / and @ triggers.
        #expect(suggestions.first?.insertionText == "$sample-dollar-skill")
    }

    @Test
    func testTextBoxMentionSkillSuggestionsUseTypedSlashTriggerForEmptyQuery() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-slash-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("sample-slash-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: sample-slash-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        // An empty query returns the whole skill corpus, which also includes the
        // machine's global skill roots (~/.codex/skills, etc.), so the temp skill
        // is not guaranteed to sort first. Assert it is present with the typed
        // trigger rather than asserting its position.
        let slashSkill = suggestions.first { $0.title == "/sample-slash-skill" }
        #expect(slashSkill != nil)
        #expect(slashSkill?.insertionText.hasPrefix("[/sample-slash-skill](") == true)
    }

    @Test
    func testTextBoxMentionEmptySkillSuggestionsKeepNearestProjectSkillsBeforeCap() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-local-skill-priority-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let ancestorSkillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let projectSkillsDirectory = projectDirectory.appendingPathComponent("skills", isDirectory: true)
        let localSkillDirectory = projectSkillsDirectory.appendingPathComponent("zz-local-skill", isDirectory: true)
        try fileManager.createDirectory(at: localSkillDirectory, withIntermediateDirectories: true)
        try "name: zz-local-skill\n".write(
            to: localSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        for index in 0..<520 {
            let skillName = String(format: "aaa-global-%03d", index)
            let skillDirectory = ancestorSkillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 1),
                query: "",
                trigger: "/"
            ),
            rootDirectory: projectDirectory.path
        )

        let localSkillIndex = suggestions.firstIndex { $0.title == "/zz-local-skill" }
        let ancestorSkillIndex = suggestions.firstIndex { $0.title.hasPrefix("/aaa-global-") }
        #expect(localSkillIndex != nil)
        #expect(ancestorSkillIndex != nil)
        #expect((localSkillIndex ?? Int.max) < (ancestorSkillIndex ?? Int.max))
    }

    @Test
    func testTextBoxMentionSkillSuggestionsFindNestedSkillPacks() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-nested-skills-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillDirectory = root
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("team", isDirectory: true)
            .appendingPathComponent("nested-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "name: nested-skill\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 13),
                query: "nested-skill",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        let nestedSkill = suggestions.first { $0.title == "/nested-skill" }
        #expect(nestedSkill != nil)
        #expect(nestedSkill?.insertionText.hasPrefix("[/nested-skill](") == true)
    }

    @Test
    func testTextBoxMentionSkillSuggestionsPreferExactNameOverPathOnlyFuzzyMatches() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skill-fuzzy-filter-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        let skillNames = [
            "agent-browser",
            "agent-cli-integration",
            "algorithmic-complexity-audit",
            "auto-issue",
            "cleanup-dev-builds",
            "close-issues",
            "pi-agent-rust",
            "xcodebuildmcp-cli",
            "iterate-pr"
        ] + (0..<40).map { String(format: "zzz-distractor-%02d", $0) }
        for skillName in skillNames {
            let skillDirectory = skillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        for trigger in ["/", "$"] as [Character] {
            let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
                for: TextBoxMentionQuery(
                    kind: .skill,
                    range: NSRange(location: 0, length: 11),
                    query: "iterate-pr",
                    trigger: trigger
                ),
                rootDirectory: root.path
            )

            #expect(suggestions.first?.title == "\(trigger)iterate-pr")
            #expect(!suggestions.contains { $0.title == "\(trigger)pi-agent-rust" })
            #expect(!suggestions.contains { $0.title == "\(trigger)agent-browser" })
        }
    }

    @Test
    func testTextBoxMentionSkillSuggestionsFilterWeakPartialFuzzyMatches() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-skill-partial-fuzzy-filter-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let skillsDirectory = root.appendingPathComponent("skills", isDirectory: true)
        for skillName in [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ] {
            let skillDirectory = skillsDirectory.appendingPathComponent(skillName, isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try "name: \(skillName)\n".write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
            for: TextBoxMentionQuery(
                kind: .skill,
                range: NSRange(location: 0, length: 8),
                query: "iterate",
                trigger: "/"
            ),
            rootDirectory: root.path
        )

        #expect(suggestions.first?.title == "/iterate-pr")
        #expect(!suggestions.contains { $0.title == "/agent-browser" })
        #expect(!suggestions.contains { $0.title == "/pi-agent-rust" })
    }

    @Test
    func testTextBoxMentionCandidateIndexDoesNotReturnUnvalidatedNucleoRows() {
        let skillNames = [
            "agent-browser",
            "agent-cli-integration",
            "algorithmic-complexity-audit",
            "auto-issue",
            "cleanup-dev-builds",
            "close-issues",
            "pi-agent-rust",
            "xcodebuildmcp-cli"
        ] + (0..<40).map { String(format: "zzz-distractor-%02d", $0) }
        let candidates = skillNames.map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate-pr",
            limit: 500
        )

        #expect(matches.isEmpty)
    }

    @Test
    func testTextBoxMentionCandidateIndexFiltersWeakPartialFuzzyRows() {
        let candidates = [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ].map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate",
            limit: 500
        )

        #expect(matches.map(\.title) == ["/iterate-pr"])
    }

    @Test
    func testTextBoxMentionCandidateIndexStopsPrefilterWhenCancelled() {
        let candidates = [
            "agent-browser",
            "agent-cli-integration",
            "pi-agent-rust",
            "iterate-pr"
        ].map { skillName in
            TextBoxMentionCandidate(
                title: "/\(skillName)",
                subtitle: "/tmp/skills/\(skillName)/SKILL.md",
                targetPath: "/tmp/skills/\(skillName)/SKILL.md",
                systemImageName: "sparkle.magnifyingglass",
                searchKey: skillName,
                priority: 0
            )
        }
        var cancellationChecks = 0

        let matches = TextBoxMentionCandidateIndex(candidates: candidates).rankedCandidates(
            matching: "iterate",
            limit: 500
        ) {
            cancellationChecks += 1
            return cancellationChecks > 1
        }

        #expect(matches.isEmpty)
        #expect(cancellationChecks > 1)
    }

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
    func testTextBoxMentionRootDirectoryChangeClearsActiveFileSuggestions() throws {
        let fileManager = FileManager.default
        let oldRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-old-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let newRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-new-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: oldRoot)
            try? fileManager.removeItem(at: newRoot)
        }
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.completionRootDirectory = oldRoot.path
        textView.string = "@a"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.debugSetMentionCompletionState(
            query: TextBoxMentionQuery(kind: .file, range: NSRange(location: 0, length: 2), query: "a"),
            suggestions: [
                TextBoxMentionSuggestion(
                    id: "old:alpha",
                    title: "@alpha.txt",
                    subtitle: "alpha.txt",
                    insertionText: "[@alpha.txt](\(oldRoot.path)/alpha.txt)",
                    systemImageName: "doc"
                )
            ],
            rootDirectory: oldRoot.path
        )
        #expect(textView.debugMentionSuggestionsAreCurrent())

        textView.completionRootDirectory = newRoot.path

        #expect(textView.debugMentionSuggestionCount() == 0)
        #expect(!(textView.debugAcceptMentionCompletion()))
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
