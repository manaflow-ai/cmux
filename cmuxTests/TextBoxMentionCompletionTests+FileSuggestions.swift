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


// MARK: - File mention suggestions
extension TextBoxMentionCompletionTests {
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

}
