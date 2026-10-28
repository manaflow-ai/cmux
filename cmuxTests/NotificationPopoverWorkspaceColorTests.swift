import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The notifications popover shows each row's workspace color on the row's leading rail.
@MainActor
@Suite("Notification popover workspace colors", .serialized)
struct NotificationPopoverWorkspaceColorTests {
    /// The popover builds one id -> color index per render. It holds every requested workspace
    /// that has a color, across windows, and leaves out the ones without a color.
    @Test func workspaceColorIndexCoversEveryWindow() {
        let first = TabManager(autoWelcomeIfNeeded: false)
        let second = TabManager(autoWelcomeIfNeeded: false)
        let red = first.addWorkspace(title: "Red", autoWelcomeIfNeeded: false)
        let plain = first.addWorkspace(title: "Plain", autoWelcomeIfNeeded: false)
        let blue = second.addWorkspace(title: "Blue", autoWelcomeIfNeeded: false)
        let unrequested = second.addWorkspace(title: "Unrequested", autoWelcomeIfNeeded: false)
        first.setTabColor(tabId: red.id, color: "#C0392B")
        second.setTabColor(tabId: blue.id, color: "#2980B9")
        second.setTabColor(tabId: unrequested.id, color: "#27AE60")

        let appDelegate = AppDelegate()
        let firstWindow = appDelegate.registerMainWindowContextForTesting(tabManager: first)
        let secondWindow = appDelegate.registerMainWindowContextForTesting(tabManager: second)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstWindow)
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondWindow)
        }

        let colors = appDelegate.workspaceColorHexByTabId(for: [red.id, plain.id, blue.id, UUID()])
        #expect(colors.count == 2)
        #expect(colors[red.id] == red.customColor)
        #expect(colors[blue.id] == blue.customColor)
    }

    /// An open popover recolors a row when its workspace's color changes, so a change has to be
    /// announced. Setting the same color again announces nothing.
    @Test func changingAWorkspaceColorIsAnnounced() {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(title: "Colored", autoWelcomeIfNeeded: false)
        let announced = AnnouncedWorkspaceIds()
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("cmux.workspaceColorDidChange"), object: nil, queue: nil
        ) { notification in
            if let id = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID { announced.ids.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")
        manager.setTabColor(tabId: workspace.id, color: "#C0392B")
        manager.setTabColor(tabId: workspace.id, color: nil)

        #expect(announced.ids == [workspace.id, workspace.id])
    }
}

/// Collects the workspace ids a notification observer saw. Unchecked: the observer runs
/// synchronously on the posting (main) thread, the same thread the test reads it from.
private final class AnnouncedWorkspaceIds: @unchecked Sendable {
    var ids: [UUID] = []
}
