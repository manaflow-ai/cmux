import Foundation
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CrashDiagnosticSessionPolicyTests {
    func replayedWindowPair() -> (original: SessionWindowSnapshot, replay: SessionWindowSnapshot) {
        func workspace(_ title: String, checkpoints: [String]) -> SessionWorkspaceSnapshot {
            let panels = checkpoints.map { checkpoint -> SessionPanelSnapshot in
                let terminal = SessionTerminalPanelSnapshot(
                    workingDirectory: "/work/\(title)",
                    agent: SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: checkpoint,
                        workingDirectory: "/work/\(title)"
                    ),
                    wasAgentRunning: true
                )
                return terminalPanelSnapshot(id: UUID(), directory: "/work/\(title)", terminal: terminal)
            }
            let first = panels.first?.id ?? UUID()
            return SessionWorkspaceSnapshot(
                workspaceId: UUID(),
                processTitle: "Terminal",
                customTitle: title,
                customColor: nil,
                isPinned: false,
                currentDirectory: "/work/\(title)",
                focusedPanelId: first,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: first)),
                panels: panels,
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                windowId: UUID(),
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }
        let original = window([
            workspace("api", checkpoints: ["a"]),
            workspace("docs", checkpoints: ["b"]),
            workspace("infra", checkpoints: []),
            workspace("web", checkpoints: []),
        ])
        let replay = window([
            workspace("web", checkpoints: ["d"]),
            workspace("api", checkpoints: ["a"]),
            workspace("infra", checkpoints: ["c"]),
            workspace("docs", checkpoints: ["b"]),
        ])
        return (original, replay)
    }
    func crashTestWorkspace(
        _ title: String,
        agents: [String] = [],
        tmuxSessions: [String] = [],
        richDirectories: Bool = true
    ) -> SessionWorkspaceSnapshot {
        let directory = "/work/\(title)"
        let agentPanels = agents.map { checkpoint -> SessionPanelSnapshot in
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: richDirectories ? directory : nil,
                agent: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: checkpoint,
                    workingDirectory: richDirectories ? directory : nil
                ),
                wasAgentRunning: true
            )
            return terminalPanelSnapshot(id: UUID(), directory: richDirectories ? directory : nil, terminal: terminal)
        }
        let tmuxPanels = tmuxSessions.map { name -> SessionPanelSnapshot in
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                resumeBinding: SurfaceResumeBindingSnapshot(
                    name: "tmux \(name)",
                    kind: "tmux",
                    command: "tmux new-session -A -s \(name)",
                    cwd: directory,
                    checkpointId: name,
                    source: "process-detected"
                )
            )
            return terminalPanelSnapshot(id: UUID(), directory: directory, terminal: terminal)
        }
        let panels = agentPanels + tmuxPanels
        let first = panels.first?.id ?? UUID()
        return SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Terminal",
            customTitle: title,
            customColor: nil,
            isPinned: false,
            currentDirectory: directory,
            focusedPanelId: first,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: first)),
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }
    func crashTestWindow(_ workspaces: [SessionWorkspaceSnapshot], id: UUID = UUID()) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: id,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
    }

    func pruningAndMergingCrashWindows(
        from snapshot: AppSessionSnapshot
    ) -> (snapshot: AppSessionSnapshot?, removedAny: Bool) {
        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)
        guard let prunedSnapshot = pruned.snapshot else { return (nil, pruned.removedAny) }
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: prunedSnapshot)
        return (merged.snapshot, pruned.removedAny || merged.mergedWindowCount > 0)
    }
}
