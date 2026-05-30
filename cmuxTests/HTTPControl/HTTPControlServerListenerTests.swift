import Foundation
import Network
import Testing
@testable import cmux

@Suite struct HTTPControlServerListenerTests {
    @Test func startsOnEphemeralPortAndCloses() throws {
        let server = HTTPControlServer(
            routeTable: RouteTable(),
            auth: HTTPAuth(expectedToken: "t"),
            hostAllowlistFor: { p in HostAllowlist(port: Int(p)) }
        )
        let port = try server.startTCP(port: 0)
        #expect(port > 0)
        server.stop()
    }

    @Test func boundPortIsLoopbackReachable() throws {
        let server = HTTPControlServer(
            routeTable: RouteTable(),
            auth: HTTPAuth(expectedToken: "t"),
            hostAllowlistFor: { p in HostAllowlist(port: Int(p)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        conn.start(queue: .global())
        #expect(ready.wait(timeout: .now() + 2) == .success)
        conn.cancel()
    }
}
