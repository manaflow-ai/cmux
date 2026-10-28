import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CrashDiagnosticSessionPolicyTests {
    @Test("Merging identical window IDs does not absorb another window sharing sessions")
    func crashMergeDoesNotInventReplayEvidence() throws {
        let original = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]), crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ])
        var independent = original
        independent.windowId = UUID()
        independent.tabManager.workspaces = independent.tabManager.workspaces.map {
            var copy = $0
            copy.workspaceId = UUID()
            return copy
        }
        let result = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, original, independent]
        )))
        #expect(result.windows.count == 2)
        #expect(Set(result.windows.compactMap(\.windowId)) == Set([original.windowId, independent.windowId].compactMap { $0 }))
    }

    @Test("Differing dock ownership remains recoverable instead of being normalized away")
    func crashMergePreservesDifferentDockOwners() throws {
        var original = crashTestWindow([crashTestWorkspace("api", agents: ["a"])])
        let owner = try #require(original.tabManager.workspaces[0].workspaceId)
        let panel = terminalPanelSnapshot(id: UUID(), directory: "/work", terminal: SessionTerminalPanelSnapshot())
        original.dock = SessionSplitContainerSnapshot(
            focusedPanelId: panel.id,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)), panels: [panel]
        )
        var replay = original
        replay.dock?.sourceWorkspaceIdsByPanelId = [panel.id: owner]
        let result = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        #expect(result.windows.count == 2)
        #expect(result.windows[0].dock?.sourceWorkspaceIdsByPanelId == nil)
        #expect(result.windows[1].dock?.sourceWorkspaceIdsByPanelId == [panel.id: owner])
    }

    @Test("Different user-authored workspace state survives identical panel evidence")
    func crashMergeKeepsWorkspaceMetadata() throws {
        let original = crashTestWindow([crashTestWorkspace("api", agents: ["a"])])
        var replay = original
        replay.tabManager.workspaces[0].customDescription = "Important work"
        replay.tabManager.workspaces[0].customColor = "blue"
        replay.tabManager.workspaces[0].isPinned = true
        replay.tabManager.workspaces[0].environment = ["BUILD_MODE": "special"]
        let result = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        let workspaces = try #require(result.windows.first).tabManager.workspaces
        #expect(workspaces.count == 2)
        #expect(workspaces[1].customDescription == "Important work")
        #expect(workspaces[1].customColor == "blue")
        #expect(workspaces[1].isPinned)
        #expect(workspaces[1].environment == ["BUILD_MODE": "special"])
    }

    @Test("A legacy richer workspace retains the ID needed by a nonfirst group anchor")
    func crashMergeKeepsLegacyAnchorIdentity() throws {
        let group = UUID()
        var original = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]), crashTestWorkspace("docs", agents: ["b"]),
            crashTestWorkspace("infra", agents: ["c"])
        ])
        original.tabManager.workspaces[0].groupId = group
        original.tabManager.workspaces[1].groupId = group
        let anchor = try #require(original.tabManager.workspaces[1].workspaceId)
        original.tabManager.workspaceGroups = [SessionWorkspaceGroupSnapshot(
            id: group, name: "work", isCollapsed: false, anchorWorkspaceId: anchor, anchorMemberIndex: 1
        )]
        var replay = original
        var richer = crashTestWorkspace("docs", agents: ["b", "extra"], richDirectories: false)
        richer.groupId = group
        richer.workspaceId = nil
        replay.tabManager.workspaces[1] = richer
        let result = try #require(SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 10, windows: [original, replay]
        )))
        let window = try #require(result.windows.first)
        #expect(window.tabManager.workspaces[1].workspaceId == anchor)
        #expect(window.tabManager.workspaceGroups?.first?.anchorWorkspaceId == anchor)
        #expect(window.tabManager.workspaceGroups?.first?.anchorMemberIndex == 1)
    }

    @Test("Malformed anchor indices cannot index outside kept members", arguments: [-1, Int.min, Int.max])
    func crashMergeRejectsMalformedAnchorIndices(index: Int) throws {
        let groupID = UUID()
        var workspace = crashTestWorkspace("api", agents: ["a"])
        workspace.groupId = groupID
        let groups = SessionPersistencePolicy.pruningWorkspaceGroups(
            [SessionWorkspaceGroupSnapshot(id: groupID, name: "work", isCollapsed: false, anchorMemberIndex: index)],
            originalWorkspaces: [workspace], keptWorkspaces: [workspace]
        )
        let group = try #require(groups?.first)
        #expect(group.anchorMemberIndex == 0)
        #expect(group.anchorWorkspaceId == workspace.workspaceId)
    }
}
