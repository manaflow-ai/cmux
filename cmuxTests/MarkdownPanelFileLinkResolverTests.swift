import CmuxPanes
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Markdown panel file link resolver")
struct MarkdownPanelFileLinkResolverTests {
    @Test("Explicit dotless-host HTTPS href remains remote beside a matching file")
    func explicitDotlessHostHTTPSHrefRemainsRemoteBesideMatchingFile() throws {
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

        let resolved = makeResolver(fallbackDirectoryPath: root.path).resolve(
            rawPath: "https://raw/plans/agent-ticket-v2/w5-runner-design.md",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(resolved == nil)
    }

    @Test("Explicitly relative Markdown filenames containing colons resolve beside the source file")
    func explicitlyRelativeMarkdownFilenameContainingColonResolvesBesideSourceFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-colon-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let targetFile = root.appendingPathComponent("chapter:one.md")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Chapter".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = makeResolver(fallbackDirectoryPath: root.path).resolve(
            rawPath: "./chapter:one.md",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(resolved == targetFile.path)
        #expect(MarkdownLinkPath("./chapter:one.md").isMarkdownFile)
        #expect(!MarkdownLinkPath("chapter:one.md").isMarkdownFile)
    }

    @Test("Dotted HTTPS hosts remain remote even when a matching local path exists")
    func dottedHTTPSHostRemainsRemote() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-remote-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let matchingLocalFile = root.appendingPathComponent("example.com/plan.md")

        try FileManager.default.createDirectory(
            at: matchingLocalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Local".write(to: matchingLocalFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = makeResolver(fallbackDirectoryPath: root.path).resolve(
            rawPath: "https://example.com/plan.md",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(resolved == nil)
    }

    @Test(
        "Guarded HTTPS forms remain remote",
        arguments: [
            ("https://localhost/plan.md", "localhost/plan.md"),
            ("https://raw:8443/plan.md", "raw/plan.md"),
            ("https://user@raw/plan.md", "raw/plan.md"),
            ("https://raw/", "raw")
        ]
    )
    func guardedHTTPSFormRemainsRemote(_ rawPath: String, _ matchingLocalPath: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-guarded-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let matchingLocalFile = root.appendingPathComponent(matchingLocalPath)

        try FileManager.default.createDirectory(
            at: matchingLocalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Local".write(to: matchingLocalFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(makeResolver(fallbackDirectoryPath: root.path).resolveLocalFile(
            rawPath: rawPath,
            relativeToMarkdownFile: sourceFile.path
        ) == nil)
    }

    @Test("Custom schemes remain external even when a matching local path exists")
    func customSchemeRemainsExternal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-scheme-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let matchingLocalFile = root.appendingPathComponent("obsidian:chapter.md")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Local".write(to: matchingLocalFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = makeResolver(fallbackDirectoryPath: root.path).resolve(
            rawPath: "obsidian:chapter.md",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(resolved == nil)
    }

    @Test("Relative non-Markdown href resolves only as a local file")
    func relativeNonMarkdownHrefResolvesOnlyAsLocalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-non-markdown-link-\(UUID().uuidString)", isDirectory: true)
        let sourceFile = root.appendingPathComponent("index.md")
        let targetFile = root.appendingPathComponent("assets/spec.txt")

        try FileManager.default.createDirectory(
            at: targetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "Spec".write(to: targetFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = makeResolver(fallbackDirectoryPath: root.path)
        let localFile = resolver.resolveLocalFile(
            rawPath: "assets/spec.txt",
            relativeToMarkdownFile: sourceFile.path
        )

        #expect(localFile == targetFile.path)
        #expect(resolver.resolve(
            rawPath: "assets/spec.txt",
            relativeToMarkdownFile: sourceFile.path
        ) == nil)
    }

    private func makeResolver(fallbackDirectoryPath: String) -> CmuxPanes.MarkdownPanelFileLinkResolver {
        CmuxPanes.MarkdownPanelFileLinkResolver(
            fileManager: .default,
            fallbackDirectoryPath: fallbackDirectoryPath
        )
    }
}

// Keep legacy resolver and renderer tests source-compatible without adding
// default/global dependencies back to production initializers.
enum MarkdownPanelFileLinkResolver {
    static func isMarkdownPathLike(_ rawPath: String) -> Bool {
        MarkdownLinkPath(rawPath).isMarkdownFile
    }

    static func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let fileManager = FileManager.default
        return CmuxPanes.MarkdownPanelFileLinkResolver(
            fileManager: fileManager,
            fallbackDirectoryPath: fileManager.currentDirectoryPath
        ).resolve(rawPath: rawPath, relativeToMarkdownFile: markdownFilePath)
    }
}

@MainActor
extension MarkdownWebRenderer.Coordinator {
    // The defaulted argument avoids overriding NSObject.init() while keeping
    // the legacy test call sites source-compatible.
    convenience init(testing _: Void = ()) {
        let fileManager = FileManager.default
        self.init(
            fileLinkResolver: CmuxPanes.MarkdownPanelFileLinkResolver(
                fileManager: fileManager,
                fallbackDirectoryPath: fileManager.currentDirectoryPath
            )
        )
    }
}

@MainActor
extension MarkdownRendererSession {
    convenience init() {
        let fileManager = FileManager.default
        self.init(
            fileLinkResolver: CmuxPanes.MarkdownPanelFileLinkResolver(
                fileManager: fileManager,
                fallbackDirectoryPath: fileManager.currentDirectoryPath
            )
        )
    }
}
