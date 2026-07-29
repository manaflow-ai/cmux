import Foundation
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
        // updating it with task summaries; those win, with the redundant
        // state glyph dropped since the tab already shows the brand icon.
        #expect(
            resolver.displayTitle(
                processTitle: "✳ Claude Code",
                titleAtAgentAttach: "~",
                for: definition("claude")
            ) == "Claude Code"
        )
        #expect(
            resolver.displayTitle(
                processTitle: "✳ Add Codex and Grok CLI support",
                titleAtAgentAttach: "~",
                for: definition("claude")
            ) == "Add Codex and Grok CLI support"
        )
        #expect(
            resolver.displayTitle(
                processTitle: "✶ Thinking through the plan",
                titleAtAgentAttach: nil,
                for: definition("claude")
            ) == "Thinking through the plan"
        )
        #expect(
            resolver.displayTitle(
                processTitle: "Codex — fixing tests",
                titleAtAgentAttach: "~",
                for: definition("codex")
            ) == "Codex — fixing tests"
        )
        // A title that is only a state glyph keeps its original form rather
        // than collapsing to nothing.
        #expect(
            resolver.displayTitle(
                processTitle: "✳",
                titleAtAgentAttach: "~",
                for: definition("claude")
            ) == "✳"
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

/// Behavior coverage for the unconditional foreground-PID agent matcher used
/// by the tab-branding launch fast-path.
@Suite struct CodingAgentDefinitionForegroundPIDTests {
    @Test func invalidPIDFailsClosed() {
        #expect(CmuxTopProcessSnapshot.codingAgentDefinition(foregroundPID: -1) == nil)
        #expect(CmuxTopProcessSnapshot.codingAgentDefinition(foregroundPID: 0) == nil)
    }

    @Test func nonAgentProcessResolvesToNoDefinition() {
        // The test runner itself is a live, inspectable process that matches
        // no agent definition.
        #expect(
            CmuxTopProcessSnapshot.codingAgentDefinition(
                foregroundPID: Int(ProcessInfo.processInfo.processIdentifier)
            ) == nil
        )
    }

    @Test func agentBasenameProcessResolvesUnconditionallyButStaysPromptFiltered() throws {
        // A real process whose executable basename matches an agent definition
        // without prompt-turn support (grok): the unconditional matcher must
        // resolve it through the genuine kernel-path identity rules, while the
        // prompt-gated matcher keeps filtering it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-matcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grokBinary = directory.appendingPathComponent("grok")
        // cat blocked on an open pipe lives until terminated, so the test has
        // no wall-clock dependency on the helper process's lifetime.
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: grokBinary.path)

        let process = Process()
        process.executableURL = grokBinary
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let pid = Int(process.processIdentifier)
        #expect(CmuxTopProcessSnapshot.codingAgentDefinition(foregroundPID: pid)?.id == "grok")
        #expect(CmuxTopProcessSnapshot.promptAgentDefinition(foregroundPID: pid) == nil)
    }
}
