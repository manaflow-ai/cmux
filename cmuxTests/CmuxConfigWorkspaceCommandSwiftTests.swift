import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cmux config workspace command extension resolution")
struct CmuxConfigWorkspaceCommandSwiftTests {

    @Test @MainActor
    func executionContextStartingFromDirectoryLoadsNearestWorkspaceCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let nestedDirectory = projectDirectory.appendingPathComponent("packages/app", isDirectory: true)
        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = configDirectory.appendingPathComponent("cmux.json")
        let localWorkspaceCommand = CmuxCommandDefinition(
            name: "Local Dev",
            workspace: CmuxWorkspaceDefinition(name: "Local", cwd: ".")
        )
        let collidingCommandActionID = localWorkspaceCommand.id
        try """
        {
          "commands": [{
            "name": "Global Dev",
            "workspace": { "name": "Global", "cwd": "." }
          }]
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "worktree-dev": { "type": "workspaceCommand", "commandName": "Local Dev" },
            "\(collidingCommandActionID)": { "type": "workspaceCommand", "commandName": "Global Dev" }
          },
          "ui": { "newWorkspace": { "action": "worktree-dev" } },
          "commands": [{
            "name": "Local Dev",
            "workspace": { "name": "Local", "cwd": "." }
          }]
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: globalConfigURL.path, startFileWatchers: false)
        store.loadAll()
        #expect(store.resolvedAction(id: "worktree-dev") == nil)

        let context = store.executionContext(startingFrom: nestedDirectory.path)
        #expect(context.loadedCommands.map(\.name) == ["Local Dev", "Global Dev"])
        let firstCommand = try #require(context.loadedCommands.first)
        #expect(context.commandSourcePaths[firstCommand.id] == localConfigURL.path)
        let commandActionByName = try #require(context.resolvedWorkspaceCommandAction(identifier: "Local Dev"))
        #expect(commandActionByName.workspaceCommandName == "Local Dev")
        #expect(commandActionByName.terminalCommand == nil)
        let commandActionByID = try #require(context.resolvedWorkspaceCommandAction(identifier: collidingCommandActionID))
        #expect(commandActionByID.workspaceCommandName == "Local Dev")
        #expect(commandActionByID.terminalCommand == nil)
        #expect(context.resolvedWorkspaceCommandAction(identifier: "worktree-dev")?.workspaceCommandName == "Local Dev")
        #expect(context.resolvedNewWorkspaceAction()?.workspaceCommandName == "Local Dev")

        try """
        {
          "commands": [{
            "name": "Local Test",
            "workspace": { "name": "Test", "cwd": "." }
          }]
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let reusedContext = store.executionContext(startingFrom: nestedDirectory.path)
        #expect(context === reusedContext)
        #expect(reusedContext.loadedCommands.map(\.name) == ["Local Test", "Global Dev"])
        #expect(reusedContext.resolvedWorkspaceCommandAction(identifier: "Local Test")?.workspaceCommandName == "Local Test")
    }

    @Test @MainActor
    func resolvedWorkspaceCommandActionResolvesWorkspaceActionCollidingWithNonWorkspaceCommandID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plainCommand = CmuxCommandDefinition(name: "Build", command: "make")
        let collidingActionID = plainCommand.id

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "\(collidingActionID)": { "type": "workspaceCommand", "commandName": "Deploy" }
          },
          "commands": [
            { "name": "Build", "command": "make" },
            { "name": "Deploy", "workspace": { "name": "Deploy", "cwd": "." } }
          ]
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        let action = try #require(store.resolvedWorkspaceCommandAction(identifier: collidingActionID))
        #expect(action.workspaceCommandName == "Deploy")
        #expect(store.resolvedWorkspaceCommandAction(identifier: "Build") == nil)
        #expect(store.resolvedWorkspaceCommandAction(identifier: "Deploy")?.workspaceCommandName == "Deploy")
    }

    @Test @MainActor
    func resolvedWorkspaceCommandActionPreservesLocalAliasSourceForGlobalCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = configDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "commands": [{
            "name": "Global Deploy",
            "workspace": { "name": "Deploy", "cwd": "." }
          }]
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "project-deploy": { "type": "workspaceCommand", "commandName": "Global Deploy" }
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: globalConfigURL.path, startFileWatchers: false)
        let context = store.executionContext(startingFrom: projectDirectory.path)
        let command = try #require(context.loadedCommands.first { $0.name == "Global Deploy" })
        #expect(context.commandSourcePaths[command.id] == globalConfigURL.path)

        let action = try #require(context.resolvedWorkspaceCommandAction(identifier: "project-deploy"))
        #expect(action.workspaceCommandName == "Global Deploy")
        #expect(action.actionSourcePath == localConfigURL.path)
    }

    @Test @MainActor
    func resolvedNewWorkspaceActionForExtensionPreservesLocalSettingSourceForGlobalAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = configDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "global-deploy": { "type": "workspaceCommand", "commandName": "Global Deploy" }
          },
          "commands": [{
            "name": "Global Deploy",
            "workspace": { "name": "Deploy", "cwd": "." }
          }]
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "ui": {
            "newWorkspace": { "action": "global-deploy" }
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: globalConfigURL.path, startFileWatchers: false)
        let context = store.executionContext(startingFrom: projectDirectory.path)
        let command = try #require(context.loadedCommands.first { $0.name == "Global Deploy" })
        #expect(context.commandSourcePaths[command.id] == globalConfigURL.path)

        let action = try #require(context.resolvedNewWorkspaceActionForExtension())
        #expect(action.workspaceCommandName == "Global Deploy")
        #expect(action.actionSourcePath == localConfigURL.path)
    }

    @Test @MainActor
    func resolvedNewWorkspaceActionForExtensionRejectsCommandAction() throws {
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

        let shared = try #require(store.resolvedNewWorkspaceAction())
        #expect(shared.terminalCommand == "codex")
        #expect(shared.workspaceCommandName == nil)
        #expect(store.resolvedNewWorkspaceActionForExtension() == nil)
    }

    @Test @MainActor
    func resolvedNewWorkspaceActionForExtensionAllowsWorkspaceCommand() throws {
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
            "worktree-dev": { "type": "workspaceCommand", "commandName": "Local Dev" }
          },
          "ui": {
            "newWorkspace": { "action": "worktree-dev" }
          },
          "commands": [{
            "name": "Local Dev",
            "workspace": { "name": "Local", "cwd": "." }
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

        let action = try #require(store.resolvedNewWorkspaceActionForExtension())
        #expect(action.workspaceCommandName == "Local Dev")
        #expect(action.terminalCommand == nil)
    }
}
