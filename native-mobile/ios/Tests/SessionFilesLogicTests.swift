import Foundation
import Testing
@testable import CmuxNative

@Suite("Session reference groups")
struct SessionRefGroupTests {
    private func ref(_ path: String, _ kind: String, exists: Bool? = true, size: Int? = nil) -> HostFileRef {
        HostFileRef(path: path, kind: kind, exists: exists, size: size)
    }

    @Test func groupsByKindInFixedOrder() {
        let groups = SessionRefGroup.make([
            ref("https://cmux.com/docs", "url"),
            ref("/repo/src", "dir"),
            ref("/repo/README.md", "file"),
        ])
        #expect(groups.map(\.kind) == [.files, .folders, .links])
        #expect(groups.map { $0.refs.map(\.path) } == [["/repo/README.md"], ["/repo/src"], ["https://cmux.com/docs"]])
    }

    @Test func mostRecentMentionFirstAndDeduped() {
        let groups = SessionRefGroup.make([
            ref("/repo/a.swift", "file"),
            ref("/repo/b.swift", "file"),
            ref("/repo/a.swift", "file"),
            ref("/repo/src/", "dir"),
            ref("/repo/src", "dir"),
        ])
        #expect(groups[0].refs.map(\.path) == ["/repo/a.swift", "/repo/b.swift"])
        #expect(groups[1].refs.count == 1)
    }

    @Test func dropsMissingFilesButKeepsUnknown() {
        let groups = SessionRefGroup.make([
            ref("/repo/missing.txt", "file", exists: false),
            ref("/repo/unknown.txt", "file", exists: nil),
        ])
        #expect(groups.first?.refs.map(\.path) == ["/repo/unknown.txt"])
    }

    @Test func filtersByQueryCaseInsensitively() {
        let refs = [ref("/repo/Package.swift", "file"), ref("/repo/main.ts", "file"), ref("https://example.com/package", "url")]
        let groups = SessionRefGroup.make(refs, query: "  PACKAGE ")
        #expect(groups.map(\.kind) == [.files, .links])
        #expect(groups[0].refs.map(\.path) == ["/repo/Package.swift"])
        #expect(SessionRefGroup.make(refs, query: "nothing").isEmpty)
    }

    @Test func httpPathsAreLinksEvenWithoutURLKind() {
        #expect(SessionRefGroup.kind(of: ref("https://x.dev", "file")) == .links)
        #expect(SessionRefGroup.kind(of: ref("/tmp", "directory")) == .folders)
    }
}

@Suite("File preview kinds")
struct FilePreviewKindTests {
    @Test func detectsByExtension() {
        #expect(FilePreviewKind.detect(path: "/a/photo.PNG") == .image)
        #expect(FilePreviewKind.detect(path: "/a/clip.mov") == .video)
        #expect(FilePreviewKind.detect(path: "/a/song.mp3") == .audio)
        #expect(FilePreviewKind.detect(path: "/a/doc.pdf") == .pdf)
        #expect(FilePreviewKind.detect(path: "/a/index.html") == .html)
        #expect(FilePreviewKind.detect(path: "/a/README.md") == .markdown)
        #expect(FilePreviewKind.detect(path: "/a/logo.svg") == .svg)
        #expect(FilePreviewKind.detect(path: "/a/package.json") == .json)
        #expect(FilePreviewKind.detect(path: "/a/main.swift") == .text)
        #expect(FilePreviewKind.detect(path: "/a/build.zig") == .text)
        #expect(FilePreviewKind.detect(path: "/a/Makefile") == .text)
        #expect(FilePreviewKind.detect(path: "/a/archive.zip") == .other)
    }

    @Test func fallsBackToMime() {
        #expect(FilePreviewKind.detect(path: "/a/blob", mime: "image/png") == .image)
        #expect(FilePreviewKind.detect(path: "/a/blob", mime: "text/plain") == .text)
        #expect(FilePreviewKind.detect(path: "/a/blob", mime: "application/octet-stream") == .other)
    }

    @Test func gitStatusDecoding() {
        let value: JSONValue = [
            "root": "/repo",
            "files": [
                ["path": "a.swift", "index": " ", "worktree": "M", "status": "modified", "staged": false, "unstaged": true],
                ["path": "b.swift", "old_path": "old.swift", "index": "R", "worktree": " ", "status": "renamed", "staged": true, "unstaged": false],
                ["path": "new.txt", "index": "?", "worktree": "?", "status": "untracked", "staged": false, "unstaged": true],
            ],
        ]
        let parsed = GitChangedFile.parse(value)
        #expect(parsed.root == "/repo")
        #expect(parsed.files.map(\.badge) == ["M", "R", "U"])
        #expect(parsed.files[1].oldPath == "old.swift")
    }
}

@Suite("Markdown HTML")
struct FilePreviewMarkdownTests {
    @Test func blocksAndInline() {
        let html = FilePreviewMarkdown.render("""
        # Title

        Some **bold** and `a<b>` with [link](https://cmux.com).

        - [x] done
        - todo

        ```swift
        let x = 1 < 2
        ```
        """)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<code>a&lt;b&gt;</code>"))
        #expect(html.contains("<a href=\"https://cmux.com\">link</a>"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
    }

    @Test func rawHTMLAndScriptLinksAreNeutralized() {
        let html = FilePreviewMarkdown.render("<script>alert(1)</script> [x](javascript:alert(1))")
        #expect(!html.contains("<script>"))
        #expect(html.contains("href=\"#\""))
    }

    @Test func tables() {
        let html = FilePreviewMarkdown.render("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(html.contains("<th>a</th><th>b</th>"))
        #expect(html.contains("<td>1</td><td>2</td>"))
    }
}
