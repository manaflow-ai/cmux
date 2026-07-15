import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CmuxConfigSurfaceTabBarWorkspaceCommandTests {
    @Test func testDecodeActionsSurfaceTabBarButtonSupportsWorkspaceCommand() throws {
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

    @Test func testSurfaceTabBarWorkspaceCommandButtonRoundTrips() throws {
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

    @Test func testSurfaceTabBarDropsUnresolvedWorkspaceCommandButtons() throws {
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

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.id), ["newTerminal", "dev", "cmux.more"])
        XCTAssertEqual(store.surfaceTabBarButtons.dropLast().last?.workspaceCommandName, "Dev Environment")
    }

    @Test func testSurfaceTabBarMenuResolvesNestedWorkspaceCommandsAndSourcePaths() throws {
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
            "repo-status": { "type": "command", "command": "git status" }
          }
        }
        """
        let localJSON = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                {
                  "id": "workspace-tools",
                  "type": "menu",
                  "menu": [
                    { "action": "repo-status" },
                    { "id": "dev", "type": "workspaceCommand", "commandName": "Dev Environment" },
                    { "id": "typo", "type": "workspaceCommand", "commandName": "Typo" }
                  ]
                }
              ]
            }
          },
          "commands": [
            {
              "name": "Dev Environment",
              "workspace": { "name": "Dev" }
            }
          ]
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

        let menu = try XCTUnwrap(store.surfaceTabBarButtons.first?.menu)
        XCTAssertEqual(menu.map(\.id), ["repo-status", "dev"])
        XCTAssertEqual(menu[0].terminalCommand, "git status")
        XCTAssertEqual(menu[1].workspaceCommandName, "Dev Environment")
        XCTAssertEqual(store.surfaceTabBarCommandSourcePaths["repo-status"], globalConfigURL.path)
    }

    @Test func testCustomButtonReusingMoreIdDoesNotDuplicateMoreButton() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A configured non-More button may legally take the default More
        // button's id; normalization must not append a second `cmux.more`
        // (duplicate ids trap Dictionary(uniqueKeysWithValues:) when the
        // workspace applies the buttons).
        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "id": "cmux.more", "command": "echo ok" }
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

        let moreIdButtons = store.surfaceTabBarButtons.filter { $0.id == "cmux.more" }
        XCTAssertEqual(moreIdButtons.count, 1)
        XCTAssertEqual(moreIdButtons.first?.terminalCommand, "echo ok")
    }

}
