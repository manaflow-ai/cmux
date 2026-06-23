import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure command-builder + output-parser that backs the remote-tmux
/// agent busy/idle + model enrichment (Attempt 2). The shell pipeline itself was
/// validated live against a real `~/.claude` host; these lock the
/// cwd→project-dir derivation, the busy-window logic, and the parse robustness.
@Suite struct RemoteTmuxAgentProbeTests {
    typealias Probe = RemoteTmuxAgentProbe

    @Test func encodesProjectDirLikeClaude() {
        // Claude replaces both "/" and "." with "-".
        #expect(Probe.encodeProjectDir("/local/home/maxshmi/Developer/realtime-core")
            == "-local-home-maxshmi-Developer-realtime-core")
        #expect(Probe.encodeProjectDir("/Users/x/repo/.claude") == "-Users-x-repo--claude")
    }

    @Test func activityProbeCommandEmbedsTheProjectDir() {
        let argv = Probe.activityProbeCommand(cwd: "/work/proj")
        let script = try! #require(argv?.last)
        #expect(argv?.first == "sh")
        #expect(script.contains("-work-proj"))
        // Portable stat: must try GNU then BSD form.
        #expect(script.contains("stat -c %Y"))
        #expect(script.contains("stat -f %m"))
    }

    @Test func activityProbeRejectsEmptyCwd() {
        #expect(Probe.activityProbeCommand(cwd: "") == nil)
        #expect(Probe.activityProbeCommand(cwd: "   \n") == nil)
    }

    @Test func parseActivityMarksRecentWriteBusy() {
        let s = Probe.fieldSeparator
        // now=1000, mtime=990 → age 10s ≤ window → busy.
        let a = try! #require(Probe.parseActivity(stdout: "1000\(s)990\(s)/home/u/.claude/projects/p/x.jsonl"))
        #expect(a.busy)
        #expect(a.transcriptPath == "/home/u/.claude/projects/p/x.jsonl")
    }

    @Test func parseActivityMarksStaleWriteIdle() {
        let s = Probe.fieldSeparator
        // age 922s ≫ window → idle (matches the live host probe).
        let a = try! #require(Probe.parseActivity(stdout: "1782168804\(s)1782167882\(s)/p/x.jsonl"))
        #expect(!a.busy)
    }

    @Test func parseActivityClampsNegativeAgeToBusy() {
        let s = Probe.fieldSeparator
        // mtime slightly ahead of local now (clock skew) → still treated busy, not idle.
        let a = try! #require(Probe.parseActivity(stdout: "1000\(s)1002\(s)/p/x.jsonl"))
        #expect(a.busy)
    }

    @Test func parseActivityReturnsNilForNoTranscriptOrGarbage() {
        #expect(Probe.parseActivity(stdout: "") == nil)
        #expect(Probe.parseActivity(stdout: "   \n") == nil)
        #expect(Probe.parseActivity(stdout: "notanumber\u{1f}990\u{1f}/p/x") == nil)
        let s = Probe.fieldSeparator
        #expect(Probe.parseActivity(stdout: "1000\(s)990\(s)") == nil) // empty path
    }

    @Test func parseActivityPreservesPathContainingSeparator() {
        // Defensive: a path with the (improbable) separator byte is rejoined.
        let s = Probe.fieldSeparator
        let a = try! #require(Probe.parseActivity(stdout: "1000\(s)990\(s)/p\(s)x.jsonl"))
        #expect(a.transcriptPath == "/p\(s)x.jsonl")
    }

    @Test func parseModelStripsRetentionSuffix() {
        #expect(Probe.parseModel(stdout: "global.anthropic.claude-opus-4-6-v1[1m]\n")
            == "global.anthropic.claude-opus-4-6-v1")
        #expect(Probe.parseModel(stdout: "claude-sonnet-4-6") == "claude-sonnet-4-6")
    }

    @Test func parseModelReturnsNilWhenEmpty() {
        #expect(Probe.parseModel(stdout: "") == nil)
        #expect(Probe.parseModel(stdout: "  \n") == nil)
    }

    @Test func modelProbeCommandRejectsEmptyPath() {
        #expect(Probe.modelProbeCommand(transcriptPath: "") == nil)
        #expect(Probe.modelProbeCommand(transcriptPath: "/p/x.jsonl")?.first == "sh")
    }
}
