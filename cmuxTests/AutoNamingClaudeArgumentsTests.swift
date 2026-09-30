import Foundation
import Testing

// `AutoNamingEnvironmentPolicy` lives in the shared auto-naming CLI file,
// which is compiled directly into this test target (see AutoNamingEngineTests
// for the same arrangement).

/// Behavior tests for the argument vector cmux hands `claude -p` when it
/// summarizes a transcript into a workspace title.
@Suite struct AutoNamingClaudeArgumentsTests {
    private let policy = AutoNamingEnvironmentPolicy()

    private func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Claude Code validates `--mcp-config` against a schema that requires an
    /// `mcpServers` record. A bare `{}` fails argument validation and the
    /// summarizer exits before producing a title (cmux#9457).
    @Test func mcpConfigIsAValidEmptyServerConfiguration() throws {
        let arguments = policy.claudeSummarizerArguments(from: [:])
        let raw = try #require(value(of: "--mcp-config", in: arguments))
        #expect(raw != "{}")

        let parsed = try JSONSerialization.jsonObject(
            with: Data(raw.utf8)
        ) as? [String: Any]
        let object = try #require(parsed)
        #expect(object["mcpServers"] as? [String: Any] != nil)
        #expect(object.count == 1)
    }

    @Test func keepsToolsAndSessionIsolationFlags() {
        let arguments = policy.claudeSummarizerArguments(from: [:])
        #expect(arguments.first == "-p")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(value(of: "--tools", in: arguments) == "")
    }

    @Test func honorsSmallFastModelOverride() {
        let arguments = policy.claudeSummarizerArguments(from: [:])
        #expect(value(of: "--model", in: arguments) == "haiku")

        let overridden = policy.claudeSummarizerArguments(
            from: ["ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5"]
        )
        #expect(value(of: "--model", in: overridden) == "claude-haiku-4-5")
    }
}
