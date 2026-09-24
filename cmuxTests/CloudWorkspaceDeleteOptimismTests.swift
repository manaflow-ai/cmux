import AppKit
import CmuxCloudMachines
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudWorkspaceDeleteOptimismTests {
    @Test func deletionIsVisibleBeforeProviderRefresh() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        provider.onRefresh = {
            #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.isEmpty == true)
            #expect(catalog.snapshot.resources.isEmpty)
            #expect(catalog.resources[provider.terminal.id] != nil, "Keep authoritative state for rollback")
        }
        let count = try await CloudTreeNodeActions.deleteWorkspaceAndTerminals(
            machine: provider.machine, provider: provider, catalog: catalog, workspaceID: provider.workspace.id
        )
        #expect(count == 1)
        #expect(provider.closedTerminals == [provider.terminal.id])
        #expect(catalog.snapshot.resources.isEmpty)
    }
    @Test func admissionAndRepeatedCallsShareOneMutation() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let restoring = SurfaceProjection(resource: .init(machine: .local, kind: .terminal, key: "restoring"),
            workspaceID: UUID(), panelID: UUID())
        catalog.record(restoring)
        let first = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        #expect(catalog.snapshot.resources.isEmpty, "Removal is synchronous, before the task runs")
        #expect(catalog.snapshot.projections == [restoring], "An unrelated restoring pane must remain visible")
        #expect(catalog.snapshot.pendingWorkspaceDeletions?[provider.machine] == [provider.workspace.id])
        let second = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(provider.closedTerminals.count == 1 && provider.closedWorkspaces.count == 1)
        catalog.updateMachine(provider.info, from: provider)
        catalog.replaceResources([provider.terminal], on: provider.machine, from: provider)
        #expect(catalog.snapshot.resources.isEmpty, "A late provider refresh cannot resurrect the terminal")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces?.isEmpty == true)
        #expect(catalog.snapshot.pendingWorkspaceDeletions?.isEmpty == true)
    }

    @Test func failedDeleteRestoresSnapshotAndPreservesErrorForRetry() async throws {
        enum Failure: Error { case denied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let previous = catalog.snapshot
        provider.beforeTerminalClose = { _ in throw Failure.denied }
        let failed = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do { _ = try await failed.value; Issue.record("Expected backend failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot == previous)
        provider.beforeTerminalClose = { _ in }
        #expect(try await catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id).value == 1)
        #expect(catalog.snapshot.resources.isEmpty)
    }

    @Test func cancelledDeleteRollsBackBeforeDestruction() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let previous = catalog.snapshot
        let deletion = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        deletion.cancel()
        do { _ = try await deletion.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(catalog.snapshot == previous)
        #expect(provider.closedTerminals.isEmpty && provider.closedWorkspaces.isEmpty)
    }

    @Test func selectionAndExpansionSurviveFailureWithoutOverwritingNewSelection() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let previous = fixture.nodes()
        let root = try #require(CloudTreeNodeBuilder.flattened(previous).first { $0.id == fixture.folderID("ws_1") })
        let selected = try #require(root.children.first).id
        var snapshot = fixture.snapshot()
        snapshot.machines[0].remoteWorkspaces?.removeAll { $0.id == "ws_1" }
        snapshot.resources.removeAll { $0.remoteWorkspaces.contains { $0.id == "ws_1" } }
        let next = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false)
        let presentation = CloudTreeDeletionPresentation()
        let pending = [fixture.machine: Set(["ws_1"])]
        let removed = presentation.update(previous: previous, next: next, pending: pending, selectedNodeID: selected)
        #expect(removed.selectedNodeID == CloudTreeNodeBuilder.nodeID(machine: fixture.machine))
        #expect(CloudTreeNodeBuilder.flattened(removed.expansionNodes).contains { $0.id == root.id })
        let restored = presentation.update(previous: next, next: previous, pending: [:], selectedNodeID: removed.selectedNodeID)
        #expect(restored.selectedNodeID == selected)
        _ = presentation.update(previous: previous, next: next, pending: pending, selectedNodeID: selected)
        let newer = fixture.folderID("ws_2")
        #expect(presentation.update(previous: next, next: previous, pending: [:], selectedNodeID: newer).selectedNodeID == newer)
    }

    @Test func staleNavigationIsCancelledOnlyForDeletedWorkspace() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        let deletion = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do {
            try catalog.checkCloudWorkspaceNavigation(machine: provider.machine, workspaceID: provider.workspace.id)
            Issue.record("Deleted workspace must reject navigation")
        } catch { #expect(error is CancellationError) }
        try catalog.checkCloudWorkspaceNavigation(machine: provider.machine, workspaceID: "unrelated")
        _ = try await deletion.value
    }

    @Test func concurrentDeletesAndPartialFailurePreserveUnrelatedState() async throws {
        enum Failure: Error { case denied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        let other = SurfaceRemoteWorkspace(id: "ws-other", name: "Keep me", index: 1, focused: false)
        var info = provider.info
        info.remoteWorkspaces?.append(other)
        catalog.updateMachine(info, from: provider)
        var secondTerminal = provider.terminal
        secondTerminal.id.key = "term-other"
        secondTerminal.remoteWorkspace = other
        catalog.replaceResources([provider.terminal, secondTerminal], on: provider.machine)
        provider.beforeTerminalClose = { id in
            if id.key == "term-other" { throw Failure.denied }
            catalog.remove(id, from: provider)
        }
        let first = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        let second = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(catalog.snapshot.resources.isEmpty)
        _ = try await first.value
        do { _ = try await second.value; Issue.record("Expected second deletion failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot.resources == [secondTerminal])
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces == [other])
        #expect(provider.closedWorkspaces == [provider.workspace.id])
        #expect(catalog.snapshot.machines.count == 1, "Never delete the Cloud VM")
    }

    @Test func confirmedTerminalCloseIsNotResurrectedWhenWorkspaceCloseFails() async throws {
        enum Failure: Error { case workspaceDenied }
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        catalog.replaceResources([provider.terminal], on: provider.machine)
        provider.beforeTerminalClose = { catalog.remove($0, from: provider) }
        provider.beforeClose = { throw Failure.workspaceDenied }
        let deletion = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        do { _ = try await deletion.value; Issue.record("Expected workspace failure") }
        catch { #expect(error is Failure) }
        #expect(catalog.snapshot.resources.isEmpty, "Rollback cannot recreate a killed process")
        #expect(catalog.snapshot.machines.first?.remoteWorkspaces == [provider.workspace])
        #expect(catalog.snapshot.pendingWorkspaceDeletions == nil)
    }

    @Test func renderedOutlineRemovesDescendantsThenRestoresSelectionOnFailure() async throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(coordinator.nodes).first { $0.id == fixture.folderID("ws_1") })
        let child = try #require(folder.children.first)
        try #require(outline.row(forItem: child) >= 0)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: child)), byExtendingSelection: false)
        coordinator.selectedNodeID = child.id
        try fixture.attachScreenshot(named: "cloud-delete-before")
        let deletion = fixture.catalog.deleteCloudWorkspace(machine: fixture.machine, workspaceID: "ws_1")
        func applyCatalog() {
            let snapshot = fixture.catalog.snapshot
            coordinator.pendingWorkspaceDeletions = snapshot.pendingWorkspaceDeletions ?? [:]
            coordinator.apply(nodes: CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot,
                localWorkspaces: [], includeLocalMachine: false))
        }
        applyCatalog()
        let visible = CloudTreeNodeBuilder.flattened(coordinator.nodes)
        #expect(!visible.contains { $0.id == folder.id || $0.id == child.id })
        #expect(visible.contains { $0.id == fixture.folderID("ws_2") })
        #expect(coordinator.selectedNodeID == CloudTreeNodeBuilder.nodeID(machine: fixture.machine))
        try fixture.attachScreenshot(named: "cloud-delete-pending")
        // This fixture provider intentionally refuses destructive operations.
        do { _ = try await deletion.value; Issue.record("Expected unsupported delete") }
        catch { #expect(error is SurfaceCatalogError) }
        applyCatalog()
        #expect(coordinator.selectedNodeID == child.id)
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == child.id)
        try fixture.attachScreenshot(named: "cloud-delete-rollback")
    }

    @Test("A provider replaced during refresh cannot receive destructive calls")
    func providerReplacementCancelsDelete() async throws {
        let catalog = SurfaceCatalog()
        let old = CloudWorkspaceDeleteTestProvider()
        let replacement = CloudWorkspaceDeleteTestProvider()
        catalog.register(old)
        catalog.replaceResources([old.terminal], on: old.machine)
        old.onRefresh = { catalog.register(replacement) }
        let task = catalog.deleteCloudWorkspace(machine: old.machine, workspaceID: old.workspace.id)
        do { _ = try await task.value; Issue.record("Retired provider must not delete") }
        catch { #expect(error is CancellationError) }
        #expect(old.closedTerminals.isEmpty && old.closedWorkspaces.isEmpty)
        #expect(replacement.closedTerminals.isEmpty && replacement.closedWorkspaces.isEmpty)
        #expect(!catalog.isCloudWorkspaceDeletionHidden(machine: old.machine, workspaceID: old.workspace.id))
    }

    @Test("Concurrent workspaces sharing a terminal close its process once")
    func sharedTerminalClosesOnce() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudWorkspaceDeleteTestProvider()
        catalog.register(provider)
        let other = SurfaceRemoteWorkspace(id: "other", name: "Other", index: 1, focused: false)
        var terminal = provider.terminal
        terminal.remoteViews = [SurfaceRemoteView(tabID: "first", workspace: provider.workspace),
                                SurfaceRemoteView(tabID: "second", workspace: other)]
        catalog.replaceResources([terminal], on: provider.machine)
        let first = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: provider.workspace.id)
        let second = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(provider.closedTerminals == [terminal.id])
        #expect(Set(provider.closedWorkspaces) == [provider.workspace.id, other.id])
        let repeated = catalog.deleteCloudWorkspace(machine: provider.machine, workspaceID: other.id)
        #expect(try await repeated.value == 1)
        #expect(provider.closedWorkspaces.count == 2)
    }

}
