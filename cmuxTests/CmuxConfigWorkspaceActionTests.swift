import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxConfigWorkspaceActionTests: XCTestCase {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    private func workspaceAction(
        in config: CmuxConfigFile,
        id: String
    ) throws -> (definition: CmuxWorkspaceDefinition, restart: CmuxRestartBehavior?) {
        let action = try XCTUnwrap(config.actions[id]?.action)
        return try XCTUnwrap(action.inlineWorkspace)
    }

    // MARK: - Decoding workspace actions

    func testDecodeWorkspaceActionWithExplicitType() throws {
        let config = try decode("""
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "restart": "recreate",
              "newWorkspaceMenu": true,
              "workspace": {
                "name": "Dev",
                "cwd": "~/code/app",
                "setup": "  git fetch --all  ",
                "layout": {
                  "direction": "horizontal",
                  "split": 0.4,
                  "children": [
                    { "pane": { "surfaces": [ { "type": "terminal", "command": "claude", "focus": true } ] } },
                    { "pane": { "surfaces": [ { "type": "browser", "url": "https://example.com" } ] } }
                  ]
                }
              }
            }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "dev-setup")
        XCTAssertEqual(inline.definition.name, "Dev")
        XCTAssertEqual(inline.definition.cwd, "~/code/app")
        XCTAssertEqual(inline.definition.setup, "git fetch --all")
        XCTAssertEqual(inline.restart, .recreate)
        XCTAssertEqual(config.actions["dev-setup"]?.newWorkspaceMenu, true)
        guard case .split(let split)? = inline.definition.layout else {
            return XCTFail("Expected split layout")
        }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.children.count, 2)
    }

    func testDecodeWorkspaceActionInferredFromWorkspaceKey() throws {
        let config = try decode("""
        {
          "actions": {
            "quick": {
              "title": "Quick",
              "workspace": { "name": "Quick" }
            }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "quick")
        XCTAssertEqual(inline.definition.name, "Quick")
        XCTAssertNil(inline.restart)
    }

    func testWorkspaceActionRequiresWorkspaceObject() {
        XCTAssertThrowsError(try decode("""
        {
          "actions": {
            "broken": { "type": "workspace", "title": "Broken" }
          }
        }
        """))
    }

    func testWorkspaceActionEncodeDecodeRoundTrip() throws {
        let definition = CmuxWorkspaceDefinition(
            name: "Round Trip",
            cwd: "~/code",
            env: ["FOO": "bar"],
            setup: "make deps",
            layout: .split(CmuxSplitDefinition(
                direction: .vertical,
                split: 0.3,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Agent", command: "opencode", focus: true)
                    ])),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, url: "https://example.com")
                    ])),
                ]
            ))
        )
        let original = CmuxConfigActionDefinition(
            action: .workspace(definition, restart: .confirm),
            title: "Round Trip",
            newWorkspaceMenu: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxConfigActionDefinition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeBlankSetupBecomesNil() throws {
        let config = try decode("""
        {
          "actions": {
            "blank-setup": { "workspace": { "name": "X", "setup": "   " } }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "blank-setup")
        XCTAssertNil(inline.definition.setup)
    }

    // MARK: - Agent kinds

    func testDecodeKnownAndCustomAgents() throws {
        let config = try decode("""
        {
          "actions": {
            "oc": { "type": "agent", "agent": "opencode" },
            "custom": { "type": "agent", "agent": "aider", "args": "--model gpt" }
          }
        }
        """)
        guard case .agent(let ocKind, _)? = config.actions["oc"]?.action else {
            return XCTFail("Expected agent action")
        }
        XCTAssertEqual(ocKind, .opencode)
        XCTAssertEqual(ocKind.commandName, "opencode")

        guard case .agent(let customKind, let args)? = config.actions["custom"]?.action else {
            return XCTFail("Expected agent action")
        }
        XCTAssertEqual(customKind, .custom("aider"))
        XCTAssertEqual(customKind.commandName, "aider")
        XCTAssertEqual(args, "--model gpt")
        XCTAssertEqual(config.actions["custom"]?.action?.terminalCommand, "aider --model gpt")
    }

    func testCustomAgentRejectsWhitespaceNames() {
        XCTAssertThrowsError(try decode("""
        {
          "actions": {
            "bad": { "type": "agent", "agent": "aider --yolo" }
          }
        }
        """))
    }

    func testAgentEncodeRoundTrip() throws {
        for kind in [CmuxConfigAgentKind.codex, .claudeCode, .opencode, .custom("goose")] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(CmuxConfigAgentKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - Resolved action defaults

    func testWantsNewWorkspaceMenuDefaults() throws {
        let workspaceAction = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "ws",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "W"), restart: nil)
            ),
            sourcePath: nil
        ))
        XCTAssertTrue(workspaceAction.wantsNewWorkspaceMenu)

        let commandAction = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "cmd",
            definition: CmuxConfigActionDefinition(action: .command("make")),
            sourcePath: nil
        ))
        XCTAssertFalse(commandAction.wantsNewWorkspaceMenu)

        let optedOut = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "ws2",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "W2"), restart: nil),
                newWorkspaceMenu: false
            ),
            sourcePath: nil
        ))
        XCTAssertFalse(optedOut.wantsNewWorkspaceMenu)

        let optedIn = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "cmd2",
            definition: CmuxConfigActionDefinition(
                action: .command("make"),
                newWorkspaceMenu: true
            ),
            sourcePath: nil
        ))
        XCTAssertTrue(optedIn.wantsNewWorkspaceMenu)
    }

    // MARK: - Store: plus-button menu auto-append

    @MainActor
    private func loadStore(globalJSON: String) throws -> CmuxConfigStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-workspace-action-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let globalConfigURL = root.appendingPathComponent("cmux.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return store
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
    func testStoreAutoAppendsWorkspaceActionsToPlusButtonMenu() throws {
        let store = try loadStore(globalJSON: """
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
        let ids = menuActionIDs(store)
        XCTAssertTrue(ids.contains("dev-setup"), "workspace action should be auto-offered, got \(ids)")
        // Defaults stay first.
        XCTAssertEqual(ids.first, CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)
        // Auto block is separated from the configured items.
        if case .separator? = store.newWorkspaceContextMenuItems.dropLast().last {} else {
            XCTFail("Expected separator before auto-appended actions")
        }
    }

    @MainActor
    func testStoreRespectsNewWorkspaceMenuOptOut() throws {
        let store = try loadStore(globalJSON: """
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
        let ids = menuActionIDs(store)
        XCTAssertFalse(ids.contains("hidden"))
        XCTAssertTrue(ids.contains("shown-command"))
    }

    @MainActor
    func testStoreDoesNotDuplicateExplicitMenuEntries() throws {
        let store = try loadStore(globalJSON: """
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
        let ids = menuActionIDs(store)
        XCTAssertEqual(ids.filter { $0 == "dev-setup" }.count, 1)
    }

    // MARK: - Saver

    func testSlugForTitle() {
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "My Dev Setup!"), "my-dev-setup")
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "  --  "), "workspace")
        XCTAssertEqual(CmuxConfigActionSaver.slug(forTitle: "日本語 Dev"), "日本語-dev")
    }

    func testUniqueActionID() {
        XCTAssertEqual(
            CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: []),
            "dev"
        )
        XCTAssertEqual(
            CmuxConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: ["dev", "dev-2"]),
            "dev-3"
        )
    }

    func testSaveWorkspaceActionPreservesCommentsAndDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let configPath = root.appendingPathComponent("cmux.json").path
        let existing = """
        {
          // build actions
          "actions": {
            "dev": { "type": "command", "command": "make" } // keep me
          }
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        let definition = CmuxWorkspaceDefinition(
            name: "Dev",
            cwd: "~/code",
            setup: "make deps",
            layout: .pane(CmuxPaneDefinition(surfaces: [
                CmuxSurfaceDefinition(type: .terminal, command: "claude", focus: true)
            ]))
        )
        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: definition,
            globalConfigPath: configPath
        )
        XCTAssertEqual(result.actionID, "dev-2", "id should be uniquified against the existing 'dev'")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("// build actions"))
        XCTAssertTrue(saved.contains("// keep me"))

        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        let inline = try XCTUnwrap(config.actions["dev-2"]?.action?.inlineWorkspace)
        XCTAssertEqual(inline.definition.name, "Dev")
        XCTAssertEqual(inline.definition.setup, "make deps")
        XCTAssertEqual(config.actions["dev-2"]?.title, "Dev")
        guard case .pane(let pane)? = inline.definition.layout else {
            return XCTFail("Expected pane layout")
        }
        XCTAssertEqual(pane.surfaces.first?.command, "claude")
    }

    // MARK: - Executor

    @MainActor
    func testInlineWorkspaceActionCreatesWorkspace() throws {
        let manager = TabManager()
        let action = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Dev Setup"), restart: nil),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        XCTAssertTrue(CmuxConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev Setup")
    }

    @MainActor
    func testInlineWorkspaceActionHonorsIgnoreRestart() throws {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev Setup")

        let action = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Dev Setup"), restart: .ignore),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        XCTAssertTrue(CmuxConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.map(\.id), [existingWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspace?.id, existingWorkspace.id)
    }

    func testSaveWorkspaceActionCreatesFileFromTemplate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-action-saver-template-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let configPath = root.appendingPathComponent("nested/cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Fresh",
            definition: CmuxWorkspaceDefinition(name: "Fresh"),
            globalConfigPath: configPath
        )
        XCTAssertEqual(result.actionID, "fresh")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("$schema"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        XCTAssertNotNil(config.actions["fresh"]?.action?.inlineWorkspace)
    }
}
