import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
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
        let forward = try CloudLoopbackPortForward(target: target, dialer: dialer)
        let localPort = try await forward.start()

        for _ in 0..<3 {
            let client = try await CloudLoopbackPortForwardTests.client(port: localPort)
            try await client.sendAll(Data("ping".utf8))
            #expect(try await client.receiveExactly(4) == Array("ping".utf8))
            client.cancel()
        }
        let attempts = hub.connectTargets
        #expect(attempts.filter { $0.host == ipv4 }.count == 1,
                "A desktop asset burst must not dial the failed family for every connection")
        #expect(attempts.filter { $0.host == ipv6 }.count == 3)

        hub.refusedHosts = [ipv6]
        let recovered = try await CloudLoopbackPortForwardTests.client(port: localPort)
        try await recovered.sendAll(Data("back".utf8))
        #expect(try await recovered.receiveExactly(4) == Array("back".utf8),
                "Remembering a family must preserve fallback when reachability changes")
        recovered.cancel()
        await forward.stop()
        #expect(await CloudLoopbackPortForwardTests.waitUntil { dialer.claims == dialer.releases })
    }

}
