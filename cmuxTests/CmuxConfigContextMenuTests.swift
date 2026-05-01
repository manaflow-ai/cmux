import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxConfigContextMenuTests: XCTestCase {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    func testDecodeNewWorkspaceContextMenuPreservesOrder() throws {
        let json = """
        {
          "actions": {
            "start-codex": { "type": "command", "command": "codex" },
            "new-dev": { "type": "workspaceCommand", "commandName": "Dev Environment" }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                "start-codex",
                { "type": "separator" },
                {
                  "action": "new-dev",
                  "title": "Open Dev",
                  "icon": { "type": "symbol", "name": "hammer" }
                }
              ]
            }
          },
          "commands": [{
            "name": "Dev Environment",
            "workspace": { "name": "Dev" }
          }]
        }
        """
        let config = try decode(json)
        let menu = try XCTUnwrap(config.ui?.newWorkspace?.contextMenu)
        XCTAssertEqual(menu.count, 3)
        if case .action(let first) = menu[0] {
            XCTAssertEqual(first.action, "start-codex")
        } else {
            XCTFail("Expected first context-menu item to be an action.")
        }
        if case .separator = menu[1] {
        } else {
            XCTFail("Expected second context-menu item to be a separator.")
        }
        if case .action(let third) = menu[2] {
            XCTAssertEqual(third.action, "new-dev")
            XCTAssertEqual(third.title, "Open Dev")
            XCTAssertEqual(third.icon, .symbol("hammer"))
        } else {
            XCTFail("Expected third context-menu item to be an action.")
        }
    }

    @MainActor
    func testResolvedNewWorkspaceContextMenuSupportsBuiltInsAndActionOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "command": "codex",
              "title": "Start Codex",
              "icon": { "type": "symbol", "name": "sparkles" }
            },
            "open-dev": {
              "type": "workspaceCommand",
              "commandName": "Dev Environment",
              "title": "Dev"
            }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                "cmux.newTerminal",
                "start-codex",
                { "type": "separator" },
                { "action": "open-dev", "title": "Open Dev" }
              ]
            }
          },
          "commands": [{
            "name": "Dev Environment",
            "workspace": { "name": "Dev" }
          }]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let items = store.newWorkspaceContextMenuItems
        XCTAssertEqual(items.count, 4)
        if case .action(let first) = items[0] {
            XCTAssertEqual(first.action.id, CmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
        } else {
            XCTFail("Expected first context-menu item to be an action.")
        }
        if case .action(let second) = items[1] {
            XCTAssertEqual(second.action.id, "start-codex")
            XCTAssertEqual(second.title, "Start Codex")
            XCTAssertEqual(second.icon, .symbol("sparkles"))
        } else {
            XCTFail("Expected second context-menu item to be an action.")
        }
        if case .separator = items[2] {
        } else {
            XCTFail("Expected third context-menu item to be a separator.")
        }
        if case .action(let fourth) = items[3] {
            XCTAssertEqual(fourth.action.id, "open-dev")
            XCTAssertEqual(fourth.title, "Open Dev")
        } else {
            XCTFail("Expected fourth context-menu item to be an action.")
        }
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testResolvedNewWorkspaceContextMenuSurfacesMissingActionIssue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "actions": {
            "start-codex": { "type": "command", "command": "codex" }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                "missing-action",
                "start-codex"
              ]
            }
          }
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.newWorkspaceContextMenuItems.count, 1)
        if case .action(let item) = store.newWorkspaceContextMenuItems.first {
            XCTAssertEqual(item.action.id, "start-codex")
        } else {
            XCTFail("Expected missing context-menu action to be filtered.")
        }
        XCTAssertEqual(store.configurationIssues.first?.kind, .newWorkspaceActionNotFound)
        XCTAssertEqual(store.configurationIssues.first?.settingName, "ui.newWorkspace.contextMenu[0]")
        XCTAssertEqual(store.configurationIssues.first?.commandName, "missing-action")
        XCTAssertEqual(store.configurationIssues.first?.sourcePath, configURL.path)
    }

    @MainActor
    func testResolvedNewWorkspaceContextMenuFiltersInvalidWorkspaceCommandActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "actions": {
            "missing-dev": { "type": "workspaceCommand", "commandName": "Missing Dev" },
            "run-tests": { "type": "workspaceCommand", "commandName": "Run Tests" }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                "missing-dev",
                "run-tests",
                "cmux.newTerminal"
              ]
            }
          },
          "commands": [{
            "name": "Run Tests",
            "command": "npm test"
          }]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.newWorkspaceContextMenuItems.count, 1)
        if case .action(let item) = store.newWorkspaceContextMenuItems.first {
            XCTAssertEqual(item.action.id, CmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
        } else {
            XCTFail("Expected invalid workspace-command actions to be filtered.")
        }
        XCTAssertEqual(store.configurationIssues.map(\.kind), [
            .newWorkspaceCommandNotFound,
            .newWorkspaceCommandRequiresWorkspace,
        ])
        XCTAssertEqual(store.configurationIssues.map(\.settingName), [
            "ui.newWorkspace.contextMenu[0]",
            "ui.newWorkspace.contextMenu[1]",
        ])
        XCTAssertEqual(store.configurationIssues.map(\.commandName), [
            "Missing Dev",
            "Run Tests",
        ])
    }

    @MainActor
    func testResolvedNewWorkspaceContextMenuSanitizesLabels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "actions": {
            "run": {
              "type": "command",
              "title": "Run\\u202E",
              "command": "echo hi"
            }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                {
                  "action": "run",
                  "title": "\\u202EMenu",
                  "tooltip": "Tip\\u200B"
                }
              ]
            }
          }
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        guard case .action(let item) = store.newWorkspaceContextMenuItems.first else {
            return XCTFail("Expected resolved menu action.")
        }
        XCTAssertEqual(item.title, "Menu")
        XCTAssertEqual(item.tooltip, "Tip")
    }
}
