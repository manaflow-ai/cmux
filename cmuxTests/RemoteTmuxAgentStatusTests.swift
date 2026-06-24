import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure parser for the `@cmux_agent` hook status (Option C). The tmux
/// subscription delivery was verified live (tmux 3.6a pushes
/// `%subscription-changed cmux_agent_<pane> … : <json>` when the option is set);
/// these lock the JSON contract and the state-word mapping.
@Suite struct RemoteTmuxAgentStatusTests {
    typealias Status = RemoteTmuxAgentStatus

    @Test func parsesWorkingWithModel() {
        let s = try! #require(Status.parse(#"{"agent":"claude","state":"working","model":"claude-opus-4-8"}"#))
        #expect(s.agent == "claude")
        #expect(s.state == .working)
        #expect(s.model == "claude-opus-4-8")
        #expect(s.title == nil)
    }

    @Test func parsesIdleAndRunning() {
        #expect(Status.parse(#"{"agent":"codex","state":"idle"}"#)?.state == .idle)
        #expect(Status.parse(#"{"agent":"claude","state":"running"}"#)?.state == .running)
    }

    @Test func mapsLifecycleSynonyms() {
        // The hook may emit the raw lifecycle word; map common synonyms.
        #expect(Status.parse(#"{"agent":"claude","state":"busy"}"#)?.state == .working)
        #expect(Status.parse(#"{"agent":"claude","state":"stop"}"#)?.state == .idle)
        #expect(Status.parse(#"{"agent":"claude","state":"session-start"}"#)?.state == .running)
        #expect(Status.parse(#"{"agent":"claude","state":"WORKING"}"#)?.state == .working)
    }

    @Test func stripsModelRetentionSuffix() {
        let s = try! #require(Status.parse(#"{"agent":"claude","state":"working","model":"global.anthropic.claude-opus-4-6-v1[1m]"}"#))
        #expect(s.model == "global.anthropic.claude-opus-4-6-v1")
    }

    @Test func lowercasesAgentLabel() {
        #expect(Status.parse(#"{"agent":"Claude","state":"idle"}"#)?.agent == "claude")
    }

    @Test func carriesTitleWhenPresent() {
        let s = try! #require(Status.parse(#"{"agent":"codex","state":"working","title":"refactor parser"}"#))
        #expect(s.title == "refactor parser")
        #expect(s.model == nil)
    }

    @Test func returnsNilForEmptyOrCleared() {
        // The hook clears @cmux_agent to remove the chip → empty value.
        #expect(Status.parse("") == nil)
        #expect(Status.parse("   \n") == nil)
    }

    @Test func returnsNilForMissingRequiredFields() {
        #expect(Status.parse(#"{"state":"working"}"#) == nil)        // no agent
        #expect(Status.parse(#"{"agent":"claude"}"#) == nil)          // no state
        #expect(Status.parse(#"{"agent":"","state":"idle"}"#) == nil) // empty agent
        #expect(Status.parse(#"{"agent":"claude","state":"weird"}"#) == nil) // unknown state
    }

    @Test func returnsNilForNonJSON() {
        #expect(Status.parse("not json") == nil)
        #expect(Status.parse("{broken") == nil)
    }
}
