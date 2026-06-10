import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Markdown file link resolver
extension SessionPersistenceTests {
    func testMarkdownFileLinkResolverRecognizesMarkdownPathLikeStrings() {
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("other-markdown.md"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("test/markdown.md"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("../notes/plan.mdx#section"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("file:///tmp/plan.markdown"))

        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("https://example.com/plan.md"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("mailto:person@example.com"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("README.txt"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("md"))
    }

    func testMarkdownFileLinkResolverPrefersCurrentMarkdownDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let cwdFile = root.appendingPathComponent("other-markdown.md")
        let adjacentFile = docs.appendingPathComponent("other-markdown.md")
        let openedFile = docs.appendingPathComponent("index.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "cwd".write(to: cwdFile, atomically: true, encoding: .utf8)
        try "adjacent".write(to: adjacentFile, atomically: true, encoding: .utf8)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "other-markdown.md",
            relativeToMarkdownFile: openedFile.path
        )
        XCTAssertEqual(resolved, adjacentFile.path)
    }

    func testMarkdownFileLinkResolverFallsBackToProcessWorkingDirectory() throws {
        let originalCWD = FileManager.default.currentDirectoryPath
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-cwd-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let fallbackFile = root.appendingPathComponent("test/markdown.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "fallback".write(to: fallbackFile, atomically: true, encoding: .utf8)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalCWD)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "test/markdown.md",
            relativeToMarkdownFile: openedFile.path
        )
        XCTAssertEqual(resolved, fallbackFile.path)
    }

    func testMarkdownFileLinkResolverRejectsMissingAndNonMarkdownFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-reject-\(UUID().uuidString)", isDirectory: true)
        let openedFile = root.appendingPathComponent("index.md")
        let textFile = root.appendingPathComponent("notes.txt")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "text".write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "missing.md", relativeToMarkdownFile: openedFile.path))
        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "notes.txt", relativeToMarkdownFile: openedFile.path))
        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "https://example.com/notes.md", relativeToMarkdownFile: openedFile.path))
    }
}
