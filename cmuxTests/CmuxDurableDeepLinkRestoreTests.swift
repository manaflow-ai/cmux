import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
        let terminalSurfaceId = try #require(workspace.surfaceIdFromPanelId(panel.id)?.uuid)

        let link = try #require(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: workspace,
                surfaceId: terminalSurfaceId
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
