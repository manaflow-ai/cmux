import AppKit
import Foundation
import struct CmuxSettings.BrowserCatalogSection
import struct CmuxSettings.UserDefaultsSettingsClient
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link browser placement", .serialized)
@MainActor
struct TerminalLinkBrowserPlacementTests {
    private var terminalLinkPlacementKey: String {
        BrowserCatalogSection().terminalLinkBrowserPlacement.userDefaultsKey
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "terminal-link-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        defaults.set("samePane", forKey: terminalLinkPlacementKey)
        try body(defaults)
    }

    @Test("Clicked links open tabs in their source pane even when another pane is focused")
    func workspaceUsesSourcePane() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let workspace = Workspace()
            defer { workspace.teardownAllPanels() }
            let source = try #require(workspace.focusedPanelId)
            let sourcePane = try #require(workspace.paneId(forPanelId: source))
            let other = try #require(workspace.newTerminalSplit(from: source, orientation: .horizontal))
            #expect(workspace.paneId(forPanelId: other.id) != sourcePane)
            let originalPanes = workspace.bonsplitController.allPaneIds
            let coordinator = TerminalLinkOpenCoordinator(
                defaults: defaults,
                containerResolver: { _, _ in workspace },
                externalOpen: { _ in Issue.record("Unexpected external open"); return false },
                deferOperation: { $0() }
            )
            for path in ["first", "second"] {
                #expect(coordinator.open(TerminalLinkOpenRequest(
                    rawValue: "https://example.com/\(path)",
                    sourceWorkspaceId: workspace.id,
                    sourcePanelId: source,
                    workingDirectory: nil
                )))
            }
            let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
            #expect(browsers.count == 2)
            #expect(browsers.allSatisfy { workspace.paneId(forPanelId: $0.id) == sourcePane })
            #expect(workspace.bonsplitController.allPaneIds == originalPanes)
            #expect(browsers.contains { $0.id == workspace.focusedPanelId })

            // An explicit split remains a split even with same-pane terminal links.
            let split = try #require(workspace.newBrowserSplit(from: source, orientation: .vertical))
            #expect(workspace.paneId(forPanelId: split.id) != sourcePane)
            #expect(workspace.bonsplitController.allPaneIds.count == originalPanes.count + 1)
        }
    }

    @Test("Dock terminal links use the same placement policy and preserve tab identity routing")
    func dockUsesSourcePane() throws {
        try withDefaults { defaults in
            let dock = DockSplitStore(
                workspaceId: UUID(),
                baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
                browserAvailabilityProvider: { true }
            )
            defer { dock.closeAllPanels() }
            let sourcePane = try #require(dock.bonsplitController.allPaneIds.first)
            let source = try #require(dock.newSurface(kind: .terminal, inPane: sourcePane, focus: true))
            let tabID = try #require(dock.surfaceId(forPanelId: source))
            let coordinator = TerminalLinkOpenCoordinator(
                defaults: defaults,
                containerResolver: { _, _ in dock },
                externalOpen: { _ in Issue.record("Unexpected external open"); return false },
                deferOperation: { $0() }
            )
            #expect(coordinator.open(TerminalLinkOpenRequest(
                rawValue: "https://example.com/dock",
                sourceWorkspaceId: dock.workspaceId,
                sourcePanelId: tabID.uuid,
                workingDirectory: nil
            )))
            let browser = try #require(dock.panels.values.compactMap { $0 as? BrowserPanel }.first)
            #expect(dock.paneId(forPanelId: browser.id) == sourcePane)
            #expect(dock.bonsplitController.allPaneIds.count == 1)
            #expect(dock.focusedPanelId == browser.id)
        }
    }

    @Test("Default and invalid placement retain split-right behavior", arguments: ["split", "invalid", ""])
    func splitFallback(rawValue: String) throws {
        try withDefaults { defaults in
            if rawValue.isEmpty {
                defaults.removeObject(forKey: terminalLinkPlacementKey)
            } else {
                defaults.set(rawValue, forKey: terminalLinkPlacementKey)
            }
            let workspace = Workspace()
            defer { workspace.teardownAllPanels() }
            let source = try #require(workspace.focusedPanelId)
            let coordinator = TerminalLinkOpenCoordinator(
                defaults: defaults,
                containerResolver: { _, _ in workspace },
                externalOpen: { _ in false },
                deferOperation: { $0() }
            )
            #expect(coordinator.open(TerminalLinkOpenRequest(
                rawValue: "https://example.com/split",
                sourceWorkspaceId: workspace.id,
                sourcePanelId: source,
                workingDirectory: nil
            )))
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
        }
    }

    @Test("Settings JSON imports, reloads, and rejects invalid placement")
    func settingsJSONRoundTrip() throws {
        try withDefaults { defaults in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("cmux.json")
            try #"{"browser":{"terminalLinkBrowserPlacement":"samePane"}}"#.write(to: file, atomically: true, encoding: .utf8)
            defaults.removeObject(forKey: "browserTerminalLinkBrowserPlacement")
            let store = CmuxSettingsFileStore(
                primaryPath: file.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                userDefaults: defaults,
                startWatching: false
            )
            #expect(defaults.string(forKey: terminalLinkPlacementKey) == "samePane")
            try #"{"browser":{"terminalLinkBrowserPlacement":"split"}}"#.write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(defaults.string(forKey: terminalLinkPlacementKey) == "split")
            try #"{"browser":{"terminalLinkBrowserPlacement":"samePane"}}"#.write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(defaults.string(forKey: terminalLinkPlacementKey) == "samePane")
            try #"{"browser":{"terminalLinkBrowserPlacement":"invalid"}}"#.write(to: file, atomically: true, encoding: .utf8)
            store.reload()
            #expect(UserDefaultsSettingsClient(defaults: defaults)
                .value(for: BrowserCatalogSection().terminalLinkBrowserPlacement) == .split)
            #expect(defaults.string(forKey: terminalLinkPlacementKey) != "invalid")
        }
    }

    @Test("Socket terminal origin obeys placement while explicit browser open keeps split behavior")
    func socketRespectsTerminalOrigin() throws {
        // `browser.open_split` is the production socket handler and reads
        // UserDefaults.standard, so this integration fixture must temporarily
        // configure the process-wide store. All other tests use an isolated suite.
        let defaults = UserDefaults.standard
        let key = terminalLinkPlacementKey
        let original = defaults.object(forKey: key)
        defaults.set("samePane", forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let fixture = DockSocketLifecycleTests()
        try fixture.withSocketAppContext { _, workspace, _ in
            let source = try #require(workspace.focusedPanelId)
            let sourcePane = try #require(workspace.paneId(forPanelId: source))
            let result = try fixture.v2Result(method: "browser.open_split", params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": source.uuidString,
                "url": "about:blank",
                "terminal_link": true,
                "focus": false,
            ])
            #expect(result["created_split"] as? Bool == false)
            #expect(result["placement_strategy"] as? String == "same_pane")
            #expect(result["pane_id"] as? String == sourcePane.id.uuidString)
            #expect(workspace.bonsplitController.allPaneIds.count == 1)
            #expect(workspace.focusedPanelId == source)

            let explicit = try fixture.v2Result(method: "browser.open_split", params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": source.uuidString,
                "url": "about:blank",
                "focus": false,
            ])
            #expect(explicit["created_split"] as? Bool == true)
            #expect(explicit["placement_strategy"] as? String == "split_right")
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
        }
    }

    @Test("Socket links resolve a Dock tab alias to its owning pane")
    func dockSocketUsesSourceAlias() throws {
        // The socket handler intentionally reads UserDefaults.standard; keep
        // this integration test scoped to one suite and restore the value.
        let defaults = UserDefaults.standard
        let key = terminalLinkPlacementKey
        let original = defaults.object(forKey: key)
        defaults.set("samePane", forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let fixture = DockSocketLifecycleTests()
        try fixture.withSocketAppContext { _, workspace, _ in
            let dock = DockSplitStore(
                workspaceId: workspace.id,
                baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
                browserAvailabilityProvider: { true }
            )
            defer { dock.closeAllPanels() }
            let pane = try #require(dock.bonsplitController.allPaneIds.first)
            let source = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: true))
            let alias = try #require(dock.surfaceId(forPanelId: source))
            #expect(alias.uuid != source)
            let result = try fixture.v2Result(method: "browser.open_split", params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": alias.uuid.uuidString,
                "url": "about:blank",
                "terminal_link": true,
                "focus": false,
            ])
            #expect(result["source_surface_id"] as? String == source.uuidString)
            #expect(result["pane_id"] as? String == pane.id.uuidString)
            #expect(result["placement_strategy"] as? String == "same_pane")
            #expect(dock.bonsplitController.allPaneIds.count == 1)
            #expect(dock.panels.values.contains { $0 is BrowserPanel })
            #expect(!workspace.panels.values.contains { $0 is BrowserPanel })
        }
    }

}
