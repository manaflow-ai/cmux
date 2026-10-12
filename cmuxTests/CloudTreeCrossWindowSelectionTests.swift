import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Cloud tree row in one window can resolve to a local workspace that
/// another window owns, because every window reads the app-wide catalog (#19967).
@MainActor
@Suite(.serialized)
struct CloudTreeCrossWindowSelectionTests {
    @Test func selectingAWorkspaceOwnedByTheFirstWindowSelectsItThere() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        let firstWindowId = app.registerMainWindowContextForTesting(tabManager: firstManager)
        let secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
        }

        let cloudWorkspace = firstManager.addWorkspace(select: false, eagerLoadTerminal: false)
        let firstSelectionBefore = firstManager.selectedTabId
        let secondSelectionBefore = secondManager.selectedTabId
        #expect(firstSelectionBefore != cloudWorkspace.id)

        let didSelect = app.selectCloudTreeLocalWorkspace(cloudWorkspace.id, from: secondManager)

        #expect(didSelect)
        #expect(firstManager.selectedTabId == cloudWorkspace.id)
        #expect(secondManager.selectedTabId == secondSelectionBefore)
        #expect(secondManager.workspacesById[cloudWorkspace.id] == nil)
    }

    @Test func selectingAWorkspaceInTheSameWindowStillSelectsIt() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)

        #expect(app.selectCloudTreeLocalWorkspace(workspace.id, from: manager))
        #expect(manager.selectedTabId == workspace.id)
    }

    @Test func selectingAnUnknownWorkspaceChangesNothing() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let selectionBefore = manager.selectedTabId

        #expect(!app.selectCloudTreeLocalWorkspace(UUID(), from: manager))
        #expect(manager.selectedTabId == selectionBefore)
    }
}
