import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Codex lifecycle-to-tab-title presentation path.
@MainActor
@Suite(.serialized)
struct CodexTabTitlePresentationTests {
    @Test("a running Codex turn decorates the tab without changing its stable title")
    func runningTurnShowsAnimatedMarker() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "◐ some-name")
        #expect(tab.isLoading)
        #expect(workspace.panelTitles[panelId] == "some-name")
    }

    @Test("an idle Codex turn leaves the completion marker on the tab")
    func idleTurnShowsCompletionMarker() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "✳ some-name")
        #expect(!tab.isLoading)
    }

    @Test("a user-owned tab title is never decorated by Codex lifecycle state")
    func customTitleWins() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Pinned lane"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "Pinned lane")
        #expect(tab.isLoading)
    }

    @Test("an auto-generated title still receives Codex lifecycle markers")
    func autoTitleIsNotTreatedAsUserOwned() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(
            workspace.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .auto
            )
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "◐ Generated lane")
        #expect(tab.isLoading)
    }

    @Test("same-text auto-to-user ownership removes the marker but keeps activity")
    func sameTextOwnershipChangeReconcilesPresentation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(
            workspace.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .auto
            )
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ Generated lane")

        #expect(
            workspace.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .user
            )
        )
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "Generated lane")
        #expect(tab.isLoading)
    }

    @Test("a remote tmux mirror clears stale Codex tab presentation state")
    func remoteMirrorDoesNotRetainCodexMarkerOrLoading() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ some-name")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == true)

        // A mirror transition can leave the old local projection in Bonsplit
        // until the next lifecycle/title event. Reconciliation must clear both
        // transient fields when that event arrives.
        workspace.isRemoteTmuxMirror = true
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
    }

    @Test("a remote tmux title event also reconciles stale Codex presentation state")
    func remoteMirrorTitleEventReconcilesPresentation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.isRemoteTmuxMirror = true

        // Mirror title events intentionally do not overwrite the local stable
        // title. They still must clear any transient projection inherited
        // before the workspace became a mirror.
        #expect(!workspace.updatePanelTitle(panelId: panelId, title: "remote-name"))

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
    }

    @Test("another agent lifecycle key does not borrow Codex title markers")
    func nonCodexLifecycleIsIgnored() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panelId,
            lifecycle: .running
        )

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
    }

    @Test("Codex lifecycle presentation survives a Dock round trip")
    func lifecyclePresentationSurvivesDockRoundTrip() throws {
        let source = Workspace()
        let destination = Workspace()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer {
            dock.closeAllPanels()
            source.teardownAllPanels()
            destination.teardownAllPanels()
        }
        let panelId = try #require(source.focusedPanelId)
        let terminal = try #require(source.panels[panelId] as? TerminalPanel)
        terminal.updateTitle("some-name")
        #expect(source.updatePanelTitle(panelId: panelId, title: "some-name"))
        source.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let transfer = try #require(source.detachSurface(panelId: panelId))
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: dockPane, focus: false) == panelId)

        let dockTabId = try #require(dock.surfaceId(forPanelId: panelId))
        let dockTab = try #require(dock.bonsplitController.tab(dockTabId))
        #expect(dockTab.title == "◐ some-name")
        #expect(dockTab.isLoading)

        let roundTripped = try #require(dock.detachSurface(panelId: panelId))
        #expect(roundTripped.title == "some-name")
        #expect(roundTripped.cachedTitle == "some-name")

        let destinationPane = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        #expect(
            destination.attachDetachedSurface(
                roundTripped,
                inPane: destinationPane,
                focus: false
            ) == panelId
        )
        let destinationTabId = try #require(
            destination.surfaceIdFromPanelId(panelId)
        )
        let destinationTab = try #require(
            destination.bonsplitController.tab(destinationTabId)
        )
        #expect(destinationTab.title == "◐ some-name")
        #expect(destinationTab.isLoading)
        #expect(destination.panelTitles[panelId] == "some-name")
    }

    @Test("Dock lifecycle, title, and custom-title changes share one presentation path")
    func dockLifecycleAndTitleChangesReconcilePresentation() throws {
        let source = Workspace()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer {
            dock.closeAllPanels()
            source.teardownAllPanels()
        }
        let panelId = try #require(source.focusedPanelId)
        let terminal = try #require(source.panels[panelId] as? TerminalPanel)
        terminal.updateTitle("first-name")
        #expect(source.updatePanelTitle(panelId: panelId, title: "first-name"))

        let transfer = try #require(source.detachSurface(panelId: panelId))
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: dockPane, focus: false) == panelId)
        let tabId = try #require(dock.surfaceId(forPanelId: panelId))

        dock.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(dock.bonsplitController.tab(tabId)?.title == "◐ first-name")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == true)

        dock.applyResolvedTerminalTitle("second-name", to: terminal)
        #expect(dock.bonsplitController.tab(tabId)?.title == "◐ second-name")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == true)

        #expect(dock.setDockPanelCustomTitle(panelId: panelId, title: "Pinned lane"))
        dock.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        #expect(dock.bonsplitController.tab(tabId)?.title == "Pinned lane")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == false)

        dock.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(dock.bonsplitController.tab(tabId)?.title == "Pinned lane")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == true)

        #expect(dock.clearAgentLifecycle(key: "codex", panelId: panelId))
        #expect(dock.bonsplitController.tab(tabId)?.title == "Pinned lane")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == false)
    }

    @Test(
        "Dock persistence keeps the transferred title before another terminal title arrives",
        arguments: [false, true]
    )
    func dockPersistenceKeepsTransferredTitle(isRemoteTerminal: Bool) throws {
        let source = Workspace()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer {
            dock.closeAllPanels()
            source.teardownAllPanels()
        }
        let panelId = try #require(source.focusedPanelId)
        let terminal = try #require(source.panels[panelId] as? TerminalPanel)
        terminal.updateTitle("runtime-title")
        #expect(
            source.updatePanelTitle(
                panelId: panelId,
                title: "Configured lane"
            )
        )
        if isRemoteTerminal {
            source.activeRemoteTerminalSurfaceIds.insert(panelId)
        }

        let transfer = try #require(source.detachSurface(panelId: panelId))
        #expect(transfer.isRemoteTerminal == isRemoteTerminal)
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPane,
                focus: false
            ) == panelId
        )

        let roundTripped = try #require(
            dock.detachSurface(panelId: panelId)
        )
        #expect(roundTripped.title == "Configured lane")
        #expect(roundTripped.cachedTitle == "Configured lane")
        roundTripped.panel.close()
    }

    @Test("renaming a running auto-titled Dock tab claims the stable title")
    func dockRenameClaimsStableAutoTitle() throws {
        let source = Workspace()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer {
            dock.closeAllPanels()
            source.teardownAllPanels()
        }
        let panelId = try #require(source.focusedPanelId)
        #expect(
            source.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .auto
            )
        )
        source.setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        let transfer = try #require(source.detachSurface(panelId: panelId))
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPane,
                focus: false
            ) == panelId
        )
        let tabId = try #require(dock.surfaceId(forPanelId: panelId))
        #expect(dock.bonsplitController.tab(tabId)?.title == "◐ Generated lane")
        let stableTitle = try #require(
            dock.stableDockTerminalTabTitle(panelId: panelId)?.title
        )
        #expect(stableTitle == "Generated lane")

        #expect(
            dock.setDockPanelCustomTitle(
                panelId: panelId,
                title: stableTitle
            )
        )
        #expect(dock.bonsplitController.tab(tabId)?.title == "Generated lane")
        #expect(dock.bonsplitController.tab(tabId)?.isLoading == true)

        let roundTripped = try #require(
            dock.detachSurface(panelId: panelId)
        )
        #expect(roundTripped.customTitle == "Generated lane")
        #expect(roundTripped.customTitleSource == .user)
        roundTripped.panel.close()
    }
}
