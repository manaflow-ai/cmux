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
/// source's, and names none at all for the default account (#4255).
struct ClaudeAccountSwitchResumeInputTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let project = "/Users/cmux-test/project"

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
    func typedInputForDefaultTargetOmitsConfigDirectory() throws {
        let snapshot = claudeSnapshot(configDirectory: "\(home)/.claude-work")
        let plan = try makePlan(snapshot, to: ClaudeAccountRegistry.defaultAccountName)

        let input = try #require(ClaudeAccountSwitchResumeInput(snapshot: snapshot, plan: plan).typedInput(dialect: .posix))

        #expect(!input.contains("CLAUDE_CONFIG_DIR"))
        #expect(input.contains("--resume"))
        #expect(input.contains(sessionID))
    }

    private func claudeSnapshot(configDirectory: String) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: project,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"],
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
