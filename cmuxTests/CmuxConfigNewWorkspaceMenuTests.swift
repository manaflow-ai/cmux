import AppKit
import Foundation
import enum CmuxWorkspaces.CmuxSurfaceTabBarBuiltInAction
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Plus-button menu resolution: auto-append of workspace actions, opt-in/out,
/// validation of workspaceCommand references, and de-duplication.
struct CmuxConfigNewWorkspaceMenuTests {
    @MainActor
    private final class TestAppMenuHost: AppMenuHosting {}

    // MARK: - Store: plus-button menu auto-append

    @MainActor
    private func loadStore(globalJSON: String) throws -> (store: CmuxConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-workspace-action-tests-\(UUID().uuidString)",
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
        return (store, root)
    }

    @MainActor
    private func menuActionIDs(_ store: CmuxConfigStore) -> [String] {
        store.newWorkspaceContextMenuItems.compactMap { item in
            if case .action(let menuAction) = item {
                return menuAction.action.id
            }
            return nil
        }
    }

    @MainActor
    private func plannedContextMenuActions(_ store: CmuxConfigStore) -> [CmuxResolvedConfigAction] {
        let inputs: [NewWorkspaceContextMenuItemInput] = store.newWorkspaceContextMenuItems.enumerated().map { index, item in
            switch item {
            case .separator:
                return .separator
            case .action(let menuAction):
                return .action(
                    title: menuAction.title,
                    tooltip: menuAction.tooltip,
                    iconSourcePath: menuAction.iconSourcePath,
                    actionIndex: index
                )
            }
        }
        let host = TestAppMenuHost()
        let coordinator = AppMenuCoordinator(host: host)
        let plan = coordinator.planNewWorkspaceContextMenu(items: inputs) ?? []
        return plan.compactMap { planItem in
            guard case .action(_, _, _, let actionIndex) = planItem,
                  case .action(let item) = store.newWorkspaceContextMenuItems[actionIndex] else {
                return nil
            }
            return item.action
        }
    }

    @MainActor
    private func plannedContextMenuActionIDs(_ store: CmuxConfigStore) -> [String] {
        plannedContextMenuActions(store).map(\.id)
    }

    @MainActor
    @Test func storeAutoAppendsWorkspaceActionsToPlusButtonMenu() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(ids.contains("dev-setup"), "workspace action should be auto-offered, got \(ids)")
        // Defaults stay first.
        #expect(ids.first == CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)
        // Auto block is separated from the configured items.
        if case .separator? = store.newWorkspaceContextMenuItems.dropLast().last {} else {
            Issue.record("Expected separator before auto-appended actions")
        }
    }

    @MainActor
    @Test func contextMenuPlanIncludesBuiltInAgentChatAction() throws {
        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!store.newWorkspaceContextMenuIsConfigured)
        #expect(store.newWorkspaceMenuSectionOrder == .cloudFirst)
        let actions = plannedContextMenuActions(store)
        let ids = actions.map(\.id)
        let cloudOpenIndex = try #require(ids.firstIndex { $0 == CmuxSurfaceTabBarBuiltInAction.cloudVM.configID })
        let newWorkspaceIndex = try #require(ids.firstIndex { $0 == CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID })
        let agentChatIndex = try #require(ids.firstIndex { $0 == CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID })
        let agentChatAction = actions[agentChatIndex]

        #expect(cloudOpenIndex < newWorkspaceIndex)
        #expect(newWorkspaceIndex < agentChatIndex)
        #expect(agentChatAction.action == .builtIn(.newAgentChat))
        #expect(agentChatAction.title == String(localized: "command.newAgentChat.title", defaultValue: "New agent chat"))
    }

    @MainActor
    @Test func contextMenuHidesBuiltInAgentChatWhenActionOptsOut() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "cmux.newAgentChat": {
              "type": "builtin",
              "builtin": "cmux.newAgentChat",
              "newWorkspaceMenu": false
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = plannedContextMenuActionIDs(store)
        #expect(!ids.contains(CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID))
    }

    @MainActor
    @Test func customContextMenuWithoutAgentChatStillAppendsBuiltInAgentChat() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "ui": {
            "newWorkspace": {
              "contextMenu": ["cmux.newWorkspace"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.newWorkspaceContextMenuIsConfigured)
        let ids = plannedContextMenuActionIDs(store)
        let newWorkspaceIndex = try #require(ids.firstIndex(of: CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID))
        let agentChatIndex = try #require(ids.firstIndex(of: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID))
        #expect(newWorkspaceIndex < agentChatIndex)
        #expect(ids.filter { $0 == CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID }.count == 1)
    }

    @MainActor
    @Test func customContextMenuCanExplicitlyIncludeBuiltInAgentChat() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "ui": {
            "newWorkspace": {
              "contextMenu": ["cmux.newAgentChat"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.newWorkspaceContextMenuIsConfigured)
        let ids = plannedContextMenuActionIDs(store)
        #expect(ids.filter { $0 == CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID }.count == 1)
    }

    @MainActor
    @Test func storeRespectsNewWorkspaceMenuOptOut() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "hidden": {
              "type": "workspace",
              "title": "Hidden",
              "newWorkspaceMenu": false,
              "workspace": { "name": "Hidden" }
            },
            "shown-command": {
              "type": "command",
              "title": "Shown",
              "command": "make",
              "newWorkspaceMenu": true
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(!ids.contains("hidden"))
        #expect(ids.contains("shown-command"))
    }

    @MainActor
    @Test func storeValidatesAutoAppendedWorkspaceCommandActions() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dead-ref": {
              "type": "workspaceCommand",
              "commandName": "No Such Command",
              "newWorkspaceMenu": true
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!menuActionIDs(store).contains("dead-ref"))
        #expect(
            store.configurationIssues.contains { $0.commandName == "No Such Command" },
            "a dead workspaceCommand reference must surface as a config issue"
        )
    }

    @MainActor
    @Test func storeDoesNotDuplicateExplicitMenuEntries() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": ["dev-setup"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(ids.filter { $0 == "dev-setup" }.count == 1)
    }
}
