import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the resume coordinator: live agents get the breadcrumb
/// directly, dead agents get a native resume first, breadcrumb injection is
/// gated, and non-resumable surfaces are never touched.
@MainActor
@Suite struct WorkspaceResumeCoordinatorTests {

    final class FakeSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool
        var isAgentLive: Bool
        var resumeCwd: String? = "/Users/me/repo"
        var resumeTranscriptPath: String? = "/Users/me/.claude/projects/-Users-me-repo/sess-1.jsonl"
        var transcriptExistsAtWindowCwd: Bool = true
        var transcriptExistsElsewhere: Bool = false

        private(set) var nativeResumeCount = 0
        private(set) var deliveredBreadcrumbs: [String] = []

        init(
            name: String = "Fix auth bug",
            kind: RestorableAgentKind? = .claude,
            session: String? = "claude --resume sess-1",
            proven: Bool = true,
            live: Bool = true
        ) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.isResumeBindingProven = proven
            self.isAgentLive = live
        }

        func runNativeResume() { nativeResumeCount += 1 }
        func deliverResumeBreadcrumb(_ text: String) { deliveredBreadcrumbs.append(text) }
    }

    @Test func liveAgentGetsBreadcrumbWithoutNativeResume() {
        let surface = FakeSurface(live: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.count == 1)
        #expect(surface.deliveredBreadcrumbs.first?.contains("Fix auth bug") == true)
    }

    @Test func deadAgentGetsNativeResumeThenBreadcrumb() {
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.count == 1)
    }

    @Test func breadcrumbOmittedWhenInjectionDisabledButStillResumes() {
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: false).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: false))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
    }

    @Test func unsupportedAgentIsSkippedAndUntouched() {
        let surface = FakeSurface(kind: .gemini)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .skipped(.unsupportedAgent(.gemini)))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
    }

    @Test func unprovenBindingIsSkipped() {
        let surface = FakeSurface(proven: false)
        #expect(WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface) == .skipped(.unprovenSession))
        #expect(surface.nativeResumeCount == 0)
    }

    @Test func missingVerifiedTranscriptIsSkipped() {
        let surface = FakeSurface(live: false)
        surface.transcriptExistsAtWindowCwd = false
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .skipped(.unprovenSession))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
    }

    @Test func missingSessionIsSkipped() {
        let surface = FakeSurface(session: nil)
        #expect(WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface) == .skipped(.noSessionId))
    }

    @Test func bareSessionIdStripsQuotesFromResumeEqualsAndFallback() {
        #expect(WorkspaceResumeCoordinator.bareSessionId(from: "claude --resume='sess-A'") == "sess-A")
        #expect(WorkspaceResumeCoordinator.bareSessionId(from: "'sess-B'") == "sess-B")
    }

    @Test func bareSessionIdParsesLegacyCodexResumeCommand() {
        #expect(WorkspaceResumeCoordinator.bareSessionId(from: "codex resume s2") == "s2")
        #expect(WorkspaceResumeCoordinator.bareSessionId(from: "cd '/tmp/project' && codex resume s3 -m gpt-5") == "s3")
        #expect(WorkspaceResumeCoordinator.bareSessionId(from: "'codex' 'resume' 's4'") == "s4")
    }

    @Test func canResumeReflectsDecision() {
        let coordinator = WorkspaceResumeCoordinator(injectBreadcrumb: false)
        #expect(coordinator.canResume(FakeSurface()))
        #expect(!coordinator.canResume(FakeSurface(kind: .gemini)))
        #expect(!coordinator.canResume(FakeSurface(session: nil)))
    }

    // MARK: - Verification-gated recovery (U11)

    /// A surface that can report the on-disk verification facts the gate needs.
    final class VerifiableFakeSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool
        var isAgentLive: Bool
        var resumeCwd: String?
        var resumeTranscriptPath: String?
        var transcriptExistsAtWindowCwd: Bool
        var transcriptExistsElsewhere: Bool

        private(set) var nativeResumeCount = 0
        private(set) var deliveredBreadcrumbs: [String] = []
        private(set) var deliveredHonestPrompts: [String] = []

        init(
            name: String = "Fix order-to-go CLI",
            kind: RestorableAgentKind? = .claude,
            session: String? = "claude --resume sess-1",
            live: Bool = false,
            cwd: String? = "/Users/me/repo",
            transcriptPath: String? = "/Users/me/.claude/projects/-Users-me-repo/sess-1.jsonl",
            atWindowCwd: Bool = true,
            elsewhere: Bool = false
        ) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.isResumeBindingProven = true
            self.isAgentLive = live
            self.resumeCwd = cwd
            self.resumeTranscriptPath = transcriptPath
            self.transcriptExistsAtWindowCwd = atWindowCwd
            self.transcriptExistsElsewhere = elsewhere
        }

        func runNativeResume() { nativeResumeCount += 1 }
        func deliverResumeBreadcrumb(_ text: String) { deliveredBreadcrumbs.append(text) }
        func deliverHonestRecoveryPrompt(_ text: String) { deliveredHonestPrompts.append(text) }
    }

    @Test func recoverVerifiedBindingResumesAndKeepsBreadcrumbPrivacySafe() {
        let surface = VerifiableFakeSurface(live: false, atWindowCwd: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.first?.contains("sess-1.jsonl") == false)
        #expect(surface.deliveredHonestPrompts.isEmpty)
    }

    @Test func recoverCwdMismatchDeliversHonestPromptToLiveAgentAndNeverResumes() {
        // Transcript exists only elsewhere -> the anti-Example-3 mis-attribution.
        let surface = VerifiableFakeSurface(live: true, atWindowCwd: false, elsewhere: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .honestRecovery(reason: .cwdMismatch, deliveredPrompt: true))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
        #expect(surface.deliveredHonestPrompts.count == 1)
        #expect(surface.deliveredHonestPrompts.first?.contains("/Users/me/repo") == true)
        #expect(surface.deliveredHonestPrompts.first?.contains("sess-1") == false)
    }

    @Test func recoverCwdMismatchWithoutSafeAgentChannelDoesNotTypePromptIntoShell() {
        let surface = VerifiableFakeSurface(live: false, atWindowCwd: false, elsewhere: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)

        #expect(outcome == .honestRecovery(reason: .cwdMismatch, deliveredPrompt: false))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
        #expect(surface.deliveredHonestPrompts.isEmpty)
    }

    @Test func recoverMissingTranscriptDoesNotPromptDeadShell() {
        let surface = VerifiableFakeSurface(atWindowCwd: false, elsewhere: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .honestRecovery(reason: .transcriptMissing, deliveredPrompt: false))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredHonestPrompts.isEmpty)
    }

    @Test func recoverUnwiredSurfaceDefaultsToHonestRecovery() {
        // The v1 FakeSurface does not implement the verification facts, so the
        // conservative defaults route it to honest recovery — never a blind
        // auto-resume of an unverified binding.
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        guard case .honestRecovery(reason: _, deliveredPrompt: false) = outcome else {
            Issue.record("expected honestRecovery for an unwired surface, got \(outcome)")
            return
        }
        #expect(surface.nativeResumeCount == 0)
    }

    @Test func recoverLiveVerifiedAgentSkipsNativeResume() {
        let surface = VerifiableFakeSurface(live: true, atWindowCwd: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.count == 1)
    }

    @Test func realWorkspaceResumeMarksRestoredAgentCommandExpected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let sessionId = "sess-expected-resume"
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: cwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/bin/claude",
                arguments: ["/usr/bin/claude"],
                workingDirectory: cwd.path,
                environment: ["CLAUDE_CONFIG_DIR": configDir.path],
                capturedAt: 123,
                source: "test"
            )
        )
        workspace.restoredAgentSnapshotsByPanelId[panelId] = agent
        workspace.restoredAgentVerificationByPanelId[panelId] = Workspace.crashRecoveryVerification(agent: agent)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable

        let suiteName = "workspace-resume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        CrashRecoverySettings.setInjectResumeBreadcrumb(false, defaults: defaults)
        let outcome = workspace.resumeWhereWeLeftOff(defaults: defaults)

        #expect(outcome == .resumed(deliveredBreadcrumb: false))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test func coldRestoredWorkspaceQueuesBreadcrumbUntilResumeCommandRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-breadcrumb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let sessionId = "sess-pending-breadcrumb"
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: cwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/bin/claude",
                arguments: ["/usr/bin/claude"],
                workingDirectory: cwd.path,
                environment: ["CLAUDE_CONFIG_DIR": configDir.path],
                capturedAt: 123,
                source: "test"
            )
        )
        workspace.restoredAgentSnapshotsByPanelId[panelId] = agent
        workspace.restoredAgentVerificationByPanelId[panelId] = Workspace.crashRecoveryVerification(agent: agent)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable

        let suiteName = "workspace-breadcrumb-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        let outcome = workspace.resumeWhereWeLeftOff(defaults: defaults)

        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
        #expect(workspace.pendingResumeBreadcrumbsByPanelId[panelId]?.localizedCaseInsensitiveContains("pick up") == true)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        #expect(workspace.pendingResumeBreadcrumbsByPanelId[panelId] == nil)
    }

    @Test func bindingOnlyResumeIsNotLiveUntilResumeCommandRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-binding-not-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let sessionId = "sess-binding-not-live"
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Recovered binding",
            kind: RestorableAgentKind.claude.rawValue,
            command: "claude --resume \(sessionId)",
            cwd: cwd.path,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: ["CLAUDE_CONFIG_DIR": configDir.path],
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.restoredAgentVerificationByPanelId[panelId] = Workspace.crashRecoveryVerification(binding: binding)
        workspace.restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)

        let suiteName = "binding-not-live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        CrashRecoverySettings.setInjectResumeBreadcrumb(false, defaults: defaults)

        #expect(!workspace.isAgentLive)
        let outcome = workspace.resumeWhereWeLeftOff(defaults: defaults)

        #expect(outcome == .resumed(deliveredBreadcrumb: false))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test func bindingOnlyResumeQueuesBreadcrumbUntilCommandRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-binding-breadcrumb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let sessionId = "sess-binding-breadcrumb"
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Recovered binding",
            kind: RestorableAgentKind.claude.rawValue,
            command: "claude --resume \(sessionId)",
            cwd: cwd.path,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: ["CLAUDE_CONFIG_DIR": configDir.path],
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(binding, panelId: panelId))
        workspace.restoredAgentVerificationByPanelId[panelId] = Workspace.crashRecoveryVerification(binding: binding)
        workspace.restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable

        let suiteName = "binding-breadcrumb-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        let outcome = workspace.resumeWhereWeLeftOff(defaults: defaults)

        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
        #expect(workspace.pendingResumeBreadcrumbsByPanelId[panelId] != nil)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        #expect(workspace.pendingResumeBreadcrumbsByPanelId[panelId] == nil)
    }
}
