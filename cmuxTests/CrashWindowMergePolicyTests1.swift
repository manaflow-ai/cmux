import AppKit
import CmuxWorkspaces
import Foundation
import Testing
import UniformTypeIdentifiers

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CrashDiagnosticSessionPolicyTests {
    @Test
    func sessionSnapshotDropsAnExactDuplicateWindowManifest() {
        let workspaceID = UUID()
        var workspace = terminalWorkspaceSnapshot(currentDirectory: "/tmp/cmux-project")
        workspace.workspaceId = workspaceID
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [window, window]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.first?.workspaceId == workspaceID)
    }
    @Test
    func sessionSnapshotKeepsTheRicherCopyWhenCrashWindowsShareAgentCheckpoints() {
        let checkpointID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let projectDirectory = "/Volumes/Workshop/Code/pulp"
        let panelID = UUID()
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: checkpointID,
            workingDirectory: projectDirectory
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(checkpointID)",
            cwd: projectDirectory,
            checkpointId: checkpointID,
            source: "agent-hook",
            autoResume: true
        )
        let richTerminal = SessionTerminalPanelSnapshot(
            workingDirectory: projectDirectory,
            agent: agent,
            resumeBinding: binding,
            wasAgentRunning: true
        )
        let degradedTerminal = SessionTerminalPanelSnapshot(
            workingDirectory: "/Users/danielraffel",
            agent: agent,
            wasAgentRunning: true
        )

        func window(workspaceID: UUID, currentDirectory: String, terminal: SessionTerminalPanelSnapshot) -> SessionWindowSnapshot {
            let workspace = SessionWorkspaceSnapshot(
                workspaceId: workspaceID,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: currentDirectory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: currentDirectory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
            return SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let degraded = window(
            workspaceID: UUID(),
            currentDirectory: "/Users/danielraffel",
            terminal: degradedTerminal
        )
        let rich = window(
            workspaceID: UUID(),
            currentDirectory: projectDirectory,
            terminal: richTerminal
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [degraded, rich]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        let keptWorkspace = pruned.snapshot?.windows.first?.tabManager.workspaces.first
        #expect(keptWorkspace?.currentDirectory == projectDirectory)
        #expect(keptWorkspace?.panels.first?.terminal?.workingDirectory == projectDirectory)
        #expect(keptWorkspace?.panels.first?.terminal?.resumeBinding?.cwd == projectDirectory)
    }
    @Test
    func sessionSnapshotKeepsSameSizeWindowsWhenCheckpointSetsPartiallyOverlap() {
        let projectDirectory = "/Volumes/Workshop/Code/pulp"
        let homeDirectory = "/Users/danielraffel"

        func workspace(
            id: UUID,
            checkpointID: String?,
            directory: String,
            includeBinding: Bool
        ) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let agent = checkpointID.map {
                SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: $0,
                    workingDirectory: includeBinding ? projectDirectory : nil
                )
            }
            let binding = includeBinding && checkpointID != nil
                ? SurfaceResumeBindingSnapshot(
                    kind: "codex",
                    command: "codex resume \(checkpointID!)",
                    cwd: projectDirectory,
                    checkpointId: checkpointID,
                    source: "agent-hook",
                    autoResume: true
                )
                : nil
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: agent,
                resumeBinding: binding,
                wasAgentRunning: true
            )
            return SessionWorkspaceSnapshot(
                workspaceId: id,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }

        let retainedID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let extraID = "01a149a8-00ed-7890-845c-dce07298068a"
        let degraded = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [
                    workspace(id: UUID(), checkpointID: retainedID, directory: homeDirectory, includeBinding: false),
                    workspace(id: UUID(), checkpointID: nil, directory: homeDirectory, includeBinding: false),
                ]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        let rich = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [
                    workspace(id: UUID(), checkpointID: retainedID, directory: projectDirectory, includeBinding: true),
                    workspace(id: UUID(), checkpointID: extraID, directory: projectDirectory, includeBinding: true),
                ]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        let pruned = pruningAndMergingCrashWindows(
            from: AppSessionSnapshot(
                version: SessionSnapshotSchema.currentVersion,
                createdAt: 10,
                windows: [degraded, rich]
            )
        )

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(pruned.snapshot?.windows.allSatisfy { $0.tabManager.workspaces.count == 2 } == true)
    }
    @Test
    func sessionSnapshotDoesNotMatchIdentityLessWorkspacesByPosition() {
        let retainedID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let projectDirectory = "/Volumes/Workshop/Code/pulp"

        func workspace(directory: String, checkpointID: String?) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpointID.map {
                    SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: $0,
                        workingDirectory: projectDirectory
                    )
                },
                wasAgentRunning: checkpointID != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }

        func window(workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: workspaces
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window(workspaces: [
                    workspace(directory: projectDirectory, checkpointID: retainedID),
                    workspace(directory: "/Volumes/Workshop/Code/first", checkpointID: nil),
                    workspace(directory: "/Volumes/Workshop/Code/auxiliary", checkpointID: nil),
                ]),
                window(workspaces: [
                    workspace(directory: projectDirectory, checkpointID: retainedID),
                    workspace(directory: "/Volumes/Workshop/Code/second", checkpointID: "01a149a8-00ed-7890-845c-dce07298068a"),
                    workspace(directory: "/Volumes/Workshop/Code/third", checkpointID: nil),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(
            Set(pruned.snapshot?.windows.flatMap { $0.tabManager.workspaces.map(\.currentDirectory) } ?? []) == [
                projectDirectory,
                "/Volumes/Workshop/Code/first",
                "/Volumes/Workshop/Code/auxiliary",
                "/Volumes/Workshop/Code/second",
                "/Volumes/Workshop/Code/third",
            ]
        )
    }
    @Test
    func sessionSnapshotMergesExactAgentFingerprintAndRetainsIdentitylessWorkspaces() {
        let checkpointID = "01a149a7-fbec-7240-9c88-ed6faec559ca"

        func workspace(_ directory: String, checkpoint: String? = nil) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpoint.map {
                    SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: $0,
                        workingDirectory: directory
                    )
                },
                wasAgentRunning: checkpoint != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window([
                    workspace("/work/project", checkpoint: checkpointID),
                    workspace("/work/first"),
                    workspace("/work/auxiliary"),
                ]),
                window([
                    workspace("/work/project", checkpoint: checkpointID),
                    workspace("/work/second"),
                    workspace("/work/third"),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(
            Set(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) ?? []) == [
                "/work/project",
                "/work/first",
                "/work/auxiliary",
                "/work/second",
                "/work/third",
            ]
        )
    }
    @Test
    func sessionSnapshotMergesReorderedTitledCrashWindowsWithoutDroppingUniqueWorkspaces() {
        func workspace(_ title: String, _ directory: String, _ checkpoint: String?) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpoint.map {
                    SessionRestorableAgentSnapshot(kind: .codex, sessionId: $0, workingDirectory: directory)
                },
                wasAgentRunning: checkpoint != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: title,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let first = window([
            workspace("A", "/work/a", "a"),
            workspace("B", "/work/b", "b"),
            workspace("C", "/work/c", "c"),
            workspace("D", "/work/d", "d"),
            workspace("E", "/work/e", nil),
        ])
        let reordered = window([
            workspace("C", "/work/c", "c"),
            workspace("A", "/work/a", "a"),
            workspace("E", "/work/e-new", "e"),
            workspace("D", "/work/d", "d"),
            workspace("B", "/work/b", "b"),
        ])

        let pruned = pruningAndMergingCrashWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [first, reordered]
        ))

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(Set(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.customTitle) ?? []) == ["A", "B", "C", "D", "E"])
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.contains { $0.currentDirectory == "/work/e-new" } == true)
    }
    @Test
    func sessionSnapshotKeepsWindowsThatShareTmuxSessionsSeparate() {
        let titles = ["api", "docs", "infra", "web"]
        let laptop = crashTestWindow(titles.map { crashTestWorkspace($0, tmuxSessions: ["cmux", "work"]) })
        let monitor = crashTestWindow(titles.map { crashTestWorkspace($0, tmuxSessions: ["cmux", "work"]) })
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [laptop, monitor]
        ))

        #expect(merged.mergedWindowCount == 0)
        #expect(merged.snapshot.windows.count == 2)
    }
}
