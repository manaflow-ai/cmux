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
