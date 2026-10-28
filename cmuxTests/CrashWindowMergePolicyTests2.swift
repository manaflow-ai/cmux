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
    func sessionSnapshotKeepsTheWorkspaceCopyWithMoreAgentsWhenCrashCopiesMerge() {
        let id = UUID()
        let rich = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]),
            crashTestWorkspace("docs", agents: ["c"]),
            crashTestWorkspace("infra", agents: ["d"]),
            crashTestWorkspace("web", agents: ["e"]),
        ], id: id)
        let replay = crashTestWindow([
            crashTestWorkspace("api", agents: ["a", "b"], richDirectories: false),
            crashTestWorkspace("docs", agents: ["c"], richDirectories: false),
            crashTestWorkspace("infra", agents: ["d"], richDirectories: false),
            crashTestWorkspace("web", agents: ["e"], richDirectories: false),
        ], id: id)
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [rich, replay]
        ))

        #expect(merged.mergedWindowCount == 1)
        let api = merged.snapshot.windows.first?.tabManager.workspaces.first { $0.customTitle == "api" }
        #expect(Set(api?.panels.compactMap { $0.terminal?.agent?.sessionId } ?? []) == ["a", "b"])
        #expect(merged.snapshot.windows.first?.tabManager.workspaces.count == 4)
    }
    @Test
    func liveRestoreSnapshotMergesAfterRecoveringScrollback() {
        let pair = replayedWindowPair()
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        )
        var recoveredWindowCount: Int?
        let restored = SessionPersistencePolicy.snapshotForLiveRestore(snapshot) { pruned in
            recoveredWindowCount = pruned.windows.count
            var recovered = pruned
            for windowIndex in recovered.windows.indices {
                for workspaceIndex in recovered.windows[windowIndex].tabManager.workspaces.indices {
                    for panelIndex in recovered.windows[windowIndex].tabManager.workspaces[workspaceIndex].panels.indices {
                        recovered.windows[windowIndex].tabManager.workspaces[workspaceIndex]
                            .panels[panelIndex].terminal?.scrollback = "recovered"
                    }
                }
            }
            return recovered
        }

        #expect(recoveredWindowCount == 2)
        #expect(restored?.windows.count == 1)
        let panels = restored?.windows.first?.tabManager.workspaces.flatMap(\.panels) ?? []
        #expect(!panels.isEmpty)
        #expect(panels.allSatisfy { $0.terminal == nil || $0.terminal?.scrollback == "recovered" })
    }
    @Test
    func liveRestoreSnapshotCollapsesThreeCopiesOfAWindow() {
        let pair = replayedWindowPair()
        var third = pair.replay
        third.windowId = UUID()
        let restored = SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay, third]
        ))

        #expect(restored?.windows.count == 1)
        #expect(restored?.windows.first?.tabManager.workspaces.count == 4)
    }
    @Test
    func sessionSnapshotMergesACrashReplayedWindowWithANewWindowID() {
        let pair = replayedWindowPair()
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        ))

        #expect(merged.mergedWindowCount == 1)
        let windows = merged.snapshot.windows
        #expect(windows.count == 1)
        let titles = windows.first?.tabManager.workspaces.compactMap(\.customTitle) ?? []
        #expect(titles.sorted() == ["api", "docs", "infra", "web"])
        let checkpoints = Set(windows.first?.tabManager.workspaces.flatMap { workspace in
            workspace.panels.compactMap { $0.terminal?.agent?.sessionId }
        } ?? [])
        #expect(checkpoints == ["a", "b", "c", "d"])
    }
    @Test
    func crashPruningKeepsBothCopiesOfAReplayedWindowForTheBackup() {
        let pair = replayedWindowPair()
        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        ))

        #expect(pruned.snapshot?.windows.count == 2)
        let expectedIDs = Set([pair.original.windowId, pair.replay.windowId].compactMap { $0 })
        #expect(Set(pruned.snapshot?.windows.compactMap(\.windowId) ?? []) == expectedIDs)
    }
    @Test
    func sessionSnapshotKeepsDistinctPersistedWindowsWithOverlappingAgentsSeparate() {
        func workspace(_ directory: String, checkpoint: String) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: checkpoint,
                    workingDirectory: directory
                ),
                wasAgentRunning: true
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
        func window(_ id: UUID, directory: String) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                windowId: id,
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [workspace(directory, checkpoint: "shared")]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let pruned = pruningAndMergingCrashWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window(firstWindowID, directory: "/work/first-window"),
                window(secondWindowID, directory: "/work/second-window"),
            ]
        ))

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(Set(pruned.snapshot?.windows.flatMap { $0.tabManager.workspaces.map(\.currentDirectory) } ?? []) == [
            "/work/first-window", "/work/second-window",
        ])
    }
    @Test
    func sessionSnapshotKeepsSameTitleWorkspacesWithDifferentDirectoriesSeparate() {
        func workspace(
            title: String?,
            directory: String,
            checkpoint: String? = nil
        ) -> SessionWorkspaceSnapshot {
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

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window([
                    workspace(title: "anchor", directory: "/work/anchor", checkpoint: "shared"),
                    workspace(title: "same-title", directory: "/work/one"),
                ]),
                window([
                    workspace(title: "anchor", directory: "/work/anchor", checkpoint: "shared"),
                    workspace(title: "same-title", directory: "/work/two"),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)
        let workspaces = pruned.snapshot?.windows.first?.tabManager.workspaces ?? []

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(Set(workspaces.map(\.currentDirectory)) == [
            "/work/anchor", "/work/one", "/work/two",
        ])
    }
}
