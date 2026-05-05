import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class DockFocusReactivationTests: XCTestCase {
    func testApplicationDidBecomeActiveRestoresFocusedDockSurface() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer {
            closeWindow(withId: windowId)
        }

        guard let window = window(withId: windowId),
              let coordinator = appDelegate.keyboardFocusCoordinator(for: window) else {
            XCTFail("Expected test window and focus coordinator")
            return
        }

        let dockHost = DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let surfaceId = UUID()
        var restoredSurfaceId: UUID?
        dockHost.focusSurface = { requestedSurfaceId in
            restoredSurfaceId = requestedSurfaceId
            return true
        }
        coordinator.registerDockHost(dockHost)
        coordinator.noteDockTerminalInteraction(surfaceId: surfaceId)

        appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertEqual(restoredSurfaceId, surfaceId)
    }

    func testDockHostResponderDoesNotEraseFocusedDockSurface() {
        let fileExplorerState = FileExplorerState()
        let coordinator = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState
        )
        let dockHost = DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let surfaceId = UUID()
        var restoredSurfaceId: UUID?
        dockHost.focusSurface = { restoredSurfaceId = $0; return true }
        coordinator.registerDockHost(dockHost)
        coordinator.noteDockTerminalInteraction(surfaceId: surfaceId)

        coordinator.debugSyncAfterResponderChange(responder: dockHost)

        XCTAssertTrue(coordinator.restoreTargetAfterWindowBecameKey())
        XCTAssertEqual(restoredSurfaceId, surfaceId)
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
