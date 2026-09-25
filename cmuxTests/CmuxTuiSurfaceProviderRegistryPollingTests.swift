import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The registry's periodic fleet read is the only Cloud API traffic an idle
/// app makes, so it must follow the activation policy: never scheduled for a
/// Mac that has not opted in, started when the Beta Features toggle turns on,
/// and cancelled again when it turns off, all without a relaunch.
/// Each fixture owns its notification center so account changes cannot retire
/// a registry running in another test suite.
@Suite(.serialized)
struct CmuxTuiSurfaceProviderRegistryPollingTests {
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    @Test("fleet polling starts only when background Cloud work is allowed, and follows the toggle at runtime")
    @MainActor
    func pollingFollowsTheActivationPolicy() async {
        let allowed = Switch()
        let center = NotificationCenter()
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed.isOn },
            listPage: { nil },
            notificationCenter: center
        )

        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling == false)

        // Settings › Beta Features › Cloud Machines turned on.
        allowed.isOn = true
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { registry.isPolling })

        // A repeated change is idempotent.
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { registry.isPolling })

        // Turned off again: the poll is cancelled.
        allowed.isOn = false
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { !registry.isPolling })
    }

    @Test("sign-out re-syncs the poll: with the opt-in gone it stops instead of listing the next account")
    @MainActor
    func signOutStopsPollingWhenNoLongerAllowed() async {
        let allowed = Switch()
        let center = NotificationCenter()
        allowed.isOn = true
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed.isOn },
            listPage: { nil },
            notificationCenter: center
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling)

        // Sign-out clears the marker and enrollment files (the policy now says no).
        allowed.isOn = false
        center.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
        #expect(await waitUntil { !registry.isPolling })
    }

    @Test("a registry that is allowed background work polls from start")
    @MainActor
    func allowedRegistryPollsImmediately() async {
        let allowed = Switch()
        allowed.isOn = true
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed.isOn },
            listPage: { nil }
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling)

        allowed.isOn = false
        registry.syncPollingToActivationPolicy()
        #expect(registry.isPolling == false)
    }

    @Test("Cloud activation starts carrier preparation before fleet discovery finishes")
    @MainActor
    func activationStartsCarrierBeforeFleetReadFinishes() async {
        let listStarted = CloudLinkFirstValue<Bool>()
        let releaseList = CloudLinkFirstValue<Bool>()
        let enrollmentStarted = CloudLinkFirstValue<Bool>()
        let h = makeHub {
            enrollmentStarted.resolve(true)
            return .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            allowsBackgroundWork: { true },
            listPage: {
                listStarted.resolve(true)
                _ = await releaseList.result
                return VMListPage(vms: [], limits: nil)
            },
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(await received(enrollmentStarted))
        #expect(await received(listStarted))
        releaseList.resolve(true)
        await registry.accessDidEnd()
    }

    @Test("Restarting Cloud discovery during an in-flight fleet read starts the new account promptly")
    @MainActor
    func restartingDuringInFlightDiscoveryDoesNotLeaveThePollSleeping() async {
        let firstStarted = CloudLinkFirstValue<Bool>()
        let secondStarted = CloudLinkFirstValue<Bool>()
        let releaseFirst = CloudLinkFirstValue<Bool>()
        let calls = CloudWireGuardHubTests.AttemptCounter()
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { true },
            listPage: {
                if await calls.next() == 1 {
                    firstStarted.resolve(true)
                    _ = await releaseFirst.result
                } else {
                    secondStarted.resolve(true)
                }
                return VMListPage(vms: [], limits: nil)
            },
            notificationCenter: NotificationCenter()
        )

        registry.start(catalog: SurfaceCatalog())
        #expect(await received(firstStarted))

        // A sign-in/account restart must invalidate the blocked pass and start a
        // fresh poll. Otherwise the old task is discarded by generation fencing,
        // then the retained poll sleeps for its full 45-second cadence.
        registry.start(catalog: SurfaceCatalog())
        releaseFirst.resolve(true)
        #expect(await received(secondStarted))
        await registry.accessDidEnd()
    }

    @Test("An authenticated empty fleet prepares the shared terminal tunnel without delaying discovery")
    @MainActor
    func emptyFleetPreparesBeforeTheFirstMachine() async throws {
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let attempts = CloudWireGuardHubTests.AttemptCounter()
        let h = makeHub {
            _ = await attempts.next()
            started.resolve(true)
            _ = await release.result
            try Task.checkCancellation()
            return .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            listPage: { VMListPage(vms: [], limits: nil) },
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: SurfaceCatalog())
        let discoveryFinished = CloudLinkFirstValue<Bool>()
        let discovery = Task { discoveryFinished.resolve(await registry.refresh(force: true)) }
        let discoveredWhileEnrollmentWasPending = await received(discoveryFinished)
        let beganBeforeMachineCreation = await received(started)
        release.resolve(true)
        await discovery.value

        // The first terminal joins the same preparation; it does not enroll again.
        let terminal = try await h.hub.acquire()
        await h.hub.release(terminal.lease)
        let status = await h.hub.status()
        await registry.accessDidEnd()

        #expect(discoveredWhileEnrollmentWasPending)
        #expect(beganBeforeMachineCreation)
        #expect(await attempts.value == 1)
        #expect(h.spawner.count == 1)
        #expect(status.running)
        #expect(status.leases == 1, "Cloud availability keeps the prepared hub alive with no machines")
    }

    @Test("Repeated empty-fleet discovery does not restart failed automatic preparation")
    @MainActor
    func failedAutomaticPreparationWaitsForExplicitDemand() async throws {
        let allowed = Switch()
        let firstAttempt = CloudLinkFirstValue<Bool>()
        let attempts = CloudWireGuardHubTests.AttemptCounter()
        let h = makeHub {
            let attempt = await attempts.next()
            if attempt == 1 {
                firstAttempt.resolve(true)
                throw VMClientError.httpStatus(
                    400,
                    #"{"error":"vm_tunnel_invalid_key","message":"Invalid public key"}"#
                )
            }
            return .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            allowsBackgroundWork: { allowed.isOn },
            listPage: { VMListPage(vms: [], limits: nil) },
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling == false)

        // A forced empty-fleet read is still authenticated Cloud use, so it
        // starts the one automatic preparation sequence without waiting for a VM.
        allowed.isOn = true
        #expect(await registry.refresh(force: true))
        #expect(await received(firstAttempt))
        #expect(await waitUntilAsync { await h.hub.status().lastError != nil })
        #expect(await attempts.value == 1)

        // Later empty-fleet reads reuse the completed preparation task. They must
        // not rearm enrollment after a permanent automatic-start failure.
        for _ in 0..<3 {
            #expect(await registry.refresh(force: true))
            await Task.yield()
        }
        #expect(await attempts.value == 1)

        // An explicit terminal demand is allowed to retry and, once successful,
        // the account-level preparation claim keeps the hub resident.
        let demand = try await h.hub.acquire()
        #expect(await attempts.value == 2)
        #expect(await h.hub.status().leases == 2)
        await h.hub.release(demand.lease)
        #expect(await h.hub.status().leases == 1)

        // Stopping and reactivating Cloud starts a fresh automatic sequence.
        await registry.accessDidEnd()
        allowed.isOn = false
        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling == false)
        allowed.isOn = true
        #expect(await registry.refresh(force: true))
        #expect(await waitUntilAsync { await attempts.value == 3 })
        await registry.accessDidEnd()
    }

    @Test("Disabling Cloud or signing out cancels preparation before a helper can start", arguments: [false, true])
    @MainActor
    func endingAccessCancelsPendingPreparation(signOut: Bool) async {
        var enabled = true
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let closed = CloudLinkFirstValue<Bool>()
        let h = makeHub {
            started.resolve(true)
            _ = await release.result
            try Task.checkCancellation()
            return .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let center = NotificationCenter()
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            isCloudEnabled: { enabled },
            listPage: { VMListPage(vms: [], limits: nil) },
            closeTransports: { await h.hub.stop(); closed.resolve(true) },
            notificationCenter: center
        )
        registry.start(catalog: SurfaceCatalog())
        let refresh = Task { await registry.refresh(force: true) }
        let began = await received(started)
        if signOut {
            await registry.accessDidEnd()
        } else {
            enabled = false
            center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        }
        let stopped = await received(closed)
        release.resolve(true)
        _ = await refresh.value
        let status = await h.hub.status()
        await registry.accessDidEnd()

        #expect(began)
        #expect(stopped)
        #expect(!status.running)
        #expect(status.leases == 0)
        #expect(h.spawner.count == 0)
    }

    @Test("A closed Cloud gate or an unauthenticated fleet read cannot prepare a tunnel", arguments: [false, true])
    @MainActor
    func unavailableCloudDoesNotPrepare(enabled: Bool) async {
        let attempts = CloudWireGuardHubTests.AttemptCounter()
        let h = makeHub {
            _ = await attempts.next()
            return .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            isCloudEnabled: { enabled },
            listPage: { nil },
            hasCloudSession: { false },
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(await registry.refresh(force: true) == false)
        await registry.accessDidEnd()
        #expect(await attempts.value == 0)
        #expect(h.spawner.count == 0)
    }

    @Test("Ending Cloud access cancels activation preparation before it can finish", arguments: [false, true])
    @MainActor
    func endingAccessCancelsActivationPreparation(signOut: Bool) async {
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let preparedAfterAccessEnded = CloudLinkFirstValue<Bool>()
        var enabled = true
        let h = makeHub {
            .init(configPath: "/tmp/cmux-preparation.conf", routes: ["10.0.0.0/8"])
        }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: h.hub, hostThemeColors: { nil }),
            wireGuardHub: h.hub,
            isCloudEnabled: { enabled },
            allowsBackgroundWork: { true },
            prepareCloudCarrier: {
                started.resolve(true)
                _ = await release.result
                guard !Task.isCancelled else { return }
                await h.hub.prepareForCloudUse()
                preparedAfterAccessEnded.resolve(true)
            },
            listPage: { nil },
            notificationCenter: NotificationCenter()
        )

        registry.start(catalog: SurfaceCatalog())
        #expect(await received(started))
        if signOut {
            await registry.accessDidEnd()
        } else {
            enabled = false
            registry.syncPollingToActivationPolicy()
        }
        release.resolve(true)

        #expect(await received(preparedAfterAccessEnded, timeout: .seconds(1)) == false)
        #expect(await h.hub.status().running == false)
        await registry.accessDidEnd()
    }

    @MainActor
    private func makeHub(
        enrollment: @escaping @Sendable () async throws -> CloudWireGuardHub.Enrollment
    ) -> (hub: CloudWireGuardHub, spawner: CloudWireGuardHubTests.FakeSpawner) {
        let spawner = CloudWireGuardHubTests.FakeSpawner()
        let hub = CloudWireGuardHub(configuration: .init(
            enroll: enrollment,
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: FileManager.default.temporaryDirectory.appendingPathComponent("cmux-preparation-\(UUID()).sock"),
            spawner: spawner,
            waitUntilReady: { _ in },
            sleep: { try await ContinuousClock().sleep(for: $0) },
            restartBackoff: [],
            idleGrace: .seconds(3_600)
        ))
        return (hub, spawner)
    }

    /// A failure deadline, not a delay used to let production work settle.
    private func received(
        _ signal: CloudLinkFirstValue<Bool>,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await signal.result == true }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
