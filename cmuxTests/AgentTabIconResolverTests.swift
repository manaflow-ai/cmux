import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite struct AgentTabIconResolverTests {
    private let resolver = AgentTabIconResolver()

    // MARK: assetName(forStatusKey:)

    @Test func mapsKeyedStatusKeysToBrandAssets() {
        #expect(resolver.assetName(forStatusKey: "claude_code") == "AgentIcons/Claude")
        #expect(resolver.assetName(forStatusKey: "codex") == "AgentIcons/Codex")
        #expect(resolver.assetName(forStatusKey: "grok") == "AgentIcons/Grok")
        #expect(resolver.assetName(forStatusKey: "augment") == "AgentIcons/Augment")
        #expect(resolver.assetName(forStatusKey: "cursor") == "AgentIcons/Cursor")
        #expect(resolver.assetName(forStatusKey: "antigravity") == "AgentIcons/Antigravity")
    }

    @Test func returnsNilForUnknownStatusKey() {
        #expect(resolver.assetName(forStatusKey: "definitely-not-an-agent") == nil)
    }

    // MARK: assetName(forStatusKeys:) priority resolution

    @Test func resolvesSingleStatusKeyToItsAsset() {
        #expect(resolver.assetName(forStatusKeys: ["cursor"]) == "AgentIcons/Cursor")
    }

    @Test func picksHighestPriorityWinnerWhenMultipleKeysCollide() {
        // claude_code outranks every other brand.
        #expect(resolver.assetName(forStatusKeys: ["grok", "claude_code", "cursor"]) == "AgentIcons/Claude")
        // Without claude_code, codex outranks augment/grok/cursor.
        #expect(resolver.assetName(forStatusKeys: ["grok", "augment", "codex"]) == "AgentIcons/Codex")
        // augment outranks grok and cursor.
        #expect(resolver.assetName(forStatusKeys: ["cursor", "grok", "augment"]) == "AgentIcons/Augment")
    }

    @Test func returnsNilForEmptyOrUnrecognizedStatusKeys() {
        #expect(resolver.assetName(forStatusKeys: []) == nil)
        #expect(resolver.assetName(forStatusKeys: ["bash", "node"]) == nil)
    }

    // MARK: scanStatusKey — process name / comm

    @Test func matchesByProcessCommName() {
        #expect(resolver.scanStatusKey(name: "grok", path: nil, arguments: []) == "grok")
        #expect(resolver.scanStatusKey(name: "agy", path: nil, arguments: []) == "antigravity")
        #expect(resolver.scanStatusKey(name: "Codex", path: nil, arguments: []) == "codex")
    }

    // MARK: scanStatusKey — executable path basename

    @Test func matchesByExecutablePathBasename() {
        #expect(resolver.scanStatusKey(name: "node", path: "/opt/homebrew/bin/auggie", arguments: []) == "augment")
    }

    // MARK: scanStatusKey — argv-token basename (script launches)

    @Test func matchesAuggieByArgvTokenBasename() {
        // `auggie` launches as `node /opt/homebrew/bin/auggie`; comm/path are `node`.
        let argv = ["node", "/opt/homebrew/bin/auggie", "--some-flag"]
        #expect(resolver.scanStatusKey(name: "node", path: "/usr/bin/node", arguments: argv) == "augment")
    }

    // MARK: scanStatusKey — argv path substring (cursor-agent wrapper)

    @Test func matchesCursorAgentByArgvSubstring() {
        // cursor-agent execs `node …/cursor-agent/versions/<v>/index.js`; argv basenames are
        // node/index.js plus the invocation alias, so the stable path fragment is the signal.
        let argv = [
            "cursor-agent",
            "--use-system-ca",
            "/Users/x/.local/share/cursor-agent/versions/2026.06.04-5fd875e/index.js",
        ]
        #expect(resolver.scanStatusKey(name: "node", path: "/usr/bin/node", arguments: argv) == "cursor")
    }

    @Test func matchesCursorWhenLaunchedViaBareAgentAlias() {
        // Invoked as the bare `agent` symlink: argv[0] basename is `agent` (too generic to match),
        // but the exec'd script path still contains `cursor-agent`.
        let argv = [
            "agent",
            "/Users/x/.local/share/cursor-agent/versions/2026.06.04-5fd875e/index.js",
        ]
        #expect(resolver.scanStatusKey(name: "node", path: "/usr/bin/node", arguments: argv) == "cursor")
    }

    @Test func doesNotMatchUnrelatedAgentProcesses() {
        // The bare `agent` alias alone (no cursor-agent path fragment) must not match.
        #expect(resolver.scanStatusKey(name: "ssh-agent", path: "/usr/bin/ssh-agent", arguments: ["ssh-agent"]) == nil)
        #expect(resolver.scanStatusKey(name: "node", path: "/usr/bin/node", arguments: ["agent"]) == nil)
        #expect(resolver.scanStatusKey(name: "zsh", path: "/bin/zsh", arguments: ["-zsh"]) == nil)
    }
}
