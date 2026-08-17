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

        let knownIds = Set(manager.tabs.map(\.id))
        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        let created = try createdWorkspace(in: manager, knownIds: knownIds)
        waitUntil { created.customTitle != nil }

        #expect(
            created.customTitle == "EmptyAreaLayout",
            Comment(
                rawValue: "Empty-area double-click must honor ui.newWorkspace.action, got title "
                    + "\(created.customTitle ?? "<none>")"
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
        let knownIds = Set(manager.tabs.map(\.id))

        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        let created = try createdWorkspace(in: manager, knownIds: knownIds)

        #expect(
            manager.tabs.last?.id == created.id,
            "A plain empty-area workspace still lands after the last row"
        )
        #expect(created.id == manager.selectedTabId, "The appended workspace is the selected one")
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
        let knownIds = Set(manager.tabs.map(\.id))

        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        let created = try createdWorkspace(in: manager, knownIds: knownIds)

        #expect(
            created.groupId == nil,
            "Empty-area double-click lands outside the selected workspace's group"
        )
        #expect(manager.tabs.last?.id == created.id, "The new workspace lands after the last row")
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
        let retired = waitUntil {
            !appDelegate.mainWindowContexts.values.contains { $0.windowId == windowId }
                && (appDelegate.windowForMainWindowId(windowId) == nil || !window.isVisible)
        }
        #expect(retired, "Timed out waiting for the test main window to retire")
    }

    /// The one workspace the gesture created, identified by id against the
    /// pre-gesture snapshot: position and title alone could match a
    /// pre-existing workspace and hide a creation that never happened.
    private func createdWorkspace(
        in manager: TabManager,
        knownIds: Set<UUID>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Workspace {
        var newWorkspaces: [Workspace] = []
        let appeared = waitUntil {
            newWorkspaces = manager.tabs.filter { !knownIds.contains($0.id) }
            return newWorkspaces.count == 1
        }
        #expect(
            appeared,
            Comment(
                rawValue: "Timed out waiting for exactly one new workspace, got "
                    + "\(newWorkspaces.count)"
            ),
            sourceLocation: sourceLocation
        )
        return try #require(newWorkspaces.first, sourceLocation: sourceLocation)
    }

    /// Polls the run loop until `condition` holds, so assertions wait on the
    /// state they care about instead of a fixed delay that a slow runner can
    /// outlast. Returns false when the deadline passes first, letting callers
    /// fail on the timeout itself rather than on whatever stale state remains.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return true
    }
}
