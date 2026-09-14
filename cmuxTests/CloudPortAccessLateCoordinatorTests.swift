import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Direct HTTPS panes can be restored before the shared tunnel coordinator is
/// installed. Late attachment observes it without activating NetworkExtension.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloudPortAccessLateCoordinatorTests {
    private static let use = CloudPrivateNetworkUse(machineID: "vm-1", purpose: .attach)

    private static func makeCoordinator() -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(
            backend: .networkExtension(extensionBundleIdentifier: "com.cmuxterm.app.tests.portaccess"),
            controller: FakeTunnelController(),
            enroller: FakeTunnelEnroller(),
            consumers: FakeTunnelConsumers()
        )
    }

    private static func makeModel(
        store: CloudPortAccessStore,
        port: Int
    ) -> CloudPortAccessModel {
        let target = CloudPortForwardTarget(host: "10.40.0.10", port: port)
        return store.model(machineID: use.machineID, target: target) {
            CloudPortAccessModel(
                target: target,
                coordinator: store.coordinator,
                wake: {},
                startForward: { _ in 10_001 },
                stopForward: {}
            )
        }
    }

    /// Polls on the main actor so the model's observation task gets to run.
    /// Bounded only so a regression fails instead of hanging the suite.
    private static func holds(
        _ predicate: @MainActor () -> Bool,
        within timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("a pane built before the coordinator lands connects once the store attaches it")
    func lateCoordinatorLeavesTheSetupCard() async {
        let store = CloudPortAccessStore()
        let model = Self.makeModel(store: store, port: 3000)
        #expect(model.phase == .needsVPN)

        let coordinator = Self.makeCoordinator()
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.state == .up)

        store.coordinator = coordinator

        #expect(await Self.holds { model.phase == .direct })
        #expect(model.tunnelState == .up)
        await coordinator.requestDown()
        await model.retire()
    }

    @Test("a pane keeps the coordinator it was built with")
    func attachDoesNotReplaceAnInstalledCoordinator() async {
        let store = CloudPortAccessStore()
        let connected = Self.makeCoordinator()
        await connected.prepareForPrivateNetworkUse(Self.use)
        store.coordinator = connected
        let model = Self.makeModel(store: store, port: 8080)
        #expect(await Self.holds { model.phase == .direct })

        // A second, never-started coordinator must not displace the first. The
        // pane proves which one it follows by tracking that one's transitions.
        store.coordinator = Self.makeCoordinator()

        await connected.requestDown()
        #expect(await Self.holds { model.phase == .needsVPN })
        await connected.prepareForPrivateNetworkUse(Self.use)
        #expect(await Self.holds { model.phase == .direct })
        await connected.requestDown()
        await model.retire()
    }

    @Test("a direct pane follows explicit CLI approval without starting a tunnel itself")
    func browserVPNStateStaysLive() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let coordinator = CloudTunnelCoordinator(
            backend: .networkExtension(extensionBundleIdentifier: "com.cmuxterm.app.tests.browser"),
            controller: controller,
            enroller: FakeTunnelEnroller(),
            consumers: FakeTunnelConsumers()
        )
        let model = CloudPortAccessModel(
            target: CloudPortForwardTarget(host: "10.40.0.10", port: 3000),
            coordinator: coordinator,
            wake: {},
            startForward: { _ in 10_001 },
            stopForward: {}
        )
        model.observe()
        await coordinator.beginUp(pin: true)
        #expect(await Self.holds { model.tunnelState == CloudTunnelState.awaitingApproval })
        #expect(model.phase == .needsVPN)
        await coordinator.requestDown()
        controller.approve(with: CancellationError())
        await model.retire()
    }
}
