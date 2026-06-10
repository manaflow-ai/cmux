import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Mobile route resolver
extension MobileHostAuthorizationTests {
    func testMobileRouteResolverPrefersTailscaleMagicDNSBeforeIPv4Fallback() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            tailscaleHosts: [
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        XCTAssertEqual(tailscaleRoutes.count, 2)
        XCTAssertEqual(tailscaleRoutes.first?.priority, 10)
        XCTAssertEqual(tailscaleRoutes.last?.priority, 20)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected first Tailscale route to use a host/port endpoint")
        }
        if case let .hostPort(host, port) = tailscaleRoutes.last?.endpoint {
            XCTAssertEqual(host, "100.71.210.41")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected fallback Tailscale route to use a host/port endpoint")
        }
    }

    func testMobileRouteResolverImmediateSnapshotUsesNumericTailscaleFallbackWithoutDNS() throws {
        let resolver = MobileRouteResolver()

        let snapshot = resolver.routes(
            port: 61234,
            immediateHosts: {
                ["100.71.210.41"]
            }
        )

        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        XCTAssertEqual(tailscaleRoutes.count, 1)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "100.71.210.41")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected immediate snapshot to include a numeric Tailscale route")
        }
        XCTAssertEqual(snapshot.routes.filter { $0.kind == .debugLoopback }.count, 1)
    }

    func testMobileRouteResolverAwaitsMagicDNSForPublicStatusRoutes() async throws {
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
        XCTAssertEqual(tailscaleRoutes.count, 2)
        if case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected public status route to wait for MagicDNS")
        }
    }

    func testMobileRouteResolverRefreshesStalePublicStatusRoutes() async throws {
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
            XCTAssertEqual(host, "new-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected stale public status routes to refresh")
        }
    }

    func testMobileRouteResolverRetriesAfterIPOnlyPublicStatusRoutes() async throws {
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
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
            XCTAssertEqual(port, 61234)
        } else {
            XCTFail("Expected IP-only public status routes to retry MagicDNS resolution")
        }
    }

    func testMobileRouteResolverNotifiesCallbackForInFlightMagicDNSRefresh() async throws {
        let resolver = MobileRouteResolver()
        let started = expectation(description: "refresh started")
        let callback = expectation(description: "refresh callback")
        let startedBox = SendableExpectation(started)
        let callbackBox = SendableExpectation(callback)
        let gate = SendableSemaphore(value: 0)
        let observedHosts = LockedHosts()

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                startedBox.fulfill()
                gate.wait()
                return [
                    "work-mac.tailnet.ts.net",
                    "100.71.210.41",
                ]
            }
        )
        await fulfillment(of: [started], timeout: 1)

        resolver.refreshTailscaleRoutes(
            resolveHosts: {
                ["unused.tailnet.ts.net"]
            },
            onResolvedHosts: { hosts in
                observedHosts.set(hosts)
                callbackBox.fulfill()
            }
        )

        gate.signal()
        await fulfillment(of: [callback], timeout: 1)
        XCTAssertEqual(observedHosts.value(), [
            "work-mac.tailnet.ts.net",
            "100.71.210.41",
        ])

        let snapshot = resolver.routes(port: 61234, immediateHosts: { [] })
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }
        if case let .hostPort(host, _) = tailscaleRoutes.first?.endpoint {
            XCTAssertEqual(host, "work-mac.tailnet.ts.net")
        } else {
            XCTFail("Expected callback refresh to populate the MagicDNS route")
        }
    }

}
