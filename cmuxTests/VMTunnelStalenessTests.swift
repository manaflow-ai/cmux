import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression: every enrollment gives this Mac the same tunnel-side address,
/// so the liveness check alone read a `cmux` interface left up for another
/// account as "this tunnel is up" and `cmux vpn up` answered "already up"
/// while every private route stayed dead. The app now keeps the digest of the
/// config `vpn up` actually brought up and reports the interface as stale
/// when the config on disk differs; `vpn up` replaces a stale tunnel.
@Suite("VM tunnel staleness")
struct VMTunnelStalenessTests {
    @Test("Up with the applied config is fine; another config, or no record, is stale; down is never stale")
    func stalenessTable() {
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: "a", configDigest: "a"))
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: "a", configDigest: "b"), "another enrollment on disk")
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: nil, configDigest: "b"), "a tunnel from before the record existed re-applies once")
        #expect(!VMTunnelManager.isStale(interfaceUp: false, appliedDigest: nil, configDigest: "b"))
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: nil, configDigest: nil), "nothing enrolled: nothing to be stale against")
    }

    @Test("The applied record follows the config on disk")
    func appliedRecordRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tunnel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        #expect(manager.configDigest() == nil)
        #expect(manager.appliedDigest() == nil)
        #expect(throws: VMTunnelManager.TunnelError.self) { try manager.recordApplied(true) }

        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        let production = "[Interface]\nPrivateKey = k\nAddress = 100.64.0.1/32\n\n[Peer]\nEndpoint = tun-a.example:51820\n"
        let staging = "[Interface]\nPrivateKey = k\nAddress = 100.64.0.1/32\n\n[Peer]\nEndpoint = tun-b.example:51820\n"
        try production.write(to: manager.configURL, atomically: true, encoding: .utf8)
        let applied = try #require(manager.configDigest())
        try manager.recordApplied(true, expectedDigest: applied)
        #expect(manager.appliedDigest() == applied)
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: manager.appliedDigest(), configDigest: manager.configDigest()))

        // The same tunnel-side address, a different peer: the exact shape of a
        // second account enrolling on this Mac.
        try staging.write(to: manager.configURL, atomically: true, encoding: .utf8)
        #expect(VMTunnelManager.interfaceAddresses(in: staging) == VMTunnelManager.interfaceAddresses(in: production), "liveness by address cannot tell them apart")
        #expect(manager.configDigest() != applied)
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: manager.appliedDigest(), configDigest: manager.configDigest()))

        #expect(throws: VMTunnelManager.TunnelError.self) {
            try manager.recordApplied(true, expectedDigest: applied)
        }

        try manager.recordApplied(false)
        #expect(manager.appliedDigest() == nil)
    }

    @Test("The sidebar names the tunnel as the blocker, and the fix")
    func blockerText() throws {
        #expect(VMTunnelManager.privateRouteBlocker(interfaceUp: true, stale: false) == nil)
        let down = try #require(VMTunnelManager.privateRouteBlocker(interfaceUp: false, stale: false))
        #expect(down.contains("cmux vpn up"))
        let stale = try #require(VMTunnelManager.privateRouteBlocker(interfaceUp: true, stale: true))
        #expect(stale.contains("different enrollment") && stale.contains("cmux vpn up"))
    }
}
