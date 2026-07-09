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
struct CmuxConfigSurfaceTabBarMenuTests {
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
                CmuxSurfaceTabBarBuiltInAction.newNote.configID,
                CmuxSurfaceTabBarBuiltInAction.filesPane.configID,
                CmuxSurfaceTabBarBuiltInAction.findPane.configID,
                CmuxSurfaceTabBarBuiltInAction.vaultPane.configID,
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
                CmuxSurfaceTabBarBuiltInAction.newNote.configID,
                CmuxSurfaceTabBarBuiltInAction.filesPane.configID,
                CmuxSurfaceTabBarBuiltInAction.findPane.configID,
                CmuxSurfaceTabBarBuiltInAction.vaultPane.configID,
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

}
