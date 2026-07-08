import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Plus-button menu resolution: auto-append of workspace actions, opt-in/out,
/// validation of workspaceCommand references, and de-duplication.
struct CmuxConfigNewWorkspaceMenuTests {

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
