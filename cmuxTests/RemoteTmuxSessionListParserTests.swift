import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for parsing remote `tmux list-sessions -F` output into
/// ``RemoteTmuxSession`` values. Exercises the real parser, not source text.
@Suite struct RemoteTmuxSessionListParserTests {
    @Test func parsesTabSeparatedSessions() {
        let output = "$0\tmain\t3\t1\t1780000000\n$1\tscratch\t2\t0\t1780000001\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(
            id: "$0", name: "main", windowCount: 3, attached: true, createdUnix: 1780000000
        ))
        #expect(sessions[1] == RemoteTmuxSession(
            id: "$1", name: "scratch", windowCount: 2, attached: false, createdUnix: 1780000001
        ))
    }

    @Test func attachedReflectsNonZeroCount() {
        // tmux reports session_attached as a client count, not a 0/1 boolean.
        let output = "$5\twork\t1\t2\t1780000002"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].attached == true)
    }

    @Test func emptyOutputYieldsNoSessions() {
        #expect(RemoteTmuxSessionListParser.parse("").isEmpty)
        #expect(RemoteTmuxSessionListParser.parse("\n\n").isEmpty)
    }

    @Test func skipsMalformedLinesButKeepsValidOnes() {
        // A short line (missing window count) is skipped; the valid line remains.
        let output = "garbage-without-tabs\n$2\tcmux-probe\t1\t0\t1780000003\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "$2")
        #expect(sessions[0].name == "cmux-probe")
    }

    @Test func toleratesMissingTrailingFields() {
        // Only id+name+windows present; attached defaults false, created nil.
        let output = "$9\tminimal\t4"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0] == RemoteTmuxSession(
            id: "$9", name: "minimal", windowCount: 4, attached: false, createdUnix: nil
        ))
    }
}
