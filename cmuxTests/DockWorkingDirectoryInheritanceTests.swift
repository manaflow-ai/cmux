import Bonsplit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock working-directory inheritance", .serialized)
struct DockWorkingDirectoryInheritanceTests {
    @Test("New terminal surface inherits the selected Dock terminal directory")
    @MainActor
    func newSurfaceInheritsSelectedTerminalDirectory() throws {
        try withDock(inheritanceEnabled: true) { store, rootPane, root, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))

            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

            #expect(sourcePanelId != newPanelId)
            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory != root.path)
        }
    }

    @Test("Programmatic Dock split inherits its source terminal directory")
    @MainActor
    func newSplitInheritsSourceTerminalDirectory() throws {
        try withDock(inheritanceEnabled: true) { store, rootPane, _, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))

            let newPanelId = try #require(store.newSplit(
                kind: .terminal,
                orientation: .horizontal,
                insertFirst: false,
                sourcePanelId: sourcePanelId,
                focus: true
            ))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Interactive Dock split inherits the original pane terminal directory")
    @MainActor
    func interactiveSplitInheritsOriginalPaneTerminalDirectory() throws {
        try withDock(inheritanceEnabled: true) { store, rootPane, _, sourceDirectory in
            _ = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))

            let newPane = try #require(store.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: nil,
                initialDividerPosition: 0.5
            ))
            let newTabId = try #require(store.bonsplitController.selectedTab(inPane: newPane)?.id)
            let newPanelId = try #require(store.surfaceIdToPanelId[newTabId])

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Disabled inheritance starts new Dock terminals in the workspace root")
    @MainActor
    func disabledInheritanceUsesWorkspaceRoot() throws {
        try withDock(inheritanceEnabled: false) { store, rootPane, root, sourceDirectory in
            _ = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))

            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == root.path)
        }
    }

    @Test("Explicit Dock terminal directory overrides inherited directory")
    @MainActor
    func explicitDirectoryOverridesInheritance() throws {
        try withDock(inheritanceEnabled: true) { store, rootPane, root, sourceDirectory in
            let explicitDirectory = root.appending(path: "Explicit", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: explicitDirectory, withIntermediateDirectories: true)
            _ = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))

            let newPanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: explicitDirectory.path,
                focus: true
            ))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == explicitDirectory.path)
        }
    }

    @MainActor
    private func withDock(
        inheritanceEnabled: Bool,
        _ body: (DockSplitStore, PaneID, URL, URL) throws -> Void
    ) throws {
        let root = URL.temporaryDirectory.appending(
            path: "cmux-dock-cwd-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let sourceDirectory = root.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let suiteName = "DockWorkingDirectoryInheritanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(inheritanceEnabled, for: SettingCatalog().app.workspaceInheritWorkingDirectory)

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            settings: settings
        )
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        defer {
            store.closeAllPanels()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        try body(store, rootPane, root, sourceDirectory)
    }

    @MainActor
    private func terminalPanel(in store: DockSplitStore, panelId: UUID) throws -> TerminalPanel {
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        return try #require(store.panel(for: tabId) as? TerminalPanel)
    }
}
