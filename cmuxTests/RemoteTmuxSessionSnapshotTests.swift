import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct RemoteTmuxSessionSnapshotTests {
    @Test func sessionSnapshotSkipsWindowWithOnlyRemoteTmuxMirrorWorkspaces() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        #expect(appDelegate.sessionSnapshotForTesting() == nil)
    }

    @Test func sessionSnapshotPreservesLocalWorkspaceInWindowWithRemoteTmuxMirror() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let localWorkspace = try #require(manager.selectedWorkspace)
        localWorkspace.setCustomTitle("Local")
        let remoteWorkspace = manager.addWorkspace(
            title: "remote",
            select: true,
            autoWelcomeIfNeeded: false
        )
        remoteWorkspace.isRemoteTmuxMirror = true
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        let snapshot = try #require(appDelegate.sessionSnapshotForTesting())
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].tabManager.workspaces.map(\.workspaceId) == [localWorkspace.id])
        #expect(snapshot.windows[0].tabManager.selectedWorkspaceIndex == nil)
    }

    @Test func autosaveProjectionUsesTheSameEligibleRoutesAsSessionSnapshot() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let remoteOnlyWindowId = try #require(
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")
        )
        let persistedWindowId = try #require(
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")
        )
        let remoteOnlyManager = TabManager(autoWelcomeIfNeeded: false)
        let remoteOnlyWorkspace = try #require(remoteOnlyManager.selectedWorkspace)
        remoteOnlyWorkspace.isRemoteTmuxMirror = true
        let persistedManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.registerMainWindowContextForTesting(
            windowId: remoteOnlyWindowId,
            tabManager: remoteOnlyManager
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: persistedWindowId,
            tabManager: persistedManager
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: remoteOnlyWindowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: persistedWindowId)
            AppDelegate.shared = originalAppDelegate
        }

        let eligibleRoutes = appDelegate.orderedSessionRouteSnapshots()
        let projection = MainWindowRouteAutosaveProjection(
            orderedWindowIds: eligibleRoutes.map(\.windowId),
            previouslyPersistedWindowIds: [],
            maximumFingerprintWindows: 1
        )
        let snapshot = try #require(appDelegate.sessionSnapshotForTesting())

        #expect(eligibleRoutes.map(\.windowId) == [persistedWindowId])
        #expect(projection.fingerprintWindowIds == [persistedWindowId])
        #expect(snapshot.windows.compactMap(\.windowId) == [persistedWindowId])
    }
}
