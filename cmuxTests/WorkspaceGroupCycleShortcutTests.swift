import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite("Workspace group cycle shortcuts", .serialized)
struct WorkspaceGroupCycleShortcutTests {
    @Test func actionsAreVisibleAndUnboundByDefault() throws {
        let actions: [KeyboardShortcutSettings.Action] = [
            .nextSidebarTabInGroup,
            .prevSidebarTabInGroup,
        ]

        for action in actions {
            let sharedAction = try #require(ShortcutAction(rawValue: action.rawValue))
            #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
            #expect(action.defaultShortcut == .unbound)
            #expect(sharedAction.defaultShortcut == nil)
            #expect(sharedAction.displayName == action.label)
        }
    }

    @Test func configuredActionsCycleMembersWithoutSelectingAnchor() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-workspace-group-cycle"
        )
        KeyboardShortcutSettings.resetAll()
        try """
        {
          "shortcuts": {
            "bindings": {
              "nextSidebarTabInGroup": "ctrl+opt+cmd+j",
              "prevSidebarTabInGroup": "ctrl+opt+cmd+k"
            }
          }
        }
        """.write(
            to: KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing(),
            atomically: true,
            encoding: .utf8
        )
        KeyboardShortcutSettings.settingsFileStore.reload()
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
        let firstMember = try #require(manager.addTab(select: false))
        let secondMember = try #require(manager.addTab(select: false))
        let groupId = try #require(manager.createWorkspaceGroup(
            name: "Grouped",
            childWorkspaceIds: [firstMember.id, secondMember.id]
        ))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        let nextEvent = try #require(keyEvent(
            key: "j",
            keyCode: 38,
            windowNumber: window.windowNumber
        ))
        let previousEvent = try #require(keyEvent(
            key: "k",
            keyCode: 40,
            windowNumber: window.windowNumber
        ))

        manager.selectWorkspace(firstMember)
        #expect(appDelegate.debugHandleCustomShortcut(event: nextEvent))
        #expect(manager.selectedTabId == secondMember.id)
        #expect(appDelegate.debugHandleCustomShortcut(event: nextEvent))
        #expect(manager.selectedTabId == firstMember.id)
        #expect(appDelegate.debugHandleCustomShortcut(event: previousEvent))
        #expect(manager.selectedTabId == secondMember.id)

        manager.selectWorkspace(anchor)
        #expect(appDelegate.debugHandleCustomShortcut(event: nextEvent))
        #expect(manager.selectedTabId == firstMember.id)
        manager.selectWorkspace(anchor)
        #expect(appDelegate.debugHandleCustomShortcut(event: previousEvent))
        #expect(manager.selectedTabId == secondMember.id)

        manager.selectWorkspace(ungroupedWorkspace)
        #expect(appDelegate.debugHandleCustomShortcut(event: nextEvent))
        #expect(manager.selectedTabId == group.anchorWorkspaceId)
    }

    @Test(arguments: [true, false], [false, true])
    func groupingShortcutCreatesEmptyGroupWhenSidebarSelectionIsEmpty(
        hasFocusedWorkspace: Bool,
        useCustomBinding: Bool
    ) throws {
        try withGroupingShortcutWindow { appDelegate, window, manager in
            let originalWorkspace = try #require(manager.selectedWorkspace)
            if !hasFocusedWorkspace { manager.selectedTabId = nil }
            let selectedWorkspaceId = manager.selectedTabId
            manager.setSidebarSelectedWorkspaceIds([])
            #expect(manager.sidebarSelectedWorkspaceIds.isEmpty)
            let responder = window.firstResponder
            var shortcut = KeyboardShortcutSettings.Action.groupSelectedWorkspaces.defaultShortcut
            if useCustomBinding {
                shortcut = .init(key: "g", command: true, shift: true, option: true, control: true)
            }
            KeyboardShortcutSettings.setShortcut(shortcut, for: .groupSelectedWorkspaces)
            let event = try #require(groupingKeyEvent(window: window, modifiers: shortcut.modifierFlags))

            #expect(appDelegate.debugHandleCustomShortcut(event: event))

            let group = try #require(manager.workspaceGroups.last)
            #expect(manager.workspaceGroups.count == 1)
            #expect(group.anchorWorkspaceProvenance == .generated)
            #expect(manager.tabs.filter { $0.groupId == group.id }.map(\.id) == [group.anchorWorkspaceId])
            #expect(manager.selectedTabId == selectedWorkspaceId)
            #expect(window.firstResponder === responder)
            #expect(originalWorkspace.groupId == nil)
            #expect(manager.sidebarSelectedWorkspaceIds.isEmpty)
            // A generated anchor renders exclusively as a header, so an
            // anchor-only group is visibly empty and keeps a live identity.
            let rows = SidebarWorkspaceRenderItem.renderItems(
                tabs: manager.tabs,
                groupsById: [group.id: group]
            )
            #expect(rows.map(\.id) == [.group(group.id), .workspace(originalWorkspace.id)])
            #expect(rows.first?.rowWorkspaceId == group.anchorWorkspaceId)
        }
    }

    @Test func groupingShortcutPreservesOrderedMultiSelectionAndAnchorFocus() throws {
        try withGroupingShortcutWindow { appDelegate, window, manager in
            let first = try #require(manager.selectedWorkspace)
            _ = try #require(manager.addTab(select: false))
            let last = try #require(manager.addTab(select: false))
            let selectedIds: Set<UUID> = [last.id, first.id]
            let originalOrder = manager.tabs.map(\.id)
            let expectedChildren = originalOrder.filter { selectedIds.contains($0) }
            let expectedRemaining = originalOrder.filter { !selectedIds.contains($0) }
            manager.setSidebarSelectedWorkspaceIds(selectedIds)
            let event = try #require(groupingKeyEvent(window: window))

            #expect(appDelegate.debugHandleCustomShortcut(event: event))

            let group = try #require(manager.workspaceGroups.last)
            #expect(manager.tabs.map(\.id) == [group.anchorWorkspaceId] + expectedChildren + expectedRemaining)
            #expect(manager.tabs.filter { selectedIds.contains($0.id) }.allSatisfy { $0.groupId == group.id })
            #expect(manager.selectedTabId == group.anchorWorkspaceId)
            #expect(manager.sidebarSelectedWorkspaceIds == [group.anchorWorkspaceId])
            #expect(!appDelegate.handleGroupSelectedWorkspacesShortcut(preferredWindow: window))
            #expect(manager.workspaceGroups.count == 1)
        }
    }

    @Test func groupingShortcutDoesNotTurnAnIneligibleSelectionIntoAnEmptyGroup() throws {
        try withGroupingShortcutWindow { appDelegate, window, manager in
            let originalWorkspace = try #require(manager.selectedWorkspace)
            #expect(appDelegate.createEmptyWorkspaceGroup(tabManager: manager, preferredWindow: window))
            let group = try #require(manager.workspaceGroups.last)
            let originalOrder = manager.tabs.map(\.id)
            let selection: Set<UUID> = [group.anchorWorkspaceId, originalWorkspace.id]
            manager.setSidebarSelectedWorkspaceIds(selection)

            #expect(!appDelegate.handleGroupSelectedWorkspacesShortcut(preferredWindow: window))

            #expect(manager.workspaceGroups.count == 1)
            #expect(manager.tabs.map(\.id) == originalOrder)
            #expect(manager.sidebarSelectedWorkspaceIds == selection)
            #expect(manager.selectedTabId == group.anchorWorkspaceId)
        }
    }

    @Test func emptyGroupingShortcutUsesPreferredWindowRatherThanAppFallback() throws {
        try withGroupingShortcutWindow { appDelegate, window, manager in
            let otherWindowId = appDelegate.createMainWindow()
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: otherWindowId) }
            let otherManager = try #require(appDelegate.tabManagerFor(windowId: otherWindowId))
            let otherSelection = otherManager.selectedTabId
            let selectedWorkspaceId = manager.selectedTabId
            manager.setSidebarSelectedWorkspaceIds([])
            #expect(appDelegate.tabManager === otherManager)

            #expect(appDelegate.handleGroupSelectedWorkspacesShortcut(preferredWindow: window))

            #expect(manager.workspaceGroups.count == 1)
            #expect(manager.selectedTabId == selectedWorkspaceId)
            #expect(otherManager.workspaceGroups.isEmpty)
            #expect(otherManager.selectedTabId == otherSelection)
        }
    }

    private func withGroupingShortcutWindow(
        _ body: (AppDelegate, NSWindow, TabManager) throws -> Void
    ) throws {
        let appDelegate = try #require(AppDelegate.shared)
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-empty-group-shortcut"
        )
        KeyboardShortcutSettings.resetAll()
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
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try body(appDelegate, window, context.tabManager)
    }

    private func groupingKeyEvent(
        window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [.command, .shift]
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "g",
            charactersIgnoringModifiers: "g",
            isARepeat: false,
            keyCode: 5
        )
    }

    private func keyEvent(
        key: String,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option, .command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
#endif
