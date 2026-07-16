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

    @Test("pup launched by cmux (CMUX_AGENT_LAUNCH_KIND=code-puppy) matches")
    func pupViaLaunchKind() throws {
        // `pup` is the second console script, but the bare basename is NOT a
        // detection matcher because ericchiang/pup (a popular HTML CLI) shares
        // it. When cmux launches the alias it stamps the launch kind, so the
        // agent is still identified without false-positiving the HTML tool.
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "pup",
                processPath: "/Users/example/.venv/bin/pup",
                arguments: ["/Users/example/.venv/bin/pup"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "code-puppy"]
            )
        )
        #expect(definition.id == "code-puppy")
    }

    // MARK: - Module invocation

    @Test("python -m code_puppy matches via argument needle")
    func pythonModuleInvocation() throws {
        // code_puppy appears as an argv token, matched by the code_puppy needle.
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

    // MARK: - Wrapper launchers

    @Test("uvx code-puppy matches via code-puppy argument needle")
    func uvxCodePuppyArgNeedle() throws {
        // uvx / pipx run code-puppy: the wrapper is the process, code-puppy
        // appears only as an argument token.
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "uvx",
                processPath: "/Users/example/.local/bin/uvx",
                arguments: ["/Users/example/.local/bin/uvx", "code-puppy"],
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

    @Test("bare pup process is NOT detected as code-puppy (ericchiang/pup HTML CLI)")
    func barePupIsNotFalseMatched() {
        // github.com/ericchiang/pup is a widely-installed HTML processor. Its
        // bare process must never be mistaken for Code Puppy, so `pup` is not a
        // directBasename or argv needle. Only an explicit cmux launch kind or a
        // real code-puppy/code_puppy token identifies the agent.
        let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "pup",
            processPath: "/opt/homebrew/bin/pup",
            arguments: ["/opt/homebrew/bin/pup", "div.title", "text{}"],
            environment: [:]
        )
        #expect(definition == nil)
    }

    @Test("bare pup with a different launch kind resolves to that agent, not code-puppy")
    func pupWithOtherLaunchKindIsNotCodePuppy() throws {
        // Since `pup` is no longer a code-puppy basename, an unrelated launch
        // kind is honored as-is.
        let definition = try #require(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "pup",
                processPath: nil,
                arguments: [],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "codex"]
            )
        )
        #expect(definition.id == "codex")
    }
}
