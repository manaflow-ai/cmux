import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) @MainActor
struct SessionSnapshotLimitTests {
    @Test func persists130WorkspacesAndRestoresSelectedWorkspace129() throws {
        let manager = TabManager()
        defer { manager.closeWorkspacesForTesting() }
        for _ in 1..<130 {
            _ = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        }
        let selected = manager.tabs[129]
        manager.selectWorkspace(selected)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.workspaces.count == 130)
        #expect(snapshot.omittedWorkspaceCount == nil)
        let selectedIndex = try #require(snapshot.selectedWorkspaceIndex)
        #expect(selectedIndex == 129)
        #expect(snapshot.workspaces[selectedIndex].workspaceId == selected.id)
        #expect(snapshot.workspaces.map(\.workspaceId) == manager.tabs.map { Optional($0.id) })

        let restored = TabManager()
        defer { restored.closeWorkspacesForTesting() }
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.tabs.count == 130)
        #expect(restored.selectedTabId == selected.id)
    }

    @Test func mixedRestorableTabsRetainAllWorkspacesAndShareFingerprintBoundary() {
        let manager = TabManager()
        defer { manager.closeWorkspacesForTesting() }
        manager.tabs[0].isRemoteTmuxAuthLogin = true
        for _ in 1..<131 {
            _ = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
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
        #expect(manager.sessionAutosaveFingerprint() != before)
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
