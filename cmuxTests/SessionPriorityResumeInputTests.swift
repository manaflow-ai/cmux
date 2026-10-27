import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The command typed into a pane restarted for a session priority target must resume the same
/// session with the target's effort on `CLAUDE_CODE_EFFORT_LEVEL` (Claude Code's `/effort` would
/// write the user's settings file) and its model on `--model`. Everything else the launch
/// recorded, the account's `CLAUDE_CONFIG_DIR` included, is replayed unchanged.
struct SessionPriorityResumeInputTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let project = "/Users/cmux-test/project"

    private var changeDirectoryPrefix: String {
        "cd -- '\(project)' 2>/dev/null || [ ! -d '\(project)' ] && "
    }

    @Test
    func effortRidesOnTheEnvPrefix() throws {
        let resume = resumeInput(claudeSnapshot(), target: SessionPriorityTarget(effort: .high))

        let command = try #require(resume.posixCommand())

        #expect(command.hasPrefix(changeDirectoryPrefix))
        let effort = try #require(command.range(of: "CLAUDE_CODE_EFFORT_LEVEL=high"))
        let resumeOption = try #require(command.range(of: "--resume"))
        let session = try #require(command.range(of: sessionID))
        #expect(effort.upperBound <= resumeOption.lowerBound)
        #expect(resumeOption.upperBound <= session.lowerBound)
        #expect(resume.typedInput(dialect: .posix) == command + "\n")
    }

    @Test
    func effortReplacesTheRecordedLevel() throws {
        let snapshot = claudeSnapshot(environment: ["CLAUDE_CODE_EFFORT_LEVEL": "low"])

        let command = try #require(resumeInput(snapshot, target: SessionPriorityTarget(effort: .xhigh)).posixCommand())

        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=xhigh"))
        #expect(occurrences(of: "CLAUDE_CODE_EFFORT_LEVEL=", in: command) == 1)
    }

    @Test
    func emptyTargetKeepsTheRecordedEnvironment() throws {
        let snapshot = claudeSnapshot(environment: ["CLAUDE_CODE_EFFORT_LEVEL": "low"])

        let command = try #require(resumeInput(snapshot, target: SessionPriorityTarget()).posixCommand())

        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=low"))
        #expect(occurrences(of: "CLAUDE_CODE_EFFORT_LEVEL=", in: command) == 1)
    }

    @Test
    func modelReplacesTheRecordedModelArgument() throws {
        let command = try #require(
            resumeInput(claudeSnapshot(), target: SessionPriorityTarget(model: "opus")).posixCommand()
        )

        #expect(occurrences(of: "--model", in: command) == 1)
        #expect(command.contains("opus"))
        #expect(!command.contains("sonnet"))
        #expect(!command.contains("ANTHROPIC_MODEL"))
    }

    @Test
    func accountEnvironmentIsReplayedUnchanged() throws {
        let configDirectory = "\(home)/.claude-work"
        let snapshot = claudeSnapshot(environment: ["CLAUDE_CONFIG_DIR": configDirectory])

        let command = try #require(
            resumeInput(snapshot, target: SessionPriorityTarget(effort: .low, model: "opus")).posixCommand()
        )

        #expect(command.contains("CLAUDE_CONFIG_DIR=\(configDirectory)"))
        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=low"))
    }

    @Test
    func ignoredCwdRegistrationGetsNoPrefix() throws {
        var snapshot = claudeSnapshot()
        snapshot.registration = CmuxVaultAgentRegistration(
            id: "claude-cwd-ignore",
            name: "Claude Ignoring Cwd",
            detect: CmuxVaultAgentDetectRule(processName: "claude"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "claude --resume {{sessionId}}",
            cwd: .ignore
        )

        let command = try #require(resumeInput(snapshot, target: SessionPriorityTarget(effort: .high)).posixCommand())

        #expect(!command.hasPrefix("cd "))
        #expect(!command.contains("cd -- '\(project)'"))
        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=high"))
    }

    @Test
    func targetWithoutALaunchCaptureIsNotResumed() {
        // A plain `claude --resume` would restart the pane without the target, and the next
        // reconcile would restart it again.
        var snapshot = claudeSnapshot()
        snapshot.launchCommand = nil

        #expect(resumeInput(snapshot, target: SessionPriorityTarget(effort: .high)).posixCommand() == nil)
        #expect(resumeInput(snapshot, target: SessionPriorityTarget(model: "opus")).typedInput() == nil)
    }

    private func resumeInput(
        _ snapshot: SessionRestorableAgentSnapshot,
        target: SessionPriorityTarget
    ) -> SessionPriorityResumeInput {
        SessionPriorityResumeInput(snapshot: snapshot, target: target, workingDirectory: project)
    }

    private func claudeSnapshot(environment: [String: String] = [:]) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: project,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"],
                workingDirectory: project,
                environment: environment,
                capturedAt: 123,
                source: "environment"
            )
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
