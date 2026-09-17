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
        await status.refresh(coordinator)
        #expect(await coordinator.state == .off)
        #expect(builds == 0)
        #expect(enroller.enrollCount == 0)
        #expect(controller.calls.isEmpty)

        await coordinator.beginUp(pin: true)
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        #expect(builds == 1)
        #expect(enroller.enrollCount == 1)
        await coordinator.requestDown()
    }

    @Test("Cancelling approval returns setup to off without starting the VPN")
    func cancelApprovalReturnsToOff() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(
            backend: backend, controller: controller, enroller: enroller, consumers: FakeTunnelConsumers()
        )
        await coordinator.beginUp(pin: true)
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval } == .awaitingApproval)
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)
        #expect(!controller.calls.contains("start"))
        #expect(enroller.enrollCount == 1)
        controller.approve(with: CancellationError())
    }
}
