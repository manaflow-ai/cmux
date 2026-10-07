import CmuxiOSViewersCore
import Testing

@Suite struct UnifiedDiffParserTests {
    let patch = """
    diff --git a/a.swift b/a.swift
    index 1111111..2222222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,4 +1,5 @@ struct Viewer {
     import UIKit
    -let mode = "unified"
    +let mode = "split"
    +let hunks = 2
     struct Viewer {}
     // end
    @@ -40 +41,2 @@
    -old
    +new
    +added
    \\ No newline at end of file
    """

    @Test func parsesHunksNumbersAndSections() {
        let document = UnifiedDiffParser().parse(patch)
        #expect(document.hunks.count == 2)
        let first = document.hunks[0]
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 4, 1, 5))
        #expect(first.section == "struct Viewer {")
        #expect(first.lines.map(\.kind) == [.context, .removal, .addition, .addition, .context, .context])
        #expect(first.lines[0].oldNumber == 1 && first.lines[0].newNumber == 1)
        #expect(first.lines[1].oldNumber == 2 && first.lines[1].newNumber == nil)
        #expect(first.lines[3].newNumber == 3)
        #expect(first.lines[4].oldNumber == 3 && first.lines[4].newNumber == 4)
        let second = document.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (40, 1, 41, 2))
        #expect(second.lines.last?.kind == .noNewlineMarker)
        #expect(document.additions == 4 && document.deletions == 2)
    }

    @Test func pairedLinesGetTheirChangedSpan() {
        let lines = UnifiedDiffParser().parse(patch).hunks[0].lines
        // Runs of 1 removal and 2 additions are not paired.
        #expect(lines[1].emphasis == nil)
        let single = UnifiedDiffParser().parse("@@ -1 +1 @@\n-let mode = \"unified\"\n+let mode = \"split\"\n").hunks[0].lines
        #expect(single[0].emphasis == 12..<19)
        #expect(single[1].emphasis == 12..<17)
    }

    @Test func keepsCarriageReturnsAndEmptyPatches() {
        let crlf = UnifiedDiffParser().parse("@@ -1 +1 @@\n-a\r\n+b\r\n")
        #expect(crlf.hunks[0].lines.map(\.text) == ["a\r", "b\r"])
        #expect(UnifiedDiffParser().parse("").isEmpty)
        let renameOnly = UnifiedDiffParser().parse("diff --git a/x b/y\nsimilarity index 100%\nrename from x\nrename to y\n")
        #expect(renameOnly.isEmpty && !renameOnly.isBinary)
        let binary = UnifiedDiffParser().parse("@@ -1 +1 @@\n-a\n+b\n", binary: true)
        #expect(binary.isBinary && binary.isEmpty)
        #expect(UnifiedDiffParser().parse("@@ -1 +1 @@\n+x\n", truncated: true).isTruncated)
    }

    @Test func malformedHeadersAreIgnored() {
        let document = UnifiedDiffParser().parse("@@ nope @@\n+x\n@@ -a +b @@\n+y\n@@ -3,2 +3 @@\n x\n")
        #expect(document.hunks.count == 1)
        #expect(document.hunks[0].newCount == 1)
    }
}
