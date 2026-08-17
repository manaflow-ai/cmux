import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Git diff parser")
struct GitDiffParserTests {
    @Test("classifies each unified-diff line kind")
    func classifiesKinds() {
        let diff = """
        diff --git a/hello.txt b/hello.txt
        index 1111111..2222222 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,2 +1,3 @@
         context line
        -removed line
        +added line
        \\ No newline at end of file
        """
        let rows = GitDiffParser.parse(diff)
        #expect(rows.map(\.kind) == [
            .header,      // diff --git
            .context,     // index line
            .header,      // ---
            .header,      // +++
            .hunk,        // @@
            .context,     // context line
            .deletion,    // -removed
            .addition,    // +added
            .noNewline,   // \ No newline
        ])
    }

    @Test("keeps the leading diff marker in each row's text")
    func preservesLeadingMarker() {
        let rows = GitDiffParser.parse("+added\n-removed\n context\n")
        #expect(rows.map(\.text) == ["+added", "-removed", " context"])
    }

    @Test("empty diff yields no rows")
    func emptyDiff() {
        #expect(GitDiffParser.parse("").isEmpty)
        #expect(GitDiffParser.parse("\n").isEmpty)
    }

    @Test("row ids are unique and sequential")
    func rowIdsAreSequential() {
        let rows = GitDiffParser.parse("a\nb\nc\n")
        #expect(rows.map(\.id) == [0, 1, 2])
    }

    @Test("addition and deletion are not confused with file headers")
    func plusMinusNotHeader() {
        let rows = GitDiffParser.parse("+++not-a-header\n---not-a-header\n+single\n-single\n")
        #expect(rows[0].kind == .header)    // +++ prefix
        #expect(rows[1].kind == .header)    // --- prefix
        #expect(rows[2].kind == .addition)  // single +
        #expect(rows[3].kind == .deletion)  // single -
    }
}
