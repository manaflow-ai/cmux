import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the crash-recovery offer copy: it names the count and is
/// non-empty on every field (so the alert never shows blank buttons).
@MainActor
@Suite struct CrashRecoveryOfferTests {

    @Test func messageNamesTheResumableCount() {
        let content = CrashRecoveryOfferText.make(resumableCount: 3)
        #expect(content.message.contains("3"))
        #expect(!content.message.contains("workspace(s)"))
    }

    @Test func allFieldsArePopulated() {
        let content = CrashRecoveryOfferText.make(resumableCount: 1)
        #expect(!content.title.isEmpty)
        #expect(!content.message.isEmpty)
        #expect(!content.resumeButton.isEmpty)
        #expect(!content.dismissButton.isEmpty)
    }

    @Test func resumableWorkspacesIncludesAllManagersOnce() async throws {
        let first = try makeManagerWithResumeBinding(session: "sess-1")
        let second = try makeManagerWithResumeBinding(session: "sess-2")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }

        let resumable = await CrashRecoveryOfferPresenter.resumableWorkspaces(
            in: [first.manager, second.manager, first.manager]
        )

        #expect(resumable.count == 2)
        #expect(Set(resumable.map(\.id)).count == 2)
    }

    @Test func recoverableWorkspacesIncludesOnlyPromptableUnverifiedBindings() async throws {
        let verified = try makeManagerWithResumeBinding(session: "sess-verified")
        let promptableUnverified = try makeManagerWithResumeBinding(
            session: "sess-promptable",
            createTranscript: false,
            restoredAgentResumeState: .observedAgentCommandRunning
        )
        let shellOnlyUnverified = try makeManagerWithResumeBinding(
            session: "sess-missing",
            createTranscript: false
        )
        defer {
            try? FileManager.default.removeItem(at: verified.root)
            try? FileManager.default.removeItem(at: promptableUnverified.root)
            try? FileManager.default.removeItem(at: shellOnlyUnverified.root)
        }

        let resumable = await CrashRecoveryOfferPresenter.resumableWorkspaces(
            in: [verified.manager, promptableUnverified.manager, shellOnlyUnverified.manager]
        )
        let recoverable = await CrashRecoveryOfferPresenter.recoverableWorkspaces(
            in: [verified.manager, promptableUnverified.manager, shellOnlyUnverified.manager]
        )

        #expect(resumable.count == 1)
        #expect(recoverable.count == 2)
    }

    private func makeManagerWithResumeBinding(
        session: String,
        createTranscript: Bool = true,
        restoredAgentResumeState: Workspace.RestoredAgentResumeState? = nil
    ) throws -> (manager: TabManager, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-offer-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        if createTranscript {
            try "{}\n".write(
                to: projectDir.appendingPathComponent("\(session).jsonl", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let didSet = workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Recovered \(session)",
                kind: RestorableAgentKind.claude.rawValue,
                command: "claude --resume \(session)",
                cwd: cwd.path,
                checkpointId: session,
                source: "agent-hook",
                environment: ["CLAUDE_CONFIG_DIR": configDir.path],
                autoResume: true
            ),
            panelId: panelId
        )
        #expect(didSet)
        if let restoredAgentResumeState {
            workspace.restoredAgentResumeStatesByPanelId[panelId] = restoredAgentResumeState
        }
        return (manager, root)
    }
}
