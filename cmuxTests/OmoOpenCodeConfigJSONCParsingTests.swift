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

/// Regression coverage for the plugin-registration write path stripping JSONC
/// comments out of the user's real `~/.config/opencode/opencode.json`.
///
/// opencode treats `opencode.json` as JSONC, so cmux must register its session
/// plugin with a surgical, comment-preserving edit rather than re-serializing the
/// decoded dictionary back to strict JSON. See
/// https://github.com/manaflow-ai/cmux/pull/6187 for the original report.
@Suite("opencode.json JSONC-preserving plugin registration")
struct OmoOpenCodePluginRegistrationTests {
    /// Inserting the `plugin` property into a JSONC document must keep the
    /// surrounding comments and trailing commas intact.
    @Test
    func insertingPluginPreservesComments() throws {
        let source = """
        // be in -*- jsonc -*- mode
        {
          // primary model
          "model": "github-copilot/claude-opus-4.8",
        }
        """
        let valueJSON = try #require(CMUXCLI.openCodePluginListValueJSON(["cmux-session"]))
        let edited = try #require(
            JSONCObjectEditor.setRootProperty(key: "plugin", valueJSON: valueJSON, in: source)
        )
        #expect(edited.contains("// be in -*- jsonc -*- mode"))
        #expect(edited.contains("// primary model"))
        #expect(edited.contains("\"plugin\""))
        #expect(edited.contains("cmux-session"))

        // The edited document must still decode (as JSONC) back to the expected shape.
        let config = try CMUXCLI.parseOpenCodeConfig(
            data: Data(edited.utf8),
            sourcePath: "/tmp/opencode.json"
        )
        #expect(config["model"] as? String == "github-copilot/claude-opus-4.8")
        let plugins = try #require(config["plugin"] as? [Any])
        #expect(plugins.contains { $0 as? String == "cmux-session" })
    }

    /// Replacing an existing `plugin` array must keep unrelated comments intact.
    @Test
    func replacingPluginPreservesComments() throws {
        let source = """
        {
          // keep me
          "plugin": [
            "existing-plugin",
          ],
          "model": "x", /* inline */
        }
        """
        let valueJSON = try #require(
            CMUXCLI.openCodePluginListValueJSON(["existing-plugin", "cmux-session"])
        )
        let edited = try #require(
            JSONCObjectEditor.setRootProperty(key: "plugin", valueJSON: valueJSON, in: source)
        )
        #expect(edited.contains("// keep me"))
        #expect(edited.contains("/* inline */"))
        let config = try CMUXCLI.parseOpenCodeConfig(
            data: Data(edited.utf8),
            sourcePath: "/tmp/opencode.json"
        )
        let plugins = try #require(config["plugin"] as? [Any])
        #expect(plugins.compactMap { $0 as? String } == ["existing-plugin", "cmux-session"])
        #expect(config["model"] as? String == "x")
    }

    /// The logical no-op comparison must treat reordering-free identical lists as
    /// equal so an already-registered config is never rewritten.
    @Test
    func pluginListsEqualDetectsNoOp() {
        #expect(CMUXCLI.openCodePluginListsEqual(["cmux-session"], ["cmux-session"]))
        #expect(!CMUXCLI.openCodePluginListsEqual([], ["cmux-session"]))
        #expect(!CMUXCLI.openCodePluginListsEqual(["a"], ["a", "cmux-session"]))
    }
}
