import Foundation
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
        // Seed the cache through the awaited resolution path with a MagicDNS
        // name (only MagicDNS results are cached as fresh).
        let seeded = await resolver.routesResolvingTailscaleDNS(
            port: 51000,
            resolveHosts: { ["old-net.tail1234.ts.net", "100.64.0.1"] }
        )
        #expect(tailscaleHosts(in: seeded).contains("old-net.tail1234.ts.net"))

        // The cache serves the seeded hosts while fresh.
        let cached = resolver.routes(port: 51000, now: Date(), immediateHosts: { [] })
        #expect(tailscaleHosts(in: cached).contains("old-net.tail1234.ts.net"))

        // After invalidation (the network changed), the old-network hosts are
        // gone and only live interface-scan hosts remain.
        resolver.invalidateResolvedTailscaleHostCache()
        let afterInvalidate = resolver.routes(port: 51000, now: Date(), immediateHosts: { [] })
        #expect(!tailscaleHosts(in: afterInvalidate).contains("old-net.tail1234.ts.net"))
    }

    @Test func resolutionRacingInvalidationCannotRepolluteCache() async {
        let resolver = MobileRouteResolver()
        // Two-way handshake: `started` proves the resolution is genuinely in
        // flight (its cache generation already captured) before the
        // invalidation runs — `async let` alone does not guarantee the child
        // has begun — and `gate` holds it there until after the invalidation.
        let started = MobileHostNetworkPathAsyncSignal()
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
        await started.wait()
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

private final class MobileHostNetworkPathAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func signal() {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume()
            return
        }
        didSignal = true
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didSignal {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
