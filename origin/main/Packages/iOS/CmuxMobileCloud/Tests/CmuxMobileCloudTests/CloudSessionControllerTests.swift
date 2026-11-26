import Foundation
import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudSessionControllerTests {
    private func makeController(
        service: FakeCloudVMService? = nil,
        store: InMemoryCloudDeviceIdentityStore = InMemoryCloudDeviceIdentityStore(),
        starter: FakeTunnelStarter = FakeTunnelStarter(),
        connector: FakeConnector = FakeConnector(),
        clock: TestClock = TestClock()
    ) -> CloudSessionController {
        let selectedService = service ?? {
            let service = FakeCloudVMService()
            service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
            return service
        }()
        return CloudSessionController(
            service: selectedService,
            identityStore: store,
            tunnelStarter: starter,
            connector: connector,
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "Lawrence's iPhone",
            approvalClock: clock
        )
    }

    /// Yields until `condition` holds or the budget runs out.
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 2_000 where !condition() {
            await Task.yield()
        }
    }

    @Test func appearEnrollsStartsTunnelAndListsMachines() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let store = InMemoryCloudDeviceIdentityStore()
        let starter = FakeTunnelStarter()
        let controller = makeController(service: service, store: store, starter: starter)

        controller.sectionDidAppear()
        await settle { controller.machines == .loaded([CloudMachine(id: "vm1", provider: "freestyle", status: "running")]) }
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let storedIdentity = await store.stored
        let identity = try #require(storedIdentity)
        #expect(controller.tunnel == .ready(fingerprint: identity.fingerprint))
        #expect(service.calls.enroll.count == 1)
        #expect(service.calls.enroll[0].publicKey == identity.keyPair.publicKey)
        #expect(service.calls.enroll[0].fingerprint == identity.fingerprint)
        #expect(service.calls.enroll[0].purpose == .terminal)
        #expect(service.calls.enroll[0].deviceName == "Lawrence's iPhone")
        #expect(starter.startedConfigs.count == 1)
        #expect(starter.startedConfigs[0].contains("PrivateKey = \(identity.keyPair.privateKey)"))
        #expect(starter.startedConfigs[0].contains("PersistentKeepalive = 25"))
        #expect(service.calls.list == 1)
    }

    @Test func createMachineUsesTheExistingControlPlaneAndRefreshesTheList() async throws {
        let service = FakeCloudVMService()
        let controller = makeController(service: service)

        let created = await controller.createMachine(options: .init(kind: .desktop))

        #expect(created == CloudMachine(id: "vm-created", provider: "freestyle", status: "starting"))
        #expect(service.calls.create.count == 1)
        #expect(service.calls.create[0].options == .init(kind: .desktop))
        #expect(!service.calls.create[0].idempotencyKey.isEmpty)
        await settle { service.calls.list == 1 }
        #expect(controller.isCreatingMachine == false)
        #expect(controller.lastCreateFailure == nil)
    }

    @Test func cloudScreenWithNoMachinesDoesNotEnrollATunnel() async {
        let service = FakeCloudVMService()
        service.machines = .success([])
        let starter = FakeTunnelStarter()
        let controller = makeController(service: service, starter: starter)

        controller.sectionDidAppear()
        await settle { controller.machines == .loaded([]) }

        #expect(controller.tunnel == .idle)
        #expect(starter.startedConfigs.isEmpty)
        #expect(service.calls.enroll.isEmpty)
    }

    @Test func signOutCancelsAnInFlightCreateAndDropsItsLateResult() async {
        let service = FakeCloudVMService()
        service.holdCreation = true
        let controller = makeController(service: service)
        let createTask = Task { await controller.createMachine(options: .init(kind: .desktop)) }

        await service.waitForCreationStart()
        #expect(controller.isCreatingMachine)
        controller.resetForSignOut()
        #expect(!controller.isCreatingMachine)
        #expect(controller.lastCreateFailure == nil)

        await service.releaseHeldCreation()
        #expect(await createTask.value == nil)
        #expect(service.calls.list == 0)
        #expect(controller.machines == .idle)
    }

    @Test func cancellingCreateCallerCancelsTheProvisioningTask() async {
        let service = FakeCloudVMService()
        service.holdCreation = true
        let controller = makeController(service: service)
        let createTask = Task { await controller.createMachine(options: .init(kind: .desktop)) }

        await service.waitForCreationStart()
        createTask.cancel()
        await service.releaseHeldCreation()

        #expect(await createTask.value == nil)
        #expect(service.calls.list == 0)
        #expect(!controller.isCreatingMachine)
        #expect(controller.lastCreateFailure == nil)
    }

    @Test func retryingTheSameFailedCreateReusesItsIdempotencyKey() async {
        let service = FakeCloudVMService()
        service.creation = .failure(StubError(message: "timed out"))
        let controller = makeController(service: service)
        let options = CloudMachineCreateOptions(kind: .base)

        #expect(await controller.createMachine(options: options) == nil)
        service.creation = .success(CloudMachine(id: "vm-retried", provider: "freestyle", status: "starting"))
        _ = await controller.createMachine(options: options)

        #expect(service.calls.create.count == 2)
        #expect(service.calls.create[0].idempotencyKey == service.calls.create[1].idempotencyKey)
    }

    @Test func disappearDropsTunnelAndForegroundReturnRestartsOnlyWhileVisible() async {
        let starter = FakeTunnelStarter()
        let controller = makeController(starter: starter)

        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        controller.sectionDidDisappear()
        #expect(controller.tunnel == .idle)
        #expect(controller.sectionIsVisible == false)

        controller.sceneWillEnterForeground()
        #expect(controller.tunnel == .idle, "foreground alone never starts a tunnel")

        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(starter.startedConfigs.count == 2)
    }

    @Test func pushedScreenKeepsTheTunnelWhenTheSectionDisappears() async {
        let starter = FakeTunnelStarter()
        let controller = makeController(starter: starter)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        // Catalog pushed: its appear lands before the section's disappear.
        controller.sectionDidAppear()
        controller.sectionDidDisappear()
        #expect(controller.sectionIsVisible)
        if case .ready = controller.tunnel {} else { Issue.record("tunnel dropped during push") }
        #expect(starter.startedConfigs.count == 1)
        // Pop back: section appears, catalog disappears.
        controller.sectionDidAppear()
        controller.sectionDidDisappear()
        if case .ready = controller.tunnel {} else { Issue.record("tunnel dropped during pop") }
        // Leave the section entirely.
        controller.sectionDidDisappear()
        #expect(controller.tunnel == .idle)
        #expect(controller.visibleScreenCount == 0)
    }

    @Test func backgroundStopsAndForegroundRestartsWhileVisible() async {
        let starter = FakeTunnelStarter()
        let controller = makeController(starter: starter)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        controller.sceneDidEnterBackground()
        #expect(controller.tunnel == .idle)
        #expect(controller.isForeground == false)

        controller.sceneWillEnterForeground()
        #expect(controller.tunnel == .starting)
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(starter.startedConfigs.count == 2)
    }

    @Test func shellLeaseHoldsTheTunnelWithNoCloudScreenVisible() async {
        // Cloud terminals open from the Workspaces tab, where no Cloud screen
        // is on screen, so the shell's lease alone must bring the tunnel up.
        let controller = makeController()
        #expect(!controller.sectionIsVisible)

        controller.setShellLease(true)
        await settle { if case .ready = controller.tunnel { return true }; return false }
        if case .ready = controller.tunnel {} else { Issue.record("tunnel not ready: \(controller.tunnel)") }

        // Taking the lease twice is a no-op, not a second enrollment.
        controller.setShellLease(true)
        #expect(controller.shellLeaseActive)

        controller.setShellLease(false)
        #expect(controller.tunnel == .idle)
    }

    @Test func shellLeaseStillYieldsToTheBackground() async {
        let controller = makeController()
        controller.setShellLease(true)
        await settle { if case .ready = controller.tunnel { return true }; return false }

        controller.sceneDidEnterBackground()
        #expect(controller.tunnel == .idle)

        controller.sceneWillEnterForeground()
        #expect(controller.tunnel == .starting)
    }

    @Test func machineListNeedsNoTunnelAndSurvivesATunnelStop() async {
        // Listing is a control-plane read: an account with no machines must
        // see its (empty) list and the create action without any tunnel, and
        // a tunnel stop mid-refresh must not strand the list loading.
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let controller = makeController(service: service)

        controller.refreshMachines()
        controller.setShellLease(true)
        controller.setShellLease(false)
        await settle { controller.machines == .loaded([CloudMachine(id: "vm1", provider: "freestyle", status: "running")]) }

        #expect(controller.machines.elements.map(\.id) == ["vm1"])
    }

    @Test func aConnectionCreatedAfterAListSnapshotIsClosedWhenTheListOmitsIt() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([])
        let controller = makeController(service: service)
        controller.setShellLease(true)
        await settle { if case .ready = controller.tunnel { return true }; return false }

        let machine = CloudMachine(id: "vm-created", provider: "freestyle", status: "running")
        let oldConnection = try #require(controller.connection(for: machine))
        controller.refreshMachines()
        await settle { service.calls.list == 2 && controller.machines == .loaded([]) }

        let newConnection = try #require(controller.connection(for: machine))
        #expect(newConnection !== oldConnection)
    }

    @Test func signOutResetForgetsTheAccountButKeepsTheDeviceIdentity() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let store = InMemoryCloudDeviceIdentityStore()
        let controller = makeController(service: service, store: store)
        controller.setShellLease(true)
        await settle {
            guard controller.machines.elements.count == 1 else { return false }
            if case .ready = controller.tunnel { return true }
            return false
        }
        let identityBefore = await store.stored

        controller.resetForSignOut()

        #expect(controller.tunnel == .idle)
        #expect(controller.machines == .idle)
        #expect(!controller.shellLeaseActive)
        // The phone keeps one identity across accounts; only the enrollment
        // under the new account is new.
        let identityAfter = await store.stored
        #expect(identityAfter == identityBefore)
    }

    @Test func enrollFailureBecomesFailedPhaseAndRetryReenrolls() async {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        service.enrollment = .failure(CloudAPIError.httpStatus(503, message: "provider down", action: nil))
        let controller = makeController(service: service)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        #expect(controller.tunnel == .failed(CloudSessionFailure(kind: .controlPlane(status: 503), detail: "provider down")))
        #expect(controller.machines == .loaded([CloudMachine(id: "vm1", provider: "freestyle", status: "running")]))

        service.enrollment = .success(Fixtures.enrollment)
        controller.retryTunnel()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        #expect(service.calls.enroll.count == 2)
    }

    @Test func aRefusedAttachIsVisibleAndARetryDialsFresh() async throws {
        let service = FakeCloudVMService()
        let machine = CloudMachine(id: "vm1", provider: "freestyle", status: "running")
        service.machines = .success([machine])
        service.attach = .failure(CloudAPIError.httpStatus(
            502,
            message: "Cloud VM service is temporarily unavailable.",
            action: "Try again in a minute."
        ))
        let controller = makeController(service: service)
        controller.setShellLease(true)
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let connection = try #require(controller.connection(for: machine))
        await #expect(throws: CloudAPIError.self) { _ = try await connection.loadCatalog() }
        let failure = try #require(controller.connectionFailure(for: machine.id))
        #expect(failure.kind == .controlPlane(status: 502))
        #expect(failure.detail == "Cloud VM service is temporarily unavailable.")
        #expect(failure.action == "Try again in a minute.")

        let generation = controller.connectionRetryGeneration
        controller.retryConnections()
        #expect(controller.connectionRetryGeneration == generation + 1)
        #expect(controller.connectionFailure(for: machine.id) == nil)
        // The failed link was dropped, so the next read dials a new one.
        let fresh = try #require(controller.connection(for: machine))
        #expect(fresh !== connection)

        service.attach = .success(CloudAttachEndpoint(route: "ws://[fd00::10]:1337/v1/link", session: "s1"))
        _ = try await fresh.loadCatalog()
        #expect(controller.connectionFailure(for: machine.id) == nil)
        #expect(service.calls.attach.count == 2)
    }

    @Test func signedOutIsClassified() async {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        service.enrollment = .failure(CloudAPIError.notSignedIn)
        let controller = makeController(service: service)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .signedOut)
    }

    @Test func tunnelStartFailureIsClassifiedAsTunnel() async {
        let starter = FakeTunnelStarter()
        starter.failure = StubError(message: "handshake timeout")
        let controller = makeController(starter: starter)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .tunnel)
        #expect(failure.detail.contains("handshake timeout"))
    }

    @Test func tunnelStartupTimeoutBecomesRetryableFailure() async {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: HangingTunnelStarter(),
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "phone",
            tunnelStartupTimeout: .milliseconds(20)
        )

        controller.sectionDidAppear()
        try? await Task.sleep(for: .milliseconds(50))
        await settle { if case .failed = controller.tunnel { return true } else { return false } }

        guard case .failed(let failure) = controller.tunnel else {
            Issue.record("expected the hung startup to fail")
            return
        }
        #expect(failure.kind == .tunnel)
        #expect(failure.isRetryable)
    }

    @Test func lockedIdentityStoreNeverMintsAndReportsIdentityFailure() async {
        let store = InMemoryCloudDeviceIdentityStore(unavailable: true)
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let controller = makeController(service: service, store: store)
        controller.sectionDidAppear()
        await settle { if case .failed = controller.tunnel { return true } else { return false } }
        guard case .failed(let failure) = controller.tunnel else { Issue.record("expected failure"); return }
        #expect(failure.kind == .identity)
        #expect(service.calls.enroll.isEmpty)
        #expect(await store.stored == nil)
    }

    @Test func disappearDuringStartDiscardsTheLateTunnel() async {
        let gate = GatedTunnelStarter()
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: gate,
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "phone"
        )
        controller.sectionDidAppear()
        await settle { gate.pending }
        controller.sectionDidDisappear()
        gate.release()
        await settle { gate.released }
        for _ in 0 ..< 200 { await Task.yield() }
        #expect(controller.tunnel == .idle)
        #expect(controller.connection(for: CloudMachine(id: "vm", provider: "p", status: "running")) == nil)
    }

    @Test func disappearDuringStartCancelsTheTunnelStartupTask() async {
        let starter = CancellableTunnelStarter()
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let controller = CloudSessionController(
            service: service,
            identityStore: InMemoryCloudDeviceIdentityStore(),
            tunnelStarter: starter,
            connector: FakeConnector(),
            stateDirectory: Fixtures.stateDirectory(),
            deviceName: "phone"
        )

        controller.sectionDidAppear()
        await settle { starter.started }
        controller.sectionDidDisappear()
        await settle { starter.cancelled }

        #expect(starter.cancelled)
        #expect(controller.tunnel == .idle)
    }

    @Test func connectionOpensLinkWithInvitationApprovalAndReusesSession() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        service.attach = .success(CloudAttachEndpoint(
            route: "ws://[fd00::10]:1337/v1/link", session: "s1",
            invitation: .init(uri: "cmux-remote+invite://abc", invitationId: "inv1")
        ))
        service.approvals = [false, true]
        let connector = FakeConnector()
        let clock = TestClock()
        let controller = makeController(service: service, connector: connector, clock: clock)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let machine = CloudMachine(id: "vm1", provider: "freestyle", status: "running")
        let connection = try #require(controller.connection(for: machine))
        #expect(controller.connection(for: machine) === connection)

        connection.refreshTerminals()
        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 1 && clock.sleepers == 1 }
        #expect(connector.session.loadCatalogCalls == 0)
        clock.advance(by: .seconds(2))
        await settle { connection.terminals == .loaded([CloudTerminalSummary(id: "t1", name: "shell")]) }
        #expect(service.calls.approve.count == 2)
        #expect(connector.connects.count == 1)
        #expect(connector.connects[0].route == "ws://[fd00::10]:1337/v1/link")
        #expect(connector.connects[0].invitation == "cmux-remote+invite://abc")
        #expect(!connector.connects[0].trustedCarrier)
        #expect(connector.connects[0].hasTunnel)
        #expect(connector.connects[0].deviceName == "Lawrence's iPhone")
        #expect(service.calls.attach.count == 1)

        let created = await connection.createTerminal(name: "phone")
        #expect(created == "t2")
        await settle { connection.terminals.elements.count == 2 }
        #expect(connector.connects.count == 1, "the session is reused")

        let attachment = try await connection.attach(terminalID: "t2") { _ in }
        attachment.send(Data("ls\n".utf8))
        attachment.resize(cols: 60, rows: 20)
        attachment.resize(cols: 0, rows: 20)
        attachment.detach()
        let state = connector.session.state
        #expect(state.attached == "t2")
        #expect(state.sent == [Data("ls\n".utf8)])
        #expect(state.resizes.count == 1)
        #expect(state.detached == 1)

        controller.sectionDidDisappear()
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func refreshUsesTheCombinedCatalogSoTerminalsKeepTheirWorkspace() async throws {
        let connector = FakeConnector()
        connector.session.workspaces = [CloudWorkspaceSummary(id: "workspace-1", name: "API")]
        connector.session.terminals = [CloudTerminalSummary(id: "terminal-1", workspaceID: "workspace-1")]
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))
        connection.refreshTerminals()
        await settle { connection.terminals == .loaded(connector.session.terminals) }

        #expect(connector.session.loadCatalogCalls == 1)
        #expect(connection.workspaces == .loaded(connector.session.workspaces))
        #expect(connection.terminals == .loaded([CloudTerminalSummary(id: "terminal-1", workspaceID: "workspace-1")]))
    }

    @Test func closeInvalidatesAnInFlightTerminalCreate() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.session.createTerminalGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))

        let createTask = Task { await connection.createTerminal(name: "late") }
        await started.wait()
        connection.close()
        await release.signal()

        #expect(await createTask.value == nil)
        #expect(connection.lastError == nil)
        #expect(connection.terminals == .idle)
        #expect(connector.session.loadCatalogCalls == 0)
    }

    @Test func canceledTerminalCreateDoesNotMutateCachedSession() async throws {
        let connector = FakeConnector()
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))
        _ = try await connection.loadCatalog()

        let started = TestSignal()
        let release = TestSignal()
        let createTask = Task { @MainActor in
            await started.signal()
            await release.wait()
            return await connection.createTerminal(name: "cancelled")
        }
        await started.wait()
        createTask.cancel()
        await release.signal()

        #expect(await createTask.value == nil)
        #expect(connector.session.state.created.isEmpty)
        #expect(connection.lastError == nil)
    }

    @Test func closeInvalidatesAnInFlightTerminalAttach() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.session.attachGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))
        _ = try await connection.loadCatalog()

        let attachTask = Task {
            try await connection.attach(terminalID: "t1") { _ in }
        }
        await started.wait()
        connection.close()
        await release.signal()

        do {
            _ = try await attachTask.value
            Issue.record("attach unexpectedly succeeded after close")
        } catch is CancellationError {
            // Closing the connection invalidates the native attach result.
        }
        #expect(connector.session.state.detached == 1)
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func overlappingAttachmentsAreSerialized() async throws {
        let connector = FakeConnector()
        let firstStarted = TestSignal()
        let firstRelease = TestSignal()
        let secondStarted = TestSignal()
        let secondRelease = TestSignal()
        connector.session.attachGates = [
            (started: firstStarted, release: firstRelease),
            (started: secondStarted, release: secondRelease),
        ]
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))
        _ = try await connection.loadCatalog()

        let first = Task { try await connection.attach(terminalID: "t1") { _ in } }
        await firstStarted.wait()
        let second = Task { try await connection.attach(terminalID: "t2") { _ in } }
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(connector.session.state.attachStarted == ["t1"])
        await firstRelease.signal()
        let firstAttachment = try await first.value
        #expect(connector.session.state.attachStarted == ["t1"])
        firstAttachment.detach()
        await secondStarted.wait()
        #expect(connector.session.state.attachStarted == ["t1", "t2"])
        await secondRelease.signal()
        let secondAttachment = try await second.value
        secondAttachment.detach()
        #expect(connector.session.state.detached == 2)
    }

    @Test func cancelledAttachCannotDetachANewerAttachment() async throws {
        let connector = FakeConnector()
        let firstStarted = TestSignal()
        let firstRelease = TestSignal()
        let secondStarted = TestSignal()
        let secondRelease = TestSignal()
        connector.session.attachGates = [
            (started: firstStarted, release: firstRelease),
            (started: secondStarted, release: secondRelease),
        ]
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))
        _ = try await connection.loadCatalog()

        let first = Task { try await connection.attach(terminalID: "t1") { _ in } }
        await firstStarted.wait()
        first.cancel()

        let second = Task { try await connection.attach(terminalID: "t2") { _ in } }
        await firstRelease.signal()

        do {
            _ = try await first.value
            Issue.record("cancelled attach unexpectedly succeeded")
        } catch is CancellationError {
            // The cancelled attach must release its turn before the newer one.
        }
        await secondStarted.wait()
        await secondRelease.signal()
        let secondAttachment = try await second.value
        #expect(connector.session.state.attached == "t2")
        #expect(connector.session.state.attachStarted == ["t1", "t2"])
        #expect(connector.session.state.detached == 1)

        secondAttachment.detach()
        #expect(connector.session.state.detached == 2)
    }

    @Test func overlappingWorkspaceCreatesAreRejected() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.session.createWorkspaceGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))

        let first = Task { await connection.createWorkspace(name: "first") }
        await started.wait()
        #expect(connection.isCreatingWorkspace)
        #expect(await connection.createWorkspace(name: "second") == nil)
        await release.signal()

        #expect(await first.value == "workspace-created")
        #expect(!connection.isCreatingWorkspace)
    }

    @Test func overlappingTerminalCreatesAreRejected() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.session.createTerminalGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "freestyle", status: "running")))

        let first = Task { await connection.createTerminal(name: "first") }
        await started.wait()
        #expect(connection.isCreatingTerminal)
        #expect(await connection.createTerminal(name: "second") == nil)
        await release.signal()

        #expect(await first.value == "t2")
        #expect(!connection.isCreatingTerminal)
    }

    @Test func closedConnectionCannotDialAgain() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "freestyle", status: "running")])
        let connector = FakeConnector()
        let controller = makeController(service: service, connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }

        let machine = CloudMachine(id: "vm1", provider: "freestyle", status: "running")
        let connection = try #require(controller.connection(for: machine))
        _ = try await connection.loadCatalog()
        #expect(service.calls.attach.count == 1)

        connection.close()
        await #expect(throws: CancellationError.self) {
            _ = try await connection.loadCatalog()
        }
        #expect(service.calls.attach.count == 1)
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func firstUseOfTrustedCloudMachineDoesNotRequireInvitation() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm-new", provider: "freestyle", status: "running")])
        // Current Cloud servers authenticate through the private network and
        // explicitly return trustedCarrier without minting an invitation.
        service.attach = .success(try CloudAPIResponseDecoding().attachEndpoint(from: Data(#"{"transport":"cmux-remote","route":"ws://[fd00::10]:1337/v1/link","session":"cmux","trustedCarrier":true}"#.utf8)))
        let connector = FakeConnector()
        let controller = makeController(service: service, connector: connector)
        controller.sectionDidAppear()
        defer { controller.sectionDidDisappear() }
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm-new", provider: "freestyle", status: "running")))

        let terminalID = await connection.createTerminal(name: "phone")
        #expect(terminalID == "t2")
        let connect = try #require(connector.connects.first)
        #expect(connect.trustedCarrier, "The server's trust mode must reach the terminal client on first contact")
        #expect(connect.invitation == nil)
        #expect(connect.hasTunnel)
        #expect(service.calls.approve.isEmpty)
    }

    @Test func approvalLoopPollsUntilGranted() async throws {
        let service = FakeCloudVMService()
        service.approvals = [false, false, true]
        let clock = TestClock()
        let loop = Task {
            try await CloudMachineConnection.approveUntilGranted(service: service, machineID: "vm1", invitationId: "inv", clock: clock)
        }
        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 1 && clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 2 && clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        try await loop.value
        #expect(service.calls.approve.count == 3)
    }

    @Test func approvalLoopReportsADepletedInvitation() async {
        let service = FakeCloudVMService()
        service.approvals = [false]
        let clock = TestClock()
        let loop = Task {
            try await CloudMachineConnection.approveUntilGranted(
                service: service,
                machineID: "vm1",
                invitationId: "inv",
                clock: clock,
                attemptLimit: 2
            )
        }

        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 1 && clock.sleepers == 1 }
        clock.advance(by: .seconds(2))

        do {
            try await loop.value
            Issue.record("approval unexpectedly succeeded")
        } catch {
            #expect(String(describing: error) == "cloud invitation approval timed out")
        }
    }

    @Test func approvalTimeoutCancelsAnInFlightRequest() async {
        let service = FakeCloudVMService()
        service.approvals = [false]
        service.approvalDelay = .seconds(10)
        let clock = TestClock()
        let loop = Task {
            try await CloudMachineConnection.approveUntilGranted(
                service: service,
                machineID: "vm1",
                invitationId: "inv",
                clock: clock,
                timeout: .milliseconds(100)
            )
        }

        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { service.calls.approve.count == 1 }

        do {
            try await loop.value
            Issue.record("approval unexpectedly succeeded")
        } catch {
            #expect(String(describing: error) == "cloud invitation approval timed out")
        }
    }

    @Test func approvalFailureReachesCatalogBeforeLateConnectReturns() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "p", status: "running")])
        service.attach = .success(CloudAttachEndpoint(
            route: "ws://[fd00::10]:1337/v1/link", session: "s1",
            invitation: .init(uri: "cmux-remote+invite://abc", invitationId: "inv1")
        ))
        service.approvalFailure = CloudAPIError.httpStatus(404, message: nil, action: nil)
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.connectGate = (started, release)
        let clock = TestClock()
        let controller = makeController(service: service, connector: connector, clock: clock)
        controller.sectionDidAppear()
        defer { controller.sectionDidDisappear() }
        await settle { if case .ready = controller.tunnel { return true }; return false }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))

        connection.refreshTerminals()
        await started.wait()
        await settle { clock.sleepers == 1 }
        clock.advance(by: .seconds(2))
        await settle { if case .failed = connection.terminals { return true }; return false }
        #expect(connection.lastError?.kind == .link)
        #expect(connection.lastError?.isRetryable == true)
        #expect(connector.session.loadCatalogCalls == 0)

        await release.signal()
        await settle { connector.session.state.disconnected == 1 }
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func approvalFailureAfterConnectionStillRejectsTheSession() async throws {
        let service = FakeCloudVMService()
        service.machines = .success([CloudMachine(id: "vm1", provider: "p", status: "running")])
        service.attach = .success(CloudAttachEndpoint(
            route: "ws://[fd00::10]:1337/v1/link", session: "s1",
            invitation: .init(uri: "cmux-remote+invite://abc", invitationId: "inv1")
        ))
        service.approvalFailure = CloudAPIError.httpStatus(404, message: nil, action: nil)
        let connector = FakeConnector()
        let clock = TestClock()
        let controller = makeController(service: service, connector: connector, clock: clock)
        controller.sectionDidAppear()
        defer { controller.sectionDidDisappear() }
        await settle { if case .ready = controller.tunnel { return true }; return false }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))

        let load = Task {
            try await connection.loadCatalog()
        }
        await settle { clock.sleepers == 1 && connector.connects.count == 1 }
        #expect(connector.session.loadCatalogCalls == 0)
        clock.advance(by: .seconds(2))

        do {
            _ = try await load.value
            Issue.record("catalog unexpectedly succeeded after approval failure")
        } catch {
            #expect(String(describing: error) == "cloud invitation expired")
        }
        #expect(connector.session.loadCatalogCalls == 0)
        await settle { connector.session.state.disconnected == 1 }
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func cancellingCatalogCancelsConnectionAndDisconnectsLateSession() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.connectGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true }; return false }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))

        let load = Task {
            try await connection.loadCatalog()
        }
        await started.wait()
        load.cancel()
        await release.signal()

        do {
            _ = try await load.value
            Issue.record("catalog unexpectedly succeeded after cancellation")
        } catch is CancellationError {
            // Expected: cancellation must reach the in-flight connect task.
        }
        await settle { connector.session.state.disconnected == 1 }
        #expect(connector.session.state.disconnected == 1)
    }

    @Test func refreshingDuringInitialConnectionRetriesAfterCancellation() async throws {
        let connector = FakeConnector()
        let started = TestSignal()
        let release = TestSignal()
        connector.connectGate = (started, release)
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true }; return false }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))

        connection.refreshTerminals()
        await started.wait()
        try? await Task.sleep(for: .milliseconds(20))
        connection.refreshTerminals()
        connector.connectGate = nil
        await release.signal()

        await settle { connection.terminals == .loaded([CloudTerminalSummary(id: "t1", name: "shell")]) }
        #expect(connection.terminals == .loaded([CloudTerminalSummary(id: "t1", name: "shell")]))
    }

    @Test func linkFailureIsReportedOnTheCatalog() async throws {
        let connector = FakeConnector()
        connector.failure = StubError(message: "unreachable")
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let connection = try #require(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")))
        connection.refreshTerminals()
        await settle { if case .failed = connection.terminals { return true } else { return false } }
        guard case .failed(let failure, let previous) = connection.terminals else { Issue.record("expected failure"); return }
        #expect(failure.kind == .link)
        #expect(previous.isEmpty)
        #expect(controller.connectionFailure(for: "vm1") == failure)

        controller.retryConnections()
        #expect(controller.connectionFailure(for: "vm1") == nil)
        #expect(controller.connection(for: CloudMachine(id: "vm1", provider: "p", status: "running")) !== connection)
    }

    @Test func attachFailureIsReportedForGlobalRetry() async throws {
        let connector = FakeConnector()
        let controller = makeController(connector: connector)
        controller.sectionDidAppear()
        await settle { if case .ready = controller.tunnel { return true } else { return false } }
        let machine = CloudMachine(id: "vm1", provider: "p", status: "running")
        let connection = try #require(controller.connection(for: machine))
        _ = try await connection.loadCatalog()
        connector.session.attachFailure = StubError(message: "attach failed")

        await #expect(throws: StubError.self) {
            _ = try await connection.attach(terminalID: "t1") { _ in }
        }
        #expect(controller.connectionFailure(for: machine.id)?.kind == .link)

        controller.retryConnections()
        #expect(controller.connectionFailure(for: machine.id) == nil)
        #expect(controller.connection(for: machine) !== connection)
    }
}

/// A tunnel starter that parks until released, to exercise cancellation order.
final class GatedTunnelStarter: CloudTunnelStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var _pending = false
    private var _released = false

    var pending: Bool { lock.withLock { _pending } }
    var released: Bool { lock.withLock { _released } }

    func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                continuation = c
                _pending = true
            }
        }
        lock.withLock { _released = true }
        return FakeTunnel(config: wgQuickConfig)
    }

    func release() {
        let c = lock.withLock { continuation }
        c?.resume()
    }
}

/// A tunnel starter that records when the controller cancels startup.
final class CancellableTunnelStarter: CloudTunnelStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled = false

    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        lock.withLock { _started = true }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        return FakeTunnel(config: wgQuickConfig)
    }
}

/// A tunnel starter that only completes when cancellation reaches its sleep.
final class HangingTunnelStarter: CloudTunnelStarting, @unchecked Sendable {
    func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        try await Task.sleep(for: .seconds(3_600))
        return FakeTunnel(config: wgQuickConfig)
    }
}

/// A manually advanced clock for the approval loop.
final class TestClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private struct Waiter {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleepers: Int { lock.withLock { waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                var result: Result<Void, any Error>?
                lock.withLock {
                    if Task.isCancelled {
                        result = .failure(CancellationError())
                    } else if deadline <= current {
                        result = .success(())
                    } else {
                        waiters.append(Waiter(id: id, deadline: deadline, continuation: c))
                    }
                }
                if let result {
                    c.resume(with: result)
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.advanced(by: duration)
            let (ready, waiting) = waiters.reduce(into: ([CheckedContinuation<Void, any Error>](), [Waiter]())) { acc, entry in
                if entry.deadline <= current { acc.0.append(entry.continuation) } else { acc.1.append(entry) }
            }
            waiters = waiting
            return ready
        }
        for c in due { c.resume() }
    }
}
