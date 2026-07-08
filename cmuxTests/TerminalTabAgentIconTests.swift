import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TerminalTabAgentIconTests {
    private func liveAgent(
        _ statusKey: String,
        startSeconds: Int64? = nil,
        startMicroseconds: Int64 = 0
    ) -> TerminalTabAgentIconResolver.LiveAgent {
        TerminalTabAgentIconResolver.LiveAgent(
            statusKey: statusKey,
            processStart: startSeconds.map {
                AgentPIDProcessIdentity(pid: 100, startSeconds: $0, startMicroseconds: startMicroseconds)
            }
        )
    }

    @Test(arguments: [
        ("claude_code", "AgentIcons/Claude"),
        ("codex", "AgentIcons/Codex"),
        ("opencode", "AgentIcons/OpenCode"),
        ("pi", "AgentIcons/Pi"),
        ("omp", "AgentIcons/Pi"),
        ("grok", "AgentIcons/Grok"),
        ("rovodev", "AgentIcons/RovoDev"),
        ("antigravity", "AgentIcons/Antigravity"),
        ("hermes-agent", "AgentIcons/HermesAgent"),
    ])
    func liveStatusKeyMapsToAsset(statusKey: String, expectedAsset: String) {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent(statusKey)],
            restoredAgentKind: nil
        )

        #expect(asset == expectedAsset)
    }

    @Test(arguments: [
        "amp",
        "gemini",
        "cursor",
        "copilot",
        "codebuddy",
        "factory",
        "kiro",
        "qoder",
    ])
    func unsupportedAgentsUseSystemTerminalIcon(statusKey: String) {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent(statusKey)],
            restoredAgentKind: nil
        )

        #expect(asset == nil)
    }

    @Test func restoredAgentIsUsedWhenNoLiveAgentHasBrandAsset() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("amp")],
            restoredAgentKind: "codex"
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func liveAgentWinsOverRestoredAgent() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("opencode")],
            restoredAgentKind: "codex"
        )

        #expect(asset == "AgentIcons/OpenCode")
    }

    @Test func newestLiveAgentProcessWinsRegardlessOfKeyOrder() {
        // "grok" sorts after "codex" alphabetically but started later, so the
        // tab shows the agent the user launched most recently.
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("codex", startSeconds: 1_000),
                liveAgent("grok", startSeconds: 2_000),
            ],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/Grok")
    }

    @Test func processStartMicrosecondsBreakSameSecondTies() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("grok", startSeconds: 1_000, startMicroseconds: 10),
                liveAgent("codex", startSeconds: 1_000, startMicroseconds: 20),
            ],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func agentWithRecordedStartWinsOverAgentWithoutOne() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [
                liveAgent("claude_code"),
                liveAgent("rovodev", startSeconds: 1),
            ],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/RovoDev")
    }

    @Test func agentsWithoutRecordedStartsFallBackToDeterministicKeyOrder() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveAgents: [liveAgent("grok"), liveAgent("codex")],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func rawAgentPIDKeysAreNormalizedBeforeResolvingAssets() {
        let asset = TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: ["codex.12345"],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func rawAgentPIDKeyIdentitiesOrderConcurrentAgentsByRecency() {
        let asset = TerminalTabAgentIconResolver().assetName(
            agentPIDKeys: ["codex.101", "grok.102"],
            processIdentities: [
                "codex.101": AgentPIDProcessIdentity(pid: 101, startSeconds: 5, startMicroseconds: 0),
                "grok.102": AgentPIDProcessIdentity(pid: 102, startSeconds: 9, startMicroseconds: 0),
            ],
            restoredAgentKind: nil
        )

        #expect(asset == "AgentIcons/Grok")
    }
}
