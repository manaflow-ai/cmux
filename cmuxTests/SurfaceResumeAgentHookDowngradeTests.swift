import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12084: an `agent-hook` write for the same managed
/// session must not demote a trusted (auto-resume) binding to manual approval.
///
/// Hook publishers always carry `auto_resume`. The Pi extension shipped before
/// the fix re-published its binding through the public `surface resume set`
/// CLI, which never carries it, so every freshly started or restored Pi pane
/// fell back to manual until the user typed a prompt, and the following
/// relaunch restored a bare shell instead of Pi. Extensions already loaded by
/// a running Pi process keep issuing that write after cmux updates, so the
/// store itself has to keep the trusted binding.
@MainActor
@Suite(.serialized)
struct SurfaceResumeAgentHookDowngradeTests {
    private static let piSessionID = "3f2b9c1e-7d4a-4e6b-9a10-5c8e2f1d7b42"
    private static let otherPiSessionID = "8a1c0d2e-3b4f-4a5c-8d6e-7f8091a2b3c4"
    private static let piSessionPath =
        "/Users/test/.pi/agent/sessions/--Users-test-project--/" +
        "2026-09-08T10-00-00-000Z_\(piSessionID).jsonl"

    /// The binding `cmux hooks pi session-start` publishes.
    private static func trustedPiBinding(
        cwd: String = "/tmp/pi-project",
        updatedAt: TimeInterval = 10
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Pi",
            kind: "pi",
            command: "pi --session \(piSessionID) --model sonnet",
            cwd: cwd,
            checkpointId: piSessionID,
            source: "agent-hook",
            environment: ["PI_CODING_AGENT_DIR": "/tmp/pi-agent"],
            autoResume: true,
            approvalPolicy: .auto,
            updatedAt: updatedAt
        )
    }

    /// The write the pre-fix Pi extension issued through the public CLI: same
    /// session and `agent-hook` source, but no `auto_resume`, which the socket
    /// coordinator stores as a manual binding.
    private static func manualPiRepublish(
        checkpointId: String = piSessionID,
        updatedAt: TimeInterval = 11
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Pi",
            kind: "pi",
            command: "pi --session \(checkpointId)",
            cwd: "/tmp/pi-project",
            checkpointId: checkpointId,
            source: "agent-hook",
            autoResume: false,
            approvalPolicy: .manual,
            updatedAt: updatedAt
        )
    }

    // MARK: - Store behavior

    @Test
    func workspaceKeepsTrustedBindingWhenSameSessionHookWriteOmitsAutoResume() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let trusted = Self.trustedPiBinding()

        #expect(workspace.setSurfaceResumeBinding(trusted, panelId: panelID))
        #expect(!workspace.setSurfaceResumeBinding(Self.manualPiRepublish(), panelId: panelID))

        let stored = try #require(workspace.surfaceResumeBinding(panelId: panelID))
        #expect(stored == trusted)
        #expect(stored.allowsAutomaticResume)
        #expect(stored.approvalPolicy == .auto)
    }

    @Test
    func dockKeepsTrustedBindingWhenSameSessionHookWriteOmitsAutoResume() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let panel = TerminalPanel(workspaceId: store.workspaceId)
        store.panels[panel.id] = panel
        let trusted = Self.trustedPiBinding()

        #expect(store.setSurfaceResumeBinding(trusted, panelId: panel.id))
        #expect(!store.setSurfaceResumeBinding(Self.manualPiRepublish(), panelId: panel.id))

        #expect(store.surfaceResumeBinding(panelId: panel.id) == trusted)
        #expect(store.managedAgentResumeBindingsByPanelId[panel.id] == trusted)
    }

    @Test
    func workspaceAcceptsSameSessionTrustedRefresh() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let refresh = Self.trustedPiBinding(cwd: "/tmp/pi-project/refreshed", updatedAt: 12)

        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelID))
        #expect(workspace.setSurfaceResumeBinding(refresh, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == refresh)
    }

    @Test
    func workspaceAcceptsManualHookWriteForDifferentSession() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let replacement = Self.manualPiRepublish(checkpointId: Self.otherPiSessionID)

        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelID))
        #expect(workspace.setSurfaceResumeBinding(replacement, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == replacement)
    }

    @Test
    func workspacePromotesManualBindingWhenHookPublishesTrustedOne() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let trusted = Self.trustedPiBinding(updatedAt: 12)

        #expect(workspace.setSurfaceResumeBinding(Self.manualPiRepublish(updatedAt: 11), panelId: panelID))
        #expect(workspace.setSurfaceResumeBinding(trusted, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == trusted)
    }

    @Test
    func workspaceStillHonorsExplicitCLIReplacement() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let userBinding = SurfaceResumeBindingSnapshot(
            kind: "pi",
            command: "pi --session \(Self.piSessionID) --thinking high",
            cwd: "/tmp/pi-project",
            checkpointId: Self.piSessionID,
            source: "cli",
            autoResume: false,
            updatedAt: 11
        )

        #expect(workspace.setSurfaceResumeBinding(Self.trustedPiBinding(), panelId: panelID))
        #expect(workspace.setSurfaceResumeBinding(userBinding, panelId: panelID))
        #expect(workspace.surfaceResumeBinding(panelId: panelID) == userBinding)
    }

    // MARK: - Predicate

    @Test
    func downgradeRequiresTrustedSameSessionAgentHookBinding() {
        let trusted = Self.trustedPiBinding()
        let manual = Self.manualPiRepublish()

        #expect(manual.downgradesTrustedAgentHookBinding(trusted))
        #expect(!manual.downgradesTrustedAgentHookBinding(nil))
        #expect(!manual.downgradesTrustedAgentHookBinding(manual))
        #expect(!trusted.downgradesTrustedAgentHookBinding(trusted))
        #expect(!trusted.downgradesTrustedAgentHookBinding(manual))
        #expect(!Self.manualPiRepublish(checkpointId: Self.otherPiSessionID)
            .downgradesTrustedAgentHookBinding(trusted))
    }

    @Test
    func downgradeIgnoresOtherSourcesAndKinds() {
        let trusted = Self.trustedPiBinding()
        var cliWrite = Self.manualPiRepublish()
        cliWrite.source = "cli"
        var processDetected = Self.trustedPiBinding()
        processDetected.source = "process-detected"
        var otherKind = Self.manualPiRepublish()
        otherKind.kind = "omp"

        #expect(!cliWrite.downgradesTrustedAgentHookBinding(trusted))
        #expect(!Self.manualPiRepublish().downgradesTrustedAgentHookBinding(processDetected))
        #expect(!otherKind.downgradesTrustedAgentHookBinding(trusted))
    }

    @Test
    func downgradeMatchesPiSessionFileCheckpoints() {
        let trusted = Self.trustedPiBinding()
        let pathCheckpoint = Self.manualPiRepublish(checkpointId: Self.piSessionPath)

        #expect(pathCheckpoint.downgradesTrustedAgentHookBinding(trusted))
    }
}
