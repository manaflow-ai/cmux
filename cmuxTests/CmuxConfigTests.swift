import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - XCTest-style assertion shims over Swift Testing
// Pattern: cmuxTests/TerminalControllerSocketSecurityTests.swift.

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 != value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value = try expression()
        #expect(!value, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try expression()
        Issue.record(
            testComment(message()) ?? "Expected expression to throw an error",
            sourceLocation: sourceLocation
        )
    } catch {
        // Expected: the expression threw.
    }
}

private func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(abs(value1 - value2) <= accuracy, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() != nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(value, testComment(message()), sourceLocation: sourceLocation)
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
}

// MARK: - JSON Decoding

@MainActor
@Suite(.serialized)
struct CmuxConfigDecodingTests {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    private func resolvedActions(
        from config: CmuxConfigFile,
        sourcePath: String? = nil
    ) -> [String: CmuxResolvedConfigAction] {
        Dictionary(
            uniqueKeysWithValues: config.actions.compactMap { id, definition in
                CmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: definition,
                    sourcePath: sourcePath
                ).map { (id, $0) }
            }
        )
    }

    private func withSavedRightSidebarBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        let previousFeed = defaults.object(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        defer {
            restore(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        }
        try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    // MARK: Simple commands

    @Test func testDecodeSimpleCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Run tests",
            "command": "npm test"
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].name, "Run tests")
        XCTAssertEqual(config.commands[0].command, "npm test")
        XCTAssertNil(config.commands[0].workspace)
    }

    @Test func testDecodeSimpleCommandWithAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "Deploy",
            "description": "Deploy to production",
            "keywords": ["ship", "release"],
            "command": "make deploy",
            "confirm": true
          }]
        }
        """
        let config = try decode(json)
        let cmd = config.commands[0]
        XCTAssertEqual(cmd.name, "Deploy")
        XCTAssertEqual(cmd.description, "Deploy to production")
        XCTAssertEqual(cmd.keywords, ["ship", "release"])
        XCTAssertEqual(cmd.command, "make deploy")
        XCTAssertEqual(cmd.confirm, true)
    }

    @Test func testDecodeMultipleCommands() throws {
        let json = """
        {
          "commands": [
            { "name": "Build", "command": "make build" },
            { "name": "Test", "command": "make test" },
            { "name": "Lint", "command": "make lint" }
          ]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 3)
        XCTAssertEqual(config.commands.map(\.name), ["Build", "Test", "Lint"])
    }

    @Test func testDecodeNewWorkspaceCommand() throws {
        let json = """
        {
          "newWorkspaceCommand": "Dev Environment",
          "commands": [{
            "name": "Dev Environment",
            "workspace": { "name": "Dev" }
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.newWorkspaceCommand, "Dev Environment")
    }

    @Test func testDecodeNotificationHook() throws {
        let json = """
        {
          "notifications": {
            "hooks": [{
              "id": "agent-filter",
              "command": "jq '.effects.desktop = false'",
              "timeoutSeconds": 12
            }]
          }
        }
        """
        let config = try decode(json)
        let hook = try XCTUnwrap(config.notifications?.hooks?.first)
        XCTAssertEqual(hook.id, "agent-filter")
        XCTAssertEqual(hook.command, "jq '.effects.desktop = false'")
        XCTAssertEqual(hook.timeoutSeconds, 12)
        XCTAssertTrue(hook.enabled)
    }

    @Test func testDecodeNotificationHookRejectsBlankCommand() {
        let json = """
        {
          "notifications": {
            "hooks": [{
              "id": "agent-filter",
              "command": "   "
            }]
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeNewWorkspaceCommandTrimsWhitespace() throws {
        let json = """
        {
          "newWorkspaceCommand": "  Dev Environment  ",
          "commands": [{
            "name": "Dev Environment",
            "workspace": { "name": "Dev" }
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.newWorkspaceCommand, "Dev Environment")
    }

    @Test func testDecodeLegacySurfaceTabBarButtons() throws {
        let json = """
        {
          "surfaceTabBarButtons": ["newTerminal", "splitRight"],
          "commands": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons, [.newTerminal, .splitRight])
    }

    @Test func testDecodeSurfaceTabBarButtonObjects() throws {
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

    @Test func testDecodeSurfaceTabBarButtonCanOverrideBuiltInWithCommand() throws {
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

    @Test func testDecodeActionsSurfaceTabBarButtons() throws {
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

    @Test func testDecodeSurfaceTabBarMenuButton() throws {
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                {
                  "id": "workspace-tools",
                  "type": "menu",
                  "title": "Workspace Tools",
                  "icon": { "type": "symbol", "name": "ellipsis.circle" },
                  "menu": [
                    "vaultPane",
                    { "builtin": "finder" },
                    {
                      "id": "git-status",
                      "title": "Git Status",
                      "command": "git status"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        let rawButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        XCTAssertEqual(rawButton.id, "workspace-tools")
        XCTAssertEqual(rawButton.title, "Workspace Tools")
        XCTAssertEqual(rawButton.icon, .symbol("ellipsis.circle"))
        XCTAssertEqual(rawButton.action, .builtIn(.more))

        let rawMenu = try XCTUnwrap(rawButton.menu)
        XCTAssertEqual(rawMenu.count, 3)
        XCTAssertEqual(rawMenu[0].action, .actionReference(CmuxSurfaceTabBarBuiltInAction.vaultPane.configID))
        XCTAssertEqual(rawMenu[1].action, .builtIn(.revealCurrentDirectoryInFinder))
        XCTAssertEqual(rawMenu[2].id, "git-status")
        XCTAssertEqual(rawMenu[2].title, "Git Status")
        XCTAssertEqual(rawMenu[2].terminalCommand, "git status")

        let resolvedButton = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        XCTAssertEqual(resolvedButton.menu?[0].action, .builtIn(.vaultPane))
        XCTAssertEqual(resolvedButton.menu?[1].action, .builtIn(.revealCurrentDirectoryInFinder))
        XCTAssertEqual(resolvedButton.menu?[2].terminalCommand, "git status")
    }

    @Test func testDefaultSurfaceTabBarButtonsIncludeMoreMenu() throws {
        try withSavedRightSidebarBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-config-store-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = CmuxConfigStore(
                globalConfigPath: root.appendingPathComponent("missing-global.json").path,
                startFileWatchers: false
            )
            store.loadAll()

            XCTAssertEqual(store.surfaceTabBarButtons.map(\.id), [
                CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
                CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
                CmuxSurfaceTabBarBuiltInAction.splitRight.configID,
                CmuxSurfaceTabBarBuiltInAction.splitDown.configID,
                CmuxSurfaceTabBarBuiltInAction.more.configID,
            ])

            let moreButton = try XCTUnwrap(store.surfaceTabBarButtons.last)
            XCTAssertEqual(moreButton.action, .builtIn(.more))
            XCTAssertEqual(moreButton.menu?.map(\.id), [
                CmuxSurfaceTabBarBuiltInAction.diffViewer.configID,
                CmuxSurfaceTabBarBuiltInAction.filesPane.configID,
                CmuxSurfaceTabBarBuiltInAction.findPane.configID,
                CmuxSurfaceTabBarBuiltInAction.vaultPane.configID,
                CmuxSurfaceTabBarBuiltInAction.rightSidebarNotes.configID,
                CmuxSurfaceTabBarBuiltInAction.newNote.configID,
            ])
        }
    }

    @Test func testDefaultSurfaceTabBarMoreMenuIncludesNewNoteWhenSidebarBetaDisabled() throws {
        try withSavedRightSidebarBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-config-store-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = CmuxConfigStore(
                globalConfigPath: root.appendingPathComponent("missing-global.json").path,
                startFileWatchers: false
            )
            store.loadAll()

            let moreButton = try XCTUnwrap(store.surfaceTabBarButtons.last)
            XCTAssertEqual(moreButton.menu?.map(\.id), [
                CmuxSurfaceTabBarBuiltInAction.diffViewer.configID,
                CmuxSurfaceTabBarBuiltInAction.filesPane.configID,
                CmuxSurfaceTabBarBuiltInAction.findPane.configID,
                CmuxSurfaceTabBarBuiltInAction.vaultPane.configID,
                CmuxSurfaceTabBarBuiltInAction.newNote.configID,
            ])
        }
    }

    @Test func testSurfaceTabBarMenuFiltersUnavailableBetaBuiltIns() throws {
        try withSavedRightSidebarBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-config-store-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let configURL = root.appendingPathComponent("cmux.json")
            try """
            {
              "ui": {
                "surfaceTabBar": {
                  "buttons": [
                    {
                      "action": "more",
                      "menu": ["diff", "notes", "note", "feed", "dock", "vaultPane"]
                    }
                  ]
                }
              }
            }
            """.write(to: configURL, atomically: true, encoding: .utf8)

            let store = CmuxConfigStore(
                globalConfigPath: configURL.path,
                startFileWatchers: false
            )
            store.loadAll()

            XCTAssertEqual(store.surfaceTabBarButtons.last?.menu?.map(\.action), [
                .builtIn(.diffViewer),
                .builtIn(.newNote),
                .builtIn(.vaultPane),
            ])
        }
    }

    @Test func testConfiguredSurfaceTabBarButtonsAppendMoreMenu() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "newTerminal", "icon": { "type": "symbol", "name": "terminal" } },
                { "action": "newBrowser", "tooltip": "New browser" }
              ]
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.action.builtInActionReference), [
            .newTerminal,
            .newBrowser,
            .more,
        ])
        XCTAssertEqual(store.surfaceTabBarButtons.last?.menu?.first?.action, .builtIn(.diffViewer))
    }

    @Test func testSurfaceTabBarCanExplicitlyHideMoreMenu() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "hideMoreButton": true,
              "buttons": [
                { "action": "newTerminal" },
                { "action": "newBrowser" }
              ]
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.action.builtInActionReference), [
            .newTerminal,
            .newBrowser,
        ])
    }

    @Test func testDefaultSurfaceTabBarCanExplicitlyHideMoreMenu() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "hideMoreButton": true
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.action.builtInActionReference), [
            .newTerminal,
            .newBrowser,
            .splitRight,
            .splitDown,
        ])
    }

    @Test func testSurfaceTabBarKeepsConfiguredMoreMenuAtEnd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "newTerminal" },
                {
                  "action": "more",
                  "title": "Tools",
                  "menu": ["vaultPane"]
                },
                { "action": "newBrowser" }
              ]
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtons.map(\.action.builtInActionReference), [
            .newTerminal,
            .newBrowser,
            .more,
        ])
        XCTAssertEqual(store.surfaceTabBarButtons.last?.title, "Tools")
        XCTAssertEqual(store.surfaceTabBarButtons.last?.menu?.map(\.action), [.builtIn(.vaultPane)])
    }

    @Test func testProjectLocalSurfaceTabBarButtonsOverrideGlobalButtons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let localDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let localConfigURL = localDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": ["cmux.newTerminal", "cmux.newBrowser"]
            }
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": ["cmux.splitRight"]
            }
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.surfaceTabBarButtonSourcePath, localConfigURL.path)
        XCTAssertEqual(store.surfaceTabBarButtons.map(\.action.builtInActionReference), [
            .splitRight,
            .more,
        ])
    }

    @Test func testMenuSurfaceTabBarButtonActivatesOnMouseDown() throws {
        let button = CmuxSurfaceTabBarButton(
            id: CmuxSurfaceTabBarBuiltInAction.more.configID,
            action: .builtIn(.more),
            menu: [.actionReference(CmuxSurfaceTabBarBuiltInAction.vaultPane.configID)]
        )

        let bonsplitButton = button.bonsplitActionButton(
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux.json"
        )

        XCTAssertTrue(bonsplitButton.activatesOnMouseDown)
    }

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

    @Test func testDecodeActionIconObjectsSupportAllFormats() throws {
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "id": "emoji", "icon": { "type": "emoji", "value": "🤖", "scale": 0.85 }, "command": "codex" },
                { "id": "svg", "icon": { "type": "image", "path": "./icons/codex.svg" }, "command": "codex" },
                { "id": "jpeg", "icon": { "type": "image", "path": "./icons/claude.jpg" }, "command": "claude" },
                { "id": "pdf", "icon": { "type": "image", "path": "./icons/logo.pdf" }, "command": "open ." },
                { "id": "bmp", "icon": { "type": "image", "path": "./icons/logo.bmp" }, "command": "open ." },
                { "id": "heif", "icon": { "type": "image", "path": "./icons/logo.heif" }, "command": "open ." },
                { "id": "avif", "icon": { "type": "image", "path": "./icons/logo.avif" }, "command": "open ." },
                { "id": "ico", "icon": { "type": "image", "path": "./icons/logo.ico" }, "command": "open ." }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons?[0].icon, .emoji("🤖", scale: 0.85))
        XCTAssertEqual(config.surfaceTabBarButtons?[1].icon, .imagePath("./icons/codex.svg"))
        XCTAssertEqual(config.surfaceTabBarButtons?[2].icon, .imagePath("./icons/claude.jpg"))
        XCTAssertEqual(config.surfaceTabBarButtons?[3].icon, .imagePath("./icons/logo.pdf"))
        XCTAssertEqual(config.surfaceTabBarButtons?[4].icon, .imagePath("./icons/logo.bmp"))
        XCTAssertEqual(config.surfaceTabBarButtons?[5].icon, .imagePath("./icons/logo.heif"))
        XCTAssertEqual(config.surfaceTabBarButtons?[6].icon, .imagePath("./icons/logo.avif"))
        XCTAssertEqual(config.surfaceTabBarButtons?[7].icon, .imagePath("./icons/logo.ico"))
    }

    @Test func testDecodeStringIconThrows() {
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "command": "codex",
              "icon": "sparkles"
            }
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testGlobalSVGIconAllowsNamespaceAndInternalGradient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let iconsDirectory = root.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configPath = root.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("codex.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <defs>
            <linearGradient id="grad">
              <stop offset="0%" stop-color="#000"/>
              <stop offset="100%" stop-color="#fff"/>
            </linearGradient>
          </defs>
          <rect width="24" height="24" fill="url(#grad)"/>
        </svg>
        """
        let data = Data(svg.utf8)
        try data.write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/codex.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: configPath,
                globalConfigPath: configPath
            ),
            .imageData(data)
        )
    }

    @Test func testProjectLocalSVGIconRejectsExternalReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("bad.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <image href="https://example.com/icon.png" width="24" height="24"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/bad.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath
            ),
            .systemImage("questionmark.circle")
        )
    }

    @Test func testUntrustedProjectLocalIconUsesLockPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("safe.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/safe.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: false
            ),
            .systemImage("lock.fill")
        )
    }

    @Test func testInlineSurfaceButtonIconUsesTabBarConfigSourceForTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("safe.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let button = CmuxSurfaceTabBarButton(
            id: "inline-local",
            icon: .imagePath("icons/safe.svg"),
            action: .command("echo inline")
        )
        XCTAssertFalse(
            CmuxConfigExecutor.isTrustedSurfaceButton(
                button,
                workspaceCommand: nil,
                terminalCommandSourcePath: nil,
                surfaceTabBarConfigSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath
            )
        )
    }

    @Test func testDecodeNewWorkspaceAction() throws {
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

    @Test func testDecodeActionShortcutString() throws {
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

    @Test func testDecodeActionShortcutChord() throws {
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

    @Test func testInvalidConfigExposesSchemaIssueAndClearsAfterFix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let invalidJSON = """
        {
          "actions": {
            "bad": {
              "type": "command",
              "command": "echo bad",
              "icon": "sparkles"
            }
          }
        }
        """
        try invalidJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let issue = try XCTUnwrap(store.configurationIssues.first)
        XCTAssertEqual(issue.kind, .schemaError)
        XCTAssertEqual(issue.sourcePath, configURL.path)
        XCTAssertTrue(issue.message?.contains("actions.bad.icon") ?? false)
        XCTAssertNil(store.resolvedAction(id: "bad"))

        let validJSON = """
        {
          "actions": {
            "bad": {
              "type": "command",
              "command": "echo bad",
              "icon": { "type": "symbol", "name": "sparkles" }
            }
          }
        }
        """
        try validJSON.write(to: configURL, atomically: true, encoding: .utf8)
        store.loadAll()

        XCTAssertTrue(store.configurationIssues.isEmpty)
        XCTAssertNotNil(store.resolvedAction(id: "bad"))
    }

    @Test func testConfigChangesRequireExplicitLoadByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "echo first" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path)
        store.loadAll()
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertNil(store.resolvedAction(id: "second"))

        try """
        {
          "actions": {
            "second": { "type": "command", "command": "echo second" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        // cmux.json must not hot reload without an explicit loadAll(): drain the
        // main actor + run loop (a watcher delivers through them), then assert.
        for _ in 0..<8 { await Task.yield() }
        RunLoop.main.run(until: Date())
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertNil(store.resolvedAction(id: "second"))

        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "first"))
        XCTAssertNotNil(store.resolvedAction(id: "second"))
    }

    @Test func testConfigStoreParsesGlobalCmuxJSONCSettingsAndActionSections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let data = """
        {
          // cmux-owned app settings share the global cmux.json file.
          "app": {
            "appearance": "dark",
          },
          "actions": {
            "first": {
              "type": "workspaceCommand",
              "commandName": "Dev",
            },
          },
          "ui": { "newWorkspace": { "action": "first" } },
          "commands": [{ "name": "Dev", "workspace": { "name": "Dev" } }],
        }
        """.data(using: .utf16LittleEndian)!
        try data.write(to: configURL)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        XCTAssertTrue(store.configurationIssues.isEmpty)
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertEqual(store.newWorkspaceActionID, "first")
        XCTAssertEqual(store.loadedCommands.map(\.name), ["Dev"])
    }

    @Test func testConfigStoreReportsJSONCPreprocessingErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try "{\n/* missing close\n\"actions\": {}\n}".write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        let issue = try XCTUnwrap(store.configurationIssues.first)
        XCTAssertEqual(issue.kind, .schemaError)
        XCTAssertEqual(issue.message, "JSONC preprocessing failed: unterminated block comment")
    }

    @Test func testLocalWatcherDetectsFirstCanonicalConfigAfterDirectoryCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: true
        )
        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "created"))

        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "actions": {
            "created": { "type": "command", "command": "echo created" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        // The store uses a DispatchSource vnode watcher (plus a fallback directory
        // watcher) to observe the .cmux directory creation, re-arm onto the new
        // cmux.json, reload, and republish loadedActions. vnode notification +
        // re-arm + reload latency is nondeterministic under CI I/O load, so use a
        // generous deadline; polling stops as soon as the watcher has reloaded.
        let deadline = Date().addingTimeInterval(15)
        while store.resolvedAction(id: "created") == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(store.resolvedAction(id: "created"), "created local cmux config is loaded")
    }

    @Test func testLocalWatcherDetectsFirstLegacyConfigWhenCmuxDirectoryExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonicalConfigURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let legacyConfigURL = projectDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: canonicalConfigURL.path,
            startFileWatchers: true
        )
        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "legacy-created"))

        try """
        {
          "actions": {
            "legacy-created": { "type": "command", "command": "echo created" }
          }
        }
        """.write(to: legacyConfigURL, atomically: true, encoding: .utf8)

        // The store observes the legacy cmux.json write via a DispatchSource vnode
        // watcher, then reloads and republishes loadedActions. Filesystem
        // notification + reload latency is nondeterministic under CI I/O load, so
        // use a generous deadline; polling stops the moment the watcher has reloaded.
        let deadline = Date().addingTimeInterval(15)
        while store.resolvedAction(id: "legacy-created") == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(store.resolvedAction(id: "legacy-created"), "created legacy cmux config is loaded")
    }

    @Test func testResolvedNewWorkspaceCommandReturnsConfiguredWorkspaceCommand() throws {
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

    @Test func testGlobalNewWorkspaceActionUsesLocalActionOverride() throws {
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

    @Test func testNotificationHooksAppendThroughConfigHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let parentConfigDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parentConfigDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let parentConfigURL = parentConfigDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "parent", "command": "cat" }]
          }
        }
        """.write(to: parentConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "child", "command": "cat", "enabled": false }, { "id": "nearest", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: childConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["global", "parent", "nearest"])
        XCTAssertNil(store.notificationHooks[0].trustDescriptor)
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.kind, "notificationHook")
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.command, "cat")
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.configPath, parentConfigURL.path)
        XCTAssertEqual(store.notificationHooks[2].trustDescriptor?.kind, "notificationHook")
        XCTAssertEqual(store.notificationHooks[1].cwd, projectDirectory.path)
        XCTAssertEqual(store.notificationHooks[2].cwd, childDirectory.path)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @Test func testNotificationHooksIncludeExplicitLocalConfigOutsideDiscoveredHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let explicitDirectory = root.appendingPathComponent("explicit", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: explicitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let explicitConfigURL = explicitDirectory.appendingPathComponent("custom-cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "explicit", "command": "cat" }]
          }
        }
        """.write(to: explicitConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: explicitConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["global", "explicit"])
        XCTAssertEqual(store.notificationHooks[1].sourcePath, explicitConfigURL.path)
    }

    @Test func testNotificationHooksReplaceInheritedHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childConfigDirectory = projectDirectory
            .appendingPathComponent("child", isDirectory: true)
            .appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooksMode": "replace",
            "hooks": [{ "id": "child", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: childConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["child"])
    }

    @Test func testNotificationHooksResolveFromExplicitWorkspaceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "child", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            startFileWatchers: false
        )

        XCTAssertEqual(
            store.notificationHooks(startingFrom: childDirectory.path).map(\.id),
            ["global", "child"]
        )
    }

    @Test func testResolvedNewWorkspaceCommandExposesMissingCommandIssue() throws {
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

    @Test func testResolvedNewWorkspaceCommandExposesNonWorkspaceIssue() throws {
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

    @Test func testResolvedNewWorkspaceActionAllowsCommandAction() throws {
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

    @Test func testDecodeEmptySurfaceTabBarButtons() throws {
        let json = """
        {
          "surfaceTabBarButtons": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons, [])
        XCTAssertTrue(config.commands.isEmpty)
    }

    @Test func testDecodeEmptyCommandsArray() throws {
        let json = """
        { "commands": [] }
        """
        let config = try decode(json)
        XCTAssertTrue(config.commands.isEmpty)
    }

    // MARK: Workspace commands

    @Test func testDecodeWorkspaceCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "cwd": "~/projects/app",
              "color": "#FF5733"
            }
          }]
        }
        """
        let config = try decode(json)
        let ws = config.commands[0].workspace
        XCTAssertNotNil(ws)
        XCTAssertEqual(ws?.name, "Development")
        XCTAssertEqual(ws?.cwd, "~/projects/app")
        XCTAssertEqual(ws?.color, "#FF5733")
    }

    @Test func testDecodeRestartBehaviors() throws {
        for behavior in ["new", "recreate", "ignore", "confirm"] {
            let json = """
            {
              "commands": [{
                "name": "test",
                "restart": "\(behavior)",
                "workspace": { "name": "ws" }
              }]
            }
            """
            let config = try decode(json)
            XCTAssertEqual(config.commands[0].restart?.rawValue, behavior)
        }
    }

    // MARK: Layout tree

    @Test func testDecodePaneNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .pane(let pane) = layout {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].type, .terminal)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node")
        }
    }

    @Test func testDecodeSplitNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "split": 0.3,
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let split) = layout {
            XCTAssertEqual(split.direction, .horizontal)
            XCTAssertEqual(split.split, 0.3)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node")
        }
    }

    @Test func testDecodeNestedSplits() throws {
        let json = """
        {
          "commands": [{
            "name": "nested",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  {
                    "direction": "vertical",
                    "children": [
                      { "pane": { "surfaces": [{ "type": "terminal" }] } },
                      { "pane": { "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] } }
                    ]
                  }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let outer) = layout {
            XCTAssertEqual(outer.direction, .horizontal)
            if case .split(let inner) = outer.children[1] {
                XCTAssertEqual(inner.direction, .vertical)
                if case .pane(let browserPane) = inner.children[1] {
                    XCTAssertEqual(browserPane.surfaces[0].type, .browser)
                    XCTAssertEqual(browserPane.surfaces[0].url, "http://localhost:3000")
                } else {
                    XCTFail("Expected pane node for inner second child")
                }
            } else {
                XCTFail("Expected split node for outer second child")
            }
        } else {
            XCTFail("Expected split node")
        }
    }

    // MARK: Surface definitions

    @Test func testDecodeTerminalSurfaceAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "terminal",
                    "name": "server",
                    "command": "npm start",
                    "cwd": "./backend",
                    "env": { "NODE_ENV": "development", "PORT": "3000" },
                    "focus": true
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let surface = config.commands[0].workspace!.layout!
        if case .pane(let pane) = surface {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .terminal)
            XCTAssertEqual(s.name, "server")
            XCTAssertEqual(s.command, "npm start")
            XCTAssertEqual(s.cwd, "./backend")
            XCTAssertEqual(s.env, ["NODE_ENV": "development", "PORT": "3000"])
            XCTAssertEqual(s.focus, true)
            XCTAssertNil(s.url)
        } else {
            XCTFail("Expected pane node")
        }
    }

    @Test func testDecodeBrowserSurface() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "browser",
                    "name": "Preview",
                    "url": "http://localhost:8080"
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .browser)
            XCTAssertEqual(s.url, "http://localhost:8080")
        } else {
            XCTFail("Expected pane node")
        }
    }

    @Test func testDecodeMultipleSurfacesInPane() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell1" },
                    { "type": "terminal", "name": "shell2" },
                    { "type": "browser", "name": "web" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            XCTAssertEqual(pane.surfaces.count, 3)
            XCTAssertEqual(pane.surfaces.map(\.name), ["shell1", "shell2", "web"])
        } else {
            XCTFail("Expected pane node")
        }
    }

    // MARK: Decoding errors

    @Test func testDecodeInvalidLayoutNodeThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad",
            "workspace": {
              "layout": { "invalid": true }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeMissingCommandsKeyAllowsActionOnlyConfig() throws {
        let json = """
        {
          "actions": {
            "start-codex": { "type": "agent", "agent": "codex" }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "start-codex", "icon": { "type": "symbol", "name": "sparkles" } }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        XCTAssertTrue(config.commands.isEmpty)
        let rawButton = try XCTUnwrap(config.surfaceTabBarButtons?.first)
        let button = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        XCTAssertEqual(button.terminalCommand, "codex")
    }

    @Test func testDecodeInvalidSurfaceTypeThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{ "type": "invalidType" }]
                }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Command validation

    @Test func testDecodeCommandWithNeitherWorkspaceNorCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeCommandWithBothWorkspaceAndCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "hybrid",
            "command": "echo hi",
            "workspace": { "name": "ws" }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Layout validation

    @Test func testDecodeLayoutNodeWithBothPaneAndDirectionThrows() {
        let json = """
        {
          "commands": [{
            "name": "ambiguous",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [{ "type": "terminal" }] },
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeSplitWithWrongChildrenCountThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeSplitWithThreeChildrenThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "vertical",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodePaneWithEmptySurfacesThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty-pane",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [] }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeBlankNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeWhitespaceOnlyNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "   ",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeBlankCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": ""
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeWhitespaceOnlyCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": "   "
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeBlankNewWorkspaceCommandThrows() {
        let json = """
        {
          "newWorkspaceCommand": "   ",
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeDuplicateSurfaceTabBarButtonsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": ["newTerminal", "newTerminal"],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeDuplicateSurfaceTabBarButtonIdsThrows() {
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

    @Test func testDecodeDuplicateSurfaceTabBarMenuItemIdsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "tools",
              "type": "menu",
              "menu": [
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
              ]
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeSurfaceTabBarMenuItemCannotReuseTopLevelId() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "play" },
              "command": "npm run dev"
            },
            {
              "id": "tools",
              "type": "menu",
              "menu": [
                {
                  "id": "run",
                  "icon": { "type": "symbol", "name": "checkmark" },
                  "command": "npm test"
                }
              ]
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }
}

// MARK: - Command identity

@MainActor
@Suite(.serialized)
struct CmuxCommandIdentityTests {

    @Test func testCommandIdIsDeterministic() {
        let cmd = CmuxCommandDefinition(name: "Run tests", command: "test")
        XCTAssertEqual(cmd.id, "cmux.config.command.Run%20tests")
    }

    @Test func testCommandIdEncodesSpecialCharacters() {
        let cmd = CmuxCommandDefinition(name: "build & deploy", command: "make")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertFalse(cmd.id.contains("&"))
        XCTAssertFalse(cmd.id.contains(" "))
    }

    @Test func testCommandIdIsUniqueForDifferentNames() {
        let cmd1 = CmuxCommandDefinition(name: "build", command: "make build")
        let cmd2 = CmuxCommandDefinition(name: "test", command: "make test")
        XCTAssertNotEqual(cmd1.id, cmd2.id)
    }

    @Test func testCommandIdDoesNotCollideWithBuiltinPrefix() {
        let cmd = CmuxCommandDefinition(name: "palette.newWorkspace", command: "echo")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertNotEqual(cmd.id, "palette.newWorkspace")
    }
}

// MARK: - Workspace command execution

@MainActor
@Suite(.serialized)
struct CmuxConfigWorkspaceCommandExecutionTests {

    @Test func testWorkspaceCommandCreatesNewWorkspaceByDefaultWhenNameAlreadyExists() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.tabs.filter { $0.customTitle == "Dev" }.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }

    @Test func testWorkspaceCommandHonorsExplicitNewRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .new,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.tabs.filter { $0.customTitle == "Dev" }.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }

    @Test func testWorkspaceCommandHonorsIgnoreRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .ignore,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.map(\.id), [existingWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspace?.id, existingWorkspace.id)
    }

    @Test func testWorkspaceCommandHonorsRecreateRestartPolicy() {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev")

        let command = CmuxCommandDefinition(
            name: "Dev command",
            restart: .recreate,
            workspace: CmuxWorkspaceDefinition(name: "Dev")
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == existingWorkspace.id }))
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Dev")
    }
}

// MARK: - Split clamping

@MainActor
@Suite(.serialized)
struct CmuxSplitDefinitionTests {

    @Test func testClampedSplitPositionDefaultsToHalf() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.5)
    }

    @Test func testClampedSplitPositionPassesThroughValidValue() {
        let split = CmuxSplitDefinition(direction: .vertical, split: 0.3, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.3, accuracy: 0.001)
    }

    @Test func testClampedSplitPositionClampsLow() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 0.01, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    @Test func testClampedSplitPositionClampsHigh() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 0.99, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    @Test func testClampedSplitPositionClampsNegative() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: -1.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    @Test func testClampedSplitPositionClampsAboveOne() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 2.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    @Test func testSplitOrientationHorizontal() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .horizontal)
    }

    @Test func testSplitOrientationVertical() {
        let split = CmuxSplitDefinition(direction: .vertical, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .vertical)
    }
}

// MARK: - CWD resolution

@MainActor
@Suite(.serialized)
struct CmuxConfigCwdResolutionTests {

    private let baseCwd = "/Users/test/project"

    @Test func testNilCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd(nil, relativeTo: baseCwd),
            baseCwd
        )
    }

    @Test func testEmptyCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("", relativeTo: baseCwd),
            baseCwd
        )
    }

    @Test func testDotCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd(".", relativeTo: baseCwd),
            baseCwd
        )
    }

    @Test func testAbsolutePathReturnedAsIs() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("/tmp/other", relativeTo: baseCwd),
            "/tmp/other"
        )
    }

    @Test func testRelativePathJoinedToBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("backend/src", relativeTo: baseCwd),
            "/Users/test/project/backend/src"
        )
    }

    @Test func testTildeExpandsToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("~", relativeTo: baseCwd),
            home
        )
    }

    @Test func testTildeSlashExpandsToHomePlusPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("~/Documents/work", relativeTo: baseCwd),
            (home as NSString).appendingPathComponent("Documents/work")
        )
    }

    @Test func testSingleSubdirectory() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("src", relativeTo: baseCwd),
            "/Users/test/project/src"
        )
    }
}

// MARK: - Layout encoding round-trip

@MainActor
@Suite(.serialized)
struct CmuxLayoutEncodingTests {

    @Test func testPaneNodeRoundTrips() throws {
        let original = CmuxLayoutNode.pane(CmuxPaneDefinition(surfaces: [
            CmuxSurfaceDefinition(type: .terminal, name: "shell")
        ]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .pane(let pane) = decoded {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node after round-trip")
        }
    }

    @Test func testSplitNodeRoundTrips() throws {
        let original = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .vertical,
            split: 0.7,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal)])),
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .browser, url: "http://localhost")]))
            ]
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .split(let split) = decoded {
            XCTAssertEqual(split.direction, .vertical)
            XCTAssertEqual(split.split, 0.7)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node after round-trip")
        }
    }
}
