import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the network-path-change route refresh: the trigger policy on
/// `MobileHostService` (when a path observation should republish routes) and
/// the resolved-host cache invalidation on `MobileRouteResolver` (old-network
/// hosts must not be served, or land late, after the path changed).
@Suite struct MobileHostNetworkPathRefreshTests {
    // MARK: - Path signature

    @Test func signatureIsOrderInsensitiveOverInterfacesAndGateways() {
        let a = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["en0", "utun4"],
            gateways: ["192.168.1.1", "fe80::1"]
        )
        let b = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["utun4", "en0"],
            gateways: ["fe80::1", "192.168.1.1"]
        )
        #expect(a == b)
    }

    @Test func signatureChangesWhenAnInterfaceAppears() {
        // Tailscale coming up adds a utun interface; that must read as a change.
        let withoutTailscale = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"]
        )
        let withTailscale = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["en0", "utun4"],
            gateways: ["192.168.1.1"]
        )
        #expect(withoutTailscale != withTailscale)
    }

    @Test func signatureChangesWhenGatewayChanges() {
        // Same interface set, different network (e.g. a Wi-Fi move): the
        // gateway is what distinguishes the two paths.
        let homeNetwork = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["192.168.1.1"]
        )
        let officeNetwork = MobileHostService.networkPathSignature(
            status: "satisfied",
            interfaceNames: ["en0"],
            gateways: ["10.0.0.1"]
        )
        #expect(homeNetwork != officeNetwork)
    }

    // MARK: - Republish policy

    @Test func firstObservationRepublishes() {
        // The monitor's initial callback can arrive after the listener-ready
        // publish and describe a different path than the routes were computed
        // on; treating it as a silent baseline would swallow that first real
        // change. Republishing is deduped downstream, so the first observation
        // always republishes.
        #expect(MobileHostService.shouldRepublishRoutesForPathChange(
            previousSignature: nil,
            newSignature: "satisfied|en0|192.168.1.1"
        ) == true)
    }

    @Test func unchangedPathDoesNotRepublish() {
        let signature = "satisfied|en0|192.168.1.1"
        #expect(MobileHostService.shouldRepublishRoutesForPathChange(
            previousSignature: signature,
            newSignature: signature
        ) == false)
    }

    @Test func changedPathRepublishes() {
        #expect(MobileHostService.shouldRepublishRoutesForPathChange(
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
        let gate = DispatchSemaphore(value: 0)
        // Start a resolution that represents the OLD network and hold it
        // in flight while the path changes underneath it.
        async let staleResolution = resolver.routesResolvingTailscaleDNS(
            port: 51000,
            resolveHosts: {
                gate.wait()
                return ["stale-old-net.tail1234.ts.net"]
            }
        )
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
