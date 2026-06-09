import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Surface tab bar config")
struct SurfaceTabBarConfigTests {
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

    private func temporaryStoreRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Decodes menu buttons and resolves built-in menu aliases")
    func decodeSurfaceTabBarMenuButton() throws {
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
                    "vault",
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
        let rawButton = try #require(config.surfaceTabBarButtons?.first)
        #expect(rawButton.id == "workspace-tools")
        #expect(rawButton.title == "Workspace Tools")
        #expect(rawButton.icon == .symbol("ellipsis.circle"))
        #expect(rawButton.action == .builtIn(.more))

        let rawMenu = try #require(rawButton.menu)
        #expect(rawMenu.count == 3)
        #expect(rawMenu[0].action == .actionReference(CmuxSurfaceTabBarBuiltInAction.vaultPane.configID))
        #expect(rawMenu[1].action == .builtIn(.revealCurrentDirectoryInFinder))
        #expect(rawMenu[2].id == "git-status")
        #expect(rawMenu[2].title == "Git Status")
        #expect(rawMenu[2].terminalCommand == "git status")

        let resolvedButton = try rawButton.resolved(actions: resolvedActions(from: config), codingPath: [])
        #expect(resolvedButton.menu?[0].action == .builtIn(.vaultPane))
        #expect(resolvedButton.menu?[1].action == .builtIn(.revealCurrentDirectoryInFinder))
        #expect(resolvedButton.menu?[2].terminalCommand == "git status")
    }

    @MainActor
    @Test("Default buttons include a populated More menu")
    func defaultSurfaceTabBarButtonsIncludeMoreMenu() throws {
        let root = try temporaryStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            startFileWatchers: false
        )
        store.loadAll()

        #expect(store.surfaceTabBarButtons.map(\.id) == [
            CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
            CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
            CmuxSurfaceTabBarBuiltInAction.splitRight.configID,
            CmuxSurfaceTabBarBuiltInAction.splitDown.configID,
            CmuxSurfaceTabBarBuiltInAction.more.configID,
        ])

        let moreButton = try #require(store.surfaceTabBarButtons.last)
        #expect(moreButton.action == .builtIn(.more))
        #expect(moreButton.menu?.map(\.id) == [
            CmuxSurfaceTabBarBuiltInAction.vaultPane.configID,
            CmuxSurfaceTabBarBuiltInAction.filesPane.configID,
            CmuxSurfaceTabBarBuiltInAction.findPane.configID,
            CmuxSurfaceTabBarBuiltInAction.diffViewer.configID,
            CmuxSurfaceTabBarBuiltInAction.revealCurrentDirectoryInFinder.configID,
            CmuxSurfaceTabBarBuiltInAction.customizeSurfaceTabBar.configID,
        ])
    }

    @MainActor
    @Test("Configured buttons append More")
    func configuredSurfaceTabBarButtonsAppendMoreMenu() throws {
        let root = try temporaryStoreRoot()
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

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        #expect(store.surfaceTabBarButtons.map(\.action.builtInActionReference) == [
            .newTerminal,
            .newBrowser,
            .more,
        ])
        #expect(store.surfaceTabBarButtons.last?.menu?.first?.action == .builtIn(.vaultPane))
    }

    @MainActor
    @Test("Explicit empty buttons stay empty")
    func explicitEmptySurfaceTabBarButtonsStayEmpty() throws {
        let root = try temporaryStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": []
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        #expect(store.surfaceTabBarButtons.isEmpty)
    }

    @MainActor
    @Test("hideMoreButton hides only the resolved More action")
    func surfaceTabBarCanExplicitlyHideMoreMenu() throws {
        let root = try temporaryStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "custom-more": { "type": "command", "command": "echo custom" }
          },
          "ui": {
            "surfaceTabBar": {
              "hideMoreButton": true,
              "buttons": [
                { "action": "newTerminal" },
                { "id": "more", "action": "custom-more" },
                { "action": "newBrowser" }
              ]
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        #expect(store.surfaceTabBarButtons.map(\.id) == [
            CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
            "more",
            CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
        ])
        #expect(store.surfaceTabBarButtons.map(\.action.builtInActionReference) == [
            .newTerminal,
            nil,
            .newBrowser,
        ])
    }

    @MainActor
    @Test("Custom action aliases to More keep the More menu at the end")
    func surfaceTabBarKeepsConfiguredMoreMenuAtEnd() throws {
        let root = try temporaryStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "workspace-tools": {
              "type": "builtin",
              "builtin": "cmux.more",
              "title": "Tools"
            }
          },
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "action": "newTerminal" },
                {
                  "action": "workspace-tools",
                  "menu": ["vault"]
                },
                { "action": "newBrowser" }
              ]
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        #expect(store.surfaceTabBarButtons.map(\.action.builtInActionReference) == [
            .newTerminal,
            .newBrowser,
            .more,
        ])
        #expect(store.surfaceTabBarButtons.last?.title == "Tools")
        #expect(store.surfaceTabBarButtons.last?.menu?.map(\.action) == [.builtIn(.vaultPane)])
    }
}
