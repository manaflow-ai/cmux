import AppKit
import Bonsplit
import Combine
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Closed main window routing", .serialized)
struct ClosedMainWindowRoutingTests {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test("Closed main window is not listed or focusable while its objects linger")
    func closedMainWindowIsNotListedOrFocusableWhileItsObjectsLinger() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowBId)
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        windowB.makeKeyAndOrderFront(nil)
        windowA.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(managerA)

        let workspaceB = try #require(managerB.selectedWorkspace)
        let terminalPanelB = try #require(workspaceB.focusedTerminalPanel)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanelB.id) === terminalPanelB.surface)
        var surfacePortPublicationCount = 0
        let surfacePortCancellable = workspaceB.$surfaceListeningPorts.dropFirst().sink { _ in
            surfacePortPublicationCount += 1
        }
        defer { surfacePortCancellable.cancel() }
        #expect(TerminalController.shared.applyAgentPortPublication(
            workspaceId: workspaceB.id,
            ports: [4200]
        ))
        TerminalController.shared.applyPanelPortPublication(
            workspaceId: workspaceB.id,
            panelId: terminalPanelB.id,
            ports: [4300]
        )
        TerminalController.shared.applyPanelPortPublication(
            workspaceId: workspaceB.id,
            panelId: terminalPanelB.id,
            ports: [4300]
        )
        #expect(workspaceB.agentListeningPorts == [4200])
        #expect(workspaceB.surfaceListeningPorts[terminalPanelB.id] == [4300])
        #expect(surfacePortPublicationCount == 1)

        let baselineSummaries = app.listMainWindowSummaries()
        #expect(baselineSummaries.contains { $0.windowId == windowAId })
        #expect(baselineSummaries.contains { $0.windowId == windowBId })

        app.unregisterMainWindowContextForTesting(windowId: windowBId)
        windowB.orderOut(nil)

        #expect(!windowB.isVisible)
        #expect(!windowB.isMiniaturized)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowBId })
        #expect(!app.focusMainWindow(windowId: windowBId))
        #expect(!windowB.isVisible)
        #expect(app.tabManagerFor(windowId: windowBId) === managerB)
    }

    @Test("Recovered visible window stays listed and focusable")
    func recoveredVisibleWindowStaysListedAndFocusable() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowAId = UUID()
        let windowCId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowC = makeMainWindow(id: windowCId)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowAId)
            app.unregisterMainWindowContextForTesting(windowId: windowCId)
            windowA.orderOut(nil)
            windowC.orderOut(nil)
        }

        let managerA = TabManager()
        let managerC = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowC,
            windowId: windowCId,
            tabManager: managerC,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        windowA.makeKeyAndOrderFront(nil)
        windowC.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(managerA)

        let workspaceC = try #require(managerC.selectedWorkspace)
        let terminalPanelC = try #require(workspaceC.focusedTerminalPanel)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanelC.id) === terminalPanelC.surface)

        app.unregisterMainWindowContextForTesting(windowId: windowCId)

        #expect(windowC.isVisible)
        #expect(app.listMainWindowSummaries().contains { $0.windowId == windowCId })
        #expect(app.focusMainWindow(windowId: windowCId))
    }

    @Test("Retained closed window cannot respawn its context or terminal")
    func retainedClosedWindowCannotRespawnItsContextOrTerminal() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        window.makeKeyAndOrderFront(nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) === terminalPanel.surface)

        // Keep the NSWindow and SwiftUI-owned models alive across close, then
        // reproduce the late window-accessor registration from issue #8349.
        window.close()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )

        // A second AppKit close emits no notification for an already-closed
        // NSWindow. The socket/API path must still converge on final teardown.
        _ = app.closeMainWindow(windowId: windowId)

        #expect(app.tabManagerFor(windowId: windowId) == nil)
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(!app.listMainWindowSummaries().contains { $0.windowId == windowId })
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: terminalPanel.id) == nil)
    }
}
