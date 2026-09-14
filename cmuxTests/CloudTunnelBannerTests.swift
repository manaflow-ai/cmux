import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Machines panel's tunnel banner: shown only while an explicit VPN start
/// is doing something the user should see, with the System Settings control
/// exactly while macOS waits for the extension approval.
@Suite
struct CloudTunnelBannerTests {
    private static let extensionID = "com.cmuxterm.app.tests.tunnel"
    private let networkExtension = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: CloudTunnelBannerTests.extensionID)

    @Test("off, and builds without the extension, show no banner")
    func hiddenWhenNothingToSay() {
        #expect(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .off, isPinned: false)) == nil)
        #expect(CloudTunnelBanner(status: CloudTunnelStatus(backend: .unavailable(.entitlementMissing), state: .awaitingApproval, isPinned: true)) == nil)
    }

    @Test("the approval wait carries the existing copy and opens System Settings")
    func awaitingApproval() throws {
        let banner = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .awaitingApproval, isPinned: true)))
        #expect(banner.kind == .awaitingApproval)
        #expect(banner.opensSystemSettings)
        #expect(banner.text.contains("Login Items & Extensions"))
    }

    @Test("the connected banner is hidden in Machines while transient states stay visible")
    func machinesPanelVisibility() throws {
        let connected = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .up, isPinned: true)))
        #expect(!connected.showsInMachinesPanel)
        let waiting = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .awaitingApproval, isPinned: true)))
        #expect(waiting.showsInMachinesPanel)
        let failed = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .failed("no route"), isPinned: false)))
        #expect(failed.showsInMachinesPanel)
    }

    @Test("starting, failed, and up are reported without a settings control")
    func otherStates() throws {
        let starting = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .starting, isPinned: true)))
        #expect(starting.kind == .starting && !starting.opensSystemSettings)
        let stopping = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .stopping, isPinned: false)))
        #expect(stopping.kind == .stopping && stopping.text.contains("stopping"))
        let failed = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .failed("no route"), isPinned: false)))
        #expect(failed.kind == .failed && failed.text.contains("no route"))
        let pinned = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .up, isPinned: true)))
        #expect(pinned.kind == .connected && pinned.text.contains("cmux vpn down"))
        let unpinned = try #require(CloudTunnelBanner(status: CloudTunnelStatus(backend: networkExtension, state: .up, isPinned: false)))
        #expect(unpinned.kind == .connected && !unpinned.text.contains("cmux vpn down"))
    }

    @Test("the settings link lands on Login Items & Extensions on macOS 15 and Privacy & Security before")
    func settingsLinkFollowsTheOS() {
        #expect(SystemExtensionSettingsLink.url(macOSMajorVersion: 15).absoluteString == SystemExtensionSettingsLink.loginItemsAndExtensionsPane)
        #expect(SystemExtensionSettingsLink.url(macOSMajorVersion: 26).absoluteString == SystemExtensionSettingsLink.loginItemsAndExtensionsPane)
        #expect(SystemExtensionSettingsLink.url(macOSMajorVersion: 14).absoluteString == SystemExtensionSettingsLink.privacyAndSecurityPane)
    }

    @Test("the model follows a coordinator held at the approval wait, then its recovery")
    @MainActor
    func modelFollowsCoordinator() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let coordinator = CloudTunnelCoordinator(
            backend: networkExtension,
            controller: controller,
            enroller: FakeTunnelEnroller(),
            consumers: FakeTunnelConsumers()
        )
        let model = CloudTunnelStatusModel()
        let observation = Task { await model.observe(coordinator) }
        await coordinator.beginUp(pin: true)
        _ = await coordinator.waitForState(timeout: .seconds(10)) { $0 == .awaitingApproval }
        #expect(await waitUntil { model.banner?.kind == .awaitingApproval })
        #expect(model.banner?.opensSystemSettings == true)

        controller.approve()
        _ = await coordinator.waitForState(timeout: .seconds(10)) { $0 == .up }
        #expect(await waitUntil { model.banner?.kind == .connected })
        observation.cancel()
    }

    /// Polls a main-actor predicate with a real deadline so a regression fails
    /// instead of hanging the suite.
    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), _ predicate: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
@Suite("Optional Cloud VPN setup")
struct CloudVPNSetupModelTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "test.cloud.vpn")

    @Test("Opening setup reads status without enrolling or requesting approval")
    func openingIsPassive() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(backend: backend, controller: controller, enroller: enroller, consumers: FakeTunnelConsumers())
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        #expect(model.state == .off)
        #expect(model.canConnect)
        #expect(enroller.enrollCount == 0)
        #expect(controller.calls.isEmpty)
    }

    @Test("Unavailable extensions cannot start setup")
    func unsupportedBuild() async {
        let model = CloudVPNSetupModel(coordinator: nil)
        #expect(!model.canConnect)
        #expect(model.unavailableMessage != nil)
        await model.connect()
        #expect(model.state == .off)
    }

    @Test("Admission errors stay visible without an extension prompt")
    func admissionError() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(
            backend: backend,
            controller: controller,
            enroller: enroller,
            consumers: FakeTunnelConsumers(),
            admission: CloudTunnelAdmission(knownRefusal: { .noCloudMachine }, resolvedRefusal: { .noCloudMachine })
        )
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.connect()
        #expect(model.errorMessage == CloudTunnelError.noCloudMachine.description)
        #expect(!model.isSubmitting)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
    }

    @Test("Approval completes the same connection, and Disconnect stops it")
    func approvalThenDisconnect() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(backend: backend, controller: controller, enroller: enroller, consumers: FakeTunnelConsumers())
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval } == .awaitingApproval)
        await model.refresh()
        #expect(model.state == .awaitingApproval)
        #expect(!model.canConnect)
        await model.connect()
        #expect(enroller.enrollCount == 1)
        controller.approve()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await model.refresh()
        #expect(model.state == .up)
        #expect(await coordinator.status().isPinned)
        await model.disconnect()
        #expect(model.state == .off)
        #expect(!(await coordinator.status().isPinned))
    }

    @Test("Failed connection is reported and the user can retry")
    func failedStartCanRetry() async {
        let controller = FakeTunnelController()
        controller.startError = FakeTunnelController.Failure.refused
        let coordinator = CloudTunnelCoordinator(backend: backend, controller: controller, enroller: FakeTunnelEnroller(), consumers: FakeTunnelConsumers())
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.connect()
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0.failureMessage != nil }
        await model.refresh()
        #expect(model.state.failureMessage != nil)
        #expect(model.canConnect)
        controller.startError = nil
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await model.disconnect()
    }
}
