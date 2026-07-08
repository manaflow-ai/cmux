import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TerminalTabAgentIconTests {
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
            liveStatusKeys: [statusKey],
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
            liveStatusKeys: [statusKey],
            restoredAgentKind: nil
        )

        #expect(asset == nil)
    }

    @Test func restoredAgentIsUsedWhenNoLiveAgentHasBrandAsset() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveStatusKeys: ["amp"],
            restoredAgentKind: "codex"
        )

        #expect(asset == "AgentIcons/Codex")
    }

    @Test func liveAgentWinsOverRestoredAgent() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveStatusKeys: ["opencode"],
            restoredAgentKind: "codex"
        )

        #expect(asset == "AgentIcons/OpenCode")
    }

    @Test func multipleLiveAgentsChooseDeterministicallyBySortedStatusKey() {
        let asset = TerminalTabAgentIconResolver().assetName(
            liveStatusKeys: ["grok", "codex"],
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
}
