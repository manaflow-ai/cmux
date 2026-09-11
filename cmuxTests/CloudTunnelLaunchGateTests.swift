import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The launch gate as behavior: a refused start never reaches enrollment or
/// NetworkExtension, the NetworkExtension controller is not even built until
/// the first admitted start, an opt-in flipped while the app runs is honored
/// by the next use, and a Mac with a saved VPN configuration still gets the
/// eager controller so an inherited tunnel is adopted or stopped.
@Suite
struct CloudTunnelLaunchGateTests {
    private static let extensionID = "com.cmuxterm.app.tests.tunnel"
    private static let networkExtension = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: extensionID)
    private static let use = CloudPrivateNetworkUse(machineID: "vm-1", purpose: .attach)

    /// A gate the test flips mid-scenario, standing in for the Beta Features
    /// toggle and the machine marker.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var refusalValue: CloudTunnelStartRefusal?

        init(_ refusal: CloudTunnelStartRefusal?) {
            refusalValue = refusal
        }

        var refusal: CloudTunnelStartRefusal? {
            get { lock.withLock { refusalValue } }
            set { lock.withLock { refusalValue = newValue } }
        }
    }

    /// Stands in for `NetworkExtensionTunnelController.init`: counts how often
    /// the coordinator's controller seam asks for the real thing.
    @MainActor
    private final class ControllerFactory {
        let controller = FakeTunnelController()
        private(set) var builds: [String] = []

        func make(_ identifier: String = CloudTunnelLaunchGateTests.extensionID) -> any CloudTunnelControlling {
            builds.append(identifier)
            return controller
        }
    }

    private func makeCoordinator(
        controller: any CloudTunnelControlling,
        enroller: FakeTunnelEnroller,
        gate: Gate
    ) -> CloudTunnelCoordinator {
        makeCoordinator(
            controller: controller,
            enroller: enroller,
            admission: .constant { gate.refusal }
        )
    }

    private func makeCoordinator(
        controller: any CloudTunnelControlling,
        enroller: FakeTunnelEnroller,
        admission: CloudTunnelAdmission
    ) -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(
            backend: Self.networkExtension,
            controller: controller,
            enroller: enroller,
            consumers: FakeTunnelConsumers(),
            clock: SidebarTestManualClock(),
            timing: CloudTunnelTiming(),
            admission: admission
        )
    }

    /// The control plane plus the machine cache it refills: counts
    /// resolutions, answers with a settable fleet, and remembers the answer
    /// the way `VMClient.listPage` writes `CloudMachineCache`.
    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var fleetHasMachine: Bool?
        private var cached: Bool?
        private var resolutions = 0

        init(fleetHasMachine: Bool?) {
            self.fleetHasMachine = fleetHasMachine
        }

        var hasMachine: Bool? {
            get { lock.withLock { fleetHasMachine } }
            set { lock.withLock { fleetHasMachine = newValue } }
        }
        /// What local state knows: nil until the first resolution answers.
        var known: Bool? { lock.withLock { cached } }
        var count: Int { lock.withLock { resolutions } }

        func resolve() -> Bool? {
            lock.withLock {
                resolutions += 1
                if let fleetHasMachine { cached = fleetHasMachine }
                return fleetHasMachine
            }
        }
    }

    @Test("a refused start touches neither enrollment nor the controller, and says why")
    func refusedStartIsInert() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let gate = Gate(.cloudMachinesOff)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)

        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.beginUp(pin: true) == .cloudMachinesOff)
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: true)
        }

        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        #expect(await coordinator.startRefusal() == .cloudMachinesOff)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)

        gate.refusal = .noCloudMachine
        await #expect(throws: CloudTunnelError.noCloudMachine) {
            try await coordinator.requestUp(pin: false)
        }
        #expect(await coordinator.startRefusal() == .noCloudMachine)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
    }

    @Test("the NetworkExtension controller is not built until the first admitted start, and a runtime opt-in needs no relaunch")
    @MainActor
    func controllerIsBuiltOnlyForAnAdmittedStart() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        let gate = Gate(.cloudMachinesOff)
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, gate: gate)

        // Everything a launch, a quit, a sign-out, and `cmux vpn down|status|revoke`
        // do on a Mac that never opted in: none of it builds the controller.
        _ = await coordinator.status()
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await coordinator.requestDown()
        await coordinator.accessDidEnd()
        try await coordinator.revoke()
        coordinator.appWillTerminate()
        #expect(factory.builds.isEmpty)
        #expect(factory.controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)

        // The user turns Cloud Machines on and has a machine: the next use
        // builds the controller and brings the tunnel up.
        gate.refusal = nil
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.state == .up)
        #expect(factory.builds == [Self.extensionID])
        #expect(factory.controller.calls == ["install", "start"])
        #expect(enroller.enrollCount == 1)

        // Later uses and the teardown paths reuse the one controller.
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)
        #expect(factory.builds.count == 1)
        #expect(factory.controller.calls == ["install", "start", "stop"])
    }

    @Test("turning Cloud Machines off after a start refuses the next use; the existing tunnel is brought down by the observer's request")
    @MainActor
    func runtimeOptOutIsHonored() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, gate: gate)
        try await coordinator.requestUp(pin: true)
        #expect(await coordinator.state == .up)

        gate.refusal = .cloudMachinesOff
        // What `CloudTunnelActivationObserver` does on the toggle change.
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        #expect(await coordinator.state == .off)
        #expect(factory.controller.calls == ["install", "start", "stop"])
        #expect(enroller.enrollCount == 1)
    }

    @Test("an unknown machine count is resolved through the control plane before the first start, and a known answer is never re-asked")
    @MainActor
    func unknownMachineCountIsResolvedBeforeStarting() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        let resolver = Resolver(fleetHasMachine: false)
        // Cloud Machines on, machine count unknown (fresh opt-in or just signed in).
        let policy = CloudActivationPolicy(
            isCloudMachinesEnabled: { true },
            hasUsedCloud: { resolver.known == true },
            hasCloudMachine: { resolver.known },
            isTunnelConfigured: { false },
            resolveCloudMachine: { resolver.resolve() }
        )
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, admission: policy.tunnelAdmission)

        // Status never resolves: unknown is not a known refusal.
        #expect(await coordinator.knownStartRefusal() == nil)
        #expect(resolver.count == 0)

        // The account turns out to have no machine: refused, nothing built.
        await #expect(throws: CloudTunnelError.noCloudMachine) {
            try await coordinator.requestUp(pin: true)
        }
        #expect(resolver.count == 1)
        #expect(factory.builds.isEmpty)
        #expect(enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)

        // A machine appears (created elsewhere): the count last seen as zero
        // is re-asked on the next explicit use, which then comes up. The
        // in-start re-check reads the refilled cache and asks nothing.
        resolver.hasMachine = true
        try await coordinator.requestUp(pin: true)
        #expect(await coordinator.state == .up)
        #expect(resolver.count == 2)
        #expect(factory.builds.count == 1)
        #expect(factory.controller.calls == ["install", "start"])

        // Up: status and later uses read local state and ask nothing.
        #expect(await coordinator.knownStartRefusal() == nil)
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(resolver.count == 2)
    }

    @Test("a marker that still says the account has a machine is re-asked before a start: a machine deleted outside the app refuses")
    @MainActor
    func staleMachineMarkerIsReAskedBeforeStarting() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        // The last poll saw a machine; it has since been deleted on the web.
        let resolver = Resolver(fleetHasMachine: false)
        let policy = CloudActivationPolicy(
            isCloudMachinesEnabled: { true },
            hasUsedCloud: { true },
            hasCloudMachine: { resolver.known ?? true },
            isTunnelConfigured: { false },
            resolveCloudMachine: { resolver.resolve() }
        )
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, admission: policy.tunnelAdmission)

        // Status trusts the marker; a start does not.
        #expect(await coordinator.knownStartRefusal() == nil)
        await #expect(throws: CloudTunnelError.noCloudMachine) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        #expect(await coordinator.beginUp(pin: true) == .noCloudMachine)
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(resolver.count == 3)
        #expect(factory.builds.isEmpty)
        #expect(enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        // The refilled marker now says so for status as well.
        #expect(await coordinator.knownStartRefusal() == .noCloudMachine)
    }

    @Test("`beginUp` reports a refusal that arrives after the caller's own check, so `vm.tunnel_up` never reads off as success")
    func beginUpReportsLateRefusal() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        // Local state admits; the control plane, asked as the start is
        // scheduled, says the fleet is empty.
        let admission = CloudTunnelAdmission(
            knownRefusal: { nil },
            resolvedRefusal: { .noCloudMachine }
        )
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, admission: admission)
        #expect(await coordinator.knownStartRefusal() == nil)
        #expect(await coordinator.beginUp(pin: true) == .noCloudMachine)
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        #expect(await coordinator.recordedStartRefusal() == nil)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
    }

    @Test("Cloud Machines turned off during enrollment: the enrollment is discarded and nothing is installed or started")
    func refusalDuringEnrollmentDiscardsIt() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        // The toggle flips while the control-plane round trip is in flight.
        enroller.onEnroll = { gate.refusal = .cloudMachinesOff }
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)

        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: true)
        }
        #expect(enroller.enrollCount == 1)
        #expect(enroller.discardCount == 1)
        #expect(controller.calls.isEmpty)
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isInFailureBackoff == false)
        #expect(await coordinator.recordedStartRefusal() == .cloudMachinesOff)
    }

    @Test("Cloud Machines turned off while the install waits for approval: the tunnel is never started")
    @MainActor
    func refusalDuringInstallPreventsStart() async throws {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)
        let start = Task { try await coordinator.requestUp(pin: false) }
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }
        #expect(await coordinator.state == .awaitingApproval)

        gate.refusal = .cloudMachinesOff
        controller.approve()
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await start.value
        }
        // The saved configuration and the enrollment are taken back out.
        #expect(controller.calls == ["install", "remove"])
        #expect(controller.installedConfigurations.isEmpty)
        #expect(enroller.discardCount == 1)
        #expect(await coordinator.state == .off)
    }

    @Test("the production opt-out (bring the tunnel down, then refuse) while the install waits for approval removes the late-saved configuration")
    @MainActor
    func optOutDuringInstallRemovesLateSavedConfiguration() async throws {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)
        let start = Task { try await coordinator.requestUp(pin: false) }
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }
        #expect(await coordinator.state == .awaitingApproval)

        // Cloud Machines turned off: the observer brings the tunnel down
        // (cancelling the start) and the policy refuses from now on.
        gate.refusal = .cloudMachinesOff
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)

        // The user's approval arrives late; the install has saved the
        // configuration by the time the cancelled start notices.
        controller.approve()
        await #expect(throws: CloudTunnelError.self) {
            try await start.value
        }
        #expect(controller.calls == ["install", "stop", "remove"])
        #expect(controller.installedConfigurations.isEmpty)
        #expect(enroller.discardCount == 1)
        #expect(await coordinator.state == .off)

        // An explicit `cmux vpn down` during approval with the opt-in still
        // on is not a refusal: the configuration stays for the next use.
        let onEnroller = FakeTunnelEnroller()
        let onController = FakeTunnelController()
        onController.holdInstallForApproval = true
        let opted = makeCoordinator(controller: onController, enroller: onEnroller, gate: Gate(nil))
        let second = Task { try await opted.requestUp(pin: false) }
        _ = await opted.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }
        await opted.requestDown()
        onController.approve()
        await #expect(throws: CloudTunnelError.self) {
            try await second.value
        }
        #expect(onController.calls == ["install", "stop"])
        #expect(onEnroller.discardCount == 0)
    }

    @Test("a superseded start's late cleanup never deletes the configuration a newer admitted start owns")
    @MainActor
    func lateCleanupDoesNotRaceANewerStart() async throws {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)
        let first = Task { try await coordinator.requestUp(pin: false) }
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }

        // Opt-out: down (cancels the first start), then refuse.
        gate.refusal = .cloudMachinesOff
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)

        // Opt back in before the first install has resolved: a newer start
        // is admitted and owns the tunnel from now on.
        gate.refusal = nil
        let second = Task { try await coordinator.requestUp(pin: false) }
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }
        // Both held installs resolve together; the first start's cleanup
        // must step aside because the second start already owns the tunnel.
        controller.approve()
        await #expect(throws: CloudTunnelError.self) {
            try await first.value
        }
        try await second.value
        #expect(await coordinator.state == .up)
        #expect(controller.calls == ["install", "stop", "install", "start"])
        #expect(controller.installedConfigurations.count == 2)
        #expect(enroller.discardCount == 0)
    }

    @Test("a newer start inherits a superseded start's saved configuration regardless of the policy at hand-off, and discards it if refused before installing")
    @MainActor
    func inheritedConfigurationIsDiscardedByAStartThatDoesNotInstall() async throws {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)
        let first = Task { try await coordinator.requestUp(pin: false) }
        _ = await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval }

        // Opt-out cancels the first start; opt back in schedules a second.
        gate.refusal = .cloudMachinesOff
        await coordinator.requestDown()
        gate.refusal = nil
        // While the second start is enrolling, the first start's late
        // approval resolves with Cloud Machines back ON (so no refusal at
        // hand-off time), then the policy refuses again. Whether the first
        // start's resumption runs before the second start's refusal (the
        // hand-off: the second start inherits and discards) or after it (the
        // first start discards on its own), the configuration is removed
        // once, the enrollment is gone, and nothing is left behind. The
        // yields let the first start's continuation run on the actor while
        // the second is suspended here.
        enroller.onEnroll = {
            controller.approve()
            _ = try? await first.value
            for _ in 0..<64 { await Task.yield() }
            gate.refusal = .cloudMachinesOff
        }
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: false)
        }
        #expect(controller.calls == ["install", "stop", "remove"])
        #expect(controller.installedConfigurations.isEmpty)
        #expect(enroller.discardCount == 1)
        #expect(await coordinator.state == .off)

        // The obligation is gone: a later admitted start behaves normally.
        gate.refusal = nil
        enroller.onEnroll = nil
        controller.holdInstallForApproval = false
        try await coordinator.requestUp(pin: false)
        #expect(await coordinator.state == .up)
        #expect(controller.calls == ["install", "stop", "remove", "install", "start"])
        #expect(enroller.discardCount == 1)
    }

    @Test("a start that is refused after being scheduled ends off, without failure backoff, and its waiters get the real reason")
    func refusalAfterSchedulingEndsOff() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        // Admit the scheduling check, refuse the in-start re-check: the toggle
        // is turned off between the fleet answer and the scheduled start.
        let admission = CloudTunnelAdmission(
            knownRefusal: { gate.refusal },
            resolvedRefusal: {
                gate.refusal = .cloudMachinesOff
                return nil
            }
        )
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, admission: admission)
        // `cmux vpn up` waits in `ensureUp` on the state stream: it must see
        // the Cloud Machines message, not a generic cancellation.
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: true)
        }
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned)
        #expect(await coordinator.isInFailureBackoff == false)
        // `vm.tunnel_up` reads the recorded refusal after the wait settles.
        #expect(await coordinator.recordedStartRefusal() == .cloudMachinesOff)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)

        // The next scheduled start is judged afresh.
        await coordinator.requestDown()
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        #expect(await coordinator.state == .off)
        #expect(controller.calls.isEmpty)
    }

    @Test("launch composition: a saved VPN configuration gets the eager controller, otherwise construction waits; an unavailable build is inert")
    @MainActor
    func launchCompositionDefersWithoutASavedConfiguration() {
        let factory = ControllerFactory()
        let fresh = CloudActivationPolicy(
            isCloudMachinesEnabled: { false },
            hasUsedCloud: { false },
            hasCloudMachine: { nil },
            isTunnelConfigured: { false },
            resolveCloudMachine: { nil }
        )
        let deferred = CloudTunnelCoordinator.liveController(for: Self.networkExtension, activation: fresh) { identifier in
            factory.make(identifier)
        }
        #expect(deferred is CloudTunnelDeferredController)
        #expect(factory.builds.isEmpty)

        let inherited = CloudActivationPolicy(
            isCloudMachinesEnabled: { true },
            hasUsedCloud: { true },
            hasCloudMachine: { true },
            isTunnelConfigured: { true },
            resolveCloudMachine: { true }
        )
        let eager = CloudTunnelCoordinator.liveController(for: Self.networkExtension, activation: inherited) { identifier in
            factory.make(identifier)
        }
        #expect(eager is FakeTunnelController)
        #expect(factory.builds == [Self.extensionID])

        let unavailable = CloudTunnelCoordinator.liveController(
            for: .unavailable(.entitlementMissing),
            activation: inherited
        ) { identifier in
            factory.make(identifier)
        }
        #expect(unavailable is CloudTunnelInertController)
        #expect(factory.builds == [Self.extensionID])
    }

    @Test("with the eager controller an inherited tunnel is adopted by the first use and stopped by down without enrolling")
    func eagerControllerAdoptsAndStopsAnInheritedTunnel() async {
        let controller = FakeTunnelController()
        controller.currentStatusValue = .connected
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: Gate(nil))

        // Quit or sign-out on a Mac whose previous session left the link up.
        await coordinator.requestDown()
        #expect(controller.calls == ["stop"])
        #expect(enroller.enrollCount == 0)

        controller.currentStatusValue = .connected
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.state == .up)
        #expect(controller.calls == ["stop", "install"])
    }

    @Test("a saved VPN configuration with Cloud Machines off still composes the eager controller: the inherited tunnel is stopped, no new start is admitted")
    @MainActor
    func savedConfigurationWithToggleOffStopsInheritedTunnelOnly() async throws {
        let factory = ControllerFactory()
        factory.controller.currentStatusValue = .connected
        let enroller = FakeTunnelEnroller()
        // Toggle off, no machine known, but a previous opted-in session saved
        // the browser-role config on this Mac.
        let policy = CloudActivationPolicy(
            isCloudMachinesEnabled: { false },
            hasUsedCloud: { true },
            hasCloudMachine: { nil },
            isTunnelConfigured: { true },
            resolveCloudMachine: { nil }
        )
        let controller = CloudTunnelCoordinator.liveController(for: Self.networkExtension, activation: policy) { identifier in
            factory.make(identifier)
        }
        #expect(controller is FakeTunnelController)
        #expect(factory.builds == [Self.extensionID])
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, admission: policy.tunnelAdmission)

        // Quit, sign-out, or `cmux vpn down` stops the tunnel the previous
        // instance left running, without enrolling anything.
        await coordinator.requestDown()
        #expect(factory.controller.calls == ["stop"])
        #expect(enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)

        // Nothing may start while Cloud Machines is off.
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: true)
        }
        #expect(factory.controller.calls == ["stop"])
        #expect(enroller.enrollCount == 0)
    }

    /// Counts the observer's `bringDown` calls under a lock, since the
    /// observer's task and the test's task interleave.
    private final class BringDownCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @Test("the activation observer brings the tunnel down for a toggle change posted before it starts listening, and for later ones")
    @MainActor
    func activationObserverReconcilesBeforeListening() async {
        let center = NotificationCenter()
        let gate = Gate(nil)
        let downs = BringDownCounter()
        let observer = CloudTunnelActivationObserver(
            notificationCenter: center,
            isStartRefused: { gate.refusal != nil },
            bringDown: { downs.increment() }
        )
        // Nothing is refused at startup: no teardown.
        let firedAtStartup = await waitUntil(timeout: .milliseconds(300)) { downs.count > 0 }
        #expect(firedAtStartup == false)

        // Cloud Machines turned off, and the notification posted right away,
        // before the observer's task could register for it.
        gate.refusal = .cloudMachinesOff
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { downs.count >= 1 })

        // Later changes keep being honored.
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { downs.count >= 2 })
        withExtendedLifetime(observer) {}
    }

    @Test("the deferred controller is inert before its first install and forwards link status after it")
    @MainActor
    func deferredControllerForwardsAfterBuild() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let updates = deferred.statusUpdates
        await Task.yield()

        #expect(await deferred.currentStatus() == .invalid)
        try await deferred.stop()
        try await deferred.remove()
        deferred.stopForTermination()
        await #expect(throws: CloudTunnelError.configurationNotInstalled) {
            try await deferred.start()
        }
        #expect(factory.builds.isEmpty)
        #expect(factory.controller.calls.isEmpty)

        let configuration = CloudTunnelProviderConfiguration(
            wgQuickConfig: FakeTunnelEnroller.config,
            serverAddress: "vpn.example.com:51820",
            localizedDescription: "cmux Cloud"
        )
        try await deferred.install(configuration) {}
        #expect(factory.builds.count == 1)
        #expect(factory.controller.calls == ["install"])
        #expect(await deferred.currentStatus() == .disconnected)

        factory.controller.emit(.connecting)
        factory.controller.emit(.connected)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .connecting)
        #expect(await iterator.next() == .connected)

        try await deferred.start()
        try await deferred.stop()
        try await deferred.remove()
        deferred.stopForTermination()
        #expect(factory.controller.calls == ["install", "start", "stop", "remove", "stopForTermination"])
        #expect(factory.builds.count == 1)
    }
}
