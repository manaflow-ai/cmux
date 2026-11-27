import CmuxSidebar
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentWakeVerificationStateTests {
    @Test
    func startingAlwaysReturnsToPending() {
        #expect(AgentWakeVerificationState.pending.applying(.started) == .pending)
        #expect(AgentWakeVerificationState.succeeded.applying(.started) == .pending)
        #expect(AgentWakeVerificationState.failed(.didNotStart).applying(.started) == .pending)
    }

    @Test
    func agentReportWhilePendingSucceeds() {
        #expect(AgentWakeVerificationState.pending.applying(.agentReported) == .succeeded)
    }

    @Test
    func commandEndingBeforeAnyReportFails() {
        #expect(
            AgentWakeVerificationState.pending.applying(.commandEnded) ==
                .failed(.exitedBeforeStart)
        )
    }

    @Test
    func deadlineWithLiveProcessSucceeds() {
        #expect(
            AgentWakeVerificationState.pending.applying(.deadline(hasLiveProcess: true)) ==
                .succeeded
        )
    }

    @Test
    func deadlineWithoutLiveProcessFails() {
        #expect(
            AgentWakeVerificationState.pending.applying(.deadline(hasLiveProcess: false)) ==
                .failed(.didNotStart)
        )
    }

    @Test
    func liveProcessWhilePendingSucceedsButDoesNotClearAFailure() {
        #expect(AgentWakeVerificationState.pending.applying(.liveProcessFound) == .succeeded)
        #expect(
            AgentWakeVerificationState.failed(.exitedBeforeStart).applying(.liveProcessFound) ==
                .failed(.exitedBeforeStart)
        )
    }

    @Test
    func laterAgentReportClearsFailure() {
        #expect(
            AgentWakeVerificationState.failed(.didNotStart).applying(.agentReported) ==
                .succeeded
        )
        #expect(
            AgentWakeVerificationState.failed(.exitedBeforeStart).applying(.agentReported) ==
                .succeeded
        )
    }

    @Test
    func resolvedStatesIgnoreLateEndAndDeadline() {
        #expect(AgentWakeVerificationState.succeeded.applying(.commandEnded) == .succeeded)
        #expect(
            AgentWakeVerificationState.succeeded.applying(.deadline(hasLiveProcess: false)) ==
                .succeeded
        )
        #expect(
            AgentWakeVerificationState.failed(.exitedBeforeStart)
                .applying(.deadline(hasLiveProcess: false)) == .failed(.exitedBeforeStart)
        )
        #expect(
            AgentWakeVerificationState.failed(.didNotStart).applying(.commandEnded) ==
                .failed(.didNotStart)
        )
    }
}

@Suite(.serialized)
struct AgentWakeVerificationWorkspaceTests {
    private let agent = SessionRestorableAgentSnapshot(
        kind: .codex,
        sessionId: "codex-wake-verification",
        workingDirectory: "/tmp/cmux-agent-wake",
        launchCommand: nil
    )

    @MainActor
    @Test
    func agentPIDForPanelClearsPendingVerification() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        #expect(workspace.agentWakeVerificationsByPanelId[panel.id]?.state == .pending)

        workspace.recordAgentPID(
            key: "codex.codex-wake-verification",
            pid: getpid(),
            panelId: panel.id,
            refreshPorts: false
        )
        defer {
            workspace.clearAgentPID(
                key: "codex.codex-wake-verification",
                panelId: panel.id,
                refreshPorts: false
            )
        }

        #expect(workspace.agentWakeVerificationsByPanelId[panel.id] == nil)
        #expect(panel.agentWakeFailure == nil)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey] == nil)
    }

    @MainActor
    @Test
    func nonManualLifecycleForPanelClearsPendingVerification() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        workspace.setAgentLifecycle(
            key: AgentHibernationLifecycleStatusKeys.manualKey,
            panelId: panel.id,
            lifecycle: .running
        )
        #expect(workspace.agentWakeVerificationsByPanelId[panel.id]?.state == .pending)

        workspace.setAgentLifecycle(key: "codex", panelId: panel.id, lifecycle: .running)
        #expect(workspace.agentWakeVerificationsByPanelId[panel.id] == nil)
    }

    @MainActor
    @Test
    func failureSetsBannerStateAndSidebarRowButNotSessionSnapshot() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        workspace.failAgentWakeVerification(panelId: panel.id, reason: .didNotStart)

        let failure = try #require(panel.agentWakeFailure)
        #expect(failure.reason == .didNotStart)
        #expect(failure.agentDisplayName == agent.agentDisplayName)
        #expect(!failure.commandText.isEmpty)
        #expect(failure.agent.sessionId == agent.sessionId)

        let entry = try #require(workspace.statusEntries[Workspace.agentWakeFailedStatusKey])
        #expect(entry.icon == "exclamationmark.triangle")
        #expect(entry.color == "#FF9500")
        #expect(!entry.value.isEmpty)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(!snapshot.statusEntries.contains { $0.key == Workspace.agentWakeFailedStatusKey })
    }

    @MainActor
    @Test
    func laterAgentReportClearsFailureAndSidebarRow() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        workspace.failAgentWakeVerification(panelId: panel.id, reason: .exitedBeforeStart)
        #expect(panel.agentWakeFailure?.reason == .exitedBeforeStart)

        workspace.setAgentLifecycle(key: "codex", panelId: panel.id, lifecycle: .running)

        #expect(panel.agentWakeFailure == nil)
        #expect(workspace.agentWakeVerificationsByPanelId[panel.id] == nil)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey] == nil)
    }

    @MainActor
    @Test
    func sidebarRowCountsEveryFailedPane() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(
            workspace.newTerminalSplit(from: first.id, orientation: .horizontal, focus: false)
        )

        workspace.beginAgentWakeVerification(panelId: first.id, agent: agent)
        workspace.failAgentWakeVerification(panelId: first.id, reason: .didNotStart)
        let singleValue = try #require(
            workspace.statusEntries[Workspace.agentWakeFailedStatusKey]?.value
        )

        workspace.beginAgentWakeVerification(panelId: second.id, agent: agent)
        workspace.failAgentWakeVerification(panelId: second.id, reason: .didNotStart)
        let multipleValue = try #require(
            workspace.statusEntries[Workspace.agentWakeFailedStatusKey]?.value
        )
        #expect(multipleValue != singleValue)
        #expect(multipleValue.contains("2"))

        workspace.dismissAgentWakeFailure(panelId: first.id)
        #expect(first.agentWakeFailure == nil)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey]?.value == singleValue)
    }

    @MainActor
    @Test
    func resumeCommandEndingBeforeAnyReportFailsTheWake() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.restoredAgentLifecycle.setSnapshot(agent, panelId: panel.id)
        workspace.restoredAgentLifecycle.setResumeState(.autoResumeCommandRunning, panelId: panel.id)
        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)

        workspace.updateRestoredAgentResumeState(
            panelId: panel.id,
            restoredAgent: agent,
            shellState: .promptIdle
        )

        #expect(panel.agentWakeFailure?.reason == .exitedBeforeStart)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey] != nil)
    }

    @MainActor
    @Test
    func aResumeCommandEndingLateWithoutConfirmationStillFails() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        // No hook report and no live process was seen, however long the
        // command ran: the wake is not confirmed.
        workspace.noteAgentWakeCommandEnded(panelId: panel.id)

        #expect(panel.agentWakeFailure?.reason == .exitedBeforeStart)
    }

    @MainActor
    @Test
    func probeWithoutLiveProcessKeepsTheCheckPending() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        #expect(workspace.probeAgentWakeLiveProcess(panelId: panel.id))
        #expect(workspace.agentWakeVerificationsByPanelId[panel.id]?.state == .pending)
    }

    @MainActor
    @Test
    func reportFromAnotherAgentOnThePaneLeavesTheCheckPending() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.beginAgentWakeVerification(panelId: panel.id, agent: agent)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .running)
        workspace.recordAgentPID(key: "amp.other-session", pid: getpid(), panelId: panel.id, refreshPorts: false)
        defer { workspace.clearAgentPID(key: "amp.other-session", panelId: panel.id, refreshPorts: false) }

        #expect(workspace.agentWakeVerificationsByPanelId[panel.id]?.state == .pending)
    }

    @MainActor
    @Test
    func lifecycleReportWithoutPanelIdDoesNotConfirmTheFocusedPane() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let focused = try #require(workspace.focusedTerminalPanel)
        let other = try #require(
            workspace.newTerminalSplit(from: focused.id, orientation: .horizontal, focus: false)
        )
        #expect(workspace.focusedPanelId == focused.id)

        workspace.beginAgentWakeVerification(panelId: focused.id, agent: agent)
        workspace.beginAgentWakeVerification(panelId: other.id, agent: agent)
        workspace.setAgentLifecycle(key: "codex", panelId: nil, lifecycle: .running)

        #expect(workspace.agentWakeVerificationsByPanelId[focused.id]?.state == .pending)
        #expect(workspace.agentWakeVerificationsByPanelId[other.id]?.state == .pending)
    }

    @MainActor
    @Test
    func closingThePanelClearsVerificationAndSidebarRow() throws {
        let workspace = Workspace()
        defer { clearNotifications(workspace) }
        let first = try #require(workspace.focusedTerminalPanel)
        let closing = try #require(
            workspace.newTerminalSplit(from: first.id, orientation: .horizontal, focus: false)
        )

        workspace.beginAgentWakeVerification(panelId: closing.id, agent: agent)
        workspace.failAgentWakeVerification(panelId: closing.id, reason: .didNotStart)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey] != nil)

        #expect(workspace.closePanel(closing.id, force: true))

        #expect(workspace.panels[closing.id] == nil)
        #expect(workspace.agentWakeVerificationsByPanelId[closing.id] == nil)
        #expect(closing.agentWakeFailure == nil)
        #expect(workspace.statusEntries[Workspace.agentWakeFailedStatusKey] == nil)
    }

    @MainActor
    private func clearNotifications(_ workspace: Workspace) {
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
    }
}
