import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Double-clicking the sidebar's empty area must create a workspace the same
/// way the `+` button and File → New Workspace do: through the shared
/// new-workspace action path, so a configured `ui.newWorkspace.action` default
/// layout applies. Without a configured default it still appends a plain
/// workspace after the last row, outside any workspace group.
/// https://github.com/manaflow-ai/cmux/issues/10043
@MainActor
@Suite("Sidebar empty-area new workspace action", .serialized)
struct SidebarEmptyAreaNewWorkspaceActionTests {
    @Test func emptyAreaDoubleClickAppliesConfiguredNewWorkspaceLayout() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let fixture = try ConfigFixture(globalJSON: """
        {
          "actions": {
            "empty-area-layout": {
              "type": "workspace",
              "title": "Empty Area Layout",
              "workspace": { "name": "EmptyAreaLayout" }
            }
          },
          "ui": { "newWorkspace": { "action": "empty-area-layout" } }
        }
        """)
        defer { fixture.cleanUp() }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let context = try #require(
            appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.cmuxConfigStore = fixture.store

        let initialCount = manager.tabs.count
        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        waitUntil { manager.tabs.contains { $0.customTitle == "EmptyAreaLayout" } }

        #expect(manager.tabs.count == initialCount + 1, "Expected exactly one new workspace")
        #expect(
            manager.tabs.contains { $0.customTitle == "EmptyAreaLayout" },
            Comment(
                rawValue: "Empty-area double-click must honor ui.newWorkspace.action, got titles "
                    + "\(manager.tabs.map { $0.customTitle ?? "<none>" })"
            )
        )
    }

    @Test func emptyAreaDoubleClickWithoutConfiguredActionAppendsPlainWorkspace() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let fixture = try ConfigFixture(globalJSON: "{}")
        defer { fixture.cleanUp() }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let context = try #require(
            appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.cmuxConfigStore = fixture.store

        // Select the first workspace so "after the selected one" and "at the end"
        // are distinguishable positions.
        let first = try #require(manager.tabs.first)
        manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)
        let countBeforeDoubleClick = manager.tabs.count

        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        waitUntil { manager.tabs.count == countBeforeDoubleClick + 1 }

        #expect(manager.tabs.count == countBeforeDoubleClick + 1)
        #expect(
            manager.tabs.last?.id != first.id,
            "A plain empty-area workspace still lands after the last row"
        )
        #expect(
            manager.tabs.last?.id == manager.selectedTabId,
            "The appended workspace is the selected one"
        )
    }

    /// The empty area is the region below every row, so the gesture points
    /// outside all groups: an end-of-list workspace must not be filed into the
    /// selected workspace's group the way the `+` button's does.
    @Test func emptyAreaDoubleClickWithGroupedSelectionAppendsOutsideTheGroup() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let fixture = try ConfigFixture(globalJSON: "{}")
        defer { fixture.cleanUp() }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let context = try #require(
            appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.cmuxConfigStore = fixture.store

        let initialWorkspace = try #require(manager.tabs.first)
        let groupId = try #require(
            manager.createWorkspaceGroup(name: "Empty Area Group", childWorkspaceIds: [initialWorkspace.id])
        )
        let selected = try #require(manager.selectedWorkspace)
        #expect(selected.groupId == groupId, "Group creation should leave the anchor selected")
        let countBeforeDoubleClick = manager.tabs.count

        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        waitUntil { manager.tabs.count == countBeforeDoubleClick + 1 }

        #expect(manager.tabs.count == countBeforeDoubleClick + 1)
        let created = try #require(manager.tabs.last)
        #expect(
            created.groupId == nil,
            "Empty-area double-click lands outside the selected workspace's group"
        )
        #expect(created.id == manager.selectedTabId, "The appended workspace is the selected one")
    }

    // MARK: - Helpers

    @MainActor
    private struct ConfigFixture {
        let store: CmuxConfigStore
        private let root: URL

        init(globalJSON: String) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-sidebar-empty-area-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let globalConfigURL = root.appendingPathComponent("cmux.json")
            try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
            let store = CmuxConfigStore(
                globalConfigPath: globalConfigURL.path,
                localConfigPath: nil,
                startFileWatchers: false
            )
            store.loadAll()
            self.root = root
            self.store = store
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Retiring the window's `MainWindowContext` is the authoritative end of
    /// the close, so wait for that rather than for the window merely going
    /// invisible: a half-closed window would otherwise leak its workspaces into
    /// the next test.
    private func closeWindow(withId windowId: UUID) {
        guard let appDelegate = AppDelegate.shared,
              let window = appDelegate.windowForMainWindowId(windowId) else { return }
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        waitUntil {
            !appDelegate.mainWindowContexts.values.contains { $0.windowId == windowId }
                && (appDelegate.windowForMainWindowId(windowId) == nil || !window.isVisible)
        }
    }

    /// Polls the run loop until `condition` holds, so assertions wait on the
    /// state they care about instead of a fixed delay that a slow runner can
    /// outlast.
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
