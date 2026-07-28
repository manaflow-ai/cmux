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

        func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
            nil
        }

        func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
            isRemote
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

        func openOrFocusTerminalBrowserFileLink(url: URL, sourcePanelId: UUID) -> Bool {
            browserURLs.append(url)
            return true
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "terminal-link-open-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
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

    @Test("Dock terminal HTML links open in the cmux Browser")
    @MainActor
    func dockHTMLLinkOpensInBrowser() throws {
        let defaults = makeDefaults()
        let standardDefaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = standardDefaults.object(forKey: supportedFilesKey)
        defer {
            if let previousSupportedFiles {
                standardDefaults.set(previousSupportedFiles, forKey: supportedFilesKey)
            } else {
                standardDefaults.removeObject(forKey: supportedFilesKey)
            }
        }
        standardDefaults.set(true, forKey: supportedFilesKey)

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
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>dock HTML</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

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
        #expect(externallyOpened.isEmpty)
    }

    @Test("Deferred HTML routing revalidates remote state")
    @MainActor
    func deferredHTMLRouteRejectsRemoteTerminal() throws {
        let defaults = makeDefaults()
        let standardDefaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = standardDefaults.object(forKey: supportedFilesKey)
        defer {
            if let previousSupportedFiles {
                standardDefaults.set(previousSupportedFiles, forKey: supportedFilesKey)
            } else {
                standardDefaults.removeObject(forKey: supportedFilesKey)
            }
        }
        standardDefaults.set(true, forKey: supportedFilesKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>remote transition</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

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
        let standardDefaults = UserDefaults.standard
        let supportedFilesKey = AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        let previousSupportedFiles = standardDefaults.object(forKey: supportedFilesKey)
        defer {
            if let previousSupportedFiles {
                standardDefaults.set(previousSupportedFiles, forKey: supportedFilesKey)
            } else {
                standardDefaults.removeObject(forKey: supportedFilesKey)
            }
        }
        standardDefaults.set(true, forKey: supportedFilesKey)

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = fixtureDirectory.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "<!doctype html><title>deleted target</title>".write(
            to: htmlURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

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
}
