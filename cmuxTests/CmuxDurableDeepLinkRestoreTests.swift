import AppKit
import Bonsplit
import Combine
import Foundation
import CmuxRemoteWorkspace
import enum CmuxWorkspaces.SessionSidebarSelection
import struct CmuxWorkspaces.SessionSidebarSnapshot
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class DurableDeepLinkDockTestPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Docked duplicate identity"
    let displayIcon: String? = "terminal.fill"

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5486:
/// a copied `cmux://` deep link must keep resolving to the same logical
/// workspace/tab after the session is persisted and restored with re-minted
/// runtime UUIDs (what happens across an app restart).
@MainActor
@Suite("Durable deep link restore")
struct CmuxDurableDeepLinkRestoreTests {
    private let scheme = "cmux"

    private func parsedTarget(_ link: String) throws -> CmuxNavigationURLRequest.Target {
        let url = try #require(URL(string: link))
        switch CmuxNavigationURLRequest.parse(url, supportedSchemes: [scheme]) {
        case .success(let request):
            return try #require(request).target
        case .failure(let error):
            throw error
        }
    }

    @Test func workspaceLinkResolvesAfterRestoreWithRemintedIds() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        workspace.setCustomTitle("Linked workspace")
        let link = CmuxNavigationURLRequest.workspaceLink(
            workspaceId: workspace.stableId,
            scheme: scheme
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(
            restored.tabs.first(where: { $0.customTitle == "Linked workspace" })
        )
        // The restart breakage this feature fixes: runtime ids are re-minted…
        #expect(restoredWorkspace.id != workspace.id)
        // …while the persisted stable id survives.
        #expect(restoredWorkspace.stableId == workspace.stableId)

        let resolver = CmuxNavigationTargetResolver(
            workspaces: restored.tabs.map(\.cmuxNavigationDescriptor)
        )
        let resolution = try resolver.resolve(parsedTarget(link))
        #expect(resolution == .workspace(workspaceId: restoredWorkspace.id))
    }

    @Test func surfaceLinkResolvesToSameLogicalTabAfterRestore() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let linkedPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: linkedPanelId, title: "Linked tab")
        let linkedPanel = try #require(workspace.panels[linkedPanelId])

        // What "Copy Surface Link" emits since durable deep links: stable ids.
        let link = CmuxNavigationURLRequest.surfaceLink(
            workspaceId: workspace.stableId,
            surfaceId: linkedPanel.stableSurfaceId,
            scheme: scheme
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restored.tabs.first)
        let restoredPanelId = try #require(
            restoredWorkspace.panelCustomTitles.first(where: { $0.value == "Linked tab" })?.key
        )
        // Runtime panel ids are re-minted on restore; the stable id survives.
        #expect(restoredPanelId != linkedPanelId)
        let restoredPanel = try #require(restoredWorkspace.panels[restoredPanelId])
        #expect(restoredPanel.stableSurfaceId == linkedPanel.stableSurfaceId)

        let resolver = CmuxNavigationTargetResolver(
            workspaces: restored.tabs.map(\.cmuxNavigationDescriptor)
        )
        let resolution = try resolver.resolve(parsedTarget(link))
        #expect(resolution == .surface(workspaceId: restoredWorkspace.id, panelId: restoredPanelId))
    }

    @Test func terminalRespawnPreservesStableSurfaceIdForLinks() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let stableSurfaceId = try #require(workspace.panels[panelId]).stableSurfaceId
        let link = CmuxNavigationURLRequest.surfaceLink(
            workspaceId: workspace.stableId,
            surfaceId: stableSurfaceId,
            scheme: scheme
        )

        // Respawn replaces the TerminalPanel object while keeping the logical tab.
        let respawned = try #require(
            workspace.respawnTerminalSurface(panelId: panelId, command: "true")
        )
        #expect(respawned.stableSurfaceId == stableSurfaceId)

        let resolver = CmuxNavigationTargetResolver(
            workspaces: manager.tabs.map(\.cmuxNavigationDescriptor)
        )
        let resolution = try resolver.resolve(parsedTarget(link))
        #expect(resolution == .surface(workspaceId: workspace.id, panelId: panelId))
    }

    @Test func terminalContextMenuSurfaceLinkUsesMappedPanelStableId() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newTerminalSurface(inPane: pane, focus: true))
        let surfaceId = try #require(workspace.surfaceIdFromPanelId(panel.id)?.uuid)
        #expect(surfaceId != panel.id)

        let link = try #require(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: workspace,
                panelId: panel.id
            )
        )

        #expect(
            link == CmuxNavigationURLRequest.surfaceLink(
                workspaceId: workspace.stableId,
                surfaceId: panel.stableSurfaceId,
                scheme: scheme
            )
        )

        let resolver = CmuxNavigationTargetResolver(
            workspaces: manager.tabs.map(\.cmuxNavigationDescriptor)
        )
        let resolution = try resolver.resolve(parsedTarget(link))
        #expect(resolution == .surface(workspaceId: workspace.id, panelId: panel.id))
    }

    @Test func closedPanelRestoreWithLiveDockIdentityMintsFreshStableSurfaceId() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: panelId))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let dockPanel = DurableDeepLinkDockTestPanel()
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        dock.panels[dockPanel.id] = dockPanel
        let dockTabId = try #require(
            dock.bonsplitController.createTab(
                title: dockPanel.displayTitle,
                icon: dockPanel.displayIcon,
                kind: "terminal",
                isDirty: dockPanel.isDirty,
                inPane: dockPane
            )
        )
        dock.surfaceIdToPanelId[dockTabId] = dockPanel.id

        var snapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        snapshot.stableSurfaceId = dockPanel.stableSurfaceId
        snapshot.customTitle = "Restored dock duplicate"
        let entry = ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: pane.id,
            tabIndex: 0,
            snapshot: snapshot
        )

        #expect(manager.restoreClosedPanel(entry))

        let restoredPanelId = try #require(
            workspace.panelCustomTitles.first(where: { $0.value == "Restored dock duplicate" })?.key
        )
        let restoredPanel = try #require(workspace.panels[restoredPanelId])
        #expect(restoredPanel.stableSurfaceId != dockPanel.stableSurfaceId)
    }

    @Test func duplicateReopenWithLiveIdentitiesMintsFreshOnes() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let liveSurfaceId = try #require(workspace.panels[panelId]).stableSurfaceId
        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        // Manual "Reopen Previous Session" while the original is still open:
        // live identities are excluded so the duplicate copy mints fresh ones
        // and links keep targeting the original unambiguously.
        let duplicate = TabManager()
        duplicate.restoreSessionSnapshot(
            snapshot,
            excludingStableIdentities: [workspace.stableId, liveSurfaceId]
        )

        let duplicateWorkspace = try #require(duplicate.tabs.first)
        #expect(duplicateWorkspace.stableId != workspace.stableId)
        #expect(!duplicateWorkspace.panels.values.contains { $0.stableSurfaceId == liveSurfaceId })

        // The original and the duplicate together never share a stable id, so
        // a link to the original resolves to the original.
        let resolver = CmuxNavigationTargetResolver(
            workspaces: (manager.tabs + duplicate.tabs).map(\.cmuxNavigationDescriptor)
        )
        let link = CmuxNavigationURLRequest.surfaceLink(
            workspaceId: workspace.stableId,
            surfaceId: liveSurfaceId,
            scheme: scheme
        )
        let resolution = try resolver.resolve(parsedTarget(link))
        #expect(resolution == .surface(workspaceId: workspace.id, panelId: panelId))
    }

    @Test func closedPanelRestoreWithLiveIdentityMintsFreshStableSurfaceId() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: panelId))
        let liveStableSurfaceId = try #require(workspace.panels[panelId]).stableSurfaceId
        var snapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        snapshot.customTitle = "Restored closed duplicate"
        let entry = ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: pane.id,
            tabIndex: 0,
            snapshot: snapshot
        )

        #expect(manager.restoreClosedPanel(entry))

        let restoredPanelId = try #require(
            workspace.panelCustomTitles.first(where: { $0.value == "Restored closed duplicate" })?.key
        )
        let restoredPanel = try #require(workspace.panels[restoredPanelId])
        #expect(restoredPanel.stableSurfaceId != liveStableSurfaceId)
    }

    @Test func closedWorkspaceRestoreWithLiveIdentityMintsFreshStableIds() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let liveStableWorkspaceId = workspace.stableId
        let liveStableSurfaceId = try #require(workspace.panels[panelId]).stableSurfaceId
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Restored workspace duplicate"
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 1,
            snapshot: snapshot
        )

        #expect(manager.restoreClosedWorkspace(entry))

        let restoredWorkspace = try #require(
            manager.tabs.first(where: { $0.customTitle == "Restored workspace duplicate" })
        )
        #expect(restoredWorkspace.stableId != liveStableWorkspaceId)
        #expect(!restoredWorkspace.panels.values.contains { $0.stableSurfaceId == liveStableSurfaceId })
    }

    @Test func closedWindowRestoreWithLiveIdentityMintsFreshStableIds() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            ClosedItemHistoryStore.shared.removeAll()
            defer {
                for context in Array(appDelegate.mainWindowContexts.values) {
                    appDelegate.unregisterMainWindowContextForTesting(windowId: context.windowId)
                }
                ClosedItemHistoryStore.shared.removeAll()
                AppDelegate.shared = previousAppDelegate
            }

            let liveManager = TabManager()
            let liveWorkspace = try #require(liveManager.selectedWorkspace)
            let livePanelId = try #require(liveWorkspace.focusedPanelId)
            let liveStableWorkspaceId = liveWorkspace.stableId
            let liveStableSurfaceId = try #require(liveWorkspace.panels[livePanelId]).stableSurfaceId
            let liveWindowId = appDelegate.registerMainWindowContextForTesting(tabManager: liveManager)
            let recordId = UUID()
            let snapshot = SessionWindowSnapshot(
                windowId: UUID(),
                frame: nil,
                display: nil,
                tabManager: liveManager.sessionSnapshot(includeScrollback: false),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
            ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
                id: recordId,
                closedAt: Date(),
                entry: .window(ClosedWindowHistoryEntry(
                    windowId: snapshot.windowId,
                    snapshot: snapshot,
                    workspaceIds: [liveWorkspace.id]
                ))
            ))

            #expect(appDelegate.reopenClosedHistoryItem(id: recordId, shouldActivate: false))

            let restoredContext = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId != liveWindowId }
            )
            let restoredWorkspace = try #require(restoredContext.tabManager.tabs.first)
            #expect(restoredWorkspace.stableId != liveStableWorkspaceId)
            #expect(!restoredWorkspace.panels.values.contains { $0.stableSurfaceId == liveStableSurfaceId })
        }
    }

    @Test func legacySnapshotWithoutStableIdsRestoresWithFreshOnes() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var snapshot = manager.sessionSnapshot(includeScrollback: false)

        // Simulate a snapshot written before durable deep links existed.
        snapshot.workspaces = snapshot.workspaces.map { workspaceSnapshot in
            var legacy = workspaceSnapshot
            legacy.stableId = nil
            legacy.panels = legacy.panels.map { panelSnapshot in
                var legacyPanel = panelSnapshot
                legacyPanel.stableSurfaceId = nil
                return legacyPanel
            }
            return legacy
        }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restored.tabs.first)
        // Legacy snapshots cannot carry the old identity forward; the restored
        // workspace gets a fresh stable id rather than crashing or aliasing.
        #expect(restoredWorkspace.stableId != workspace.stableId)

        let resolver = CmuxNavigationTargetResolver(
            workspaces: restored.tabs.map(\.cmuxNavigationDescriptor)
        )
        #expect(resolver.resolve(.workspace(workspace.stableId)) == nil)
    }
}
