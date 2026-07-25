import AppKit
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandClickHTMLOpenRoutingTests {
    @Test
    func htmlPathOpensInBrowserInsteadOfFilePreview() throws {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = defaults.object(forKey: supportedFilesKey)
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            restore(previousSupportedFiles, forKey: supportedFilesKey, in: defaults)
            restore(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey, in: defaults)
        }
        defaults.set(true, forKey: supportedFilesKey)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>cmux test</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(browser.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(!workspace.panels.values.contains { panel in
            guard let preview = panel as? FilePreviewPanel else { return false }
            return URL(fileURLWithPath: preview.filePath).standardizedFileURL == htmlURL.standardizedFileURL
        })
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
