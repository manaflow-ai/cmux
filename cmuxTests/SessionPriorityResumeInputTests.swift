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

    /// The resume marks the level it sets, so the recorded launch of the resumed Claude reads
    /// as cmux's and a hand-set `CLAUDE_CODE_EFFORT_LEVEL` reads as the user's.
    @Test
    func effortIsMarkedAsCmuxs() throws {
        let snapshot = claudeSnapshot(environment: [
            "CLAUDE_CODE_EFFORT_LEVEL": "low",
            "CMUX_SESSION_PRIORITY_EFFORT": "low",
        ])

        let command = try #require(resumeInput(snapshot, target: SessionPriorityTarget(effort: .xhigh)).posixCommand())

        #expect(command.contains("CMUX_SESSION_PRIORITY_EFFORT=xhigh"))
        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=xhigh"))
        #expect(occurrences(of: "CMUX_SESSION_PRIORITY_EFFORT=", in: command) == 1)
        let marker = try #require(command.range(of: "CMUX_SESSION_PRIORITY_EFFORT=xhigh"))
        let resumeOption = try #require(command.range(of: "--resume"))
        #expect(marker.upperBound <= resumeOption.lowerBound)
    }

    @Test
    func modelOnlyTargetAddsNoMarker() throws {
        let command = try #require(
            resumeInput(claudeSnapshot(), target: SessionPriorityTarget(model: "opus")).posixCommand()
        )

        #expect(!command.contains("CMUX_SESSION_PRIORITY_EFFORT"))
        #expect(!command.contains("CLAUDE_CODE_EFFORT_LEVEL"))
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
    func clearedAccountKeysAreUnset() throws {
        // A pane an account switch moved to the default account runs without both keys, and the
        // restarted shell's rc files or direnv can export either one again.
        let resume = resumeInput(
            claudeSnapshot(),
            target: SessionPriorityTarget(effort: .high),
            clearedEnvironmentKeys: ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"]
        )

        let command = try #require(resume.posixCommand())

        let unset = "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "
        #expect(command.hasPrefix(changeDirectoryPrefix + unset))
        let unsetRange = try #require(command.range(of: unset))
        let resumeOption = try #require(command.range(of: "--resume"))
        #expect(unsetRange.upperBound <= resumeOption.lowerBound)
        #expect(command.contains("CLAUDE_CODE_EFFORT_LEVEL=high"))
        #expect(resume.typedInput(dialect: .posix) == command + "\n")
    }

    @Test
    func recordedKeyIsNotUnset() throws {
        let configDirectory = "\(home)/.claude-work"
        let snapshot = claudeSnapshot(environment: ["CLAUDE_CONFIG_DIR": configDirectory])

        let command = try #require(resumeInput(
            snapshot,
            target: SessionPriorityTarget(effort: .high),
            clearedEnvironmentKeys: ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        ).posixCommand())

        #expect(command.hasPrefix(changeDirectoryPrefix + "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR "))
        #expect(!command.contains("-u CLAUDE_CONFIG_DIR"))
        #expect(command.contains("CLAUDE_CONFIG_DIR=\(configDirectory)"))
    }

    @Test
    func noClearedKeysAddsNoUnset() throws {
        let command = try #require(resumeInput(claudeSnapshot(), target: SessionPriorityTarget(effort: .high)).posixCommand())

        #expect(!command.contains("env -u"))
    }

    @Test
    func emptyRecordedConfigDirectoryProbesTheDefaultAccount() {
        let defaultDirectory = "\(home)/.claude"

        #expect(Workspace.sessionPriorityConfigDirectory(launchEnvironment: nil, homeDirectory: home) == defaultDirectory)
        #expect(
            Workspace.sessionPriorityConfigDirectory(launchEnvironment: ["CLAUDE_CONFIG_DIR": ""], homeDirectory: home)
                == defaultDirectory
        )
        #expect(
            Workspace.sessionPriorityConfigDirectory(launchEnvironment: ["CLAUDE_CONFIG_DIR": "  "], homeDirectory: home)
                == defaultDirectory
        )
        #expect(
            Workspace.sessionPriorityConfigDirectory(
                launchEnvironment: ["CLAUDE_CONFIG_DIR": "\(home)/.claude-work"],
                homeDirectory: home
            ) == "\(home)/.claude-work"
        )
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
        target: SessionPriorityTarget,
        clearedEnvironmentKeys: [String] = []
    ) -> SessionPriorityResumeInput {
        SessionPriorityResumeInput(
            snapshot: snapshot,
            target: target,
            workingDirectory: project,
            clearedEnvironmentKeys: clearedEnvironmentKeys
        )
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
