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

    @MainActor
    private func loadStore(localJSON: String? = nil, globalJSON: String? = nil) throws -> CmuxConfigStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let localConfigURL = root.appendingPathComponent("cmux.json")
        if let localJSON {
            try localJSON.write(to: localConfigURL, atomically: true, encoding: .utf8)
        }
        let globalConfigURL = root.appendingPathComponent("global.json")
        if let globalJSON {
            try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        }

        let store = CmuxConfigStore(
            globalConfigPath: globalJSON == nil
                ? root.appendingPathComponent("missing-global.json").path
                : globalConfigURL.path,
            localConfigPath: localJSON == nil ? nil : localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()
        return store
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

    func testDecodeMenuBarSupportsActionRefsInlineCommandsAndSubmenus() throws {
        let json = """
        {
          "actions": {
            "run-tests": { "type": "command", "command": "npm test" }
          },
          "ui": {
            "menuBar": {
              "menus": [
                {
                  "title": "Project",
                  "items": [
                    "run-tests",
                    { "type": "separator" },
                    {
                      "title": "Tools",
                      "items": [
                        {
                          "title": "Lint",
                          "command": "npm run lint",
                          "target": "currentTerminal"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let menu = try XCTUnwrap(config.ui?.menuBar?.menus.first)
        XCTAssertEqual(menu.title, "Project")
        XCTAssertEqual(menu.items.count, 3)
        if case .action(let first) = menu.items[0] {
            XCTAssertEqual(first.action, "run-tests")
        } else {
            XCTFail("Expected first menu item to be an action reference.")
        }
        if case .separator = menu.items[1] {
        } else {
            XCTFail("Expected second menu item to be a separator.")
        }
        if case .submenu(let submenu) = menu.items[2] {
            XCTAssertEqual(submenu.title, "Tools")
            guard case .action(let item) = submenu.items.first else {
                return XCTFail("Expected nested inline command.")
            }
            XCTAssertEqual(item.title, "Lint")
            XCTAssertEqual(item.inlineAction?.action?.terminalCommand, "npm run lint")
            XCTAssertEqual(item.inlineAction?.terminalCommandTarget, .currentTerminal)
        } else {
            XCTFail("Expected third menu item to be a submenu.")
        }
    }

    func testDecodeMenuBarAcceptsArrayShorthand() throws {
        let json = """
        {
          "ui": {
            "menuBar": [
              {
                "title": "Project",
                "items": [
                  { "title": "Format", "command": "npm run format" }
                ]
              }
            ]
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.ui?.menuBar?.menus.first?.title, "Project")
    }

    func testDecodeMenuBarSupportsExtendsAndDynamicSource() throws {
        let json = """
        {
          "ui": {
            "menuBar": [
              {
                "extends": "notifications",
                "items": [
                  {
                    "title": "Recent Branches",
                    "source": {
                      "command": "printf '[]'",
                      "refresh": "interval",
                      "timeoutSeconds": 2,
                      "intervalSeconds": 10
                    }
                  }
                ]
              }
            ]
          }
        }
        """
        let config = try decode(json)
        let menu = try XCTUnwrap(config.ui?.menuBar?.menus.first)
        XCTAssertEqual(menu.extends, "notifications")
        guard case .dynamic(let item) = menu.items.first else {
            return XCTFail("Expected dynamic menu source.")
        }
        XCTAssertEqual(item.title, "Recent Branches")
        XCTAssertEqual(item.source.command, "printf '[]'")
        XCTAssertEqual(item.source.refresh, .interval)
        XCTAssertEqual(item.source.timeoutSeconds, 2)
        XCTAssertEqual(item.source.intervalSeconds, 10)
    }

    @MainActor
    func testDefaultNewWorkspaceContextMenuIncludesCloudVM() throws {
        let store = try loadStore()

        XCTAssertEqual(store.newWorkspaceContextMenuItems.count, 2)
        guard store.newWorkspaceContextMenuItems.count == 2 else { return }
        guard case .action(let first) = store.newWorkspaceContextMenuItems[0],
              case .action(let second) = store.newWorkspaceContextMenuItems[1] else {
            return XCTFail("Expected default context menu actions.")
        }
        XCTAssertEqual(first.action.id, CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)
        XCTAssertEqual(second.action.id, CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testEmptyNewWorkspaceContextMenuHidesDefaults() throws {
        let store = try loadStore(localJSON: """
        {
          "ui": {
            "newWorkspace": {
              "contextMenu": []
            }
          }
        }
        """)

        XCTAssertTrue(store.newWorkspaceContextMenuItems.isEmpty)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testCloudVMAliasesResolveToCanonicalBuiltInAction() throws {
        let store = try loadStore(localJSON: """
        {
          "ui": {
            "newWorkspace": {
              "contextMenu": [
                "cmux.cloudvm",
                "cmux.cloudVM",
                "cloudVM",
                "newCloudVM",
                "startCloudVM"
              ]
            }
          }
        }
        """)

        XCTAssertEqual(store.newWorkspaceContextMenuItems.count, 5)
        for item in store.newWorkspaceContextMenuItems {
            guard case .action(let action) = item else {
                return XCTFail("Expected Cloud VM context-menu action.")
            }
            XCTAssertEqual(action.action.id, CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)
        }
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    func testActionAliasesCannotOverrideSameBuiltInTwice() throws {
        let json = """
        {
          "actions": {
            "cmux.cloudvm": { "type": "command", "command": "echo canonical" },
            "startCloudVM": { "type": "command", "command": "echo alias" }
          }
        }
        """

        XCTAssertThrowsError(try decode(json)) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("duplicate aliases"))
            XCTAssertTrue(description.contains(CmuxSurfaceTabBarBuiltInAction.cloudVM.configID))
        }
    }

    @MainActor
    func testDefaultCloudVMMenuActionCanBeOverriddenByAlias() throws {
        let store = try loadStore(localJSON: """
        {
          "actions": {
            "cmux.cloudvm": {
              "type": "command",
              "command": "echo cloud",
              "title": "Cloud Override",
              "icon": { "type": "symbol", "name": "bolt" }
            }
          }
        }
        """)

        XCTAssertEqual(store.newWorkspaceContextMenuItems.count, 2)
        guard store.newWorkspaceContextMenuItems.count == 2 else { return }
        guard case .action(let item) = store.newWorkspaceContextMenuItems[1] else {
            return XCTFail("Expected Cloud VM context-menu action.")
        }
        XCTAssertEqual(item.action.id, CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)
        XCTAssertEqual(item.title, "Cloud Override")
        XCTAssertEqual(item.icon, .symbol("bolt"))
        XCTAssertEqual(item.action.terminalCommand, "echo cloud")
        XCTAssertTrue(store.configurationIssues.isEmpty)
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

    @MainActor
    func testResolvedMenuBarSupportsActionRefsInlineCommandsAndSubmenus() throws {
        let store = try loadStore(localJSON: """
        {
          "actions": {
            "run-tests": {
              "type": "command",
              "title": "Run Tests",
              "command": "npm test",
              "target": "newTabInCurrentPane"
            }
          },
          "ui": {
            "menuBar": {
              "menus": [
                {
                  "title": "Project",
                  "items": [
                    "run-tests",
                    { "type": "separator" },
                    {
                      "title": "Tools",
                      "items": [
                        {
                          "title": "Lint",
                          "command": "npm run lint",
                          "target": "currentTerminal"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """)

        XCTAssertEqual(store.menuBarMenus.count, 1)
        let menu = try XCTUnwrap(store.menuBarMenus.first)
        XCTAssertEqual(menu.title, "Project")
        XCTAssertEqual(menu.items.count, 3)
        guard case .action(let first) = menu.items[0] else {
            return XCTFail("Expected first menu item to resolve to an action.")
        }
        XCTAssertEqual(first.title, "Run Tests")
        XCTAssertEqual(first.action.terminalCommand, "npm test")
        guard case .separator = menu.items[1] else {
            return XCTFail("Expected second menu item to be a separator.")
        }
        guard case .submenu(let submenu) = menu.items[2] else {
            return XCTFail("Expected third menu item to resolve to a submenu.")
        }
        XCTAssertEqual(submenu.title, "Tools")
        guard case .action(let nested) = submenu.items.first else {
            return XCTFail("Expected nested menu item to resolve to an action.")
        }
        XCTAssertEqual(nested.title, "Lint")
        XCTAssertEqual(nested.action.terminalCommand, "npm run lint")
        XCTAssertEqual(nested.action.terminalCommandTarget, .currentTerminal)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testResolvedMenuBarKeepsDuplicateTitlesSeparateAndSupportsExtends() throws {
        let store = try loadStore(
            localJSON: """
            {
              "ui": {
                "menuBar": [
                  {
                    "id": "local-project",
                    "title": "Project",
                    "items": [{ "title": "Local", "command": "echo local" }]
                  },
                  {
                    "extends": "notifications",
                    "items": [{ "title": "Open Logs", "command": "echo logs" }]
                  }
                ]
              }
            }
            """,
            globalJSON: """
            {
              "ui": {
                "menuBar": [
                  {
                    "id": "global-project",
                    "title": "Project",
                    "items": [{ "title": "Global", "command": "echo global" }]
                  }
                ]
              }
            }
            """
        )

        XCTAssertEqual(store.menuBarMenus.map(\.configID), ["global-project", "local-project"])
        XCTAssertEqual(store.menuBarMenus.map(\.title), ["Project", "Project"])
        XCTAssertEqual(store.menuBarExtensions.count, 1)
        XCTAssertEqual(store.menuBarExtensions.first?.targetID, "notifications")
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testResolvedMenuBarSupportsDynamicSourcesAndRejectsGeneratedNestedSources() throws {
        let store = try loadStore(localJSON: """
        {
          "ui": {
            "menuBar": [
              {
                "title": "Project",
                "items": [
                  {
                    "id": "recent-branches",
                    "title": "Recent Branches",
                    "source": {
                      "command": "printf '[]'",
                      "refresh": "onOpen",
                      "timeoutSeconds": 3
                    }
                  }
                ]
              }
            ]
          }
        }
        """)

        let menu = try XCTUnwrap(store.menuBarMenus.first)
        guard case .dynamicSource(let source) = menu.items.first else {
            return XCTFail("Expected dynamic source.")
        }
        XCTAssertEqual(source.title, "Recent Branches")
        XCTAssertEqual(source.source.command, "printf '[]'")
        XCTAssertEqual(source.source.refresh, .onOpen)

        let generated = try JSONDecoder().decode([CmuxConfigMenuBarItem].self, from: Data("""
        [
          {
            "title": "Nested Dynamic",
            "source": { "command": "printf '[]'" }
          }
        ]
        """.utf8))
        let resolved = store.resolveGeneratedMenuBarItems(
            generated,
            settingName: "ui.menuBar.menus[0].items[0].generated",
            settingSourcePath: nil
        )
        XCTAssertTrue(resolved.items.isEmpty)
        XCTAssertEqual(resolved.issues.first?.kind, .menuBarInvalidMenu)
    }

    @MainActor
    func testResolvedMenuBarFiltersMissingActions() throws {
        let store = try loadStore(localJSON: """
        {
          "actions": {
            "run-tests": { "type": "command", "command": "npm test" }
          },
          "ui": {
            "menuBar": [
              {
                "title": "Project",
                "items": [
                  "missing-action",
                  "run-tests"
                ]
              }
            ]
          }
        }
        """)

        XCTAssertEqual(store.menuBarMenus.count, 1)
        let menu = try XCTUnwrap(store.menuBarMenus.first)
        XCTAssertEqual(menu.items.count, 1)
        guard case .action(let item) = menu.items.first else {
            return XCTFail("Expected valid action to remain.")
        }
        XCTAssertEqual(item.action.terminalCommand, "npm test")
        XCTAssertEqual(store.configurationIssues.first?.kind, .newWorkspaceActionNotFound)
        XCTAssertEqual(store.configurationIssues.first?.settingName, "ui.menuBar.menus[0].items[0]")
        XCTAssertEqual(store.configurationIssues.first?.commandName, "missing-action")
    }
}
