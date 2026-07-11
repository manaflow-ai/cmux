import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ollama agent detection")
struct OllamaAgentDetectionTests {
    @Test("Only the interactive run command matches Ollama")
    func matchesInteractiveRunOnly() throws {
        let run = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "ollama",
            processPath: "/opt/homebrew/bin/ollama",
            arguments: ["ollama", "run", "qwen3:8b"],
            environment: [:]
        ))
        #expect(run.id == "ollama")
        #expect(run.promptTurnDetection?.prompt == ">>> ")

        #expect(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "ollama",
            processPath: "/opt/homebrew/bin/ollama",
            arguments: ["ollama", "serve"],
            environment: [:]
        ) == nil)
        #expect(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "ollama",
            processPath: "/opt/homebrew/bin/ollama",
            arguments: ["ollama", "list"],
            environment: [:]
        ) == nil)
        #expect(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "ollama",
            processPath: "/opt/homebrew/bin/ollama",
            arguments: ["ollama", "serve", "run"],
            environment: [:]
        ) == nil)
    }

    @Test("Restorable kind carries Ollama identity and relaunch semantics")
    func restorableKindIsRelaunchOnly() {
        #expect(RestorableAgentKind(rawValue: "ollama") == .ollama)
        #expect(RestorableAgentKind.ollama.rawValue == "ollama")
        #expect(RestorableAgentKind.ollama.restoreMode == .relaunchCommand)
    }
}
