import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CrashDiagnosticSessionPolicyTests {
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
