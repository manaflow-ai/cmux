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

    @Test func resumableWorkspacesIncludesAllManagersOnce() throws {
        let first = try makeManagerWithResumeBinding(session: "sess-1")
        let second = try makeManagerWithResumeBinding(session: "sess-2")

        let resumable = CrashRecoveryOfferPresenter.resumableWorkspaces(
            in: [first, second, first]
        )

        #expect(resumable.count == 2)
        #expect(Set(resumable.map(\.id)).count == 2)
    }

    private func makeManagerWithResumeBinding(session: String) throws -> TabManager {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let didSet = workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Recovered \(session)",
                kind: RestorableAgentKind.claude.rawValue,
                command: "claude --resume \(session)",
                cwd: FileManager.default.temporaryDirectory.path,
                checkpointId: session,
                source: "agent-hook",
                autoResume: true
            ),
            panelId: panelId
        )
        #expect(didSet)
        return manager
    }
}
