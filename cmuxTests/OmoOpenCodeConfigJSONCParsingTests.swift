import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for `cmux omo` (and the session-plugin registration path)
/// failing to start when the user's `opencode.json` contains JSONC syntax.
///
/// opencode itself treats `opencode.json` as JSONC, so a leading `// ...` mode
/// line, block comments, and trailing commas are all valid. Before the fix, cmux
/// decoded the file with strict `JSONSerialization`, which rejects comments and
/// aborts with "Failed to parse … Fix the JSON syntax and retry." See
/// https://github.com/manaflow-ai/cmux for the omo config layering code.
@Suite("omo opencode.json JSONC parsing")
struct OmoOpenCodeConfigJSONCParsingTests {
    /// The exact shape that broke `cmux omo`: a leading editor mode-line comment
    /// on the very first byte of the file, ahead of the opening brace.
    @Test
    func parsesLeadingLineCommentBeforeOpeningBrace() throws {
        let source = """
        // be in -*- jsonc -*- mode
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "github-copilot/claude-opus-4.8"
        }
        """
        let config = try CMUXCLI.parseOpenCodeConfig(
            data: Data(source.utf8),
            sourcePath: "/tmp/opencode.json"
        )
        #expect(config["model"] as? String == "github-copilot/claude-opus-4.8")
        #expect(config["$schema"] as? String == "https://opencode.ai/config.json")
    }

    /// Line comments, block comments, and a trailing comma should all decode the
    /// same way opencode reads them.
    @Test
    func parsesInlineBlockCommentsAndTrailingCommas() throws {
        let source = """
        {
          // line comment
          "model": "x", /* trailing block comment */
          "permission": {
            "external_directory": {
              "~/foo/**": "allow",
            },
          },
        }
        """
        let config = try CMUXCLI.parseOpenCodeConfig(
            data: Data(source.utf8),
            sourcePath: "/tmp/opencode.json"
        )
        #expect(config["model"] as? String == "x")
        let permission = try #require(config["permission"] as? [String: Any])
        let external = try #require(permission["external_directory"] as? [String: Any])
        #expect(external["~/foo/**"] as? String == "allow")
    }

    /// Comment-free strict JSON must keep working unchanged.
    @Test
    func parsesPlainStrictJSON() throws {
        let source = #"{"model":"y"}"#
        let config = try CMUXCLI.parseOpenCodeConfig(
            data: Data(source.utf8),
            sourcePath: "/tmp/opencode.json"
        )
        #expect(config["model"] as? String == "y")
    }

    /// Genuinely malformed config must still surface the user-facing error so the
    /// fix does not mask real syntax mistakes.
    @Test
    func throwsCLIErrorForMalformedConfig() {
        let source = "{ not valid json"
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseOpenCodeConfig(
                data: Data(source.utf8),
                sourcePath: "/tmp/opencode.json"
            )
        }
    }
}
