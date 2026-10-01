import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent recovery snapshot merge")
struct AgentRecoverySnapshotMergeTests {
    private let workspaceId = UUID()
    private let panelId = UUID()

    @Test func agentMissedByAutosaveResumesInItsOwnPanel() throws {
        let crashed = snapshot(terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp", wasAgentRunning: false))
        let merged = AgentRecoverySnapshotMerge.merging([candidate("s-new", at: 105)], into: crashed)
        let terminal = try #require(panel(in: merged)?.terminal)
        #expect(terminal.agent?.kind == .claude)
        #expect(terminal.agent?.sessionId == "s-new")
        #expect(terminal.agent?.workingDirectory == "/repo")
        #expect(terminal.wasAgentRunning == true)
    }

    @Test func newerSessionReplacesStaleBindingAndHibernation() throws {
        var stale = SessionTerminalPanelSnapshot(workingDirectory: "/tmp", wasAgentRunning: true)
        stale.agent = SessionRestorableAgentSnapshot(kind: .claude, sessionId: "s-old", workingDirectory: "/tmp", launchCommand: nil)
        stale.hibernation = SessionAgentHibernationSnapshot(hibernatedAt: 90, lastActivityAt: 90)
        let merged = AgentRecoverySnapshotMerge.merging([candidate("s-new", at: 105)], into: snapshot(terminal: stale))
        let terminal = try #require(panel(in: merged)?.terminal)
        #expect(terminal.agent?.sessionId == "s-new")
        #expect(terminal.hibernation == nil)
        #expect(terminal.resumeBinding == nil)
    }

    @Test func tmuxAndRemoteTerminalsAreUntouched() {
        let tmux = snapshot(terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp", tmuxStartCommand: "tmux attach -t x"))
        #expect(panel(in: AgentRecoverySnapshotMerge.merging([candidate("s-new", at: 105)], into: tmux))?.terminal?.agent == nil)

        var remoteTerminal = SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        remoteTerminal.isRemoteTerminal = true
        let remote = snapshot(terminal: remoteTerminal)
        #expect(panel(in: AgentRecoverySnapshotMerge.merging([candidate("s-new", at: 105)], into: remote))?.terminal?.agent == nil)
    }

    private func candidate(_ sessionId: String, at seconds: TimeInterval) -> AgentRecoveryCandidate {
        AgentRecoveryCandidate(
            kind: "claude",
            sessionId: sessionId,
            workspaceId: workspaceId.uuidString,
            surfaceId: panelId.uuidString,
            cwd: "/repo",
            launchCommand: nil,
            lastActivity: Date(timeIntervalSince1970: seconds)
        )
    }

    private func panel(in snapshot: AppSessionSnapshot) -> SessionPanelSnapshot? {
        snapshot.windows.first?.tabManager.workspaces.first?.panels.first
    }

    private func snapshot(terminal: SessionTerminalPanelSnapshot) -> AppSessionSnapshot {
        var workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
            panels: [
                SessionPanelSnapshot(
                    id: panelId,
                    type: .terminal,
                    title: "Terminal",
                    customTitle: nil,
                    directory: "/tmp",
                    isPinned: false,
                    isManuallyUnread: false,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: terminal,
                    browser: nil,
                    markdown: nil,
                    filePreview: nil,
                    rightSidebarTool: nil
                ),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        workspace.workspaceId = workspaceId
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 100,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
    }
}
