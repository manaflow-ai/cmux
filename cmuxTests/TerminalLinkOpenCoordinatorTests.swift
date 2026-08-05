import AppKit
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link open coordinator", .serialized)
struct TerminalLinkOpenCoordinatorTests {
    @MainActor
    private final class MutableTerminalLinkContainer: TerminalLinkOpenContainer {
        var isRemote = false
        var browserURLs: [URL] = []

        var terminalLinkContainerDebugName: String { "test" }

        func terminalLinkContainsPanel(_ sourcePanelId: UUID) -> Bool {
            true
        }

        func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
            nil
        }

        func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
            isRemote
        }

        func terminalLinkSnapshotTerminalPanel(for sourcePanelId: UUID) -> TerminalPanel? {
            nil
        }

        func deferTerminalFileLinkOpen(
            sourcePanelId: UUID,
            filePath: String,
            fallback: @escaping @MainActor @Sendable () -> Void
        ) -> Bool {
            false
        }

        func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
            browserURLs.append(url)
            return true
        }

        func openOrFocusTerminalBrowserFileLink(resolvedURL: URL, sourcePanelId: UUID) -> Bool {
            browserURLs.append(resolvedURL)
            return true
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "terminal-link-open-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        defaults.set(
            true,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )
        return defaults
    }

    @Test("Embedded URL without an owning container falls back externally")
    @MainActor
    func unresolvedSourceFallsBackExternally() throws {
        let defaults = makeDefaults()
        let url = try #require(URL(string: "https://example.com/unresolved"))
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(externallyOpened == [url])
    }

    @Test("Dock terminal links split once, then reuse the right browser pane")
    @MainActor
    func dockEmbeddedLinksReuseThenSplit() throws {
        let defaults = makeDefaults()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == terminalPanelId ? store : nil
            },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: firstURL.absoluteString,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))
        #expect(store.bonsplitController.allPaneIds.count == 2)

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: secondURL.absoluteString,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))
        #expect(store.bonsplitController.allPaneIds.count == 2)

        let browserPanels = store.bonsplitController.allTabIds.compactMap {
            store.panel(for: $0) as? BrowserPanel
        }
        #expect(browserPanels.count == 2)
        #expect(Set(browserPanels.compactMap { $0.preferredURLStringForOmnibar() }) == [
            firstURL.absoluteString,
            secondURL.absoluteString,
        ])
        #expect(externallyOpened.isEmpty)
    }

    @Test(
        "Visible HTML paths open in Browser instead of File Preview",
        arguments: ["html", "htm"]
    )
    @MainActor
    func visibleHTMLPathOpensInBrowser(pathExtension: String) throws {
        _ = NSApplication.shared
        let defaults = makeDefaults()
        let htmlURL = try makeHTMLFixture(pathExtension: pathExtension)
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelId = try #require(workspace.focusedPanelId)

        #expect(CommandClickFileOpenRouter.openInCmux(
            workspace: workspace,
            sourcePanelId: sourcePanelId,
            filePath: htmlURL.path,
            defaults: defaults
        ))

        let browser = try #require(
            workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
        )
        #expect(browser.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(!workspace.panels.values.contains { $0 is FilePreviewPanel })
    }

    @Test("Dock terminal HTML links open in the cmux Browser")
    @MainActor
    func dockHTMLLinkOpensInBrowser() throws {
        let defaults = makeDefaults()

        let remoteWebsiteDataStoreIdentifier = UUID()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            remoteBrowserSettingsProvider: {
                DockRemoteBrowserSettings(
                    proxyEndpoint: nil,
                    bypassRemoteProxy: false,
                    isRemoteWorkspace: true,
                    remoteWebsiteDataStoreIdentifier: remoteWebsiteDataStoreIdentifier,
                    remoteStatus: nil
                )
            },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        let htmlURL = try makeHTMLFixture(pathExtension: "html")
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == terminalPanelId ? store : nil
            },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: htmlURL.path,
            sourceWorkspaceId: nil,
            sourcePanelId: terminalPanelId,
            workingDirectory: nil
        )))

        let browserPanels = store.bonsplitController.allTabIds.compactMap {
            store.panel(for: $0) as? BrowserPanel
        }
        #expect(browserPanels.count == 1)
        #expect(browserPanels.first?.currentURL?.standardizedFileURL == htmlURL.standardizedFileURL)
        #expect(browserPanels.first?.bypassesRemoteWorkspaceProxyForTabDuplication == true)
        if let browser = browserPanels.first {
            #expect(
                browser.webView.configuration.websiteDataStore ===
                    BrowserProfileStore.shared.websiteDataStore(for: browser.profileID)
            )
        }
        #expect(externallyOpened.isEmpty)
    }

    @Test("Dock terminal word fallback snapshots its Dock panel")
    @MainActor
    func dockWordFallbackUsesDockTerminalSnapshot() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        let terminal = try #require(store.panels[terminalPanelId] as? TerminalPanel)

        #expect(
            terminal.hostedView.surfaceView.debugWordPathSnapshotTerminalPanelID()
                == terminalPanelId
        )
    }

    @Test("Dock link-open CWD refreshes from the foreground process")
    @MainActor
    func dockLinkOpenCWDRefreshesFromForegroundProcess() throws {
        var liveDirectoryQueries = 0
        let liveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true },
            terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver(
                liveDirectoryProvider: { _ in
                    liveDirectoryQueries += 1
                    return liveDirectory.path
                }
            )
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        let terminal = try #require(store.panels[terminalPanelId] as? TerminalPanel)
        terminal.surface.recordReportedWorkingDirectory(
            FileManager.default.temporaryDirectory.path
        )

        _ = store.terminalLinkHoverWorkingDirectory(for: terminalPanelId)
        #expect(liveDirectoryQueries == 0)
        #expect(store.terminalLinkWorkingDirectory(for: terminalPanelId) == liveDirectory.path)
        #expect(liveDirectoryQueries == 1)
    }

    @Test("Dock link-open CWD falls back when foreground inspection fails")
    @MainActor
    func dockLinkOpenCWDFallsBackWithoutForegroundDirectory() throws {
        var liveDirectoryQueries = 0
        let reportedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            browserAvailabilityProvider: { true },
            terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver(
                liveDirectoryProvider: { _ in
                    liveDirectoryQueries += 1
                    return nil
                }
            )
        )
        defer { store.closeAllPanels() }

        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let terminalPanelId = try #require(
            store.newSurface(kind: .terminal, inPane: rootPane, focus: true)
        )
        let terminal = try #require(store.panels[terminalPanelId] as? TerminalPanel)
        terminal.surface.recordReportedWorkingDirectory(
            reportedDirectory.path
        )

        #expect(store.terminalLinkWorkingDirectory(for: terminalPanelId) == reportedDirectory.path)
        #expect(liveDirectoryQueries == 1)
    }

    @Test("Deferred HTML routing revalidates remote state")
    @MainActor
    func deferredHTMLRouteRejectsRemoteTerminal() throws {
        let defaults = makeDefaults()
        let htmlURL = try makeHTMLFixture(pathExtension: "html")
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        let sourcePanelId = UUID()
        let container = MutableTerminalLinkContainer()
        var externallyOpened: [URL] = []
        var deferredOperation: (@MainActor @Sendable () -> Void)?
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == sourcePanelId ? container : nil
            },
            externalOpen: { url in
                externallyOpened.append(url)
                return true
            },
            deferOperation: { operation in deferredOperation = operation }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: htmlURL.path,
            sourceWorkspaceId: nil,
            sourcePanelId: sourcePanelId,
            workingDirectory: nil
        )))
        container.isRemote = true
        deferredOperation?()

        #expect(container.browserURLs.isEmpty)
        #expect(externallyOpened == [htmlURL])
    }

    @Test("Deferred HTML routing revalidates file eligibility")
    @MainActor
    func deferredHTMLRouteRejectsDeletedFile() throws {
        let defaults = makeDefaults()
        let htmlURL = try makeHTMLFixture(pathExtension: "html")
        defer { try? FileManager.default.removeItem(at: htmlURL.deletingLastPathComponent()) }

        let sourcePanelId = UUID()
        let container = MutableTerminalLinkContainer()
        var externallyOpened: [URL] = []
        var deferredOperation: (@MainActor @Sendable () -> Void)?
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, panelId in
                panelId == sourcePanelId ? container : nil
            },
            externalOpen: { url in
                externallyOpened.append(url)
                return true
            },
            deferOperation: { operation in deferredOperation = operation }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: htmlURL.path,
            sourceWorkspaceId: nil,
            sourcePanelId: sourcePanelId,
            workingDirectory: nil
        )))
        try FileManager.default.removeItem(at: htmlURL)
        deferredOperation?()

        #expect(container.browserURLs.isEmpty)
        #expect(externallyOpened == [htmlURL])
    }

    private func makeHTMLFixture(pathExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-html-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("index.\(pathExtension)")
        try "<h1>hello</h1><p style=\"color:green\">rendered</p>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        return fileURL
    }
}
