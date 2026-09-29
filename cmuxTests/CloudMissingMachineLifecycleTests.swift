import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud missing machine lifecycle", .serialized)
struct CloudMissingMachineLifecycleTests {
    @Test("A missing machine closes every stale recoverable workspace and preserves local work")
    func missingMachineClosesAllRecoverableBindings() throws {
        _ = NSApplication.shared
        let previousApp = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        let window = makeWindow(id: windowID)
        window.orderBack(nil)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        defer {
            manager.finalizeAllWorkspacesForWindowClose()
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            window.orderOut(nil)
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousApp
        }

        let local = try #require(manager.selectedWorkspace)
        let machineID = "vm-missing-\(UUID().uuidString.lowercased())"
        let first = manager.addWorkspace(title: "Stale one", select: false)
        let second = manager.addWorkspace(title: "Stale two", select: false)
        first.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machineID, isBase: false)
        second.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machineID, isBase: false)

        app.unregisterMainWindowContextForTesting(windowId: windowID)
        app.tabManager = nil
        #expect(app.mainWindowContexts.isEmpty)
        #expect(app.liveWorkspaceIdentityTabManagers().contains { $0 === manager })

        app.closeWorkspaces(forManagedCloudVMID: machineID)

        #expect(manager.tabs.map(\.id) == [local.id])
        #expect(first.cloudVMID == nil)
        #expect(second.cloudVMID == nil)
        #expect(first.panels.isEmpty)
        #expect(second.panels.isEmpty)
        #expect(!local.panels.isEmpty)

        // A repeated terminal disposition cannot resurrect a row or clear local work.
        app.closeWorkspaces(forManagedCloudVMID: machineID)
        #expect(manager.tabs.map(\.id) == [local.id])
        #expect(!local.panels.isEmpty)
    }

    private func makeWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        window.isReleasedWhenClosed = false
        return window
    }
}
