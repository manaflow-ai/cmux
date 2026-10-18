import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ClaudeTranscriptTailReaderTests {
    private func writeTranscript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-tail-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func title(_ text: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(text)","sessionId":"s-1"}"#
    }

    private func prompt(_ text: String) -> String {
        #"{"type":"last-prompt","lastPrompt":"\#(text)","leafUuid":"l-1","sessionId":"s-1"}"#
    }

    private let userLine = #"{"type":"user","sessionId":"s-1","message":{"role":"user","content":"hello"}}"#
    private let assistantLine = #"{"type":"assistant","sessionId":"s-1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#

    @Test func newestMetadataWins() throws {
        let path = try writeTranscript([
            userLine, title("First"), prompt("p1"), assistantLine, title("Second"), prompt("p2"),
        ])
        let tail = ClaudeTranscriptTailReader().read(path: path)
        #expect(tail?.aiTitle == "Second")
        #expect(tail?.lastPrompt == "p2")
    }

    @Test func metadataAbsentYieldsNilFields() throws {
        let path = try writeTranscript([userLine, assistantLine])
        let tail = ClaudeTranscriptTailReader().read(path: path)
        #expect(tail != nil)
        #expect(tail?.aiTitle == nil)
        #expect(tail?.lastPrompt == nil)
    }

    @Test func largeFileOnlyScansTheTail() throws {
        let filler = Array(repeating: assistantLine, count: 3_000)
        let path = try writeTranscript([title("Early")] + filler + [title("Late"), prompt("recent")])
        let tail = ClaudeTranscriptTailReader(maxBytes: 4_096).read(path: path)
        #expect(tail?.aiTitle == "Late")
        #expect(tail?.lastPrompt == "recent")

        let headOnly = try writeTranscript([title("Early"), prompt("old")] + filler)
        let missed = ClaudeTranscriptTailReader(maxBytes: 4_096).read(path: headOnly)
        #expect(missed != nil)
        #expect(missed?.aiTitle == nil)
        #expect(missed?.lastPrompt == nil)
    }

    @Test func lastPromptLineWithoutTextIsTolerated() throws {
        let path = try writeTranscript([#"{"type":"last-prompt","sessionId":"s-1"}"#])
        let tail = ClaudeTranscriptTailReader().read(path: path)
        #expect(tail?.lastPrompt == nil)
    }

    @Test func promptIsCollapsedToOneLine() {
        let lines = [#"{"type":"last-prompt","lastPrompt":"fix the\nlogin   bug\t now ","sessionId":"s-1"}"#]
        #expect(ClaudeTranscriptTailReader.tail(fromLines: lines).lastPrompt == "fix the login bug now")
    }

    @Test func malformedLinesAreSkipped() {
        let lines = [#"{"type":"ai-title","aiTitle":"Good","sessionId":"s-1"}"#, #"{"type":"ai-title","aiTitle":"Broken"#]
        #expect(ClaudeTranscriptTailReader.tail(fromLines: lines).aiTitle == "Good")
    }

    @Test func missingFileReturnsNil() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl").path
        #expect(ClaudeTranscriptTailReader().read(path: path) == nil)
    }
}
