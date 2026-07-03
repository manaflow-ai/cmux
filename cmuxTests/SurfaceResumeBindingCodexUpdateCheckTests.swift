import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Persisted agent-hook resume bindings are rendered shell strings, so bindings
/// saved by a cmux build that predates the codex update-check suppression would
/// replay verbatim on the first relaunch after updating cmux — the exact restart
/// where codex's blocking "Update available!" picker used to swallow the
/// restored session. Replay must normalize those stale codex bindings.
@Suite struct SurfaceResumeBindingCodexUpdateCheckTests {
    @Test func staleCodexBindingGainsUpdateCheckSuppressionOnReplay() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ] && 'env' 'CODEX_HOME=/tmp/codex' '/opt/company/bin/codex' 'resume' 'session-stale-binding' '--model' 'gpt-5.4'",
            cwd: "/tmp/repo",
            checkpointId: "session-stale-binding",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("'resume' 'session-stale-binding' -c check_for_update_on_startup=false '--model'"),
            "\(startupInput)"
        )
    }

    @Test func staleCodexTeamsBindingGainsUpdateCheckSuppressionOnReplay() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/usr/local/bin/cmux' 'codex-teams' 'resume' 'team-stale-binding' '--model' 'gpt-5.4'",
            checkpointId: "team-stale-binding",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("'codex-teams' 'resume' 'team-stale-binding' -c check_for_update_on_startup=false '--model'"),
            "\(startupInput)"
        )
    }

    @Test func codexBindingWithExistingUpdateCheckSettingReplaysUnchanged() throws {
        let command = "'/opt/company/bin/codex' 'resume' 'session-explicit' '-c' 'check_for_update_on_startup=true'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: command,
            checkpointId: "session-explicit",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains(command), "\(startupInput)")
        #expect(!startupInput.contains("check_for_update_on_startup=false"), "\(startupInput)")
    }

    @Test func claudeBindingReplaysWithoutCodexUpdateCheckSuppression() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'/opt/company/bin/claude' '--resume' 'claude-session'",
            checkpointId: "claude-session",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(!startupInput.contains("check_for_update_on_startup"), "\(startupInput)")
    }

    @Test func codexBindingWithRemoteResumeReplaysUnchanged() throws {
        // Codex Teams subagent bindings resume by thread through the app-server
        // (`resume --remote <url> <thread>`); the option word after `resume` must
        // not be mistaken for a session id.
        let command = "'/usr/local/bin/codex' 'resume' '--remote' 'ws://127.0.0.1:4500' 'thread-1'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: command,
            checkpointId: "thread-1",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains(command), "\(startupInput)")
        #expect(!startupInput.contains("check_for_update_on_startup"), "\(startupInput)")
    }

    @Test func legacyCodexBindingWithoutKindGainsUpdateCheckSuppressionOnReplay() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "'/opt/company/bin/codex' 'resume' 'legacy-kindless-session' '--model' 'gpt-5.4'",
            checkpointId: "legacy-kindless-session",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("'resume' 'legacy-kindless-session' -c check_for_update_on_startup=false '--model'"),
            "\(startupInput)"
        )
    }

    @Test func remoteLauncherScriptCodexBindingGainsUpdateCheckSuppressionOnReplay() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/opt/company/bin/codex' 'resume' 'remote-startup-session' '--model' 'gpt-5.4'",
            checkpointId: "remote-startup-session",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.remoteStartupInputWithLauncherScript())

        #expect(
            startupInput.contains("'resume' 'remote-startup-session' -c check_for_update_on_startup=false '--model'"),
            "\(startupInput)"
        )
    }

    @Test func codexBindingWithUnrelatedUpdateCheckTextStillGainsSuppression() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/opt/company/bin/codex' 'resume' 'session-with-text' '--model' 'check_for_update_on_startup-not-config'",
            checkpointId: "session-with-text",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("'resume' 'session-with-text' -c check_for_update_on_startup=false '--model'"),
            "\(startupInput)"
        )
    }

    @Test func wrappedCodexBindingGainsUpdateCheckSuppressionOnReplay() throws {
        let wrapped = AgentResumeArgv.portableCodexResumeShellCommand(
            posixCommand: "\(AgentResumeArgv.codexWrapperShellExecutableToken) resume wrapped-session --model gpt-5.4"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ] && \(wrapped)",
            cwd: "/tmp/repo",
            checkpointId: "wrapped-session",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("resume wrapped-session -c check_for_update_on_startup=false --model"),
            "\(startupInput)"
        )
    }
}
