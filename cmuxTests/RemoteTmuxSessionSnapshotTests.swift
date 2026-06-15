import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxSessionSnapshotTests {
    @Test func sessionSnapshotSkipsDedicatedRemoteTmuxWindowWithOnlyMirrorWorkspaces() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let host = RemoteTmuxHost(destination: "user@example.test")
        appDelegate.remoteTmuxController.bindDedicatedWindowForTesting(host: host, windowId: windowId)
        defer {
            appDelegate.remoteTmuxController.unbindDedicatedWindowForTesting(windowId: windowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        #expect(appDelegate.sessionSnapshotForTesting() == nil)
    }

    @Test func sessionSnapshotPreservesLocalWorkspaceInDedicatedRemoteTmuxWindow() throws {
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
        let host = RemoteTmuxHost(destination: "user@example.test")
        appDelegate.remoteTmuxController.bindDedicatedWindowForTesting(host: host, windowId: windowId)
        defer {
            appDelegate.remoteTmuxController.unbindDedicatedWindowForTesting(windowId: windowId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }

        let snapshot = try #require(appDelegate.sessionSnapshotForTesting())
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].tabManager.workspaces.map(\.workspaceId) == [localWorkspace.id])
        #expect(snapshot.windows[0].tabManager.selectedWorkspaceIndex == nil)
    }
}
