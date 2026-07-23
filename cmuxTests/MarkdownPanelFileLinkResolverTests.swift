import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Markdown panel file link resolver")
struct MarkdownPanelFileLinkResolverTests {
    @Test("WebKit HTTPS coercion of a relative Markdown href resolves as a local file")
    func webKitHTTPSCoercionOfRelativeMarkdownHrefResolvesAsLocalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let targetFile = docs.appendingPathComponent("raw/plans/agent-ticket-v2/w5-runner-design.md")

        try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "# runner".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "https://raw/plans/agent-ticket-v2/w5-runner-design.md",
            relativeToMarkdownFile: openedFile.path
        )

        #expect(resolved == targetFile.path)
        #expect(resolved?.hasPrefix("https://") == false)
    }

    @Test("Relative Markdown filenames containing colons resolve as local files")
    func relativeMarkdownFilenamesContainingColonsResolveAsLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-colon-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let targetFile = docs.appendingPathComponent("chapter:one.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "# chapter".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "chapter:one.md",
            relativeToMarkdownFile: openedFile.path
        )

        #expect(resolved == targetFile.path)
    }

    @Test("Dotted HTTPS hosts remain remote URLs")
    func dottedHTTPSHostsRemainRemoteURLs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-remote-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let matchingLocalFile = docs.appendingPathComponent("example.com/plan.md")

        try FileManager.default.createDirectory(at: matchingLocalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "# local".write(to: matchingLocalFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "https://example.com/plan.md",
            relativeToMarkdownFile: openedFile.path
        )

        #expect(resolved == nil)
    }

    @Test("Known external schemes remain remote URLs")
    func knownExternalSchemesRemainRemoteURLs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-mailto-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let matchingLocalFile = docs.appendingPathComponent("mailto:chapter.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "# local".write(to: matchingLocalFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "mailto:chapter.md",
            relativeToMarkdownFile: openedFile.path
        )

        #expect(resolved == nil)
    }

    @Test("WebKit HTTPS coercion of a relative non-Markdown href resolves as a local file")
    func webKitHTTPSCoercionOfRelativeNonMarkdownHrefResolvesAsLocalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-file-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let targetFile = docs.appendingPathComponent("assets/spec.txt")

        try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "spec".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolveLocalFile(
            rawPath: "https://assets/spec.txt",
            relativeToMarkdownFile: openedFile.path
        )

        #expect(resolved == targetFile.path)
        #expect(MarkdownPanelFileLinkResolver.resolve(
            rawPath: "https://assets/spec.txt",
            relativeToMarkdownFile: openedFile.path
        ) == nil)
    }
}
