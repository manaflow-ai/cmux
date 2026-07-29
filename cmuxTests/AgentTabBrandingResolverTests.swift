import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for `AgentTabBrandingResolver`: status-key → definition
/// resolution and the agent-aware tab title rule that brands terminal tabs
/// while a coding-agent CLI is attached.
@Suite struct AgentTabBrandingResolverTests {
    private let resolver = AgentTabBrandingResolver()
    private let definitions = CmuxTaskManagerCodingAgentDefinition.builtIns

    private func definition(_ id: String) -> CmuxTaskManagerCodingAgentDefinition {
        definitions.first { $0.id == id }!
    }

    // MARK: - Status key → definition

    @Test func claudeCodeStatusKeyResolvesToClaudeDefinition() {
        let resolved = resolver.definition(forStatusKeys: ["claude_code"], in: definitions)
        #expect(resolved?.id == "claude")
        #expect(resolved?.displayName == "Claude Code")
    }

    @Test(arguments: ["codex", "grok", "opencode", "gemini"])
    func statusKeyResolvesToMatchingDefinition(key: String) {
        #expect(resolver.definition(forStatusKeys: [key], in: definitions)?.id == key)
    }

    @Test func unknownStatusKeyResolvesToNoDefinition() {
        #expect(resolver.definition(forStatusKeys: ["not-an-agent"], in: definitions) == nil)
        #expect(resolver.definition(forStatusKeys: [], in: definitions) == nil)
    }

    @Test func multipleStatusKeysResolveDeterministically() {
        let keys: Set<String> = ["grok", "codex"]
        let first = resolver.definition(forStatusKeys: keys, in: definitions)
        let second = resolver.definition(forStatusKeys: Array(keys).reversed(), in: definitions)
        #expect(first?.id == "codex")
        #expect(first?.id == second?.id)
    }

    // MARK: - Tab title rule

    @Test func launchBrandingShowsDisplayNameUntilCLISetsATitle() {
        // codex never sets a terminal title, so the shell's cwd title is
        // still exactly what it was at attach: the tab reads "Codex".
        #expect(
            resolver.displayTitle(
                processTitle: "~/Tools/project",
                titleAtAgentAttach: "~/Tools/project",
                for: definition("codex")
            ) == "Codex"
        )
        #expect(
            resolver.displayTitle(processTitle: "~", titleAtAgentAttach: "~", for: definition("grok"))
                == "Grok"
        )
    }

    @Test func cliOwnedTitleWinsAfterLaunch() {
        // Claude Code replaces the title right after launch and keeps
        // updating it with task summaries; those always win verbatim.
        #expect(
            resolver.displayTitle(
                processTitle: "✳ Claude Code",
                titleAtAgentAttach: "~",
                for: definition("claude")
            ) == "✳ Claude Code"
        )
        #expect(
            resolver.displayTitle(
                processTitle: "✳ Add Codex and Grok CLI support",
                titleAtAgentAttach: "~",
                for: definition("claude")
            ) == "✳ Add Codex and Grok CLI support"
        )
        #expect(
            resolver.displayTitle(
                processTitle: "Codex — fixing tests",
                titleAtAgentAttach: "~",
                for: definition("codex")
            ) == "Codex — fixing tests"
        )
    }

    @Test func bareBinaryNameTitleIsNormalizedToDisplayName() {
        // grok's own launch title is a bare lowercase "grok".
        #expect(
            resolver.displayTitle(processTitle: "grok", titleAtAgentAttach: "~", for: definition("grok"))
                == "Grok"
        )
        #expect(
            resolver.displayTitle(processTitle: "claude", titleAtAgentAttach: "~", for: definition("claude"))
                == "Claude Code"
        )
    }

    @Test func emptyTitleGetsDisplayName() {
        #expect(
            resolver.displayTitle(processTitle: "", titleAtAgentAttach: nil, for: definition("codex"))
                == "Codex"
        )
        #expect(
            resolver.displayTitle(processTitle: "  ", titleAtAgentAttach: "~", for: definition("grok"))
                == "Grok"
        )
    }

    // MARK: - Brand icons

    @Test(arguments: [
        ("claude", "AgentIcons/Claude"),
        ("codex", "AgentIcons/Codex"),
        ("grok", "AgentIcons/Grok"),
        ("opencode", "AgentIcons/OpenCode"),
    ])
    func builtInDefinitionCarriesBrandIcon(id: String, assetName: String) {
        #expect(definition(id).assetName == assetName)
    }
}
