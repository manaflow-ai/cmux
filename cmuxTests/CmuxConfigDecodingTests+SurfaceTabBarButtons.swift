import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


// MARK: - Surface tab bar buttons
extension CmuxConfigDecodingTests {
    func testDecodeLegacySurfaceTabBarButtons() throws {
        let json = """
        {
          "surfaceTabBarButtons": ["newTerminal", "splitRight"],
          "commands": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons, [.newTerminal, .splitRight])
    }

    func testDecodeSurfaceTabBarButtonObjects() throws {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "newTerminal",
              "icon": { "type": "symbol", "name": "terminal.fill" },
              "tooltip": "New shell",
              "action": "newTerminal"
            },
            {
              "id": "run-tests",
              "icon": { "type": "symbol", "name": "checkmark.circle" },
              "tooltip": "Run tests",
              "command": "npm test",
              "confirm": true
            }
          ],
          "commands": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons?.count, 2)
        let rawFirstButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        let firstButton = try rawFirstButton.resolved(actions: [:], codingPath: [])
        XCTAssertEqual(
            firstButton,
            .builtIn(.newTerminal, id: "newTerminal", icon: .symbol("terminal.fill"), tooltip: "New shell")
        )
        XCTAssertEqual(config.surfaceTabBarButtons?[1].id, "run-tests")
        XCTAssertEqual(config.surfaceTabBarButtons?[1].icon, .symbol("checkmark.circle"))
        XCTAssertEqual(config.surfaceTabBarButtons?[1].tooltip, "Run tests")
        XCTAssertEqual(config.surfaceTabBarButtons?[1].action, .command("npm test"))
        XCTAssertEqual(config.surfaceTabBarButtons?[1].confirm, true)
    }

    func testDecodeSurfaceTabBarButtonCanOverrideBuiltInWithCommand() throws {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "newTerminal",
              "icon": { "type": "symbol", "name": "play.circle" },
              "command": "npm run dev"
            }
          ]
        }
        """
        let config = try decode(json)
        let button = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        XCTAssertEqual(button.id, "newTerminal")
        XCTAssertEqual(button.icon, .symbol("play.circle"))
        XCTAssertEqual(button.command, "npm run dev")
    }

    func testDecodeActionsSurfaceTabBarButtons() throws {
        let json = """
        {
          "actions": {
            "start-codex": { "type": "agent", "agent": "codex" },
            "start-claude": { "type": "agent", "agent": "claude", "args": "--permission-mode acceptEdits" }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                {
                  "action": "start-codex",
                  "icon": { "type": "image", "path": "./icons/codex.png" },
                  "tooltip": "Start Codex"
                },
                {
                  "action": "start-claude",
                  "icon": { "type": "emoji", "value": "🤖" },
                  "tooltip": "Start Claude Code"
                }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let rawButtons = try XCTUnwrap(config.surfaceTabBarButtons)
        let buttons = try rawButtons.map {
            try $0.resolved(actions: resolvedActions(from: config), codingPath: [])
        }
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons[0].id, "start-codex")
        XCTAssertEqual(buttons[0].icon, .imagePath("./icons/codex.png"))
        XCTAssertEqual(buttons[0].terminalCommand, "codex")
        XCTAssertEqual(buttons[1].id, "start-claude")
        XCTAssertEqual(buttons[1].icon, .emoji("🤖"))
        XCTAssertEqual(buttons[1].terminalCommand, "claude --permission-mode acceptEdits")
    }

    func testDecodeSurfaceTabBarButtonsDefersUnknownActionReferences() throws {
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "global-codex", "icon": { "type": "symbol", "name": "sparkles" } }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let button = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        XCTAssertEqual(button.id, "global-codex")
        XCTAssertEqual(button.action, .actionReference("global-codex"))
    }

    func testResolveSurfaceTabBarActionReferenceUsesActionTitle() throws {
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "title": "Start Codex",
              "tooltip": "Open Codex in a new tab",
              "command": "codex",
              "icon": { "type": "symbol", "name": "sparkles" }
            }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "start-codex" }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let rawButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        let button = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        XCTAssertEqual(button.title, "Start Codex")
        XCTAssertEqual(button.tooltip, "Open Codex in a new tab")
        XCTAssertEqual(button.icon, .symbol("sparkles"))
        XCTAssertEqual(button.action, .command("codex"))
    }

    func testResolveSurfaceTabBarActionReferenceCanOverrideTitleAndIcon() throws {
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "title": "Start Codex",
              "tooltip": "Open Codex in a new tab",
              "command": "codex",
              "icon": { "type": "symbol", "name": "sparkles" }
            }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                {
                  "action": "start-codex",
                  "title": "Codex Here",
                  "icon": { "type": "emoji", "value": "🤖" }
                }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let rawButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        let button = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        XCTAssertEqual(button.title, "Codex Here")
        XCTAssertEqual(button.tooltip, "Open Codex in a new tab")
        XCTAssertEqual(button.icon, .emoji("🤖"))
        XCTAssertEqual(button.action, .command("codex"))
    }

    @MainActor
    func testSurfaceTabBarActionReferenceUsesActionSourcePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-store-\(UUID().uuidString)", isDirectory: true)
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let localDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = localDirectory.appendingPathComponent("cmux.json")
        let globalJSON = """
        {
          "actions": {
            "start-codex": { "type": "command", "command": "codex --yolo", "confirm": true }
          }
        }
        """
        let localJSON = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "start-codex", "icon": { "type": "symbol", "name": "sparkles" } }
              ]
            }
          }
        }
        """
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try localJSON.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtonSourcePath, localConfigURL.path)
        XCTAssertEqual(store.surfaceTabBarButtons.first?.terminalCommand, "codex --yolo")
        XCTAssertEqual(store.surfaceTabBarCommandSourcePaths["start-codex"], globalConfigURL.path)
    }

    func testDecodeActionsSurfaceTabBarButtonSupportsWorkspaceCommand() throws {
        let json = """
        {
          "actions": {
            "new-dev": { "type": "workspaceCommand", "commandName": "Dev Environment" }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                {
                  "action": "new-dev",
                  "icon": { "type": "symbol", "name": "rectangle.stack.badge.plus" }
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
        let rawButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        let button = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        XCTAssertEqual(button.workspaceCommandName, "Dev Environment")
        XCTAssertNil(button.terminalCommand)
    }

    func testSurfaceTabBarWorkspaceCommandButtonRoundTrips() throws {
        let original = CmuxSurfaceTabBarButton(
            id: "new-dev",
            icon: .symbol("rectangle.stack.badge.plus"),
            tooltip: "New dev workspace",
            action: .workspaceCommand("Dev Environment"),
            confirm: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxSurfaceTabBarButton.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    @MainActor
    func testSurfaceTabBarDropsUnresolvedWorkspaceCommandButtons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "newTerminal" },
                { "id": "dev", "type": "workspaceCommand", "commandName": "Dev Environment" },
                { "id": "typo", "type": "workspaceCommand", "commandName": "Typo" },
                { "id": "simple", "type": "workspaceCommand", "commandName": "Run Tests" }
              ]
            }
          },
          "commands": [
            {
              "name": "Dev Environment",
              "workspace": { "name": "Dev" }
            },
            {
              "name": "Run Tests",
              "command": "npm test"
            }
          ]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.id), ["newTerminal", "dev"])
        XCTAssertEqual(store.surfaceTabBarButtons.last?.workspaceCommandName, "Dev Environment")
    }

    func testDecodeEmptySurfaceTabBarButtons() throws {
        let json = """
        {
          "surfaceTabBarButtons": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons, [])
        XCTAssertTrue(config.commands.isEmpty)
    }

    func testDecodeDuplicateSurfaceTabBarButtonsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": ["newTerminal", "newTerminal"],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeDuplicateSurfaceTabBarButtonIdsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "play" },
              "command": "npm run dev"
            },
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "checkmark" },
              "command": "npm test"
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }
}
