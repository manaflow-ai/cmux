import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud VPN requires an explicit connection", .timeLimit(.minutes(1)))
struct CloudVPNExplicitActivationTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "test.cloud.vpn")

    @Test("Repeated explicit up requests do not enroll or request extension approval again")
    func repeatedUpIsIdempotent() async throws {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(
            backend: backend, controller: controller, enroller: enroller, consumers: FakeTunnelConsumers()
        )
        try await coordinator.requestUp(pin: true)
        await coordinator.beginUp(pin: true)
        #expect(await coordinator.state == .up)
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { !$0.isSettling } == .up)
        #expect(controller.calls == ["install", "start"])
        #expect(enroller.enrollCount == 1)
        await coordinator.requestDown()
    }

    @Test("Launch, status observation, and opening setup do not materialize NetworkExtension")
    func browsingStatusIsPassive() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        var builds = 0
        let deferred = CloudTunnelDeferredController {
            builds += 1
            return controller
        }
        let coordinator = CloudTunnelCoordinator(
            backend: backend, controller: deferred, enroller: enroller, consumers: FakeTunnelConsumers()
        )
        let status = CloudTunnelStatusModel()
        let setup = CloudVPNSetupModel(coordinator: coordinator)
        await status.refresh(coordinator)
        await setup.refresh()
        #expect(setup.state == .off)
        #expect(builds == 0)
        #expect(enroller.enrollCount == 0)
        #expect(controller.calls.isEmpty)

        await setup.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        #expect(builds == 1)
        #expect(enroller.enrollCount == 1)
        await setup.disconnect()
    }

    @Test("Cancelling approval returns setup to off without starting the VPN")
    func cancelApprovalReturnsToOff() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(
            backend: backend, controller: controller, enroller: enroller, consumers: FakeTunnelConsumers()
        )
        let setup = CloudVPNSetupModel(coordinator: coordinator)
        await setup.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval } == .awaitingApproval)
        await setup.disconnect()
        await setup.refresh()
        #expect(setup.state == .off)
        #expect(!controller.calls.contains("start"))
        #expect(enroller.enrollCount == 1)
        controller.approve(with: CancellationError())
    }
}
