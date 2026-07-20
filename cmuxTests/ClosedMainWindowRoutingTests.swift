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
}

@MainActor
@Suite("Window zombie regressions", .serialized)
struct WindowZombieRegressionTests {
    @Test("SwiftUI window state does not own its native window")
    func swiftUIWindowStateDoesNotOwnItsNativeWindow() {
        weak var releasedWindow: NSWindow?
        var reference: WeakWindowReference?

        autoreleasepool {
            var window: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            releasedWindow = window
            reference = WeakWindowReference(window)
            window = nil
        }

        #expect(reference?.window == nil)
        #expect(releasedWindow == nil)
    }

    @Test("Closed Settings window is fully retired")
    func closedSettingsWindowIsFullyRetired() async {
        _ = NSApplication.shared
        closeSettingsWindows()
        defer { closeSettingsWindows() }

        var closingWindowNumber: Int?
        weak var releasedWindow: NSWindow?
        autoreleasepool {
            let presenter = SettingsWindowPresenter()
            presenter.show()
            var closingWindow = settingsWindow()
            #expect(closingWindow != nil)
            guard closingWindow != nil else { return }
            closingWindowNumber = closingWindow?.windowNumber
            releasedWindow = closingWindow
            closingWindow?.close()
            closingWindow = nil
        }
        await settleWindowLifecycle()

        #expect(releasedWindow == nil)
        #expect(closingWindowNumber != nil)
        if let closingWindowNumber {
            #expect(!isWindowServerWindowAlive(closingWindowNumber))
        }
    }

    @Test("Closed detached main window is fully retired")
    func closedDetachedMainWindowIsFullyRetired() async {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        let previousConfirmationHandler = app.debugCloseMainWindowConfirmationHandler
        app.debugCloseMainWindowConfirmationHandler = { _ in true }
        var survivorWindowId: UUID?
        weak var releasedWindow: NSWindow?
        defer {
            if let leakedWindow = releasedWindow {
                leakedWindow.windowController?.window = nil
                leakedWindow.delegate = nil
                leakedWindow.contentViewController = nil
                leakedWindow.contentView = nil
                leakedWindow.orderOut(nil)
            }
            if let survivorWindowId,
               let survivor = app.windowForMainWindowId(survivorWindowId) {
                survivor.close()
            }
            app.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        survivorWindowId = app.createMainWindow(shouldActivate: false)
        let closingWindowId = app.createMainWindow(shouldActivate: false)
        var closingWindow = app.windowForMainWindowId(closingWindowId)
        #expect(closingWindow != nil)
        guard closingWindow != nil else { return }
        let closingWindowNumber = closingWindow?.windowNumber
        releasedWindow = closingWindow

        autoreleasepool {
            closingWindow?.close()
            closingWindow = nil
        }
        await settleWindowLifecycle()

        #expect(releasedWindow?.windowController == nil)
        #expect(releasedWindow?.contentViewController == nil)
        #expect(releasedWindow?.contentView == nil)
        #expect(closingWindowNumber != nil)
        if let closingWindowNumber {
            #expect(!isWindowServerWindowAlive(closingWindowNumber))
        }
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.settings" && $0.isVisible
        }
    }

    private func closeSettingsWindows() {
        for window in NSApp.windows where window.identifier?.rawValue == "cmux.settings" {
            window.orderOut(nil)
            window.identifier = nil
            window.close()
        }
    }

    private func settleWindowLifecycle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func isWindowServerWindowAlive(_ windowNumber: Int) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionIncludingWindow,
            CGWindowID(windowNumber)
        ) as? [[CFString: Any]] else {
            return false
        }
        return !windows.isEmpty
    }
}
