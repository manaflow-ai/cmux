import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// More windows than the limit that used to drop them silently (#15689).
private let windowCountPastOldLimit = 14

@MainActor
@Suite("Session window limit", .serialized)
struct SessionWindowLimitTests {
    @Test("A save keeps every open window past the twelfth")
    func saveKeepsEveryOpenWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        var registered: [(id: UUID, window: NSWindow, manager: TabManager)] = []
        defer {
            for entry in registered {
                app.forgetRecoverableMainWindowRoute(windowId: entry.id)
                entry.window.orderOut(nil)
            }
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        for _ in 0..<windowCountPastOldLimit {
            let windowId = UUID()
            let window = makeMainWindow(id: windowId)
            let manager = TabManager()
            registered.append((windowId, window, manager))
            app.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
        }

        let snapshot = try #require(app.sessionSnapshotForTesting())
        #expect(
            Set(snapshot.windows.compactMap(\.windowId)) == Set(registered.map(\.id))
        )
    }

    @Test("Routes whose window is gone stay bounded when few windows are open")
    func orphanedRoutesStayBounded() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        var orphaned: [(id: UUID, window: NSWindow, manager: TabManager)] = []
        defer {
            for entry in orphaned {
                app.forgetRecoverableMainWindowRoute(windowId: entry.id)
                entry.window.orderOut(nil)
            }
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        for _ in 0..<windowCountPastOldLimit {
            let windowId = UUID()
            let window = makeMainWindow(id: windowId)
            let manager = TabManager()
            orphaned.append((windowId, window, manager))
            app.registerMainWindow(
                window,
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: FileExplorerState()
            )
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.dismissMainWindowFromWindowChrome(window)
            window.orderOut(nil)
        }

        let snapshot = try #require(app.sessionSnapshotForTesting())
        #expect(snapshot.windows.count == SessionPersistencePolicy.maxOrphanedWindowRoutes)
    }

    @Test("A restore opens every saved window past the twelfth")
    func restoreOpensEverySavedWindow() {
        _ = NSApplication.shared
        let app = AppDelegate.shared ?? AppDelegate()
        let windowIds = (0..<windowCountPastOldLimit).map { _ in UUID() }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_000,
            windows: windowIds.map { windowId in
                SessionWindowSnapshot(
                    windowId: windowId,
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: false),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                )
            }
        )
        defer {
#if DEBUG
            let previousConfirmationHandler = app.debugCloseMainWindowConfirmationHandler
            app.debugCloseMainWindowConfirmationHandler = { _ in true }
            defer { app.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler }
#endif
            for windowId in windowIds {
                guard let window = app.mainWindow(for: windowId) else { continue }
                window.animationBehavior = .none
                window.orderOut(nil)
                window.close()
            }
        }

        #expect(app.restorePreviousSessionSnapshot(snapshot, shouldActivate: false))
        #expect(windowIds.filter { app.mainWindow(for: $0) == nil }.isEmpty)
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }
}
