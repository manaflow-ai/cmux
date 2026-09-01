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
    @Test func codexAgentHookCannotReplaceTUIWithLowerProvenance() {
        let existing = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume tui-session",
            checkpointId: "tui-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui"
        )
        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume exec-session",
            checkpointId: "exec-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "exec"
        )

        #expect(!incoming.allowsCodexAgentHookReplacement(of: existing))
    }

    @Test func codexUnknownEvidenceCannotOwnOrReplaceBinding() {
        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume unknown-session",
            checkpointId: "unknown-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "unknown"
        )
        let legacy = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume legacy-session",
            checkpointId: "legacy-session",
            source: "agent-hook",
            autoResume: true
        )

        #expect(!incoming.allowsCodexAgentHookReplacement(of: nil as SurfaceResumeBindingSnapshot?))
        #expect(!incoming.allowsCodexAgentHookReplacement(of: legacy))

        let manualLegacy = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume manual-session",
            checkpointId: "manual-session",
            source: "cli",
            autoResume: true
        )
        #expect(!incoming.allowsCodexAgentHookReplacement(of: manualLegacy))
    }

    @Test func unprovenancedLegacyCodexCanEstablishAndRefreshLegacyBinding() {
        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume incoming-legacy-session",
            checkpointId: "incoming-legacy-session",
            source: "agent-hook",
            autoResume: true
        )
        let existing = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume existing-legacy-session",
            checkpointId: "existing-legacy-session",
            source: "agent-hook",
            autoResume: true
        )
        let manual = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume manual-session",
            checkpointId: "manual-session",
            source: "cli",
            autoResume: true
        )

        #expect(incoming.allowsCodexAgentHookReplacement(of: nil))
        #expect(incoming.allowsCodexAgentHookReplacement(of: existing))
        #expect(!incoming.allowsCodexAgentHookReplacement(of: manual))
    }

    @Test func unprovenancedLegacyCodexCannotReplaceVerifiedBinding() {
        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume incoming-legacy-session",
            checkpointId: "incoming-legacy-session",
            source: "agent-hook",
            autoResume: true
        )
        let verified = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume verified-session",
            checkpointId: "verified-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui"
        )

        #expect(!incoming.allowsCodexAgentHookReplacement(of: verified))
    }

    @Test @MainActor
    func dockProtectsManagedCodexBindingBehindProcessDetectedBinding() {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel

        let managed = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume tui-session",
            checkpointId: "tui-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "tui"
        )
        let processDetected = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t work",
            checkpointId: "work",
            source: "process-detected",
            autoResume: true
        )
        store.managedAgentResumeBindingsByPanelId[panel.id] = managed
        store.surfaceResumeBindingsByPanelId[panel.id] = processDetected

        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume unclassified-session",
            checkpointId: "unclassified-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "unknown"
        )

        #expect(!store.setSurfaceResumeBinding(incoming, panelId: panel.id))
        #expect(store.managedAgentResumeBindingsByPanelId[panel.id] == managed)
        #expect(store.surfaceResumeBindingsByPanelId[panel.id] == processDetected)
    }

    @Test func unknownEvidenceCannotReplaceKindlessLegacyAgentHookBinding() {
        let incoming = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume unknown-session",
            checkpointId: "unknown-session",
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "unknown"
        )
        let kindlessLegacy = SurfaceResumeBindingSnapshot(
            command: "codex resume legacy-kindless-session",
            checkpointId: "legacy-kindless-session",
            source: "agent-hook",
            autoResume: true
        )

        #expect(!incoming.allowsCodexAgentHookReplacement(of: kindlessLegacy))
    }

    @Test func resumeEvidenceProvenanceOnlyPersistsForCodexAgentHooks() {
        let valid = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume valid-session",
            source: "agent-hook",
            resumeEvidenceProvenance: "tui"
        )
        let wrongSource = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume cli-session",
            source: "cli",
            resumeEvidenceProvenance: "tui"
        )
        let wrongKind = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume wrong-kind-session",
            source: "agent-hook",
            resumeEvidenceProvenance: "tui"
        )

        #expect(valid.resumeEvidenceProvenance == "tui")
        #expect(wrongSource.resumeEvidenceProvenance == nil)
        #expect(wrongKind.resumeEvidenceProvenance == nil)
    }

    @Test func staleCodexBindingGainsUpdateCheckSuppressionOnReplay() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd -- '/tmp/repo' 2>/dev/null && 'env' 'CODEX_HOME=/tmp/codex' '/opt/company/bin/codex' 'resume' 'session-stale-binding' '--model' 'gpt-5.4'",
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

    @Test func codexBindingWithShortEqualsUpdateCheckSettingReplaysUnchanged() throws {
        let command = "'/opt/company/bin/codex' 'resume' 'session-explicit-short' '-c=check_for_update_on_startup=true'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: command,
            checkpointId: "session-explicit-short",
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

    @Test func codexBindingWithRemoteResumeGainsUpdateCheckSuppressionOnReplay() throws {
        // Codex Teams subagent bindings resume by thread through the app-server
        // (`resume --remote <url> <thread>`); the override belongs after the
        // thread id, not after the `--remote` option.
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/usr/local/bin/codex' 'resume' '--remote' 'ws://127.0.0.1:4500' 'thread-1'",
            checkpointId: "thread-1",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(
            startupInput.contains("'--remote' 'ws://127.0.0.1:4500' 'thread-1' -c check_for_update_on_startup=false"),
            "\(startupInput)"
        )
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

        let startupInput = try #require(binding.remoteStartupInput())

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
            command: "cd -- '/tmp/repo' 2>/dev/null && \(wrapped)",
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
