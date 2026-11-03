import Bonsplit
import CmuxBrowser
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link browser placement", .serialized)
@MainActor
struct TerminalLinkBrowserPlacementTests {
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private static let keys = [
        BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey,
        settingsFileBackupsDefaultsKey,
        importedManagedDefaultsKey
    ]
    private let url = URL(string: "https://example.com")!

    @Test
    func readerDefaultsToSplitAndIgnoresUnknownValues() {
        let suiteName = "TerminalLinkBrowserPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BrowserLinkOpenSettings.terminalLinkBrowserPlacement(defaults: defaults) == .split)
        defaults.set("samePane", forKey: BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey)
        #expect(BrowserLinkOpenSettings.terminalLinkBrowserPlacement(defaults: defaults) == .samePane)
        defaults.set("tab", forKey: BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey)
        #expect(BrowserLinkOpenSettings.terminalLinkBrowserPlacement(defaults: defaults) == .split)
    }

    @Test
    func settingsFileAppliesSamePaneAndRejectsUnknownValues() throws {
        try withStandardDefaultsRestored {
            try loadSettingsFile(#"{ "browser": { "terminalLinkBrowserPlacement": "samePane" } }"#)
            #expect(BrowserLinkOpenSettings.terminalLinkBrowserPlacement() == .samePane)
        }
        try withStandardDefaultsRestored {
            try loadSettingsFile(#"{ "browser": { "terminalLinkBrowserPlacement": "tab" } }"#)
            #expect(UserDefaults.standard.object(forKey: BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey) == nil)
            #expect(BrowserLinkOpenSettings.terminalLinkBrowserPlacement() == .split)
        }
    }

    @Test
    func clickedLinkWithSamePaneAddsTabToTerminalPane() throws {
        try withStandardDefaultsRestored {
            UserDefaults.standard.set("samePane", forKey: BrowserLinkOpenSettings.terminalLinkBrowserPlacementKey)
            let workspace = Workspace()
            let terminalID = try #require(workspace.focusedPanelId)
            let sourcePane = try #require(workspace.paneId(forPanelId: terminalID))

            #expect(workspace.openTerminalBrowserLink(url: url, sourcePanelId: terminalID, focus: false))

            #expect(workspace.bonsplitController.allPaneIds.count == 1)
            let browser = try #require(workspace.panels.values.first { $0 is BrowserPanel })
            #expect(workspace.paneId(forPanelId: browser.id) == sourcePane)
        }
    }

    @Test
    func clickedLinkWithDefaultPlacementStillSplits() throws {
        try withStandardDefaultsRestored {
            let workspace = Workspace()
            let terminalID = try #require(workspace.focusedPanelId)
            let sourcePane = try #require(workspace.paneId(forPanelId: terminalID))

            #expect(workspace.openTerminalBrowserLink(url: url, sourcePanelId: terminalID, focus: false))

            #expect(workspace.bonsplitController.allPaneIds.count == 2)
            let browser = try #require(workspace.panels.values.first { $0 is BrowserPanel })
            #expect(workspace.paneId(forPanelId: browser.id) != sourcePane)
        }
    }

    @Test
    func openSplitWithSamePaneAddsTabToSourcePane() throws {
        let workspace = Workspace()
        let terminalID = try #require(workspace.focusedPanelId)
        let sourcePane = try #require(workspace.paneId(forPanelId: terminalID))

        let placement = try #require(BrowserSplitContainer.workspace(workspace).openBrowser(
            of: terminalID,
            placement: .samePane,
            request: BrowserSplitRequest(
                url: url,
                focus: false,
                preferredProfileID: nil,
                chromeVisibility: .visible,
                transparentBackground: false,
                bypassRemoteProxy: false
            )
        ))

        #expect(placement.strategy == .samePane)
        #expect(!placement.createdSplit)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.paneId(forPanelId: placement.panel.id) == sourcePane)
    }

    private func withStandardDefaultsRestored(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    private func loadSettingsFile(_ contents: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-terminal-link-placement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
    }
}
