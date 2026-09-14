import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Cloud browser pane can be built before ``AppDelegate`` installs the app's
/// shared tunnel coordinator. When the store hands that coordinator over later,
/// the pane must start observing tunnel state and its setup card must stop
/// claiming this build has no VPN extension. Otherwise the pane sits on the
/// setup card forever, which is what
/// https://github.com/manaflow-ai/cmux/pull/12583 set out to fix.
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
                machineID: use.machineID,
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
    }

    @Test("the setup card on a late-attached pane can act on the tunnel")
    func lateCoordinatorReachesTheSetupModel() {
        let store = CloudPortAccessStore()
        let model = Self.makeModel(store: store, port: 5173)
        #expect(model.vpn.unavailableMessage != nil)

        store.coordinator = Self.makeCoordinator()

        #expect(model.vpn.unavailableMessage == nil)
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
    }
}
