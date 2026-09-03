import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The tunnel policy as behavior: off until Cloud is used, one start per
/// demand burst, idle stop only when nothing is using the network, pinned by
/// `cmux vpn up`, torn down by sign-out and quit, and a no-op on the wg-quick
/// backend. Time is virtual (`SidebarTestManualClock`); the NetworkExtension
/// side is a fake that records calls and emits link status on demand.
@Suite(.timeLimit(.minutes(2)))
struct CloudTunnelCoordinatorTests {
    private static let extensionID = "com.cmuxterm.app.tests.tunnel"
    private static let networkExtension = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: extensionID)
    private static let use = CloudPrivateNetworkUse(machineID: "vm-1", purpose: .attach)

    private struct Harness {
        let coordinator: CloudTunnelCoordinator
        let controller: FakeTunnelController
        let enroller: FakeTunnelEnroller
        let consumers: FakeTunnelConsumers
        let clock: SidebarTestManualClock
        let timing: CloudTunnelCoordinator.Timing

        init(backend: CloudTunnelBackend = CloudTunnelCoordinatorTests.networkExtension) {
            let controller = FakeTunnelController()
            let enroller = FakeTunnelEnroller()
            let consumers = FakeTunnelConsumers()
            let clock = SidebarTestManualClock()
            let timing = CloudTunnelCoordinator.Timing(
                idleGrace: .seconds(300),
                readinessBudget: .seconds(20),
                connectTimeout: .seconds(45),
                stopTimeout: .seconds(10)
            )
            self.controller = controller
            self.enroller = enroller
            self.consumers = consumers
            self.clock = clock
            self.timing = timing
            coordinator = CloudTunnelCoordinator(
                backend: backend,
                controller: controller,
                enroller: enroller,
                consumers: consumers,
                clock: clock,
                timing: timing
            )
        }

        /// Wait for a state through the coordinator's own stream, bounded by
        /// a real (not virtual) deadline so a regression fails instead of
        /// hanging the suite.
        func awaitState(_ expected: CloudTunnelState) async -> CloudTunnelState {
            let updates = await coordinator.stateUpdates()
            return await withTaskGroup(of: CloudTunnelState?.self) { group in
                group.addTask {
                    for await state in updates where state == expected {
                        return state
                    }
                    return nil
                }
                group.addTask {
                    try? await ContinuousClock().sleep(for: .seconds(30))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? (await coordinator.state)
            }
        }
    }

    @Test("the first Cloud use enrolls, installs, starts, and waits for the link")
    func onDemandStart() async {
        let harness = Harness()
        #expect(await harness.coordinator.state == .off)
        #expect(harness.controller.calls.isEmpty)

        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)

        #expect(await harness.coordinator.state == .up)
        #expect(harness.controller.calls == ["install", "start"])
        #expect(harness.enroller.enrollCount == 1)
        #expect(harness.controller.installedConfigurations.first?.wgQuickConfig == FakeTunnelEnroller.config)
        #expect(harness.controller.installedConfigurations.first?.serverAddress == "vpn.example.com:51820")
    }

    @Test("an already-up tunnel makes later uses free")
    func repeatedUseDoesNotRestart() async {
        let harness = Harness()
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        await harness.coordinator.prepareForPrivateNetworkUse(CloudPrivateNetworkUse(machineID: "vm-2", purpose: .ssh))
        #expect(harness.controller.calls == ["install", "start"])
        #expect(harness.enroller.enrollCount == 1)
    }

    @Test("concurrent uses coalesce into one start")
    func concurrentUsesCoalesce() async {
        let harness = Harness()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await harness.coordinator.prepareForPrivateNetworkUse(
                        CloudPrivateNetworkUse(machineID: "vm-\(index)", purpose: .cmuxRemote)
                    )
                }
            }
        }
        #expect(await harness.coordinator.state == .up)
        #expect(harness.controller.calls == ["install", "start"])
        #expect(harness.enroller.enrollCount == 1)
    }

    @Test("the wg-quick backend never touches NetworkExtension")
    func wgQuickBackendIsInert() async {
        let harness = Harness(backend: .wgQuick(.entitlementMissing))
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await harness.coordinator.state == .off)
        #expect(harness.controller.calls.isEmpty)
        #expect(harness.enroller.enrollCount == 0)

        await #expect(throws: CloudTunnelError.backendUnavailable(.entitlementMissing)) {
            try await harness.coordinator.requestUp(pin: true)
        }
        harness.coordinator.appWillTerminate()
        #expect(harness.controller.calls.isEmpty)
    }

    @Test("the idle timer stops the tunnel once no consumer remains")
    func idleStopWithoutConsumers() async {
        let harness = Harness()
        harness.consumers.count = 0
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await harness.coordinator.state == .up)

        await harness.clock.waitUntilSleeping(for: harness.timing.idleGrace)
        harness.clock.advance(by: harness.timing.idleGrace)

        #expect(await harness.awaitState(.off) == .off)
        #expect(harness.controller.calls == ["install", "start", "stop"])
        #expect(harness.consumers.queries == 1)
    }

    @Test("live consumers keep the tunnel up; it stops one grace after the last one leaves")
    func idleStopWaitsForConsumers() async {
        let harness = Harness()
        harness.consumers.count = 2
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)

        await harness.clock.waitUntilSleeping(for: harness.timing.idleGrace)
        harness.clock.advance(by: harness.timing.idleGrace)
        // The timer re-arms after finding consumers; wait for that arm.
        await harness.clock.waitUntilSleeping(for: harness.timing.idleGrace)
        #expect(await harness.coordinator.state == .up)
        #expect(harness.controller.calls == ["install", "start"])
        #expect(harness.consumers.queries == 1)

        harness.consumers.count = 0
        harness.clock.advance(by: harness.timing.idleGrace)
        #expect(await harness.awaitState(.off) == .off)
        #expect(harness.controller.calls == ["install", "start", "stop"])
    }

    @Test("Cloud use restarts the idle clock")
    func useResetsIdleTimer() async {
        let harness = Harness()
        harness.consumers.count = 0
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        await harness.clock.waitUntilSleeping(for: harness.timing.idleGrace)

        harness.clock.advance(by: .seconds(200))
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        // The old deadline (t=300) is gone; a fresh one sits at t=200+300.
        await harness.clock.waitUntilSleeping(for: harness.timing.idleGrace)
        harness.clock.advance(by: .seconds(150))
        #expect(await harness.coordinator.state == .up)
        #expect(harness.consumers.queries == 0)

        harness.clock.advance(by: .seconds(150))
        #expect(await harness.awaitState(.off) == .off)
    }

    @Test("`cmux vpn up` pins the tunnel past idle until `cmux vpn down`")
    func pinnedTunnelIgnoresIdle() async throws {
        let harness = Harness()
        harness.consumers.count = 0
        try await harness.coordinator.requestUp(pin: true)
        #expect(await harness.coordinator.state == .up)
        #expect(await harness.coordinator.isPinned)
        // No idle timer is armed while pinned.
        await harness.clock.waitUntilIdle()
        harness.clock.advance(by: harness.timing.idleGrace * 3)
        #expect(await harness.coordinator.state == .up)
        #expect(harness.consumers.queries == 0)

        await harness.coordinator.requestDown()
        #expect(await harness.coordinator.state == .off)
        #expect(await harness.coordinator.isPinned == false)
        #expect(harness.controller.calls == ["install", "start", "stop"])
    }

    @Test("a failed start is reported, cleaned up, and retried on the next use")
    func startFailureThenRetry() async {
        let harness = Harness()
        harness.controller.startError = FakeTunnelController.Failure.refused
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        let failed = await harness.coordinator.state
        #expect(failed.failureMessage?.isEmpty == false)
        #expect(harness.controller.calls == ["install", "start", "stop"])

        harness.controller.startError = nil
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await harness.coordinator.state == .up)
        #expect(harness.controller.calls == ["install", "start", "stop", "install", "start"])
    }

    @Test("the readiness budget bounds how long a use waits, without giving up the start")
    func readinessBudgetBoundsTheWait() async {
        let harness = Harness()
        harness.controller.connectsOnStart = false
        let gate = Task { await harness.coordinator.prepareForPrivateNetworkUse(Self.use) }
        await harness.clock.waitUntilSleeping(for: harness.timing.readinessBudget)
        harness.clock.advance(by: harness.timing.readinessBudget)
        await gate.value
        // The caller was released while the start is still in flight.
        #expect(await harness.coordinator.state == .starting)

        harness.controller.emit(.connected)
        #expect(await harness.awaitState(.up) == .up)
    }

    @Test("a link that drops outside the app moves the state to off")
    func externalDisconnect() async {
        let harness = Harness()
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        harness.controller.emit(.disconnecting)
        harness.controller.emit(.disconnected)
        #expect(await harness.awaitState(.off) == .off)
        #expect(harness.controller.calls == ["install", "start"])
    }

    @Test("the first activation surfaces the System Settings approval wait")
    func awaitingApprovalIsVisible() async {
        let harness = Harness()
        harness.controller.holdInstallForApproval = true
        let gate = Task { await harness.coordinator.prepareForPrivateNetworkUse(Self.use) }
        #expect(await harness.awaitState(.awaitingApproval) == .awaitingApproval)
        let status = await harness.coordinator.status()
        #expect(status.state == .awaitingApproval)
        #expect(status.backend == Self.networkExtension)

        harness.controller.approve()
        await gate.value
        #expect(await harness.coordinator.state == .up)
    }

    @Test("a tunnel left connected by a previous app instance is adopted, not restarted")
    func adoptsAlreadyConnectedTunnel() async {
        let harness = Harness()
        harness.controller.currentStatusValue = .connected
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await harness.coordinator.state == .up)
        // Configuration is re-saved (install) but the live link is kept as is.
        #expect(harness.controller.calls == ["install"])
        #expect(harness.enroller.enrollCount == 1)
    }

    @Test("a superseded start that fails late does not stop the newer start's tunnel")
    func supersededStartFailureLeavesNewerTunnelAlone() async {
        let harness = Harness()
        harness.controller.holdInstallForApproval = true
        let first = Task { await harness.coordinator.prepareForPrivateNetworkUse(Self.use) }
        #expect(await harness.awaitState(.awaitingApproval) == .awaitingApproval)

        // `cmux vpn down` while the approval is pending supersedes start A.
        await harness.coordinator.requestDown()
        #expect(await harness.coordinator.state == .off)

        // Start B comes up normally.
        harness.controller.holdInstallForApproval = false
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await harness.coordinator.state == .up)
        let callsWithBUp = harness.controller.calls

        // Start A resumes with a failure; its cleanup must not touch B's tunnel.
        harness.controller.approve(with: FakeTunnelController.Failure.refused)
        await first.value
        #expect(await harness.coordinator.state == .up)
        #expect(harness.controller.calls == callsWithBUp)
    }

    @Test("sign-out and revoke tear the tunnel down; revoke also deletes the configuration")
    func signOutAndRevoke() async throws {
        let harness = Harness()
        try await harness.coordinator.requestUp(pin: true)
        await harness.coordinator.accessDidEnd()
        #expect(await harness.coordinator.state == .off)
        #expect(await harness.coordinator.isPinned == false)
        #expect(harness.controller.calls == ["install", "start", "stop"])

        try await harness.coordinator.revoke()
        #expect(harness.controller.calls == ["install", "start", "stop", "remove"])
    }

    @Test("quitting stops the tunnel synchronously")
    func terminationStopsSynchronously() async {
        let harness = Harness()
        await harness.coordinator.prepareForPrivateNetworkUse(Self.use)
        harness.coordinator.appWillTerminate()
        #expect(harness.controller.calls == ["install", "start", "stopForTermination"])
    }

    @Test("`vm.tunnel_wait` semantics: waitForState returns the settled state")
    func waitForStateSettles() async {
        let harness = Harness()
        harness.controller.connectsOnStart = false
        await harness.coordinator.beginUp(pin: false)
        let waiter = Task {
            await harness.coordinator.waitForState(timeout: .seconds(600)) { !$0.isSettling }
        }
        await harness.clock.waitUntilSleeping(for: .seconds(600))
        harness.controller.emit(.connected)
        #expect(await waiter.value == .up)
    }
}

// MARK: - Fakes

/// Records the coordinator's NetworkExtension requests and lets the test
/// drive link status. Lock-protected because the coordinator calls it from
/// its own actor and tests read it from the test's task.
final class FakeTunnelController: CloudTunnelControlling, @unchecked Sendable {
    enum Failure: Error { case refused }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var configurations: [CloudTunnelProviderConfiguration] = []
    private var continuations: [AsyncStream<CloudTunnelLinkStatus>.Continuation] = []
    private var approvalContinuations: [CheckedContinuation<Void, any Error>] = []
    private var _startError: (any Error)?
    private var _connectsOnStart = true
    private var _holdInstallForApproval = false
    private var _currentStatusValue: CloudTunnelLinkStatus = .disconnected

    var calls: [String] { lock.withLock { recorded } }
    var installedConfigurations: [CloudTunnelProviderConfiguration] { lock.withLock { configurations } }
    var startError: (any Error)? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    /// Emit `.connecting` then `.connected` right after `start()` (the normal
    /// NetworkExtension sequence). Off to hold the link in `.connecting`.
    var connectsOnStart: Bool {
        get { lock.withLock { _connectsOnStart } }
        set { lock.withLock { _connectsOnStart = newValue } }
    }
    /// `install` reports "needs user approval" and blocks until `approve()`.
    var holdInstallForApproval: Bool {
        get { lock.withLock { _holdInstallForApproval } }
        set { lock.withLock { _holdInstallForApproval = newValue } }
    }
    /// What `currentStatus()` answers: the link a previous app instance left behind.
    var currentStatusValue: CloudTunnelLinkStatus {
        get { lock.withLock { _currentStatusValue } }
        set { lock.withLock { _currentStatusValue = newValue } }
    }

    var statusUpdates: AsyncStream<CloudTunnelLinkStatus> {
        AsyncStream { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func emit(_ status: CloudTunnelLinkStatus) {
        for continuation in lock.withLock({ continuations }) {
            continuation.yield(status)
        }
    }

    /// Resolve every pending approval: the user allowed the extension, or
    /// (with `error`) macOS refused it.
    func approve(with error: (any Error)? = nil) {
        let waiting = lock.withLock {
            let pending = approvalContinuations
            approvalContinuations.removeAll()
            return pending
        }
        for continuation in waiting {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func currentStatus() async -> CloudTunnelLinkStatus { currentStatusValue }

    func install(
        _ configuration: CloudTunnelProviderConfiguration,
        onNeedsUserApproval: @escaping @Sendable () -> Void
    ) async throws {
        lock.withLock {
            recorded.append("install")
            configurations.append(configuration)
        }
        if holdInstallForApproval {
            onNeedsUserApproval()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { approvalContinuations.append(continuation) }
            }
        }
    }

    func start() async throws {
        lock.withLock { recorded.append("start") }
        if let error = startError { throw error }
        if connectsOnStart {
            emit(.connecting)
            emit(.connected)
        }
    }

    func stop() async throws {
        lock.withLock { recorded.append("stop") }
        emit(.disconnecting)
        emit(.disconnected)
    }

    func remove() async throws {
        lock.withLock { recorded.append("remove") }
    }

    nonisolated func stopForTermination() {
        lock.withLock { recorded.append("stopForTermination") }
    }
}

final class FakeTunnelEnroller: CloudTunnelEnrolling, @unchecked Sendable {
    static let config = """
    [Interface]
    PrivateKey = test
    Address = 100.64.0.9/32

    [Peer]
    PublicKey = peer
    Endpoint = vpn.example.com:51820
    AllowedIPs = 10.0.0.0/8
    """

    private let lock = NSLock()
    private var count = 0
    var enrollCount: Int { lock.withLock { count } }

    func enroll() async throws -> CloudTunnelEnrollment {
        lock.withLock { count += 1 }
        return CloudTunnelEnrollment(wgQuickConfig: Self.config, serverAddress: "vpn.example.com:51820")
    }
}

final class FakeTunnelConsumers: CloudTunnelConsumerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _queries = 0

    var count: Int {
        get { lock.withLock { _count } }
        set { lock.withLock { _count = newValue } }
    }
    var queries: Int { lock.withLock { _queries } }

    func liveConsumerCount() async -> Int {
        lock.withLock {
            _queries += 1
            return _count
        }
    }
}
