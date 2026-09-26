import AppKit
import CmuxCloud
import CmuxCloudBannerCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud VPN setup", .serialized, .timeLimit(.minutes(1)))
struct CloudVPNSetupTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "test.cloud.vpn")

    @Test("Opening and observing setup never enrolls or activates the VPN")
    func openingIsPassive() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller)
        let presenter = CloudVPNSetupWindowController(coordinator: coordinator)
        let first = presenter.managedWindow()
        #expect(presenter.managedWindow() === first)
        #expect(first.identifier?.rawValue == "cmux.cloudVPNSetup")
        await presenter.model.refresh()
        #expect(presenter.model.state == .off && presenter.model.canConnect)
        #expect(controller.calls.isEmpty && enroller.enrollCount == 0)
        presenter.close()
        #expect(presenter.window == nil)
        #expect(await coordinator.state == .off)
    }

    @Test("Unsupported builds explain the missing capability and never offer a working connect action")
    func unsupportedBuild() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(backend: .unavailable(.entitlementMissing),
            controller: controller, enroller: enroller, consumers: FakeTunnelConsumers())
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(!model.canConnect && !model.canDisconnect)
        #expect(model.unavailableMessage?.contains("signed VPN extension") == true)
        #expect(model.unavailableMessage?.contains("Ports") == true)
        #expect(controller.calls.isEmpty && enroller.enrollCount == 0)
    }

    @Test("Setup waits for status and accepts a late coordinator once")
    func lateCoordinator() async {
        let controller = FakeTunnelController()
        let model = CloudVPNSetupModel(coordinator: nil)
        #expect(!model.canConnect)
        let coordinator = makeCoordinator(controller: controller)
        #expect(model.attachIfNeeded(coordinator))
        #expect(!model.attachIfNeeded(makeCoordinator()))
        #expect(model.isCheckingStatus && !model.canConnect)
        await model.refresh()
        #expect(!model.isCheckingStatus && model.canConnect)
        #expect(controller.calls.isEmpty)
    }

    @Test("Only explicit Connect enrolls, and closing setup leaves the chosen VPN running")
    func explicitConnectAndDisconnect() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller)
        let presenter = CloudVPNSetupWindowController(coordinator: coordinator)
        _ = presenter.managedWindow()
        await presenter.model.refresh()
        await presenter.model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await presenter.model.refresh()
        #expect(presenter.model.canDisconnect && !presenter.model.canConnect)
        #expect(controller.calls == ["install", "start"] && enroller.enrollCount == 1)
        presenter.close()
        #expect(await coordinator.state == .up)
        _ = presenter.managedWindow()
        await presenter.model.refresh()
        #expect(presenter.model.state == .up)
        await presenter.model.disconnect()
        #expect(presenter.model.state == .off && presenter.model.canConnect)
        presenter.close()
    }

    @Test("Approval wait shows its explanation and remains cancellable")
    func approvalCanBeCancelled() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let coordinator = makeCoordinator(controller: controller)
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval } == .awaitingApproval)
        await model.refresh()
        #expect(model.statusTitle == String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting"))
        #expect(model.statusMessage?.contains("System Settings") == true)
        #expect(model.canDisconnect && !model.canConnect)
        await model.disconnect()
        #expect(model.state == .off && !controller.calls.contains("start"))
        controller.approve(with: CancellationError())
    }

    @Test("Admission refusal is visible and does not touch the system VPN")
    func refusalIsExplained() async {
        let controller = FakeTunnelController()
        let coordinator = CloudTunnelCoordinator(backend: backend, controller: controller,
            enroller: FakeTunnelEnroller(), consumers: FakeTunnelConsumers(),
            admission: .constant { .noCloudMachine })
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(model.errorMessage == CloudTunnelStartRefusal.noCloudMachine.error.description)
        #expect(model.state == .off && model.canConnect && controller.calls.isEmpty)
    }

    @Test("A failed start stays actionable and an explicit retry can connect")
    func failedStartCanRetry() async {
        let controller = FakeTunnelController()
        controller.startError = FakeTunnelController.Failure.refused
        let coordinator = makeCoordinator(controller: controller)
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        let failed = await coordinator.waitForState(timeout: .seconds(5)) { if case .failed = $0 { true } else { false } }
        if case .failed = failed {} else { Issue.record("Expected an explicit failure") }
        await model.refresh()
        #expect(model.statusMessage != nil && model.canConnect)
        controller.startError = nil
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await model.refresh()
        #expect(model.state == .up && model.errorMessage == nil)
        await model.disconnect()
    }

    private func makeCoordinator(
        controller: FakeTunnelController = FakeTunnelController(),
        enroller: FakeTunnelEnroller = FakeTunnelEnroller()
    ) -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(backend: backend, controller: controller,
            enroller: enroller, consumers: FakeTunnelConsumers())
    }
}
