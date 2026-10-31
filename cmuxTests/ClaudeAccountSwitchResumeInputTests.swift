import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The command typed into a switched pane must resume the same session under
/// the target account: it names the target's `CLAUDE_CONFIG_DIR`, never the
/// source's, and names none at all for the default account (#4255). The
/// respawned shell re-runs rc files and direnv, which can export either account
/// key again, so the command itself unsets every key the plan clears.
struct ClaudeAccountSwitchResumeInputTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let project = "/Users/cmux-test/project"

    private var changeDirectoryPrefix: String {
        "cd -- '\(project)' 2>/dev/null || [ ! -d '\(project)' ] && "
    }

    @Test
    func typedInputCarriesTargetConfigDirectoryNotSource() throws {
        let snapshot = claudeSnapshot(configDirectory: "\(home)/.claude-old")
        let plan = try makePlan(snapshot, to: "work")

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(dialect: .posix))

        #expect(input.contains("CLAUDE_CONFIG_DIR=\(home)/.claude-work"))
        #expect(!input.contains(".claude-old"))
        #expect(input.contains("--resume"))
        #expect(input.contains(sessionID))
        #expect(input.contains("cd -- '\(project)'"))
        #expect(input.hasSuffix("\n"))
    }

    @Test
    func typedInputForDefaultTargetUnsetsBothAccountKeysAfterChangingDirectory() throws {
        let snapshot = claudeSnapshot(configDirectory: "\(home)/.claude-work")
        let plan = try makePlan(snapshot, to: ClaudeAccountRegistry.defaultAccountName)

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(dialect: .posix))

        // `export CLAUDE_CONFIG_DIR=~/.claude-work` in ~/.zshrc must not resume on the source account.
        #expect(input.hasPrefix(changeDirectoryPrefix + "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "))
        #expect(!input.contains("CLAUDE_CONFIG_DIR="))
        #expect(input.contains("--resume"))
        #expect(input.contains(sessionID))
    }

    @Test
    func typedInputForCustomTargetUnsetsOnlySecureStorageAfterChangingDirectory() throws {
        let snapshot = claudeSnapshot(configDirectory: "\(home)/.claude-old")
        let plan = try makePlan(snapshot, to: "work")

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(dialect: .posix))

        #expect(input.hasPrefix(changeDirectoryPrefix + "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR "))
        #expect(!input.contains("-u CLAUDE_CONFIG_DIR"))
        #expect(input.contains("CLAUDE_CONFIG_DIR=\(home)/.claude-work"))
    }

    @Test
    func nushellInputRunsTheUnsettingCommandThroughSh() throws {
        let snapshot = claudeSnapshot(configDirectory: "\(home)/.claude-work")
        let plan = try makePlan(snapshot, to: ClaudeAccountRegistry.defaultAccountName)

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(dialect: .nushell))

        #expect(input.hasPrefix(#"^/bin/sh -c "cd -- '"#))
        #expect(input.contains("&& env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "))
    }

    @Test
    func oversizedResumeCommandRunsFromALauncherScript() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let systemPrompt = String(repeating: "x", count: 1200)
        let snapshot = claudeSnapshot(
            configDirectory: "\(home)/.claude-work",
            extraArguments: ["--append-system-prompt", systemPrompt]
        )
        let plan = try makePlan(snapshot, to: ClaudeAccountRegistry.defaultAccountName)

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(
            dialect: .posix,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ))

        // A canonical-mode tty drops a line past ~1024 bytes, newline included.
        #expect(input.utf8.count <= 900)
        let launcherPrefix = " /bin/zsh '\(temporaryDirectory.path)/cmux-r/"
        try #require(input.hasPrefix(launcherPrefix))
        try #require(input.hasSuffix("'\n"))
        let scriptPath = String(input.dropFirst(" /bin/zsh '".count).dropLast("'\n".count))
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(script.contains(changeDirectoryPrefix + "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "))
        #expect(script.contains(systemPrompt))
        #expect(script.contains(sessionID))
    }

    private func claudeSnapshot(
        configDirectory: String,
        extraArguments: [String] = []
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: project,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"] + extraArguments,
                workingDirectory: project,
                environment: ["CLAUDE_CONFIG_DIR": configDirectory],
                capturedAt: 123,
                source: "environment"
            )
        )
    }

    private func makePlan(
        _ snapshot: SessionRestorableAgentSnapshot,
        to target: String
    ) throws -> ClaudeAccountSwitchPlan {
        let registry = ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
            homeDirectory: home
        )
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: snapshot.sessionId,
            workingDirectory: snapshot.workingDirectory,
            launchEnvironment: snapshot.launchCommand?.environment,
            targetName: target,
            registry: registry,
            homeDirectory: home
        ).get()
    }
}
