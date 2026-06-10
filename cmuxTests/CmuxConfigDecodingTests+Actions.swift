import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


// MARK: - Actions and new-workspace command resolution
extension CmuxConfigDecodingTests {
    func testDecodeNewWorkspaceAction() throws {
        let json = """
        {
          "actions": {
            "new-dev": { "type": "workspaceCommand", "commandName": "Dev Environment" }
          },
          "ui": {
            "newWorkspace": { "action": "new-dev" }
          },
          "commands": [{
            "name": "Dev Environment",
            "workspace": { "name": "Dev" }
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.ui?.newWorkspace?.action, "new-dev")
        XCTAssertEqual(config.actions["new-dev"]?.action?.workspaceCommandName, "Dev Environment")
    }

    func testDecodeActionShortcutString() throws {
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "command": "codex --dangerously-bypass-approvals-and-sandbox",
              "shortcut": "cmd+shift+c"
            }
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(
            config.actions["start-codex"]?.shortcut,
            StoredShortcut.parseConfig("cmd+shift+c")
        )
    }

    func testDecodeActionShortcutChord() throws {
        let json = """
        {
          "actions": {
            "start-claude": {
              "type": "command",
              "command": "claude --dangerously-skip-permissions",
              "shortcut": ["cmd+k", "cmd+c"]
            }
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(
            config.actions["start-claude"]?.shortcut,
            StoredShortcut.parseConfig(strokes: ["cmd+k", "cmd+c"])
        )
    }

    @MainActor
    func testResolvedNewWorkspaceCommandReturnsConfiguredWorkspaceCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "newWorkspaceCommand": "Dev Environment",
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

        let resolved = try XCTUnwrap(store.resolvedNewWorkspaceCommand())
        XCTAssertEqual(resolved.command.name, "Dev Environment")
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testGlobalNewWorkspaceActionUsesLocalActionOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = root.appendingPathComponent("global-cmux.json")
        let localConfigURL = root.appendingPathComponent("local-cmux.json")
        try """
        {
          "actions": {
            "open-dev": { "type": "workspaceCommand", "commandName": "Global Dev" }
          },
          "ui": {
            "newWorkspace": { "action": "open-dev" }
          },
          "commands": [{
            "name": "Global Dev",
            "workspace": { "name": "Global" }
          }]
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "open-dev": { "type": "workspaceCommand", "commandName": "Local Dev" }
          },
          "commands": [{
            "name": "Local Dev",
            "workspace": { "name": "Local" }
          }]
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let resolved = try XCTUnwrap(store.resolvedNewWorkspaceCommand())
        XCTAssertEqual(resolved.command.name, "Local Dev")
        XCTAssertEqual(resolved.sourcePath, localConfigURL.path)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testResolvedNewWorkspaceCommandExposesMissingCommandIssue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "newWorkspaceCommand": "Missing",
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

        XCTAssertNil(store.resolvedNewWorkspaceCommand())
        XCTAssertEqual(store.configurationIssues.first?.kind, .newWorkspaceCommandNotFound)
        XCTAssertEqual(store.configurationIssues.first?.commandName, "Missing")
    }

    @MainActor
    func testResolvedNewWorkspaceCommandExposesNonWorkspaceIssue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "newWorkspaceCommand": "Run Tests",
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

        XCTAssertNil(store.resolvedNewWorkspaceCommand())
        XCTAssertEqual(store.configurationIssues.first?.kind, .newWorkspaceCommandRequiresWorkspace)
        XCTAssertEqual(store.configurationIssues.first?.commandName, "Run Tests")
        XCTAssertEqual(store.configurationIssues.first?.sourcePath, configURL.path)
    }

    @MainActor
    func testResolvedNewWorkspaceActionAllowsCommandAction() throws {
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
            "newWorkspace": { "action": "start-codex" }
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

        XCTAssertNil(store.resolvedNewWorkspaceCommand())
        let action = try XCTUnwrap(store.resolvedNewWorkspaceAction())
        XCTAssertEqual(action.id, "start-codex")
        XCTAssertEqual(action.terminalCommand, "codex")
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

}
