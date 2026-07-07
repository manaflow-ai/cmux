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
}
