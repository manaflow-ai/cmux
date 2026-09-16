import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the production workspace and Dock adapters with isolated link settings.
@MainActor
final class TerminalLinkPlacementFixture {
    let workspace: Workspace?
    let dock: DockSplitStore?
    let sourceID: UUID
    let sourcePane: PaneID
    let defaults: UserDefaults
    let suiteName = "terminal-link-placement-\(UUID().uuidString)"
    var externallyOpened: [URL] = []

    init(inDock: Bool, placement: String?) throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        if let placement { defaults.set(placement, forKey: "browserTerminalLinkBrowserPlacement") }
        if inDock {
            let store = DockSplitStore(
                workspaceId: UUID(),
                baseDirectoryProvider: { FileManager.default.temporaryDirectory.path },
                browserAvailabilityProvider: { true }
            )
            dock = store
            workspace = nil
            sourcePane = try #require(store.bonsplitController.allPaneIds.first)
            sourceID = try #require(store.newSurface(kind: .terminal, inPane: sourcePane, focus: true))
        } else {
            let store = Workspace()
            workspace = store
            dock = nil
            sourceID = try #require(store.focusedPanelId)
            sourcePane = try #require(store.paneId(forPanelId: sourceID))
        }
    }

    var container: any TerminalLinkOpenContainer {
        if let workspace { return workspace }
        return dock!
    }

    var panes: [PaneID] {
        workspace?.bonsplitController.allPaneIds ?? dock!.bonsplitController.allPaneIds
    }

    var browserPanels: [BrowserPanel] {
        if let workspace { return workspace.panels.values.compactMap { $0 as? BrowserPanel } }
        return dock!.panels.values.compactMap { $0 as? BrowserPanel }
    }

    var focusedID: UUID? { workspace?.focusedPanelId ?? dock?.focusedPanelId }

    func pane(for panelID: UUID) -> PaneID? {
        workspace?.paneId(forPanelId: panelID) ?? dock?.paneId(forPanelId: panelID)
    }

    func addRightBrowser() throws -> BrowserPanel {
        if let workspace {
            return try #require(workspace.newBrowserSplit(from: sourceID, orientation: .horizontal, url: URL(string: "about:blank")))
        }
        let id = try #require(dock!.newSplit(
            kind: .browser, orientation: .horizontal, insertFirst: false,
            sourcePanelId: sourceID, url: URL(string: "about:blank"), focus: true
        ))
        return try #require(dock!.browserPanel(for: id))
    }

    func open(_ raw: String, sourceID: UUID? = nil) -> Bool {
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { [self] _, _ in container },
            externalOpen: { [self] url in externallyOpened.append(url); return true },
            deferOperation: { operation in operation() }
        )
        return coordinator.open(TerminalLinkOpenRequest(
            rawValue: raw, sourceWorkspaceId: workspace?.id,
            sourcePanelId: sourceID ?? self.sourceID, workingDirectory: nil
        ))
    }

    func close() {
        workspace?.teardownAllPanels()
        dock?.closeAllPanels()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
