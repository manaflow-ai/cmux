import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Markdown panel file link resolver")
struct MarkdownPanelFileLinkResolverTests {
    @Test("WebKit-coerced relative Markdown href resolves beside its source file")
    func webKitCoercedRelativeMarkdownHrefResolvesBesideSourceFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-relative-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let targetFile = root.appendingPathComponent("raw/plans/agent-ticket-v2/w5-runner-design.md")

        try FileManager.default.createDirectory(
            at: targetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Runner design".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "https://raw/plans/agent-ticket-v2/w5-runner-design.md",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(resolved == targetFile.path)
    }
}
