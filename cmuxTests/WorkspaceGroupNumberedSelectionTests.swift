import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite("Workspace group numbered selection", .serialized)
struct WorkspaceGroupNumberedSelectionTests {
    @Test func controlTwoSkipsAnchorRepresentedByGroupHeader() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-workspace-group-numbered-selection"
        )
        KeyboardShortcutSettings.resetAll()
        KeyboardShortcutSettings.clearShortcut(for: .selectSurfaceByNumber)
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            for: .selectWorkspaceByNumber
        )
        appDelegate.debugResetShortcutRoutingStateForTesting()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }

        let windowId = appDelegate.createMainWindow()
        defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let window = try #require(context.window)
        let manager = context.tabManager
        let ungroupedWorkspace = try #require(manager.selectedWorkspace)
        let memberWorkspace = try #require(manager.addTab(select: false))
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Grouped",
            childWorkspaceIds: [memberWorkspace.id]
        ))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let renderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: [groupId: group]
        )
        let visibleWorkspaceRowIds = renderItems.compactMap { item -> UUID? in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }

        #expect(visibleWorkspaceRowIds == [ungroupedWorkspace.id, memberWorkspace.id])
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        manager.selectWorkspace(ungroupedWorkspace)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "2",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19
        ))

        #expect(appDelegate.routableNumberedConfiguredShortcutDigit(
            event: event,
            action: .selectWorkspaceByNumber
        ) == 2)
        #expect(appDelegate.preferredMainWindowContextForShortcutRouting(event: event)?.tabManager === manager)
        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(manager.selectedTabId == memberWorkspace.id)
        #expect(manager.selectedTabId != group.anchorWorkspaceId)
    }
}
#endif
