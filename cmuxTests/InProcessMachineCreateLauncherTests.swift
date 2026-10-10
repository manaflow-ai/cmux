import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct InProcessMachineCreateLauncherTests {
    @Test(arguments: [false, true])
    func upstreamFailureNeverReachesCreatePresentation(created: Bool) async throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--workspace", workspace.uuidString, "--focus", "false"
        ]))
        let upstreamMessage = "upstream-diagnostic-fixture-7b912"
        let testCatalog = SurfaceCatalog()
        let testProvider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: "created-machine", provider: "freestyle", status: "running", image: "snapshot", createdAt: 1),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: testCatalog
        )
        defer { testProvider.stopTransportResources() }
        var didOpen = false
        let dependencies = InProcessMachineCreateLauncher.Dependencies(
            create: { _, _ in
                if !created { throw VMClientError.httpStatus(503, "{\"message\":\"\(upstreamMessage)\"}") }
                return VMSummary(id: "created-machine", provider: "freestyle", status: "running", image: "snapshot", createdAt: 1)
            },
            record: { _, _ in created ? testProvider : nil },
            provider: { _ in created ? testProvider : nil },
            refresh: {},
            open: { _, _ in
                didOpen = true
                throw VMClientError.httpStatus(503, "{\"message\":\"\(upstreamMessage)\"}")
            }
        )
        let completion = await InProcessMachineCreateLauncher.run(
            invocation, operationID: UUID(), dependencies: dependencies, onOutput: { _ in }
        )
        #expect(didOpen == created)
        #expect(!completion.succeeded)
        #expect(!completion.output.contains(upstreamMessage))
        let coordinator = MachineCreateCoordinator(notifier: { notice in
            #expect(!notice.body.contains(upstreamMessage))
        })
        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspace)) { _, _, finish in
            finish(completion)
            return true
        }
        let finished = try #require(coordinator.lastFinished)
        switch finished.outcome {
        case .failed(let output), .createdButOpenFailed(_, let output):
            #expect(!output.contains(upstreamMessage))
        case .created:
            Issue.record("A failed create or attach must not be reported as ready")
        }
    }

    @Test func invalidDestinationRefusesAllocation() async throws {
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--workspace", UUID().uuidString
        ]))
        let dependencies = InProcessMachineCreateLauncher.Dependencies(
            create: { _, _ in
                Issue.record("An invalid destination must not allocate a machine")
                throw CloudDiagnosticFailure.placement
            },
            record: { _, _ in Issue.record("Unexpected record"); return nil },
            provider: { _ in Issue.record("Unexpected lookup"); return nil },
            refresh: { Issue.record("Unexpected refresh") },
            open: { _, _ in Issue.record("Unexpected open") },
            validate: { _ in throw CloudDiagnosticFailure.placement }
        )
        let completion = await InProcessMachineCreateLauncher.run(
            invocation, operationID: UUID(), dependencies: dependencies, onOutput: { _ in }
        )
        #expect(!completion.succeeded)
        #expect(completion.machineId == nil)
        #expect(!completion.wasCancelled)
    }

    @Test("Manual input is admitted before graph discovery; a forced retry reuses the starter")
    func admitsInputBeforeGraphRefresh() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let pending = fixture.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false)
            let invocation = try invocation(workspaceID: pending.id)
            let host = CloudWorkspaceCreationHost(manager: fixture.manager, reservedWorkspaceID: pending.id)
            let selection = fixture.manager.selectedTabId
            let starter = SurfaceRemoteWorkspace(id: "starter", name: "Existing", index: 0, focused: true)
            var refreshes: [Bool] = []
            var admittedPanelID: UUID?
            try await InProcessMachineCreateLauncher.open(
                invocation, provider: fixture.provider, catalog: fixture.catalog, host: host,
                refreshGraph: { force in
                    refreshes.append(force)
                    guard let reservation = pending.cloudPendingCreations.values.first else {
                        Issue.record("Graph discovery must not delay manual input admission")
                        return false
                    }
                    #expect(pending.panels[reservation.panelID] is TerminalPanel)
                    #expect(pending.panels.values.contains { $0 is CloudVMLoadingPanel } == false)
                    if !force {
                        admittedPanelID = reservation.panelID
                        reservation.inputRelay.send(.bytes(Data("echo early input\n".utf8)))
                        return false
                    }
                    #expect(reservation.panelID == admittedPanelID)
                    #expect(reservation.inputRelay.pendingCount == 1)
                    fixture.provider.createdWorkspaces = [starter]
                    do { try fixture.provider.publish(revision: 10) } catch { Issue.record(error); return false }
                    return true
                },
                validateScope: {}
            )
            #expect(refreshes == [false, true])
            #expect(fixture.provider.createdWorkspaces.map(\.id) == [starter.id])
            #expect(fixture.provider.terminalCreates == 0)
            #expect(fixture.provider.adoptedPanels == [admittedPanelID].compactMap { $0 })
            #expect(pending.cloudVMBinding?.remoteWorkspaceID == starter.id)
            #expect(fixture.manager.selectedTabId == selection)
        }
    }

    @Test("Failed discovery never creates from unknown or stale rows and retries the same pane", arguments: [false, true])
    func failedGraphRetainsPaneForRetry(staleEmptyRows: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let pending = fixture.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false)
            let invocation = try invocation(workspaceID: pending.id)
            let host = CloudWorkspaceCreationHost(manager: fixture.manager, reservedWorkspaceID: pending.id)
            if staleEmptyRows {
                fixture.provider.info.remoteWorkspaces = []
                fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
            }
            var refreshes: [Bool] = []
            await #expect(throws: (any Error).self) {
                try await InProcessMachineCreateLauncher.open(
                    invocation, provider: fixture.provider, catalog: fixture.catalog, host: host,
                    refreshGraph: { refreshes.append($0); return false }, validateScope: {}
                )
            }
            #expect(refreshes == [false, true])
            #expect(fixture.provider.createdWorkspaces.isEmpty)
            #expect(fixture.provider.terminalCreates == 0)
            let reservation = try #require(pending.cloudPendingCreations.values.first)
            reservation.inputRelay.send(.bytes(Data("echo retry\n".utf8)))
            let starter = SurfaceRemoteWorkspace(id: "starter", name: "Existing", index: 0, focused: true)
            fixture.provider.createdWorkspaces = [starter]
            try fixture.provider.publish(revision: 10)
            try await InProcessMachineCreateLauncher.open(
                invocation, provider: fixture.provider, catalog: fixture.catalog, host: host,
                refreshGraph: { _ in true }, validateScope: {}
            )
            #expect(fixture.provider.adoptedPanels == [reservation.panelID])
            #expect(reservation.inputRelay.pendingCount == 1)
            #expect(fixture.provider.createdWorkspaces.map(\.id) == [starter.id])
            #expect(pending.cloudPendingCreations.isEmpty)
        }
    }

    @Test("Only an authoritative empty graph permits creating a workspace")
    func successfulEmptyGraphCreatesOnce() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.info.remoteWorkspaces = []
            fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
            let pending = fixture.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false)
            try await InProcessMachineCreateLauncher.open(
                try invocation(workspaceID: pending.id), provider: fixture.provider, catalog: fixture.catalog,
                host: CloudWorkspaceCreationHost(manager: fixture.manager, reservedWorkspaceID: pending.id),
                refreshGraph: { _ in true }, validateScope: {}
            )
            #expect(fixture.provider.createdWorkspaces.count == 1)
            #expect(fixture.provider.terminalCreates == 0)
            #expect(fixture.provider.adoptedPanels.count == 1)
        }
    }

    @Test("Closed placement is rejected before graph work")
    func closedHostSkipsRefresh() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let pending = fixture.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false)
            let invocation = try invocation(workspaceID: pending.id)
            let host = CloudWorkspaceCreationHost(manager: fixture.manager, reservedWorkspaceID: pending.id)
            fixture.manager.closeWorkspace(pending, recordHistory: false)
            await #expect(throws: (any Error).self) {
                try await InProcessMachineCreateLauncher.open(
                    invocation, provider: fixture.provider, catalog: fixture.catalog, host: host,
                    refreshGraph: { _ in Issue.record("Closed host must not refresh"); return true }, validateScope: {}
                )
            }
            #expect(fixture.provider.createdWorkspaces.isEmpty)
        }
    }

    @Test("Scope loss during discovery prevents forced retry and attachment")
    func scopeLossFencesRefreshRetry() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let pending = fixture.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false)
            let invocation = try invocation(workspaceID: pending.id)
            var scopeIsValid = true
            var refreshes: [Bool] = []
            await #expect(throws: (any Error).self) {
                try await InProcessMachineCreateLauncher.open(
                    invocation, provider: fixture.provider, catalog: fixture.catalog,
                    host: CloudWorkspaceCreationHost(manager: fixture.manager, reservedWorkspaceID: pending.id),
                    refreshGraph: { force in refreshes.append(force); scopeIsValid = false; return false },
                    validateScope: { if !scopeIsValid { throw CloudDiagnosticFailure.sessionRefresh } }
                )
            }
            #expect(refreshes == [false])
            #expect(fixture.provider.createdWorkspaces.isEmpty)
            #expect(fixture.provider.adoptedPanels.isEmpty)
        }
    }

    private func invocation(workspaceID: UUID) throws -> InProcessMachineCreateLauncher.Invocation {
        try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "open", "fixture", "--workspace", workspaceID.uuidString, "--focus", "false"
        ]))
    }

    @Test func parsesTheAuthenticatedNewMachineSubset() throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--desktop", "--size", "8192", "--network-policy",
            #"{"mode":"full"}"#, "--agent-updates", "latest", "--focus", "false",
            "--workspace", workspace.uuidString
        ]))

        #expect(invocation.kind == .desktop)
        #expect(invocation.memoryMb == 8192)
        #expect(invocation.networkPolicy?.mode == .full)
        #expect(invocation.agentUpdates == .latest)
        #expect(invocation.workspaceID == workspace)
        #expect(invocation.focus == false)
    }

    @Test func rejectsPathsThatMustRemainOnTheCli() {
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "base", "open"]) == nil)
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "fork", "vm-1"]) == nil)
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "new", "--image", "legacy"]) == nil)
    }

    @Test func retryOpenKeepsTheReservedWorkspaceAndUsesTheInProcessParser() throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "open", "vm-1", "--workspace", workspace.uuidString, "--focus", "false"
        ]))
        #expect(invocation.machineID == "vm-1")
        #expect(invocation.workspaceID == workspace)
        #expect(invocation.focus == false)
    }

    @Test func oneOperationKeepsOneIdempotencyKeyAcrossRetries() {
        let operationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) == "app-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) != InProcessMachineCreateLauncher.idempotencyKey(operationID: UUID()))
    }
}
