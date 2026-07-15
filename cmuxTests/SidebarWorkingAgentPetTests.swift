import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkingAgentPetTests {
    @Test
    func speciesMapsKnownAgentStatusKeys() {
        #expect(PixelAgentPet.Species(agentStatusKey: "claude_code") == .claude)
        #expect(PixelAgentPet.Species(agentStatusKey: "codex") == .codex)
        #expect(PixelAgentPet.Species(agentStatusKey: "opencode") == .opencode)
        #expect(PixelAgentPet.Species(agentStatusKey: "pi") == .pi)
        #expect(PixelAgentPet.Species(agentStatusKey: "ollama") == .ollama)
    }

    @Test
    func speciesFallsBackToOtherForUnmappedKeys() {
        #expect(PixelAgentPet.Species(agentStatusKey: "grok") == .other)
        #expect(PixelAgentPet.Species(agentStatusKey: "totally-unknown") == .other)
    }

    @Test
    func primaryStatusKeyIsNilWhenNothingRunning() {
        #expect(SidebarWorkingAgentPresentation.primaryStatusKey(among: []) == nil)
    }

    @Test
    func primaryStatusKeyPrefersClaudeThenFirstClassAgents() {
        // Claude wins whenever it is one of the running agents.
        #expect(SidebarWorkingAgentPresentation.primaryStatusKey(among: ["codex", "claude_code"]) == "claude_code")
        // Otherwise the highest remaining first-class agent.
        #expect(SidebarWorkingAgentPresentation.primaryStatusKey(among: ["pi", "codex"]) == "codex")
        #expect(SidebarWorkingAgentPresentation.primaryStatusKey(among: ["pi", "opencode"]) == "opencode")
    }

    @Test
    func primaryStatusKeyFallsBackToAlphabeticalForUnprioritizedKeys() {
        #expect(SidebarWorkingAgentPresentation.primaryStatusKey(among: ["grok", "amp"]) == "amp")
    }

    @Test
    func displayNameUsesBrandNames() {
        #expect(SidebarWorkingAgentPresentation.displayName(forStatusKey: "claude_code") == "Claude")
        #expect(SidebarWorkingAgentPresentation.displayName(forStatusKey: "rovodev") == "Rovo Dev")
        #expect(SidebarWorkingAgentPresentation.displayName(forStatusKey: "unknown_agent") == "Unknown Agent")
    }
}
