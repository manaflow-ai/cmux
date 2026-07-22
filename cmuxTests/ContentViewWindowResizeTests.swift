import AppKit
import CmuxUpdater
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("content view window resize", .serialized)
struct ContentViewWindowResizeTests {
    @Test @MainActor
    func invalidatesActivePaneBorderGeometryAfterWindowResize() async throws {
        _ = NSApplication.shared

        let suiteName = "ContentViewWindowResizeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let notificationStore = TerminalNotificationStore.shared
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await Self.drainMainRunLoop(for: window)

        let controller = try #require(
            WindowTmuxWorkspacePaneOverlayController.controller(
                for: window,
                createIfNeeded: true
            )
        )
        controller.update(state: TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: CGRect(x: 8, y: 12, width: 320, height: 180),
            activePaneBorderColorHex: "#3A7F77",
            flashToken: 0,
            flashReason: nil
        ))
        #expect(controller.hasRenderedState)

        await Self.drainMainRunLoop(for: window, iterations: 3)
        #expect(
            controller.hasRenderedState,
            "Seeded active-pane border state must remain stable before the resize."
        )

        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        await Self.drainMainRunLoop(for: window)

        #expect(
            !controller.hasRenderedState,
            "A window resize must invalidate stale active-pane border geometry."
        )
    }

    @MainActor
    private static func turnMainRunLoopOnce(layingOut window: NSWindow) {
        autoreleasepool {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }
}
