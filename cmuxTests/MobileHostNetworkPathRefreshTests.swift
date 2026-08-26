import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the network-path-change route refresh: the observation policy on
/// `MobileHostNetworkPathMonitor` (when a path observation should republish
/// routes) and
/// the resolved-host cache invalidation on `MobileRouteResolver` (old-network
/// hosts must not be served, or land late, after the path changed).
@Suite struct MobileHostNetworkPathRefreshTests {
    // MARK: - Path signature

    @Test func signatureIsOrderInsensitiveOverInterfacesGatewaysAndAddresses() {
        let a = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0", "utun4"],
            gateways: ["192.168.1.1", "fe80::1"],
            localAddresses: ["192.168.1.42", "100.64.0.7"]
        )
        let b = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["utun4", "en0"],
            gateways: ["fe80::1", "192.168.1.1"],
            localAddresses: ["100.64.0.7", "192.168.1.42"]
        )
        #expect(a == b)
    }

    @Test func signatureChangesWhenAnInterfaceAppears() {
        // Tailscale coming up adds a utun interface; that must read as a change.
        let withoutTailscale = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.42"]
        )
        let withTailscale = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0", "utun4"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.42"]
        )
        #expect(withoutTailscale != withTailscale)
    }

    @Test func signatureChangesWhenGatewayChanges() {
        // Same interface set, different network (e.g. a Wi-Fi move): the
        // gateway is what distinguishes the two paths.
        let homeNetwork = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.42"]
        )
        let officeNetwork = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["10.0.0.1"],
            localAddresses: ["192.168.1.42"]
        )
        #expect(homeNetwork != officeNetwork)
    }

    @Test func signatureChangesWhenOnlyTheLocalAddressChanges() {
        // Two networks can present the same interface name and gateway (two
        // home LANs both `en0` + `192.168.1.1`) while assigning a different
        // local address. The advertised routes are built from the local
        // addresses, so this must read as a change or the move would be
        // deduped and the stale routes never republished.
        let firstLAN = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.42"]
        )
        let secondLAN = MobileHostNetworkPathMonitor.signature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"],
            localAddresses: ["192.168.1.77"]
        )
        #expect(firstLAN != secondLAN)
    }

    @Test func systemLocalIPv4AddressesExcludesLoopbackAndIPv6() {
        let addresses = MobileHostNetworkPathMonitor.systemLocalIPv4Addresses()
        #expect(!addresses.contains("127.0.0.1"))
        #expect(addresses.allSatisfy { !$0.contains(":") })
    }

    // MARK: - Republish policy

    @Test func firstObservationRepublishes() {
        // The monitor's initial callback can arrive after the listener-ready
        // publish and describe a different path than the routes were computed
        // on; treating it as a silent baseline would swallow that first real
        // change. Republishing is deduped downstream, so the first observation
        // always republishes.
        #expect(MobileHostNetworkPathMonitor.shouldReportPathChange(
            previousSignature: nil,
            newSignature: "satisfied|en0|192.168.1.1"
        ) == true)
    }

    @Test func unchangedPathDoesNotRepublish() {
        let signature = "satisfied|en0|192.168.1.1"
        #expect(MobileHostNetworkPathMonitor.shouldReportPathChange(
            previousSignature: signature,
            newSignature: signature
        ) == false)
    }

    @Test func changedPathRepublishes() {
        #expect(MobileHostNetworkPathMonitor.shouldReportPathChange(
            previousSignature: "satisfied|en0|192.168.1.1",
            newSignature: "satisfied|en0,utun4|192.168.1.1"
        ) == true)
    }

    @Test func pathStatusMapsToReachabilityForTransportTelemetry() {
        #expect(MobileHostNetworkPathMonitor.isOnline(status: .satisfied))
        #expect(!MobileHostNetworkPathMonitor.isOnline(status: .unsatisfied))
        #expect(!MobileHostNetworkPathMonitor.isOnline(status: .requiresConnection))
    }

    @Test func relayPolicyRetryParksOnlyForOfflineEvidence() {
        #expect(MobileHostIrohRuntime.shouldPauseRelayPolicyRetry(
            failure: .offline,
            networkReachable: nil
        ))
        #expect(!MobileHostIrohRuntime.shouldPauseRelayPolicyRetry(
            failure: .offline,
            networkReachable: true
        ))
        #expect(MobileHostIrohRuntime.shouldPauseRelayPolicyRetry(
            failure: .policyUnavailable,
            networkReachable: false
        ))
        #expect(MobileHostIrohRuntime.shouldPauseRelayPolicyRetry(
            failure: .policyUnavailable,
            networkReachable: nil
        ))
        #expect(!MobileHostIrohRuntime.shouldPauseRelayPolicyRetry(
            failure: .policyUnavailable,
            networkReachable: true
        ))
    }

    @Test func hostRelayRefreshWithoutExpiryUsesIdleCadence() {
        let now = Date(timeIntervalSince1970: 10_000)
        let attempt = MobileHostIrohRuntime.relayPolicyRefreshAttemptDate(
            policyExpiresAt: nil,
            retryAt: nil,
            now: now
        )
        #expect(attempt.timeIntervalSince(now) == 60)
    }

    @Test func armedRetryWinsWhenCachedPolicyExpiryIsAlreadyPast() {
        let now = Date(timeIntervalSince1970: 10_000)
        let retryAt = now.addingTimeInterval(60)
        let attempt = MobileHostIrohRuntime.relayPolicyRefreshAttemptDate(
            policyExpiresAt: now.addingTimeInterval(-1),
            retryAt: retryAt,
            now: now
        )

        #expect(attempt == retryAt)
    }

    @Test func offlineRelayPolicyKeepsALocalExpiryDeadline() {
        let now = Date(timeIntervalSince1970: 10_000)
        let futureExpiry = now.addingTimeInterval(300)

        #expect(
            MobileHostIrohRuntime.relayPolicyOfflineExpiryAttemptDate(
                policyExpiresAt: futureExpiry,
                now: now
            ) == futureExpiry
        )
        #expect(
            MobileHostIrohRuntime.relayPolicyOfflineExpiryAttemptDate(
                policyExpiresAt: now.addingTimeInterval(-1),
                now: now
            ) == now
        )
        #expect(
            MobileHostIrohRuntime.relayPolicyOfflineExpiryAttemptDate(
                policyExpiresAt: nil,
                now: now
            ) == nil
        )
    }

    @Test func activationAllowsUnknownInitialPathButBlocksKnownOffline() {
        #expect(MobileHostIrohRuntime.shouldStartIrohActivation(networkReachable: nil))
        #expect(!MobileHostIrohRuntime.shouldStartIrohActivation(networkReachable: false))
        #expect(MobileHostIrohRuntime.shouldStartIrohActivation(networkReachable: true))
    }

    @Test func serverConnectivitySignalsWaitForReachabilityBeforeReconciliation() {
        #expect(MobileHostIrohRuntime.shouldDeferServerConnectivitySignal(networkReachable: nil))
        #expect(MobileHostIrohRuntime.shouldDeferServerConnectivitySignal(networkReachable: false))
        #expect(!MobileHostIrohRuntime.shouldDeferServerConnectivitySignal(networkReachable: true))
    }

    // MARK: - Resolver cache invalidation

    private func tailscaleHosts(in snapshot: MobileHostRouteSnapshot) -> [String] {
        snapshot.routes.compactMap { route in
            guard route.kind == .tailscale, case let .hostPort(host, _) = route.endpoint else {
                return nil
            }
            return host
        }
    }

    @Test func invalidateDropsCachedResolvedHosts() async {
        let resolver = MobileRouteResolver()
        // Seed the cache through the awaited resolution path. MagicDNS may be
        // retained as resolver metadata, but only the numeric tailnet address
        // may be published to a plaintext compatibility client.
        let seeded = await resolver.routesResolvingTailscaleDNS(
            port: 51000,
            resolveHosts: { ["old-net.tail1234.ts.net", "100.64.0.1"] }
        )
        #expect(tailscaleHosts(in: seeded) == ["100.64.0.1"])

        // The cache serves the seeded hosts while fresh.
        let cached = resolver.routes(port: 51000, now: Date(), immediateHosts: { [] })
        #expect(tailscaleHosts(in: cached) == ["100.64.0.1"])

        // After invalidation (the network changed), the old-network hosts are
        // gone and only live interface-scan hosts remain.
        resolver.invalidateResolvedTailscaleHostCache()
        let afterInvalidate = resolver.routes(port: 51000, now: Date(), immediateHosts: { [] })
        #expect(!tailscaleHosts(in: afterInvalidate).contains("100.64.0.1"))
    }

    @Test func resolutionRacingInvalidationCannotRepolluteCache() async {
        let resolver = MobileRouteResolver()
        // Two-way handshake: `started` proves the resolution is genuinely in
        // flight (its cache generation already captured) before the
        // invalidation runs — `async let` alone does not guarantee the child
        // has begun — and `gate` holds it there until after the invalidation.
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        // Start a resolution that represents the OLD network and hold it
        // in flight while the path changes underneath it.
        async let staleResolution = resolver.routesResolvingTailscaleDNS(
            port: 51000,
            resolveHosts: {
                started.signal()
                gate.wait()
                return ["stale-old-net.tail1234.ts.net"]
            }
        )
        started.wait()
        resolver.invalidateResolvedTailscaleHostCache()
        gate.signal()
        // The awaiting caller still gets the hosts it resolved (it asked
        // before the change), but the cache write is discarded by the
        // generation guard, so later reads cannot see the old network.
        _ = await staleResolution
        let afterStaleStore = resolver.routes(port: 51000, now: Date(), immediateHosts: { [] })
        #expect(!tailscaleHosts(in: afterStaleStore).contains("stale-old-net.tail1234.ts.net"))
    }
}

@Suite(.serialized)
@MainActor
struct MobileHostIrohStartupRetryTests {
    @Test
    func bindingRemainsUnavailableUntilMatchingHostRuntimeIsActive() throws {
        let runtime = MobileHostIrohRuntime.shared
        let originalRevision = runtime.lifecycleRevision
        let revision: UInt64 = 4_200
        let binding = try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174010",
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "route-ready",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            identityGeneration: 1
        )
        defer {
            runtime.lifecycleRevision = originalRevision
            runtime.clearIrohRoutePublication()
            MobileHostPublicStatusCache.removeAll()
        }
        MobileHostPublicStatusCache.removeAll()
        runtime.lifecycleRevision = revision

        runtime.beginIrohRouteActivation(revision: revision)
        runtime.stageIrohRoute(binding, pathHints: [], revision: revision)

        #expect(!MobileHostPublicStatusCache.hasIrohRoute())
        #expect(runtime.routePublicationPhase == .starting(revision: revision))
        #expect(!runtime.publishIrohRouteIfActive(revision: revision - 1))
        #expect(!MobileHostPublicStatusCache.hasIrohRoute())
        #expect(runtime.publishIrohRouteIfActive(revision: revision))
        #expect(MobileHostPublicStatusCache.hasIrohRoute())

        runtime.lifecycleRevision = revision + 1
        runtime.beginIrohRouteActivation(revision: revision + 1)

        #expect(!MobileHostPublicStatusCache.hasIrohRoute())
        #expect(runtime.routePublicationPhase == .starting(revision: revision + 1))
    }

    @Test
    func sameAccountAuthObservationDoesNotSupersedeActivationInFlight() {
        #expect(!MobileHostIrohRuntime.shouldReconcileAuthObservation(
            accountID: "same-account",
            previousAccountID: "same-account",
            activeAccountID: nil,
            hasRuntime: false,
            transitionInFlight: true,
            preparedSignOutNeedsPersistence: false
        ))
    }

    @Test
    func sameAccountAuthObservationDoesNotRestartActiveRuntime() {
        #expect(!MobileHostIrohRuntime.shouldReconcileAuthObservation(
            accountID: "same-account",
            previousAccountID: "same-account",
            activeAccountID: "same-account",
            hasRuntime: true,
            transitionInFlight: false,
            preparedSignOutNeedsPersistence: false
        ))
    }

    @Test
    func sameAccountAuthObservationRetriesAfterFailedActivation() {
        #expect(MobileHostIrohRuntime.shouldReconcileAuthObservation(
            accountID: "same-account",
            previousAccountID: "same-account",
            activeAccountID: nil,
            hasRuntime: false,
            transitionInFlight: false,
            preparedSignOutNeedsPersistence: false
        ))
    }

    @Test
    func accountChangeStillSupersedesActivationInFlight() {
        #expect(MobileHostIrohRuntime.shouldReconcileAuthObservation(
            accountID: "next-account",
            previousAccountID: "previous-account",
            activeAccountID: nil,
            hasRuntime: false,
            transitionInFlight: true,
            preparedSignOutNeedsPersistence: false
        ))
    }

    @Test
    func networkPathRetryDoesNotSupersedeActivationInFlight() async {
        let runtime = MobileHostIrohRuntime.shared
        let originalDesiredActive = runtime.desiredActive
        let originalObservedAccountID = runtime.observedAccountID
        let originalPreparedSignOut = runtime.preparedSignOut
        let originalSignOutIntentActive = runtime.signOutIntentActive
        let originalRuntime = runtime.runtime
        let originalTransitionTask = runtime.transitionTask
        let originalRevision = runtime.lifecycleRevision
        let gate = MobileHostIrohStartupRetryGate()
        let activation = Task { await gate.suspend() }
        runtime.desiredActive = true
        runtime.observedAccountID = "network-path-race-account"
        runtime.preparedSignOut = nil
        runtime.signOutIntentActive = false
        runtime.runtime = nil
        runtime.transitionTask = activation

        runtime.retryIfNeeded()

        #expect(runtime.lifecycleRevision == originalRevision)

        let scheduled = runtime.transitionTask
        scheduled?.cancel()
        await gate.resume()
        await scheduled?.value
        runtime.transitionTask = originalTransitionTask
        runtime.runtime = originalRuntime
        runtime.desiredActive = originalDesiredActive
        runtime.observedAccountID = originalObservedAccountID
        runtime.preparedSignOut = originalPreparedSignOut
        runtime.signOutIntentActive = originalSignOutIntentActive
        runtime.lifecycleRevision = originalRevision
    }

    @Test
    func staleDeactivationCannotClearReplacementRuntimeState() async {
        let runtime = MobileHostIrohRuntime.shared
        let originalDesiredActive = runtime.desiredActive
        let originalSignOutIntentActive = runtime.signOutIntentActive
        let originalRevision = runtime.lifecycleRevision
        let probe = MobileHostIrohDeactivationProbe()
        runtime.desiredActive = true
        runtime.signOutIntentActive = false
        runtime.lifecycleRevision = 1_000

        await runtime.handleActiveRuntimeDeactivation(
            revision: 999,
            stopLANPublication: {
                probe.didStopLAN = true
            },
            clearHostRuntime: {
                probe.didClearHost = true
            }
        )

        #expect(!probe.didStopLAN)
        #expect(!probe.didClearHost)
        runtime.desiredActive = originalDesiredActive
        runtime.signOutIntentActive = originalSignOutIntentActive
        runtime.lifecycleRevision = originalRevision
    }

    @Test
    func deactivationRechecksOwnershipAfterSuspendingCleanup() async {
        let runtime = MobileHostIrohRuntime.shared
        let originalDesiredActive = runtime.desiredActive
        let originalSignOutIntentActive = runtime.signOutIntentActive
        let originalRevision = runtime.lifecycleRevision
        let probe = MobileHostIrohDeactivationProbe()
        runtime.desiredActive = true
        runtime.signOutIntentActive = false
        runtime.lifecycleRevision = 2_000

        await runtime.handleActiveRuntimeDeactivation(
            revision: 2_000,
            stopLANPublication: {
                probe.didStopLAN = true
                // A replacement activation took ownership while the old
                // callback was suspended in LAN cleanup.
                runtime.lifecycleRevision = 2_001
            },
            clearHostRuntime: {
                probe.didClearHost = true
            }
        )

        #expect(probe.didStopLAN)
        #expect(!probe.didClearHost)
        runtime.desiredActive = originalDesiredActive
        runtime.signOutIntentActive = originalSignOutIntentActive
        runtime.lifecycleRevision = originalRevision
    }
}

@MainActor
private final class MobileHostIrohDeactivationProbe {
    var didStopLAN = false
    var didClearHost = false
}

private actor MobileHostIrohStartupRetryGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
