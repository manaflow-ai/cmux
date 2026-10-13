import Foundation
import Testing
@testable import CmuxNative

@Suite("UnifiedDiffParser")
struct UnifiedDiffParserTests {
    @Test func emptyDiffHasNoFiles() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
        #expect(UnifiedDiffParser.parse("\n").isEmpty)
    }

    @Test func multiHunkModifiedFile() throws {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,4 +1,4 @@ import Foundation
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
         let d = 5
        @@ -20,3 +20,5 @@ struct App {
         func one() {}
        +func two() {}
        +func three() {}
         func four() {}
         func five() {}

        """
        let files = UnifiedDiffParser.parse(diff)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.path == "Sources/App.swift")
        #expect(file.oldPath == nil)
        #expect(file.status == .modified)
        #expect(file.hunks.count == 2)
        #expect(file.additions == 3)
        #expect(file.deletions == 1)

        let first = file.hunks[0]
        #expect(first.oldStart == 1 && first.oldCount == 4 && first.newStart == 1 && first.newCount == 4)
        #expect(first.section == "import Foundation")
        #expect(first.lines.map(\.kind) == [.context, .del, .add, .context, .context])
        #expect(first.lines[1].oldNumber == 2 && first.lines[1].newNumber == nil)
        #expect(first.lines[2].newNumber == 2 && first.lines[2].oldNumber == nil)
        #expect(first.lines[3].oldNumber == 3 && first.lines[3].newNumber == 3)

        let second = file.hunks[1]
        #expect(second.section == "struct App {")
        #expect(second.lines.count == 5)
        #expect(second.lines[2].text == "func three() {}")
        #expect(second.lines[2].newNumber == 22)
        #expect(second.lines[4].oldNumber == 22 && second.lines[4].newNumber == 24)
    }

    @Test func renameWithChanges() throws {
        let diff = """
        diff --git a/old/name.ts b/new/name.ts
        similarity index 90%
        rename from old/name.ts
        rename to new/name.ts
        index 3333333..4444444 100644
        --- a/old/name.ts
        +++ b/new/name.ts
        @@ -1 +1 @@
        -export const x = 1
        +export const x = 2
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.status == .renamed)
        #expect(file.oldPath == "old/name.ts")
        #expect(file.path == "new/name.ts")
        #expect(file.similarity == 90)
        #expect(file.hunks.first?.oldCount == 1)
        #expect(file.additions == 1 && file.deletions == 1)
    }

    @Test func pureRenameAndCopy() {
        let diff = """
        diff --git a/a.txt b/b.txt
        similarity index 100%
        rename from a.txt
        rename to b.txt
        diff --git a/c.txt b/d.txt
        similarity index 100%
        copy from c.txt
        copy to d.txt
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].status == .renamed && files[0].oldPath == "a.txt" && files[0].path == "b.txt" && files[0].hunks.isEmpty)
        #expect(files[1].status == .copied && files[1].oldPath == "c.txt" && files[1].path == "d.txt")
    }

    @Test func binaryAddedAndModified() {
        let diff = """
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..5555555
        Binary files /dev/null and b/logo.png differ
        diff --git a/icon.png b/icon.png
        index 6666666..7777777 100644
        Binary files a/icon.png and b/icon.png differ
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].isBinary && files[0].status == .added && files[0].path == "logo.png")
        #expect(files[1].isBinary && files[1].status == .modified && files[1].hunks.isEmpty)
    }

    @Test func addedDeletedAndModeChange() {
        let diff = """
        diff --git a/new.sh b/new.sh
        new file mode 100755
        --- /dev/null
        +++ b/new.sh
        @@ -0,0 +1,2 @@
        +#!/bin/sh
        +echo hi
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 3)
        #expect(files[0].status == .added && files[0].additions == 2 && files[0].hunks[0].lines[0].newNumber == 1)
        #expect(files[1].status == .deleted && files[1].path == "gone.txt" && files[1].deletions == 1)
        #expect(files[2].hasModeChange && files[2].oldMode == "100644" && files[2].newMode == "100755")
    }

    @Test func noNewlineAtEndOfFile() throws {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.hunks[0].lines.map(\.kind) == [.del, .noNewline, .add, .noNewline])
        #expect(file.additions == 1 && file.deletions == 1)
    }

    @Test func crlfLinesAreTrimmed() throws {
        let diff = "diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n@@ -1,2 +1,2 @@\r\n line\r\n-a\r\n+b\r\n"
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.path == "w.txt")
        #expect(file.hunks[0].lines.map(\.text) == ["line", "a", "b"])
    }

    @Test func quotedPathsAreDecoded() throws {
        let diff = """
        diff --git "a/caf\\303\\251 menu.md" "b/caf\\303\\251 menu.md"
        --- "a/caf\\303\\251 menu.md"
        +++ "b/caf\\303\\251 menu.md"
        @@ -1 +1 @@
        -x
        +y
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.path == "café menu.md")
        #expect(file.oldPath == nil)
    }

    @Test func unquotedPathWithSpaces() throws {
        let diff = """
        diff --git a/my file.txt b/my file.txt
        new file mode 100644
        index 0000000..1111111
        Binary files /dev/null and b/my file.txt differ
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.path == "my file.txt")
    }

    @Test func deletedLineThatLooksLikeAHeader() throws {
        let diff = """
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,1 @@
        --- a heading rule
         keep
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].hunks[0].lines.first?.kind == .del)
        #expect(files[0].hunks[0].lines.first?.text == "-- a heading rule")
    }

    @Test func plainUnifiedDiffWithoutGitHeaders() {
        let diff = """
        --- one.txt\t2026-01-01 00:00:00
        +++ one.txt\t2026-01-02 00:00:00
        @@ -1 +1 @@
        -a
        +b
        --- two.txt
        +++ two.txt
        @@ -1 +1 @@
        -c
        +d
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.map(\.path) == ["one.txt", "two.txt"])
    }
}

@Suite("Word diff")
struct WordDiffTests {
    @Test func changedWordIsHighlighted() throws {
        let diff = try #require(WordDiff.compute(old: "let value = oldName + 1", new: "let value = newName + 1"))
        #expect(diff.oldRanges == [12..<19])
        #expect(diff.newRanges == [12..<19])
    }

    @Test func rewrittenLineIsNotHighlighted() {
        #expect(WordDiff.compute(old: "alpha beta gamma", new: "1234567890 xyz!") == nil)
    }

    @Test func identicalLinesHaveNoHighlights() {
        #expect(WordDiff.compute(old: "same", new: "same") == nil)
    }

    @Test func pairsRunsOfDeletionsWithAdditions() {
        let lines: [DiffLine] = [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
            DiffLine(kind: .del, oldNumber: 2, newNumber: nil, text: "b1"),
            DiffLine(kind: .del, oldNumber: 3, newNumber: nil, text: "c1"),
            DiffLine(kind: .add, oldNumber: nil, newNumber: 2, text: "b2"),
            DiffLine(kind: .context, oldNumber: 4, newNumber: 3, text: "d"),
            DiffLine(kind: .add, oldNumber: nil, newNumber: 4, text: "e"),
        ]
        let pairs = DiffLinePairing.pairs(in: lines)
        #expect(pairs == [DiffLinePairing.Pair(del: 1, add: 3)])
    }

    @Test func utf16OffsetsAccountForEmoji() throws {
        let diff = try #require(WordDiff.compute(old: "😀 hello world", new: "😀 hello there"))
        // "😀" is two UTF-16 units, then " hello " → "world" starts at 9.
        #expect(diff.oldRanges == [9..<14])
        #expect(diff.newRanges == [9..<14])
    }
}

@Suite("Diff rendering")
struct DiffRendererTests {
    @Test func hiddenLinesBetweenHunks() throws {
        let diff = """
        diff --git a/f.swift b/f.swift
        --- a/f.swift
        +++ b/f.swift
        @@ -5,2 +5,2 @@
        -a
        +b
         c
        @@ -20,1 +20,1 @@
        -x
        +y
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(DiffRenderer.hiddenBefore(file.hunks, index: 0) == 4)
        #expect(DiffRenderer.hiddenBefore(file.hunks, index: 1) == 13)

        let contents = (1...25).map { "line \($0)" }
        let rendered = DiffRenderer.render(file, contents: contents, expanded: [1], canExpand: true)
        let restored = rendered.unified.compactMap { row -> Int? in
            if case .line(_, let line) = row, line.kind == .context { return line.newNumber }
            return nil
        }
        #expect(restored == [6] + Array(7...19))
    }

    @Test func statBarBlocks() {
        #expect(DiffStatBar.blocks(additions: 0, deletions: 0) == (0, 0))
        #expect(DiffStatBar.blocks(additions: 10, deletions: 0) == (5, 0))
        #expect(DiffStatBar.blocks(additions: 100, deletions: 1) == (4, 1))
        #expect(DiffStatBar.blocks(additions: 1, deletions: 100) == (1, 4))
    }
}

struct TrailingExpandTests {
    private func trailingGaps(_ diff: String) throws -> Int {
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        let rendered = DiffRenderer.render(file, contents: nil, expanded: [], canExpand: true)
        return rendered.unified.filter {
            if case .hunk(_, let header, let gap, _) = $0 { return header.isEmpty && gap == file.hunks.count }
            return false
        }.count
    }

    @Test func hunkEndingBeforeThreeContextLinesReachesEndOfFile() throws {
        let diff = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,3 +1,4 @@
         # Demo
         
         A small repo.
        +More.

        """
        #expect(try trailingGaps(diff) == 0)
    }

    @Test func addedFileHasNothingAfterIt() throws {
        let diff = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1 @@
        +let x = 1

        """
        #expect(try trailingGaps(diff) == 0)
    }

    @Test func fullTrailingContextMayHaveMoreLines() throws {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,4 +1,4 @@
        -let a = 1
        +let a = 2
         let b = 1
         let c = 1
         let d = 1

        """
        #expect(try trailingGaps(diff) == 1)
    }
}
