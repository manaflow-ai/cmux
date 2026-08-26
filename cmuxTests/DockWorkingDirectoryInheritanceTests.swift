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
    func newSurfaceInheritsSelectedTerminalDirectory() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, root, sourceDirectory in
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
    func newSplitInheritsSourceTerminalDirectory() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, _, sourceDirectory in
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
    func interactiveSplitInheritsOriginalPaneTerminalDirectory() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, _, sourceDirectory in
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
    func disabledInheritanceUsesWorkspaceRoot() async throws {
        try await withDock(inheritanceEnabled: false) { store, rootPane, root, sourceDirectory in
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

    @Test("Live foreground-process directory wins over the Dock terminal startup directory")
    @MainActor
    func liveDirectoryWinsOverRequestedDirectory() async throws {
        var liveDirectory: String?
        let resolver = TerminalWorkingDirectoryResolver(liveDirectoryProvider: { _ in liveDirectory })
        try await withDock(
            inheritanceEnabled: true,
            terminalWorkingDirectoryResolver: resolver
        ) { store, rootPane, root, sourceDirectory in
            _ = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: root.path,
                focus: true
            ))
            liveDirectory = sourceDirectory.path

            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Ghostty PWD report drives Dock terminal inheritance")
    @MainActor
    func reportedDirectoryDrivesNewTerminalInheritance() async throws {
        let resolver = TerminalWorkingDirectoryResolver(liveDirectoryProvider: { _ in nil })
        try await withDock(
            inheritanceEnabled: true,
            terminalWorkingDirectoryResolver: resolver
        ) { store, rootPane, root, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: root.path,
                focus: true
            ))
            let sourcePanel = try terminalPanel(in: store, panelId: sourcePanelId)

            await confirmation("PWD report delivered") { delivered in
                var wasDelivered = false
                let dispatcher = GhosttyCurrentDirectoryActionDispatcher { action in
                    guard action.directory == sourceDirectory.path else { return }
                    wasDelivered = true
                    delivered()
                }
                dispatcher.enqueue(
                    directory: sourceDirectory.path,
                    authoritativeGeometry: nil,
                    surfaceView: sourcePanel.hostedView.surfaceView,
                    terminalSurface: sourcePanel.surface
                )
                for _ in 0..<10 where !wasDelivered {
                    await Task.yield()
                }
            }

            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Ghostty PWD reports preserve path whitespace and reset on empty")
    @MainActor
    func reportedDirectoryPreservesPathWhitespace() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, root, _ in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: root.path,
                focus: true
            ))
            let sourcePanel = try terminalPanel(in: store, panelId: sourcePanelId)
            let reportedDirectory = root.appending(path: "Reported Directory ", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: reportedDirectory, withIntermediateDirectories: true)

            sourcePanel.surface.recordReportedWorkingDirectory(reportedDirectory.path)

            #expect(sourcePanel.surface.reportedWorkingDirectory == reportedDirectory.path)
            let newPanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                sourcePanelId: sourcePanelId,
                focus: true
            ))
            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == reportedDirectory.path)

            sourcePanel.surface.recordReportedWorkingDirectory("")

            #expect(sourcePanel.surface.reportedWorkingDirectory == nil)
            let fallbackPanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                sourcePanelId: sourcePanelId,
                focus: true
            ))
            #expect(try terminalPanel(in: store, panelId: fallbackPanelId).requestedWorkingDirectory == root.path)
        }
    }

    @Test("Dock PWD cache invalidates across a workspace round trip")
    @MainActor
    func dockReportInvalidatesAcrossWorkspaceRoundTrip() async throws {
        let resolver = TerminalWorkingDirectoryResolver(liveDirectoryProvider: { _ in nil })
        try await withDock(
            inheritanceEnabled: true,
            terminalWorkingDirectoryResolver: resolver
        ) { store, rootPane, root, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))
            let sourcePanel = try terminalPanel(in: store, panelId: sourcePanelId)
            sourcePanel.surface.recordReportedWorkingDirectory(root.path)
            #expect(sourcePanel.surface.reportedWorkingDirectory == root.path)

            sourcePanel.surface.setFocusPlacement(.workspace)
            defer { sourcePanel.surface.setFocusPlacement(.rightSidebarDock) }
            #expect(sourcePanel.surface.reportedWorkingDirectory == nil)

            await confirmation("workspace PWD report delivered") { delivered in
                var wasDelivered = false
                let dispatcher = GhosttyCurrentDirectoryActionDispatcher { _ in
                    wasDelivered = true
                    delivered()
                }
                dispatcher.enqueue(
                    directory: root.path,
                    authoritativeGeometry: nil,
                    surfaceView: sourcePanel.hostedView.surfaceView,
                    terminalSurface: sourcePanel.surface
                )
                for _ in 0..<10 where !wasDelivered {
                    await Task.yield()
                }
            }

            #expect(sourcePanel.surface.reportedWorkingDirectory == nil)
            sourcePanel.surface.setFocusPlacement(.rightSidebarDock)
            let newPanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                sourcePanelId: sourcePanelId,
                focus: true
            ))
            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Restored agent live cwd outranks a stale Ghostty report")
    @MainActor
    func restoredAgentLiveDirectoryOutranksStaleReport() async throws {
        var liveDirectory: String?
        let resolver = TerminalWorkingDirectoryResolver(liveDirectoryProvider: { _ in liveDirectory })
        try await withDock(
            inheritanceEnabled: true,
            terminalWorkingDirectoryResolver: resolver
        ) { store, rootPane, root, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: root.path,
                focus: true
            ))
            let sourcePanel = try terminalPanel(in: store, panelId: sourcePanelId)
            sourcePanel.surface.recordReportedWorkingDirectory(root.path)
            store.restoredAgentLifecycle.setResumeState(
                .autoResumeCommandRunning,
                panelId: sourcePanelId
            )
            liveDirectory = sourceDirectory.path

            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == sourceDirectory.path)
        }
    }

    @Test("Remote Dock directory is not inherited by a new local terminal")
    @MainActor
    func remoteDirectoryDoesNotBecomeLocalStartupDirectory() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, root, sourceDirectory in
            let sourcePanelId = try #require(store.newSurface(
                kind: .terminal,
                inPane: rootPane,
                workingDirectory: sourceDirectory.path,
                focus: true
            ))
            let sourcePanel = try terminalPanel(in: store, panelId: sourcePanelId)
            let remoteDirectory = "/home/cmux/remote-project"
            store.detachedSurfaceTransfersByPanelId[sourcePanelId] = remoteTerminalTransfer(
                panel: sourcePanel,
                sourceWorkspaceId: store.workspaceId,
                directory: remoteDirectory
            )

            #expect(store.terminalLinkWorkingDirectory(for: sourcePanelId) == remoteDirectory)
            let newPanelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))

            #expect(try terminalPanel(in: store, panelId: newPanelId).requestedWorkingDirectory == root.path)
        }
    }

    @Test("Explicit Dock terminal directory overrides inherited directory")
    @MainActor
    func explicitDirectoryOverridesInheritance() async throws {
        try await withDock(inheritanceEnabled: true) { store, rootPane, root, sourceDirectory in
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
        terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver = TerminalWorkingDirectoryResolver(),
        _ body: (DockSplitStore, PaneID, URL, URL) async throws -> Void
    ) async throws {
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
            settings: settings,
            terminalWorkingDirectoryResolver: terminalWorkingDirectoryResolver
        )
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        defer {
            store.closeAllPanels()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        try await body(store, rootPane, root, sourceDirectory)
    }

    @MainActor
    private func terminalPanel(in store: DockSplitStore, panelId: UUID) throws -> TerminalPanel {
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        return try #require(store.panel(for: tabId) as? TerminalPanel)
    }

    @MainActor
    private func remoteTerminalTransfer(
        panel: TerminalPanel,
        sourceWorkspaceId: UUID,
        directory: String
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sessionRestoreSourceWorkspaceId: nil,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: directory,
            directoryIsTrustedRemoteReport: true,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            restoredAgentCompletedGeneration: nil,
            shellActivityState: nil,
            restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            managedAgentResumeBinding: nil,
            agentRuntime: nil,
            agentLifecycleRecords: [:],
            isRemoteTerminal: true,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }
}
