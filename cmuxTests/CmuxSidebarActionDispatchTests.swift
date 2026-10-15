import AppKit
import CmuxSwiftRender
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CmuxSidebarActionDispatchTests {
    @Test func logActionReachesWorkspaceLogCommand() async throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        window.isReleasedWhenClosed = false
        let manager = TabManager(autoWelcomeIfNeeded: false)

        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        AppDelegate.shared = app
        TerminalController.shared.setActiveTabManager(manager)
        let workspace = try #require(manager.selectedWorkspace)
        let message = "row \"tapped\"\nnext"

        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            window.orderOut(nil)
            AppDelegate.shared = previousAppDelegate
        }

        makeCmuxSidebarActionDispatch().run(ButtonAction(commands: [.log(message)]))

        for _ in 0..<20 {
            if workspace.logEntries.last?.message == message { break }
            await Task.yield()
        }

        let entry = try #require(workspace.logEntries.last)
        #expect(entry.message == message)
        #expect(entry.level == .info)
        #expect(entry.source == "custom-sidebar")
    }
}
