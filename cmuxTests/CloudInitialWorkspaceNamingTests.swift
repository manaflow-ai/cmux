import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the local placeholder used while a Cloud workspace's
/// remote identity is still being discovered.
@MainActor
@Suite(.serialized)
struct CloudInitialWorkspaceNamingTests {
    @Test("Binding after discovery immediately gives both sidebars the daemon workspace name")
    func bindingReconcilesAlreadyDiscoveredName() async throws {
        try await withUnboundFixture { fixture in
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM")

            try fixture.expectParity("terminal", workspaceName: "Same workspace")
            #expect(fixture.workspace.cloudVMBinding?.remoteWorkspaceID == "a")
            #expect(fixture.provider.writes.isEmpty)
            #expect(fixture.manager.tabs.count == 1)
        }
    }

    @Test("Discovery after binding replaces the placeholder without a second create")
    func discoveryReconcilesAlreadyBoundWorkspace() async throws {
        try await withUnboundFixture { fixture in
            fixture.catalog.clearCloudState(on: fixture.provider.machine)
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM")
            #expect(fixture.workspace.title == "Cloud VM")

            fixture.catalog.replaceCloudState(
                fixture.provider.graph,
                resources: CmuxTuiSnapshotParser.resources(from: fixture.provider.graph),
                info: fixture.provider.info
            )
            fixture.renameService.reconcileRemoteState(
                machine: fixture.provider.machine,
                state: fixture.provider.graph,
                catalog: fixture.catalog,
                observation: .current
            )
            try fixture.expectParity("terminal", workspaceName: "Same workspace")
            #expect(fixture.provider.writes.isEmpty)
            #expect(fixture.manager.tabs.count == 1)
        }
    }

    @Test("Projection discovery submits a creation-time user rename before reconciling the old graph")
    func projectionBindingPreservesCreationRename() async throws {
        try await withUnboundFixture { fixture in
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: nil, generatedTitle: "Cloud VM")
            #expect(fixture.workspace.setCustomTitle("Chosen during creation", source: .user))
            fixture.catalog.record(SurfaceProjection(
                resource: .init(machine: fixture.provider.machine, kind: .terminal, key: "term_a"),
                workspaceID: fixture.workspace.id, panelID: fixture.panelID,
                remoteWorkspaceID: "a", remoteTabID: "tab_a"
            ))
            #expect(fixture.workspace.title == "Chosen during creation")
            try await fixture.settle()
            try fixture.expectParity("terminal", workspaceName: "Chosen during creation")
            #expect(fixture.provider.writes.map { $0.0 } == ["a"])
            #expect(fixture.provider.graph.lookupIndex.workspace(id: "b")?.name == "Same workspace")
        }
    }

    @Test("Choosing the placeholder text explicitly is still a user rename")
    func explicitPlaceholderTextHasUserPrecedence() async throws {
        try await withUnboundFixture { fixture in
            #expect(fixture.workspace.setCustomTitle("Cloud VM", source: .user))
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM")
            try await fixture.settle()
            try fixture.expectParity("terminal", workspaceName: "Cloud VM")
            #expect(fixture.provider.writes.map { $0.1 } == ["Cloud VM"])
            #expect(fixture.workspace.effectiveCustomTitleSource == .user)
        }
    }

    @Test("Legacy generated placeholders adopt the daemon name without a write-back")
    func legacyGeneratedPlaceholderIsNotRenamedRemotely() async throws {
        try await withUnboundFixture { fixture in
            fixture.workspace.customTitleSource = nil
            #expect(fixture.workspace.customTitle == "Cloud VM")
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM")
            try await fixture.settle()
            try fixture.expectParity("terminal", workspaceName: "Same workspace")
            #expect(fixture.provider.writes.isEmpty)
        }
    }

    @Test("Late machine-only receipts and stale snapshots cannot undo an accepted workspace rename")
    func lateReceiptsKeepIdentityAndName() async throws {
        try await withUnboundFixture { fixture in
            let oldGraph = fixture.provider.graph
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: "a", generatedTitle: "Cloud VM")
            try await fixture.provider.renameRemoteWorkspace(id: "a", name: "workspace-1")
            fixture.catalog.bindCloudWorkspace(localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine, remoteWorkspaceID: nil, generatedTitle: "Cloud VM")
            #expect(!fixture.provider.install(oldGraph))
            fixture.renameService.reconcileRemoteState(machine: fixture.provider.machine, state: oldGraph,
                catalog: fixture.catalog, observation: .current)
            try fixture.expectParity("terminal", workspaceName: "workspace-1")
            #expect(fixture.workspace.cloudVMBinding?.remoteWorkspaceID == "a")
            #expect(fixture.provider.graph.lookupIndex.workspace(id: "b")?.name == "Same workspace")
        }
    }

    @Test("Generated creation titles carry provenance before a user can rename them")
    func workspaceCreateRecordsGeneratedTitleOwnership() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { for workspace in manager.tabs { for panel in workspace.panels.values { panel.close() } } }
        let previousIDs = Set(manager.tabs.map(\.id))
        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "title": "Cloud VM", "title_source": "auto",
            "eager_load_terminal": false, "auto_refresh_metadata": false
        ], tabManager: manager)
        let created = try #require(manager.tabs.first { !previousIDs.contains($0.id) })
        #expect(created.title == "Cloud VM")
        #expect(created.effectiveCustomTitleSource == .auto)
        #expect(created.setCustomTitle("Cloud VM", source: .user))
        #expect(created.effectiveCustomTitleSource == .user)
    }

    @Test("Creation completion selects only the initiating window workspace")
    func completionSelectionStaysInInitiatingWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try #require(AppDelegate.shared)
            let first = TabManager(autoWelcomeIfNeeded: false)
            let second = TabManager(autoWelcomeIfNeeded: false)
            let firstWindowID = app.registerMainWindowContextForTesting(tabManager: first)
            let secondWindowID = app.registerMainWindowContextForTesting(tabManager: second)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: firstWindowID)
                app.unregisterMainWindowContextForTesting(windowId: secondWindowID)
                for workspace in first.tabs + second.tabs {
                    for panel in workspace.panels.values { panel.close() }
                }
            }
            let target = try #require(first.addWorkspaceIfActive(
                title: "Cloud VM", titleSource: .auto, select: false,
                autoWelcomeIfNeeded: false
            ))
            let secondSelection = second.selectedTabId
            let request = MachineCreateRequest(
                mode: .newMachine, kind: .desktop, name: nil,
                arguments: ["vm", "new", "--focus", "false"],
                selectionWindowID: firstWindowID,
                selectsCreatedWorkspace: true
            )
            let coordinator = MachineCreateCoordinator(
                notifier: { _ in }, notificationCenter: NotificationCenter()
            )
            var completion: (@MainActor (CloudVMActionLauncher.Completion) -> Void)?
            #expect(coordinator.start(request, cancellableLaunch: { _, _, handler in
                completion = handler
                return CloudVMActionLauncher.CancellationHandle { }
            }))
            completion?(CloudVMActionLauncher.Completion(
                terminationStatus: 0,
                output: "OK workspace=\(target.id.uuidString)",
                workspaceId: target.id
            ))
            #expect(first.selectedTabId == target.id)
            #expect(second.selectedTabId == secondSelection)
        }
    }

    private func withUnboundFixture(_ body: (CloudNameAuthorityFixture) async throws -> Void) async throws {
        let fixture = try CloudNameAuthorityFixture()
        let previous = fixture.catalog.cloudWorkspaceRenameService
        fixture.catalog.installCloudWorkspaceRenameService(fixture.renameService)
        fixture.catalog.endProjections(panelID: fixture.panelID, reason: .replaced)
        fixture.workspace.cloudVMBinding = nil
        fixture.workspace.setCustomTitle(nil)
        fixture.workspace.setCustomTitle("Cloud VM", source: .auto)
        do { try await body(fixture) }
        catch {
            fixture.catalog.installCloudWorkspaceRenameService(previous)
            await fixture.close()
            throw error
        }
        fixture.catalog.installCloudWorkspaceRenameService(previous)
        await fixture.close()
    }

    @Test("A creation-time rename survives delayed binding and the old remote snapshot")
    func creationRenameIsPreservedAcrossBinding() async throws {
        let fixture = try CloudNameAuthorityFixture()
        let originalService = fixture.catalog.cloudWorkspaceRenameService
        fixture.catalog.installCloudWorkspaceRenameService(fixture.renameService)
        do {
            fixture.workspace.cloudVMBinding = nil
            #expect(fixture.workspace.setCustomTitle("Chosen during creation", source: .user))

            fixture.catalog.bindCloudWorkspace(
                localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine,
                remoteWorkspaceID: "a",
                generatedTitle: "Cloud VM"
            )
            #expect(fixture.workspace.title == "Chosen during creation")
            #expect(fixture.workspace.effectiveCustomTitleSource == .user)

            // The remote graph still has its older default name. Binding must
            // submit the local intent before that snapshot can overwrite it:
            // the title is protected by the unacknowledged intent, not by its
            // user provenance (#12986).
            let key = CloudRenameCoordinator.Key.workspace(machine: fixture.provider.machine, id: "a")
            #expect(fixture.catalog.pendingCloudRenameName(for: key) == "Chosen during creation")
            fixture.renameService.reconcileRemoteState(
                machine: fixture.provider.machine, state: fixture.provider.graph,
                catalog: fixture.catalog, observation: .current
            )
            #expect(fixture.workspace.title == "Chosen during creation")
            try await fixture.settle()
            #expect(fixture.catalog.pendingCloudRenameName(for: key) == nil)
            #expect(fixture.provider.writes.map { $0.0 } == ["a"])
            #expect(fixture.provider.writes.map { $0.1 } == ["Chosen during creation"])
            try fixture.expectParity("terminal", workspaceName: "Chosen during creation")
        } catch {
            fixture.catalog.installCloudWorkspaceRenameService(originalService)
            await fixture.close()
            throw error
        }
        fixture.catalog.installCloudWorkspaceRenameService(originalService)
        await fixture.close()
    }
}
