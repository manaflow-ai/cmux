import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudMachineWorkspaceAdoptionTests {
    @Test("The bind acknowledgement returns the explicit workspace's owning window")
    func bindReceiptOwnsWindowResolution() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let controller = TerminalController.shared
            let previousManager = controller.activeTabManagerForCallerNotification()
            let betaKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
            let previousBeta = UserDefaults.standard.object(forKey: betaKey)
            let flag = CmuxFeatureFlags.cloudMachinesFlag
            let previousFlag = CmuxFeatureFlags.shared.overrideValue(for: flag)
            let other = TabManager(autoWelcomeIfNeeded: false)
            let otherWindow = app.appDelegate.registerMainWindowContextForTesting(tabManager: other)
            defer {
                app.appDelegate.unregisterMainWindowContextForTesting(windowId: otherWindow)
                other.tabs.forEach { $0.teardownAllPanels() }
                app.tearDown()
                controller.setActiveTabManager(previousManager)
                UserDefaults.standard.set(previousBeta, forKey: betaKey)
                CmuxFeatureFlags.shared.setOverride(previousFlag, for: flag)
            }
            UserDefaults.standard.set(true, forKey: betaKey)
            CmuxFeatureFlags.shared.setOverride(true, for: flag)
            controller.setActiveTabManager(other)
            let ref = try #require(controller.v2Ref(kind: .workspace, uuid: app.workspace.id) as? String)
            for target in [ref, app.workspace.id.uuidString.lowercased()] {
                let response = controller.v2WorkspaceCloudVMBind(params: ["workspace_id": target, "vm_id": "receipt-fixture"])
                let bytes = Data(controller.v2Result(id: "receipt", response).utf8)
                let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(object["ok"] as? Bool == true)
                let result = try #require(object["result"] as? [String: Any])
                #expect(result["workspace_id"] as? String == app.workspace.id.uuidString)
                #expect(result["workspace_ref"] as? String == ref)
                #expect(result["window_id"] as? String == app.windowID.uuidString)
            }
        }
    }

    @Test("Abandoning the last creating card leaves no orphan and keeps the window usable")
    func cancellationOfLastWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            app.manager.closeWorkspace(app.workspace, recordHistory: false)
            #expect(app.manager.tabs.map(\.id) == [pending.id])
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id)
            #expect(app.manager.tabs.count == 1)
            #expect(app.manager.tabs.first?.id != pending.id)
            #expect(app.manager.tabs.first?.panels.values.contains { $0 is CloudVMLoadingPanel } == false)
            let remaining = app.manager.tabs.map(\.id)
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id)
            #expect(app.manager.tabs.map(\.id) == remaining)
        }
    }

    @Test("Cleanup preserves ordinary content and removes only its loading card")
    func userPanesAreNotDisposable() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let panel = try #require(app.workspace.focusedTerminalPanel)
            pending.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "cancelled-machine", isBase: false)
            NewMachineSheetPresenter.closeReservedWorkspace(app.workspace.id)
            #expect(app.manager.tabs.contains { $0.id == app.workspace.id })
            #expect(app.workspace.panels[panel.id] === panel)
            let pane = try #require(pending.bonsplitController.allPaneIds.first)
            let command = try #require(pending.newTerminalSurface(inPane: pane, focus: false,
                initialCommand: "echo first-command", autoRefreshMetadata: false))
            pending.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "newer-machine", isBase: false)
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id, machineID: "cancelled-machine")
            #expect(app.manager.tabs.contains { $0.id == pending.id })
            #expect(pending.panels.count == 2 && pending.panels[command.id] === command)
            #expect(pending.cloudVMBinding?.vmID == "newer-machine")
            pending.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "cancelled-machine", isBase: false)
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id, machineID: "cancelled-machine")
            #expect(pending.panels.count == 1 && pending.panels[command.id] === command)
            #expect(pending.cloudVMBinding == nil)
            app.appDelegate.closeWorkspaces(forManagedCloudVMID: "cancelled-machine")
            #expect(app.manager.tabs.contains { $0.id == pending.id })
            #expect(pending.panels[command.id] === command)
            #expect(command.surface.initialCommand?.contains("first-command") == true)
        }
    }

    @Test("A create adopts the reserved workspace and tab once without selecting it")
    func adoptionAndReconnect() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let manager = app.manager
            let catalog = makeCatalog(manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            let pending = manager.addWorkspace(title: "New Machine", titleSource: .auto,
                initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let loading = try #require(pending.panels.values.first as? CloudVMLoadingPanel)
            let tab = pending.surfaceIdFromPanelId(loading.id)
            let pane = pending.paneId(forPanelId: loading.id)
            let stableID = pending.stableId
            let selection = manager.selectedTabId
            #expect(pending.cloudVMBinding == nil)
            #expect(!pending.isRestorableInSessionSnapshot, "an uncommitted creating card cannot restore as a local shell")

            try provider.install(in: catalog)
            catalog.bindCloudWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            #expect(CloudWorkspaceSidebarPresentation(workspace: pending, orderedPanelIDs: [loading.id], usesLastSegmentPath: false)?
                .directoryCandidates.first?.hasPrefix("brave-sapphire-lobster") == true)
            let first = try await open(pending, provider: provider, catalog: catalog)
            #expect(first.panelID == loading.id)
            #expect(pending.surfaceIdFromPanelId(first.panelID) == tab)
            #expect(pending.paneId(forPanelId: first.panelID) == pane)
            #expect(pending.panels.count == 1)
            #expect(pending.stableId == stableID)
            #expect(pending.panels[first.panelID]?.stableSurfaceId == loading.stableSurfaceId)
            #expect(pending.terminalPanel(for: first.panelID)?.surface.initialCommand == nil)
            #expect(pending.cloudVMBinding?.remoteWorkspaceID == "ws-first")
            #expect(pending.title == "workspace-1")
            #expect(manager.selectedTabId == selection)
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id)
            #expect(manager.tabs.contains { $0.id == pending.id }, "an adopted projection is no longer disposable")

            let repeated = try await open(pending, provider: provider, catalog: catalog)
            #expect(repeated == first)
            #expect(provider.materializations == 1)
            try provider.install(in: catalog, generation: "reconnected")
            await catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
            #expect(catalog.projections == [first])
            var saved = pending.sessionSnapshot(includeScrollback: false)
            saved.surfaceProjections = catalog.projectionRecords(forWorkspace: pending.id)
            #expect(saved.cloudVM?.remoteWorkspaceID == "ws-first")
            #expect(pending.isRestorableInSessionSnapshot)
            let restored = Workspace(initialSurface: .cloudVMLoading)
            defer { restored.teardownAllPanels() }
            restored.restoreSessionSnapshot(saved)
            #expect(restored.cloudVMBinding == pending.cloudVMBinding)
            #expect(restored.title == "workspace-1")
        }
    }

    @Test("Daemon failure keeps only its creating card; retry adopts it and later workspaces stay separate")
    func failureAndLaterWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let manager = app.manager
            let catalog = makeCatalog(manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let first = manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let second = manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let loading = try #require(first.panels.values.first as? CloudVMLoadingPanel)
            catalog.bindCloudWorkspace(localWorkspaceID: first.id, machine: provider.machine, remoteWorkspaceID: nil)
            provider.beforeMaterialization = { throw CloudDiagnosticFailure.network }
            await #expect(throws: CloudDiagnosticFailure.self) { try await open(first, provider: provider, catalog: catalog) }
            #expect(first.panels[loading.id] === loading)
            #expect(catalog.projections.isEmpty)
            provider.beforeMaterialization = nil
            let attached = try await open(first, provider: provider, catalog: catalog)
            #expect(attached.panelID == loading.id)
            #expect(second.panels.values.first is CloudVMLoadingPanel)

            // An explicit later mirror has its own UUID, even for the same terminal.
            catalog.bindCloudWorkspace(localWorkspaceID: second.id, machine: provider.machine, remoteWorkspaceID: nil)
            let later = try await open(second, provider: provider, catalog: catalog)
            #expect(later.workspaceID != attached.workspaceID && later.panelID != attached.panelID)
            #expect(first.panels.count == 1 && second.panels.count == 1)
            #expect(catalog.projections.count == 2)

            // An ordinary terminal can contain the user's first command; it is
            // never consumed as a loading card, regardless of a matching title.
            let ordinary = manager.addWorkspace(title: "Cloud VM", titleSource: .auto, initialTerminalCommand: "echo first-command",
                select: false, eagerLoadTerminal: false, autoWelcomeIfNeeded: false)
            let command = try #require(ordinary.focusedTerminalPanel)
            catalog.bindCloudWorkspace(localWorkspaceID: ordinary.id, machine: provider.machine, remoteWorkspaceID: nil)
            _ = try await open(ordinary, provider: provider, catalog: catalog)
            #expect(ordinary.panels[command.id] === command)
            #expect(command.surface.initialCommand?.contains("first-command") == true)
        }
    }

    @Test("Concurrent opens share one attachment within the reserved workspace")
    func concurrentOpen() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            catalog.bindCloudWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = CloudLinkFirstValue<Bool>(), release = CloudLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let first = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            let started = CloudLinkFirstValue<Bool>()
            let second = Task { started.resolve(true); return try await open(pending, provider: provider, catalog: catalog) }
            _ = await started.result
            #expect(provider.materializations == 1)
            release.resolve(true)
            let a = try await first.value, b = try await second.value
            #expect(a == b)
            #expect(pending.panels.count == 1)
        }
    }

    @Test("Placement rejection restores the creating card for retry")
    func placementFailureRestoresLoadingCard() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            provider.returnMismatchedPlacement = true
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            catalog.bindCloudWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let originalID = try #require(pending.panels.values.first?.id)
            await #expect(throws: (any Error).self) { try await open(pending, provider: provider, catalog: catalog) }
            #expect(pending.panels.count == 1)
            #expect((pending.panels[originalID] as? CloudVMLoadingPanel)?.hasFailed == true)
            #expect(catalog.projections.isEmpty)
            provider.returnMismatchedPlacement = false
            let retry = try await open(pending, provider: provider, catalog: catalog)
            #expect(retry.panelID == originalID)
            #expect(pending.panels[originalID] is TerminalPanel)
        }
    }

    private func makeCatalog(_ manager: TabManager) -> SurfaceCatalog {
        SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        )))
    }

    @Test("Closing a pending workspace cannot adopt into another create")
    func closedDestinationRejectsLateAttachment() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let other = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            catalog.bindCloudWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = CloudLinkFirstValue<Bool>(), release = CloudLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let attachment = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            app.manager.closeWorkspace(pending, recordHistory: false)
            release.resolve(true)
            await #expect(throws: (any Error).self) { try await attachment.value }
            #expect(other.panels.count == 1 && other.panels.values.first is CloudVMLoadingPanel)
            #expect(other.cloudVMBinding == nil)
            #expect(catalog.projections.isEmpty)
        }
    }

    @Test("Cancelling a mixed-content workspace fences its delayed attachment", arguments: [false, true])
    func mixedContentCancellationRejectsLateAttachment(openAgain: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { for workspace in app.manager.tabs { workspace.teardownAllPanels() }; app.tearDown() }
            let catalog = makeCatalog(app.manager)
            let provider = CloudMachineWorkspaceTestProvider()
            catalog.register(provider)
            defer { catalog.unregister(machine: provider.machine) }
            try provider.install(in: catalog)
            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let other = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let pane = try #require(pending.bonsplitController.allPaneIds.first)
            let command = try #require(pending.newTerminalSurface(inPane: pane, focus: false, initialCommand: "echo first-command", autoRefreshMetadata: false))
            catalog.bindCloudWorkspace(localWorkspaceID: pending.id, machine: provider.machine, remoteWorkspaceID: nil)
            let entered = CloudLinkFirstValue<Bool>(), release = CloudLinkFirstValue<Bool>()
            provider.beforeMaterialization = { entered.resolve(true); _ = await release.result }
            let attachment = Task { try await open(pending, provider: provider, catalog: catalog) }
            _ = await entered.result
            NewMachineSheetPresenter.closeReservedWorkspace(pending.id, machineID: provider.machine.rawValue)
            #expect(pending.cloudVMBinding == nil)
            // A later explicit open has a different admission claim and must not
            // join the cancelled adoption or be discarded with its late result.
            provider.beforeMaterialization = nil
            let reopened = openAgain ? try await open(pending, provider: provider, catalog: catalog) : nil
            release.resolve(true)
            await #expect(throws: (any Error).self) { try await attachment.value }
            #expect(pending.panels.count == (openAgain ? 2 : 1) && pending.panels[command.id] === command)
            if let reopened { #expect(pending.panels[reopened.panelID] is TerminalPanel) }
            #expect(command.surface.initialCommand?.contains("first-command") == true)
            #expect(other.panels.count == 1 && other.panels.values.first is CloudVMLoadingPanel)
            #expect(catalog.projections.count == (openAgain ? 1 : 0))
        }
    }

    private func open(_ workspace: Workspace, provider: CloudMachineWorkspaceTestProvider, catalog: SurfaceCatalog) async throws -> SurfaceProjection {
        let resource = try #require(catalog.snapshot.resources(on: provider.machine).first)
        return try await catalog.project(resource.id, into: .workspace(id: workspace.id, placement: .split),
            focus: false, reuseExisting: true, reuseInWorkspace: workspace.id, remoteView: resource.remoteViews?.first).projection
    }
}
