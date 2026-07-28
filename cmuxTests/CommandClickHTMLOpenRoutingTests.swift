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

    @Test
    func repeatedHTMLPathOpenFocusesOneBrowser() throws {
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
        try "<!doctype html><title>single browser</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        for _ in 0..<2 {
            #expect(CommandClickFileOpenRouter.openInCmux(
                workspace: workspace,
                sourcePanelId: sourcePanelId,
                filePath: htmlURL.path
            ))
        }

        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsers.count == 1)
        #expect(workspace.focusedPanelId == browsers.first?.id)
    }

    @Test
    func repeatedHTMLPathOpenReloadsChangedContent() async throws {
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
        try "<!doctype html><title>before regeneration</title>".write(
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
        #expect(await waitForDocumentTitle("before regeneration", in: browser))

        try "<!doctype html><title>after regeneration</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 1)
        #expect(await waitForDocumentTitle("after regeneration", in: browser))
    }

    @Test
    func commandClickedHTMLUsesFileOnlyReadAccess() throws {
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
        try "<!doctype html><title>restricted read access</title>".write(
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
        let readAccessPolicy = Mirror(reflecting: browser).children
            .first(where: { $0.label == "localFileReadAccessPolicy" })
            .map { String(describing: $0.value) }
        #expect(readAccessPolicy == "fileOnly")
    }

    @Test
    func restrictedHTMLNewTabPreservesFileOnlyReadAccess() throws {
        _ = NSApplication.shared

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousShared
        }

        let workspace = try #require(manager.selectedWorkspace)
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>restricted child tab</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: htmlURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))
        browser.openLinkInNewTab(url: htmlURL)

        let browsers = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsers.count == 2)
        #expect(browsers.allSatisfy { $0.localFileReadAccessPolicy == .fileOnly })
    }

    @Test
    func restrictedHTMLPopupContextPreservesFileOnlyReadAccess() throws {
        _ = NSApplication.shared

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ))

        let popupPolicy = Mirror(reflecting: browser.popupBrowserContext).children
            .first(where: { $0.label == "localFileReadAccessPolicy" })
            .map { String(describing: $0.value) }
        #expect(popupPolicy == "fileOnly")
    }

    @Test
    func provisionalNavigationPreventsStaleHTMLBrowserReuse() throws {
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
        try "<!doctype html><title>provisional navigation</title>".write(
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
        let firstBrowser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        firstBrowser.isMainFrameProvisionalNavigationActive = true

        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path
        ))

        #expect(workspace.panels.values.compactMap { $0 as? BrowserPanel }.count == 2)
    }

    @Test
    func htmlSymlinkOpensResolvedTargetInBrowser() throws {
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
        let linkDirectory = fixtureDirectory.appendingPathComponent("link", isDirectory: true)
        let targetDirectory = fixtureDirectory.appendingPathComponent("target", isDirectory: true)
        let targetURL = targetDirectory.appendingPathComponent("page.html")
        let symlinkURL = linkDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>symlink target</title>".write(
            to: targetURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { workspaceId, panelId in
                workspaceId == workspace.id && panelId == sourcePanelId ? workspace : nil
            },
            externalOpen: { url in
                externallyOpened.append(url)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: symlinkURL.path,
            sourceWorkspaceId: workspace.id,
            sourcePanelId: sourcePanelId,
            workingDirectory: nil
        )))

        let browser = try #require(workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(browser.currentURL?.standardizedFileURL == targetURL.standardizedFileURL)
        #expect(externallyOpened.isEmpty)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func waitForDocumentTitle(_ expectedTitle: String, in browser: BrowserPanel) async -> Bool {
        for _ in 0..<100 {
            if let result = try? await browser.webView.evaluateJavaScript("document.title"),
               result as? String == expectedTitle {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
