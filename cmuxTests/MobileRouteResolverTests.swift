import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Route-resolution coverage for the mobile host: Tailscale MagicDNS
/// preference, numeric fallbacks, and public-status route refresh. Split from
/// MobileHostAuthorizationTests to keep that file within the length budget.
@Suite(.serialized)
@MainActor
struct MobileRouteResolverTests {
    @Test func testMobileRouteResolverPrefersTailscaleMagicDNSBeforeIPv4Fallback() throws {
        let resolver = MobileRouteResolver()
        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 2)
        #expect(tailscaleRoutes.first?.priority == 10)
        #expect(tailscaleRoutes.last?.priority == 20)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected first Tailscale route to use a host/port endpoint")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected fallback Tailscale route to use a host/port endpoint")
        }
    }
    @Test func testMobileRouteResolverImmediateSnapshotUsesNumericTailscaleFallbackWithoutDNS() throws {
        let resolver = MobileRouteResolver()
        let snapshot = resolver.routes(
            port: 61234,
            immediateHosts: {
                ["100.71.210.41"]
            }
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "100.71.210.41")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected immediate snapshot to include a numeric Tailscale route")
        }
        #expect(snapshot.routes.filter { $0.kind == .debugLoopback }.count == 1)
    }
    @Test func testMobileRouteResolverAwaitsMagicDNSForPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let snapshot = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        #expect(tailscaleRoutes.count == 2)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected public status route to wait for MagicDNS")
        }
    }
    @Test func testMobileRouteResolverRefreshesStalePublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()
        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "old-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "new-mac.tailnet.ts.net",
                    "100.71.210.42",
                ]
            },
            now: now.addingTimeInterval(31)
        )
        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "new-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected stale public status routes to refresh")
        }
    }
    @Test func testMobileRouteResolverRetriesAfterIPOnlyPublicStatusRoutes() async throws {
        let resolver = MobileRouteResolver()
        let now = Date()
        _ = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                ["100.71.210.41"]
            },
            now: now
        )
        let refreshed = await resolver.routesResolvingTailscaleDNS(
            port: 61234,
            resolveHosts: {
                [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            },
            now: now.addingTimeInterval(1)
        )
        let tailscaleRoutes = refreshed.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
            #expect(port == 61234)
        } else {
            #expect(Bool(false), "Expected IP-only public status routes to retry MagicDNS resolution")
        }
    }
    @Test func testMobileRouteResolverNotifiesCallbackForInFlightMagicDNSRefresh() async throws {
        let resolver = MobileRouteResolver()
        let started = AsyncTestSignal()
        let callback = AsyncTestSignal()
        let gate = SendableSemaphore(value: 0)
        let observedHosts = LockedHosts()
        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                started.fulfill()
                gate.wait()
                return [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        try await started.wait()
        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                ["unused.tailnet.ts.net"]
            },
            onResolvedHosts: { hosts in
                observedHosts.set(hosts)
                callback.fulfill()
            }
        )
        gate.signal()
        try await callback.wait()
        #expect(observedHosts.value() == [
            "work-mac.tailnet.ts.net",
            "100.71.210.41",
        ])
        let snapshot = resolver.routes(port: 61234, immediateHosts: { [] })
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, _) = tailscaleRoutes.first?.endpoint {
            #expect(host == "work-mac.tailnet.ts.net")
        } else {
            #expect(Bool(false), "Expected callback refresh to populate the MagicDNS route")
        }
    }
}
