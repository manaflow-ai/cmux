import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalControllerSocketSecurityTests {
    @Test func sidebarContributionsPreserveWorkspaceProviderAndPaneCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-contributions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"Text("Contribution content")"#.write(
            to: directory.appendingPathComponent("demo.swift"), atomically: true, encoding: .utf8
        )

        let defaults = UserDefaults.standard
        let keys = [
            "customSidebars.beta.enabled", CmuxExtensionSidebarSelection.defaultsKey,
            "rightSidebar.mode", "rightSidebar.customSidebarName", "fileExplorer.isVisible"
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "customSidebars.beta.enabled")
        defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)

        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let tabManager = TabManager()
        let state = FileExplorerState()
        let windowID = UUID()
        app.fileExplorerState = state
        app.registerMainWindowContextForTesting(
            windowId: windowID, tabManager: tabManager, fileExplorerState: state
        )
        defer { app.unregisterMainWindowContextForTesting(windowId: windowID) }
        state.mode = .files
        state.setVisible(false)
        let initialWorkspace = tabManager.selectedTabId
        let initialPanels = tabManager.tabs.map { Set($0.panels.keys) }

        try CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            for (id, placement) in [
                ("plugin.example.right", "right-tab"),
                ("plugin.example.left", "workspace-header")
            ] {
                let response = try contributionRPC("sidebar.contribution.register", params: [
                    "id": id, "placement": placement, "name": "demo",
                    "title": "Example", "symbol": "puzzlepiece.extension", "height": 96
                ])
                try #require(response["ok"] as? Bool == true, "Registration failed: \(response)")
            }
            #expect(!state.isVisible, "Registration must not open the right sidebar")
            #expect(tabManager.selectedTabId == initialWorkspace)
            #expect(defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
                == CmuxExtensionSidebarSelection.defaultProviderId)

            let selected = TerminalController.shared.handleSocketLine(
                "right_sidebar set plugin.example.right --no-focus"
            )
            #expect(selected == "OK")
            #expect(state.isVisible)
            #expect(state.rightSidebarRemoteModeRawValue == "plugin.example.right")
            #expect(tabManager.tabs.map { Set($0.panels.keys) } == initialPanels)
            #expect(tabManager.selectedTabId == initialWorkspace)

            #expect(TerminalController.shared.handleSocketLine("right_sidebar set find --no-focus") == "OK")
            #expect(state.mode == .find)
            #expect(TerminalController.shared.handleSocketLine(
                "right_sidebar set plugin.example.right --no-focus"
            ) == "OK")

            let removed = try contributionRPC("sidebar.contribution.remove", params: ["id": "plugin.example.right"])
            #expect(removed["ok"] as? Bool == true)
            #expect(state.mode == .files, "Removing the selected tab must restore a built-in panel")
            #expect(TerminalController.shared.handleSocketLine(
                "right_sidebar set plugin.example.right --no-focus"
            ).hasPrefix("ERROR:"))
            #expect(defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
                == CmuxExtensionSidebarSelection.defaultProviderId)
            #expect(tabManager.tabs.map { Set($0.panels.keys) } == initialPanels)
        }
    }

    private func contributionRPC(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        let request = try #require(String(data: data, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }
}
