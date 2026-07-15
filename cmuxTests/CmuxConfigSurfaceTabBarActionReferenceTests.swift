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
struct CmuxConfigSurfaceTabBarActionReferenceTests {
    @Test func testDecodeSurfaceTabBarButtonsDefersUnknownActionReferences() throws {
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

    @Test func testResolveSurfaceTabBarActionReferenceUsesActionTitle() throws {
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

    @Test func testResolveSurfaceTabBarActionReferenceCanOverrideTitleAndIcon() throws {
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

    @Test func testSurfaceTabBarActionReferenceUsesActionSourcePath() throws {
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
}
