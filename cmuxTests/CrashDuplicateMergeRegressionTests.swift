import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CrashDiagnosticSessionPolicyTests {
    @Test("A large restored generation retains every panel and its scrollback")
    func crashMergeLargeScrollbackGeneration() throws {
        let scrollback = String(repeating: "x", count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal)
        let workspaces = (0..<41).map { index -> SessionWorkspaceSnapshot in
            var workspace = terminalWorkspaceSnapshot(currentDirectory: "/work/\(index)")
            workspace.workspaceId = UUID()
            workspace.panels = (0..<4).map { _ in
                terminalPanelSnapshot(
                    id: UUID(), directory: workspace.currentDirectory,
                    terminal: SessionTerminalPanelSnapshot(workingDirectory: workspace.currentDirectory, scrollback: scrollback)
                )
            }
            workspace.layout = .pane(SessionPaneLayoutSnapshot(
                panelIds: workspace.panels.map(\.id), selectedPanelId: workspace.panels[0].id
            ))
            return workspace
        }
        let window = crashTestWindow(workspaces)
        let start = ContinuousClock.now
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [window, window]
        )))
        let elapsed = start.duration(to: .now)
        #expect(restored.windows.count == 1)
        let panels = restored.windows[0].tabManager.workspaces.flatMap(\.panels)
        #expect(panels.count == 164)
        #expect(Set(panels.map(\.id)) == Set(workspaces.flatMap(\.panels).map(\.id)))
        #expect(panels.allSatisfy { $0.terminal?.scrollback == scrollback })
        print("Crash merge: 41 workspaces, 164 panels, \(164 * scrollback.utf8.count) scrollback bytes per generation, elapsed \(elapsed)")
    }

    @Test("Recovered scrollback in only one crash generation survives metadata selection")
    func crashMergeKeepsPartiallyRecoveredScrollback() throws {
        let original = crashTestWindow([crashTestWorkspace("api", agents: ["a"])])
        let replay = crashTestWindow(
            [crashTestWorkspace("api", agents: ["a"], richDirectories: false)], id: try #require(original.windowId)
        )
        let recoveredPanelID = try #require(replay.tabManager.workspaces[0].panels.first?.id)
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )) { snapshot in
            var snapshot = snapshot
            snapshot.windows[1].tabManager.workspaces[0].panels[0].terminal?.scrollback = "recovered only here"
            return snapshot
        })
        #expect(restored.windows.count == 1)
        #expect(restored.windows[0].tabManager.workspaces.count == 1)
        #expect(restored.windows[0].tabManager.workspaces[0].panels[0].id == recoveredPanelID)
        #expect(restored.windows[0].tabManager.workspaces[0].panels[0].terminal?.scrollback == "recovered only here")
    }

    @Test("Dock contents are compared even when all panel identities match")
    func crashMergeKeepsConflictingDockContents() throws {
        var original = crashTestWindow([crashTestWorkspace("api", agents: ["a"])])
        let panel = terminalPanelSnapshot(id: UUID(), directory: "/work", terminal: SessionTerminalPanelSnapshot(scrollback: "first"))
        original.dock = SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)), panels: [panel]
        )
        var replay = original
        replay.dock?.panels[0].terminal?.scrollback = "second"
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        #expect(restored.windows.count == 2)
        #expect(Set(restored.windows.compactMap { $0.dock?.panels.first?.terminal?.scrollback }) == ["first", "second"])
    }

    @Test("The same browser panel identity does not erase conflicting saved pages")
    func crashMergeKeepsConflictingBrowserContents() throws {
        var original = crashTestWindow([crashTestWorkspace("api", agents: ["a"])])
        var panel = terminalPanelSnapshot(id: UUID(), directory: nil, terminal: SessionTerminalPanelSnapshot())
        panel.type = .browser
        panel.terminal = nil
        panel.browser = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/first", profileID: nil, shouldRenderWebView: true,
            pageZoom: 1, developerToolsVisible: false, backHistoryURLStrings: [], forwardHistoryURLStrings: []
        )
        original.tabManager.workspaces[0].panels.append(panel)
        original.tabManager.workspaces[0].layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: original.tabManager.workspaces[0].panels.map(\.id), selectedPanelId: panel.id
        ))
        var replay = original
        replay.tabManager.workspaces[0].panels[1].browser?.urlString = "https://example.com/second"
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        #expect(restored.windows.count == 1)
        let pages = restored.windows[0].tabManager.workspaces.flatMap(\.panels).compactMap { $0.browser?.urlString }
        #expect(Set(pages) == ["https://example.com/first", "https://example.com/second"])
    }

    @Test("Dock ownership follows replacement workspace identities", arguments: [false, true])
    func crashMergeRemapsDockOwnership(windowDock: Bool) throws {
        var original = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]), crashTestWorkspace("docs", agents: ["c"]),
            crashTestWorkspace("infra", agents: ["d"])
        ])
        var replay = crashTestWindow([
            crashTestWorkspace("api", agents: ["a", "b"], richDirectories: false),
            crashTestWorkspace("docs", agents: ["c"], richDirectories: false),
            crashTestWorkspace("infra", agents: ["d"], richDirectories: false)
        ], id: try #require(original.windowId))
        let sourceID = try #require(original.tabManager.workspaces[0].workspaceId)
        let replacementID = try #require(replay.tabManager.workspaces[0].workspaceId)
        let panel = terminalPanelSnapshot(id: UUID(), directory: "/work", terminal: SessionTerminalPanelSnapshot())
        let dock = SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel], sourceWorkspaceIdsByPanelId: [panel.id: sourceID]
        )
        if windowDock {
            original.dock = dock; replay.dock = dock
        } else {
            original.tabManager.workspaces[0].dock = dock; replay.tabManager.workspaces[0].dock = dock
        }
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        #expect(restored.windows.count == 1)
        let window = try #require(restored.windows.first)
        let workspace = try #require(window.tabManager.workspaces.first { $0.customTitle == "api" })
        #expect(workspace.workspaceId == replacementID)
        let restoredDock = try #require(windowDock ? window.dock : workspace.dock)
        #expect(restoredDock.sourceWorkspaceIdsByPanelId?[panel.id] == replacementID)
    }

    @Test("Crash merging preserves unique terminal and browser panels", arguments: [false, true])
    func crashMergeKeepsNonAgentPanels(browser: Bool) throws {
        let original = crashTestWindow([crashTestWorkspace("api", agents: ["a", "b"])])
        var replay = original
        var panel = terminalPanelSnapshot(
            id: UUID(), directory: "/work/api", terminal: SessionTerminalPanelSnapshot(scrollback: "saved output")
        )
        if browser {
            panel.type = .browser
            panel.terminal = nil
            panel.browser = SessionBrowserPanelSnapshot(
                urlString: "https://example.com/saved", profileID: nil,
                shouldRenderWebView: true, pageZoom: 1, developerToolsVisible: false,
                backHistoryURLStrings: [], forwardHistoryURLStrings: []
            )
        }
        replay.tabManager.workspaces[0].panels.append(panel)
        replay.tabManager.workspaces[0].layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: replay.tabManager.workspaces[0].panels.map(\.id), selectedPanelId: panel.id
        ))
        let restored = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        #expect(restored.windows.count == 1)
        #expect(restored.windows[0].tabManager.workspaces.count == 1)
        let panels = restored.windows[0].tabManager.workspaces[0].panels
        #expect(Set(panels.map(\.id)) == Set(replay.tabManager.workspaces[0].panels.map(\.id)))
        let saved = try #require(panels.first { $0.id == panel.id })
        #expect(saved.terminal?.scrollback == panel.terminal?.scrollback)
        #expect(saved.browser?.urlString == panel.browser?.urlString)
    }

    @Test("Merging crash generations keeps agents unique to either copy")
    func crashMergeKeepsIncomparableAgentSets() throws {
        let id = UUID()
        let original = crashTestWindow([
            crashTestWorkspace("api", agents: ["a", "old"]),
            crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ], id: id)
        var replay = crashTestWindow([
            crashTestWorkspace("api", agents: ["a", "new"]),
            crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ], id: id)
        // Both stable identity and title fallback must preserve a divergent
        // generation; matching a workspace does not justify dropping its agent.
        for sameIdentity in [false, true] {
            if sameIdentity {
                replay.tabManager.workspaces[0].workspaceId = original.tabManager.workspaces[0].workspaceId
            }
            let result = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
                version: SessionSnapshotSchema.currentVersion,
                createdAt: 10,
                windows: [original, replay]
            ))
            #expect(result.mergedWindowCount == 1)
            let window = try #require(result.snapshot.windows.first)
            let agents = Set(window.tabManager.workspaces.flatMap(\.panels).compactMap { $0.terminal?.agent?.sessionId })
            #expect(agents == ["a", "b", "c", "old", "new"])
        }
    }

    @Test("A preferred workspace is consumed at most once by a crash generation")
    func crashMergeDoesNotCollapseTwoSupplementalWorkspaces() throws {
        let id = UUID()
        let preferred = crashTestWindow([
            crashTestWorkspace("shared", agents: ["a", "b"]),
            crashTestWorkspace("plain", tmuxSessions: ["build"])
        ], id: id)
        let supplemental = crashTestWindow([
            crashTestWorkspace("one", agents: ["a"], richDirectories: false),
            crashTestWorkspace("two", agents: ["b"], richDirectories: false)
        ], id: id)
        let result = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [preferred, supplemental]
        ))
        #expect(result.mergedWindowCount == 1)
        let workspaces = try #require(result.snapshot.windows.first).tabManager.workspaces
        #expect(workspaces.count == 3)
        #expect(workspaces.contains { $0.workspaceId == supplemental.tabManager.workspaces[1].workspaceId })
    }

    @Test("Merged groups discard orphan groups and reconcile replaced anchors")
    func crashMergeReconcilesGroups() throws {
        let id = UUID()
        let groupID = UUID()
        let orphanID = UUID()
        let pinnedID = UUID()
        var preferred = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]),
            crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ], id: id)
        preferred.tabManager.workspaces[0].groupId = groupID
        preferred.tabManager.workspaces[1].groupId = groupID
        preferred.tabManager.workspaceGroups = [SessionWorkspaceGroupSnapshot(
            id: groupID, name: "work", isCollapsed: false,
            anchorWorkspaceId: preferred.tabManager.workspaces[1].workspaceId,
            anchorMemberIndex: 1
        )]
        var supplemental = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"], richDirectories: false),
            crashTestWorkspace("docs", agents: ["b", "d"], richDirectories: false),
            crashTestWorkspace("infra", agents: ["c"], richDirectories: false)
        ], id: id)
        supplemental.tabManager.workspaces[0].groupId = groupID
        supplemental.tabManager.workspaces[1].groupId = groupID
        supplemental.tabManager.workspaceGroups = [
            SessionWorkspaceGroupSnapshot(id: orphanID, name: "old", isCollapsed: false),
            SessionWorkspaceGroupSnapshot(
                id: pinnedID, name: "pinned", isCollapsed: false,
                anchorIsEmpty: true, isPinned: true
            )
        ]
        let result = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [preferred, supplemental]
        ))
        let window = try #require(result.snapshot.windows.first)
        let groups = try #require(window.tabManager.workspaceGroups)
        #expect(Set(groups.map(\.id)) == [groupID, pinnedID])
        let group = try #require(groups.first { $0.id == groupID })
        #expect(group.anchorMemberIndex == 1)
        #expect(group.anchorWorkspaceId == supplemental.tabManager.workspaces[1].workspaceId)
        #expect(group.anchorIsEmpty == nil)
        #expect(groups.first { $0.id == pinnedID }?.anchorIsEmpty == true)
    }
    @Test("Different docks are preserved instead of being discarded by a crash merge", arguments: [false, true])
    func crashMergeKeepsDifferentDocks(windowDock: Bool) throws {
        let original = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]),
            crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ])
        var replay = original
        let dockWorkspace = crashTestWorkspace("dock", agents: ["dock-agent"])
        let dock = SessionSplitContainerSnapshot(
            focusedPanelId: dockWorkspace.focusedPanelId,
            layout: dockWorkspace.layout,
            panels: dockWorkspace.panels
        )
        if windowDock {
            replay.dock = dock
        } else {
            replay.tabManager.workspaces[0].dock = dock
        }
        let result = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [original, replay]
        ))
        let dockAgents = result.snapshot.windows.flatMap { window in
            (window.dock?.panels ?? []) + window.tabManager.workspaces.flatMap { $0.dock?.panels ?? [] }
        }.compactMap { $0.terminal?.agent?.sessionId }
        #expect(dockAgents == ["dock-agent"])
        if windowDock { #expect(result.snapshot.windows.count == 2) }
    }

}
