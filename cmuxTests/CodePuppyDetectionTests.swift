import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for Code Puppy process detection.
///
/// Two-commit structure (per repo policy):
///   Commit 1 (this file): tests fail because the builtin definition does not exist yet.
///   Commit 2: adds the definition to CmuxTaskManagerCodingAgentDefinition+BuiltIns.swift.
@Suite("Code Puppy detection")
struct CodePuppyDetectionTests {

    // MARK: - Basename matching

    @Test("code-puppy console script matches by direct basename")
    func codePuppyConsoleBinaryBasename() throws {
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "code-puppy",
                processPath: "/Users/example/.venv/bin/code-puppy",
                arguments: ["/Users/example/.venv/bin/code-puppy"],
                environment: [:]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    @Test("code_puppy underscore basename matches (some installs use underscore)")
    func codePuppyUnderscoreBasename() throws {
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "code_puppy",
                processPath: "/Users/example/.local/bin/code_puppy",
                arguments: ["/Users/example/.local/bin/code_puppy"],
                environment: [:]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    @Test("pup alias (second pyproject.toml console script) matches")
    func pupAlias() throws {
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "pup",
                processPath: "/Users/example/.venv/bin/pup",
                arguments: ["/Users/example/.venv/bin/pup"],
                environment: [:]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    // MARK: - Module invocation

    @Test("python -m code_puppy matches via argument needle")
    func pythonModuleInvocation() throws {
        // python is an argumentHostBasename; code_puppy is the needle.
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "python",
                processPath: "/Users/example/.venv/bin/python",
                arguments: ["/Users/example/.venv/bin/python", "-m", "code_puppy"],
                environment: [:]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    @Test("python3 -m code_puppy also matches")
    func python3ModuleInvocation() throws {
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "python3",
                processPath: "/usr/bin/python3",
                arguments: ["/usr/bin/python3", "-m", "code_puppy"],
                environment: [:]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    // MARK: - Environment / launch-kind fallback

    @Test("CMUX_AGENT_LAUNCH_KIND=code-puppy matches when process is uv")
    func uvRunViaLaunchKindEnv() throws {
        // uv run code-puppy: uv is the process, launch kind carries the agent identity.
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "uv",
                processPath: "/Users/example/.cargo/bin/uv",
                arguments: ["/Users/example/.cargo/bin/uv", "run", "code-puppy"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "code-puppy"]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    // MARK: - Asset name

    @Test("definition carries the CodePuppy brand asset name")
    func assetName() throws {
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "code-puppy",
                processPath: nil,
                arguments: [],
                environment: [:]
            )
        )
        #expect(definition.assetName == "AgentIcons/CodePuppy")
    }

    // MARK: - No false positives

    @Test("bare python process without code_puppy argument does not match")
    func noPythonFalsePositive() {
        let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "python",
            processPath: nil,
            arguments: ["/usr/bin/python", "my_script.py"],
            environment: [:]
        )
        #expect(definition == nil)
    }

    @Test("pup does not match when CMUX_AGENT_LAUNCH_KIND is a different agent")
    func pupWithOtherLaunchKindDoesNotFalseMatch() throws {
        // pup is a directBasename for code-puppy, so it matches regardless of env.
        // This test confirms the definition id is still code-puppy (not the env agent).
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "pup",
                processPath: nil,
                arguments: [],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "codex"]
            )
        )
        // Direct basename wins over CMUX_AGENT_LAUNCH_KIND per matchingDefinition priority.
        #expect(definition.id == "code-puppy")
    }
}
