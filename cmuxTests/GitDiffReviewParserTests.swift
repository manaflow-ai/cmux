import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GitDiffReviewParserTests: XCTestCase {
    func testParserBuildsFilesHunksAndLineNumbersFromUnifiedDiff() {
        let diffText = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@
         import SwiftUI
        -let title = "Old"
        +let title = "New"
        +let subtitle = "Review"
         AppView()
        diff --git a/README.md b/README.md
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1,2 @@
        +# cmux
        +Review notes
        """

        let files = GitDiffReviewParser.parse(
            diffText: diffText,
            statusText: " M Sources/App.swift\u{0}A  README.md\u{0}"
        )

        XCTAssertEqual(files.count, 2)

        let appFile = files[0]
        XCTAssertEqual(appFile.path, "Sources/App.swift")
        XCTAssertEqual(appFile.status, .modified)
        XCTAssertEqual(appFile.additions, 2)
        XCTAssertEqual(appFile.deletions, 1)
        XCTAssertEqual(appFile.hunks.count, 1)
        XCTAssertEqual(appFile.hunks[0].oldStart, 1)
        XCTAssertEqual(appFile.hunks[0].newStart, 1)
        XCTAssertEqual(appFile.hunks[0].lines[0].oldLineNumber, 1)
        XCTAssertEqual(appFile.hunks[0].lines[0].newLineNumber, 1)
        XCTAssertEqual(appFile.hunks[0].lines[1].kind, .deletion)
        XCTAssertEqual(appFile.hunks[0].lines[1].oldLineNumber, 2)
        XCTAssertNil(appFile.hunks[0].lines[1].newLineNumber)
        XCTAssertEqual(appFile.hunks[0].lines[2].kind, .addition)
        XCTAssertNil(appFile.hunks[0].lines[2].oldLineNumber)
        XCTAssertEqual(appFile.hunks[0].lines[2].newLineNumber, 2)

        let readme = files[1]
        XCTAssertEqual(readme.path, "README.md")
        XCTAssertEqual(readme.status, .added)
        XCTAssertEqual(readme.additions, 2)
        XCTAssertEqual(readme.deletions, 0)
    }

    func testParserAddsStatusOnlyUntrackedFiles() {
        let files = GitDiffReviewParser.parse(
            diffText: "",
            statusText: "?? notes/review.md\u{0}"
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "notes/review.md")
        XCTAssertEqual(files[0].status, .untracked)
        XCTAssertEqual(files[0].additions, 0)
        XCTAssertEqual(files[0].deletions, 0)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testParserKeepsQuotedDiffGitPathsContainingBoundaryText() {
        let diffText = """
        diff --git "a/src/tests b/helpers/foo.swift" "b/src/tests b/helpers/foo.swift"
        index 1111111..2222222 100644
        --- "a/src/tests b/helpers/foo.swift"
        +++ "b/src/tests b/helpers/foo.swift"
        @@ -1 +1 @@
        -old
        +new
        """

        let files = GitDiffReviewParser.parse(
            diffText: diffText,
            statusText: " M src/tests b/helpers/foo.swift\u{0}"
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "src/tests b/helpers/foo.swift")
        XCTAssertEqual(files[0].oldPath, "src/tests b/helpers/foo.swift")
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[0].deletions, 1)
    }

    func testParserDecodesQuotedOctalPathEscapesAsUTF8() {
        let path = "r\u{00E9}sum\u{00E9}.txt"
        let diffText = """
        diff --git "a/r\\303\\251sum\\303\\251.txt" "b/r\\303\\251sum\\303\\251.txt"
        index 1111111..2222222 100644
        --- "a/r\\303\\251sum\\303\\251.txt"
        +++ "b/r\\303\\251sum\\303\\251.txt"
        @@ -1 +1 @@
        -old
        +new
        """

        let files = GitDiffReviewParser.parse(
            diffText: diffText,
            statusText: " M \(path)\u{0}"
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, path)
        XCTAssertEqual(files[0].status, .modified)
    }

    func testParserStripsNoteMarkerFromLineContent() {
        let diffText = """
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new
        \\ No newline at end of file
        """

        let files = GitDiffReviewParser.parse(
            diffText: diffText,
            statusText: " M file.txt\u{0}"
        )

        XCTAssertEqual(files.count, 1)
        let noteLine = files[0].hunks[0].lines[2]
        XCTAssertEqual(noteLine.kind, .note)
        XCTAssertEqual(noteLine.content, " No newline at end of file")
    }

    func testParserIgnoresTrailingDiffNewline() {
        let diffText = [
            "diff --git a/file.txt b/file.txt",
            "index 1111111..2222222 100644",
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
        ].joined(separator: "\n") + "\n"

        let files = GitDiffReviewParser.parse(
            diffText: diffText,
            statusText: " M file.txt\u{0}"
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks[0].lines.map(\.kind), [.deletion, .addition])
    }
}
