import Darwin
import Foundation
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
        #expect(run.promptTurnDetection?.waitingPromptSuffixes == ["Send a message (/? for help)"])

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
        // A bare "ollama" argv token must never satisfy identity: wrappers
        // such as `npm run ollama` share the "run" prefix shape.
        #expect(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "npm",
            processPath: "/opt/homebrew/bin/npm",
            arguments: ["npm", "run", "ollama"],
            environment: [:]
        ) == nil)
    }

    @Test("A custom vault registration may reuse the ollama id")
    func customOllamaRegistrationStaysDecodable() throws {
        let registration = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: Data(Self.customOllamaRegistrationJSON.utf8)
        )
        #expect(registration.id == "ollama")
        #expect(registration.name == "My Ollama")
    }

    @Test("Snapshots with a custom ollama registration keep registration-owned resume")
    func snapshotKeepsCustomOllamaRegistrationIdentity() throws {
        let snapshotJSON = """
        {
          "kind": "ollama",
          "sessionId": "abc123",
          "registration": \(Self.customOllamaRegistrationJSON)
        }
        """
        let snapshot = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: Data(snapshotJSON.utf8)
        )
        #expect(snapshot.kind.customAgentID == "ollama")
        #expect(snapshot.kind.restoreMode == .resumeSession)

        let bare = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: Data(#"{"kind": "ollama", "sessionId": ""}"#.utf8)
        )
        #expect(bare.kind == .ollama)
        #expect(bare.kind.restoreMode == .relaunchCommand)
    }

    @Test("Pipe-backed stdio is not interactive")
    func pipedStdioIsNotInteractive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(!RestorableAgentSessionIndex.processHasInteractiveTerminalStdio(
            pid: Int(process.processIdentifier)
        ))
    }

    @Test("PTY-backed stdio is interactive")
    func ptyStdioIsInteractive() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0)
        try #require(unlockpt(master) == 0)
        let slavePath = String(cString: ptsname(master))
        let slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        try #require(slaveFD >= 0)
        defer { close(slaveFD) }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(RestorableAgentSessionIndex.processHasInteractiveTerminalStdio(
            pid: Int(process.processIdentifier)
        ))
    }

    private static let customOllamaRegistrationJSON = """
    {
      "id": "ollama",
      "name": "My Ollama",
      "sessionIdSource": "--session",
      "resumeCommand": "my-ollama --resume {{sessionId}}"
    }
    """

    @Test("Restorable kind carries Ollama identity and relaunch semantics")
    func restorableKindIsRelaunchOnly() {
        #expect(RestorableAgentKind(rawValue: "ollama") == .ollama)
        #expect(RestorableAgentKind.ollama.rawValue == "ollama")
        #expect(RestorableAgentKind.ollama.restoreMode == .relaunchCommand)
    }

    @Test("Inherited claude launch env does not misidentify an ollama process")
    func inheritedLaunchKindDoesNotOverrideExecutableIdentity() throws {
        // A pane that launched claude exports CMUX_AGENT_LAUNCH_* to every
        // descendant process. An `ollama run` started later in that pane must
        // be identified by its own executable, not the inherited env.
        let inheritedEnvironment = [
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Users/user/.local/bin/claude",
        ]
        let definition = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "ollama",
            processPath: "/usr/local/Cellar/ollama/0.31.1/libexec/ollama",
            arguments: ["ollama", "run", "qwen3:0.6b"],
            environment: inheritedEnvironment
        ))
        #expect(definition.id == "ollama")
        #expect(definition.promptTurnDetection != nil)

        // The wrapper that actually launched claude keeps its env identity.
        let wrapper = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "zsh",
            processPath: "/bin/zsh",
            arguments: ["/bin/zsh", "-lic", "exec \"$CMUX_AGENT_LAUNCH_EXECUTABLE\""],
            environment: inheritedEnvironment
        ))
        #expect(wrapper.id == "claude")
    }

    @Test("Textbox agent detection recognizes interactive Ollama sessions")
    func textBoxAgentDetectionRecognizesOllama() {
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "restoredAgent:ollama"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "agentPIDKey:ollama"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "initialCommand:ollama run qwen3:8b"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "tmuxStartCommand:ollama run qwen3:8b --think high"))
        // Utility subcommands are not interactive agents.
        #expect(!TextBoxAgentDetection.supportsAgentPrefixes(context: "initialCommand:ollama serve"))
        #expect(!TextBoxAgentDetection.supportsAgentPrefixes(context: "initialCommand:ollama pull qwen3:8b"))
    }

    @Test("Textbox launch command context binds only the run subcommand")
    func textBoxLaunchCommandContextRequiresRun() {
        #expect(TextBoxAgentDetection.boundedLaunchCommandContext(from: "ollama run qwen3:8b") == "ollama")
        #expect(TextBoxAgentDetection.boundedLaunchCommandContext(from: "ollama serve") == nil)
        #expect(TextBoxAgentDetection.boundedLaunchCommandContext(from: "ollama list") == nil)
    }

    @Test("Sleepy census buckets ollama status keys")
    func sleepyCensusBucketsOllama() {
        #expect(SleepyAgentCensus.bucket(forStatusKey: "ollama") == .ollama)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "ollama.session-abc") == .ollama)
        var counts = SleepyAgentCounts()
        counts.ollama = 2
        counts.claude = 1
        #expect(counts.total == 3)
    }
}
