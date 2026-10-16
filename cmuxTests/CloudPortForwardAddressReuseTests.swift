import CmuxCloud
import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.timeLimit(.minutes(1)))
struct CloudPortForwardAddressReuseTests {
    @Test("Successive browser connections reuse the working family and recover if it fails")
    func browserConnectionsReuseWorkingFamily() async throws {
        let hub = try CloudLoopbackPortForwardTests.FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let ipv4 = "10.0.0.7"
        let ipv6 = "fd00::1"
        hub.refusedHosts = [ipv4]
        let dialer = CloudLoopbackPortForwardTests.FakeHubDialer(endpoint: hub.endpoint)
        let target = CloudPortForwardTarget(host: ipv4, port: 6901, fallbackHosts: [ipv6])
        let clock = SidebarTestManualClock()
        var relay = CloudPortForwardRelay(dialer: dialer)
        relay.clock = clock
        let forward = try CloudLoopbackPortForward(target: target, dialer: dialer, relay: relay)
        let localPort = try await forward.start()

        for index in 0..<3 {
            let client = try await CloudLoopbackPortForwardTests.client(port: localPort)
            defer { client.cancel() }
            try await client.sendAll(Data("ping".utf8))
            if index == 0 {
                try #require(await CloudLoopbackPortForwardTests.waitUntil { hub.connectTargets.contains { $0.host == ipv4 } })
                await clock.waitUntilSleeping(for: .milliseconds(250))
                clock.advance(by: .milliseconds(250))
            }
            // Leave the fallback clock parked for subsequent connections.
            // A loaded CI runner may take over 250ms for a successful local
            // handshake; that must not be mistaken for forgetting the family.
            #expect(try await client.receiveExactly(4) == Array("ping".utf8))
            client.cancel()
        }
        let attempts = hub.connectTargets
        // Advancing the clock 250 ms in one step also passes the connector's
        // 50 ms redial point, so the first connection may redial IPv4 once if
        // its refusal was not read yet. Dialing IPv4 again for the second and
        // third connections would make at least three.
        #expect(attempts.filter { $0.host == ipv4 }.count <= 2,
                "A desktop asset burst must not dial the failed family for every connection")
        #expect(attempts.filter { $0.host == ipv6 }.count == 3)

        hub.refusedHosts = [ipv6]
        let recovered = try await CloudLoopbackPortForwardTests.client(port: localPort)
        defer { recovered.cancel() }
        try await recovered.sendAll(Data("back".utf8))
        try #require(await CloudLoopbackPortForwardTests.waitUntil { hub.connectTargets.filter { $0.host == ipv6 }.count == 4 })
        await clock.waitUntilSleeping(for: .milliseconds(250))
        clock.advance(by: .milliseconds(250))
        #expect(try await recovered.receiveExactly(4) == Array("back".utf8),
                "Remembering a family must preserve fallback when reachability changes")
        recovered.cancel()
        await forward.stop()
        #expect(await CloudLoopbackPortForwardTests.waitUntil { dialer.claims == dialer.releases })
    }

}
