import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link open coordinator", .serialized)
struct TerminalLinkOpenCoordinatorTests {
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
}
