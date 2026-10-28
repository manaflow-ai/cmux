import Foundation
import Testing
import CmuxControlSocket

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) @MainActor
struct SessionSnapshotLimitTests {
    @Test(arguments: [130, 1_024])
    func persistsAllWorkspacesAndRestoresLastSelectedWorkspace(workspaceCount: Int) throws {
        let manager = TabManager()
        defer { manager.closeWorkspacesForTesting() }
        for _ in 1..<workspaceCount {
            _ = manager.addWorkspace(
                select: false,
                placementOverride: .end,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false,
                normalizeWorkspaceGroupsAfterInsert: false
            )
        }
        let selected = manager.tabs[workspaceCount - 1]
        manager.selectWorkspace(selected)

        let captureStart = ProcessInfo.processInfo.systemUptime
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let captureSeconds = ProcessInfo.processInfo.systemUptime - captureStart
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
        _ = manager.sessionAutosaveFingerprint()
        let fingerprintSeconds = ProcessInfo.processInfo.systemUptime - fingerprintStart
        #expect(snapshot.workspaces.count == workspaceCount)
        #expect(snapshot.omittedWorkspaceCount == nil)
        let selectedIndex = try #require(snapshot.selectedWorkspaceIndex)
        #expect(selectedIndex == workspaceCount - 1)
        #expect(snapshot.workspaces[selectedIndex].workspaceId == selected.id)
        #expect(snapshot.workspaces.map(\.workspaceId) == manager.tabs.map { Optional($0.id) })

        #expect(manager.sessionSnapshotWorkspaceIds() == manager.tabs.map(\.id))
        let persistedSnapshot = try JSONDecoder().decode(
            SessionTabManagerSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        let restored = TabManager()
        defer { restored.closeWorkspacesForTesting() }
        let restoreStart = ProcessInfo.processInfo.systemUptime
        restored.restoreSessionSnapshot(persistedSnapshot)
        let restoreSeconds = ProcessInfo.processInfo.systemUptime - restoreStart
        print("session_snapshot_scale workspaces=\(workspaceCount) capture_s=\(captureSeconds) fingerprint_s=\(fingerprintSeconds) restore_s=\(restoreSeconds)")
        #expect(restored.tabs.count == workspaceCount)
        #expect(restored.selectedTabId == selected.id)
        #expect(restored.restoredSessionWorkspace(originalId: selected.id, from: persistedSnapshot)?.id == selected.id)
    }

    @Test func mixedRestorableTabsRetainAllWorkspacesAndShareFingerprintBoundary() {
        let manager = TabManager()
        defer { manager.closeWorkspacesForTesting() }
        let loginWorkspace = manager.tabs[0]
        loginWorkspace.isRemoteTmuxAuthLogin = true
        for _ in 1..<131 {
            _ = manager.addWorkspace(
                select: false,
                placementOverride: .end,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false,
                normalizeWorkspaceGroupsAfterInsert: false
            )
        }
        let boundaryWorkspace = manager.tabs[130]
        manager.selectWorkspace(manager.tabs[1])

        let before = manager.sessionAutosaveFingerprint()
        boundaryWorkspace.setCustomTitle("Changed at the restorable boundary")
        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        #expect(snapshot.workspaces.count == 130)
        #expect(snapshot.omittedWorkspaceCount == nil)
        #expect(snapshot.workspaces.last?.customTitle == "Changed at the restorable boundary")
        #expect(snapshot.workspaces.map(\.workspaceId) == manager.tabs.dropFirst().map { Optional($0.id) })
        #expect(snapshot.selectedWorkspaceIndex == 0)
        #expect(manager.sessionSnapshotWorkspaceIds() == manager.tabs.dropFirst().map(\.id))
        let after = manager.sessionAutosaveFingerprint()
        #expect(after != before)
        loginWorkspace.setCustomTitle("Excluded login workspace")
        #expect(manager.sessionAutosaveFingerprint() == after)
    }

    @Test func untrustedImportBoundsWorkspaceGraphAndRemapsGroupAnchor() throws {
        let limit = SessionPersistencePolicy.maxUntrustedImportedWorkspacesPerWindow
        let panel = SessionPanelSnapshot(id: UUID(), type: .terminal, title: "Terminal", customTitle: nil, directory: "/tmp", isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: nil, terminal: SessionTerminalPanelSnapshot(), browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil)
        let workspace = SessionWorkspaceSnapshot(processTitle: "Terminal", customTitle: nil, customColor: nil, isPinned: false, currentDirectory: "/tmp", focusedPanelId: panel.id, layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)), panels: [panel], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let groupID = UUID(); let ids = (0..<(limit + 2)).map { _ in UUID() }
        var original = AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion, createdAt: 0, windows: [SessionWindowSnapshot(frame: nil, display: nil, tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: limit + 1, workspaces: ids.map { id in var copy = workspace; copy.workspaceId = id; copy.groupId = groupID; return copy }, workspaceGroups: [SessionWorkspaceGroupSnapshot(id: groupID, name: "Imported", isCollapsed: false, anchorWorkspaceId: ids[126], anchorMemberIndex: 126)]), sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240))])
        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(original, source: .file(path: "/tmp/import.json"))
        let tabManager = try #require(restored.windows.first?.tabManager)
        #expect(tabManager.workspaces.count == limit); #expect(tabManager.selectedWorkspaceIndex == limit - 1); #expect(tabManager.workspaceGroups?.first?.anchorMemberIndex == 126); #expect(report.droppedWorkspaceCount == 2)
    }

    @Test func intermediateOmissionMetadataStillDecodes() throws {
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 127,
            workspaces: [],
            omittedWorkspaceCount: 2
        )
        let decoded = try JSONDecoder().decode(
            SessionTabManagerSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.omittedWorkspaceCount == 2)
    }

    @Test func oldSnapshotWithoutOmissionFieldsStillDecodes() throws {
        let legacy = Data(#"{"selectedWorkspaceIndex":null,"workspaces":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: legacy)
        #expect(decoded.selectedWorkspaceIndex == nil)
        #expect(decoded.workspaces.isEmpty)
    }
}
