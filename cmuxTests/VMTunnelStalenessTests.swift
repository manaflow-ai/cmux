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
        let manager = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app",
            apiBaseURL: URL(string: "https://cmux.com")!
        )
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

    @Test("Build identities get isolated interface names, with legacy URL fallback")
    func interfaceNamePerEnvironment() {
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://www.cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-staging.vercel.app")!) == "cmux-staging")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "http://localhost:3820")!) == "cmux-local")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-dev-backend-1.tail137216.ts.net:3916")!) == "cmux-dev")
        for name in ["cmux", "cmux-staging", "cmux-local", "cmux-dev"] {
            #expect(name.count <= 15, "wg-quick interface names are at most 15 characters")
        }
        let staging = VMTunnelManager(home: URL(fileURLWithPath: "/tmp/cmux-tunnel-scope", isDirectory: true), interfaceName: "cmux-staging")
        #expect(staging.configURL.lastPathComponent == "cmux-staging.conf")
        #expect(staging.appliedDigestURL.lastPathComponent == "cmux-staging.applied")
        #expect(staging.runtimeNameFileURL.path == "/var/run/wireguard/cmux-staging.name")
    }

    @Test("A production-targeted tagged DEV build never shares nightly's interface")
    func productionBuildVariantsAreDistinct() {
        let production = URL(string: "https://cmux.com")!
        let nightly = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: production
        )
        let taggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-notify",
            apiBaseURL: production
        )
        let otherTaggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-tree-agent-parity",
            apiBaseURL: production
        )
        let taggedDevOnLocalAPI = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-notify",
            apiBaseURL: URL(string: "http://localhost:9180")!
        )
        let taggedDevWithStaleLaunchEnvironment = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-notify",
            environment: ["CMUX_BUNDLE_ID": "com.cmuxterm.app"],
            apiBaseURL: production
        )

        #expect(nightly == "cmux-nightly")
        #expect(taggedDev != "cmux")
        #expect(taggedDev != nightly)
        #expect(taggedDev != otherTaggedDev)
        #expect(taggedDev == taggedDevOnLocalAPI)
        #expect(taggedDev == taggedDevWithStaleLaunchEnvironment)
        for name in [nightly, taggedDev, otherTaggedDev] {
            #expect(name.count <= 15, "wg-quick interface names are at most 15 characters")
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        }
    }

    @Test("The base DEBUG bundle uses its tag when deriving a tunnel scope")
    func baseDebugBundleUsesLaunchTag() {
        let production = URL(string: "https://cmux.com")!
        let first = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "cloud-notify"],
            apiBaseURL: production
        )
        let second = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "cloud-tree-agent-parity"],
            apiBaseURL: production
        )
        #expect(first != second)
        #expect(first != "cmux-dev")
        #expect(second != "cmux-dev")
    }

    @Test("The completed config routes only this network's prefixes, so two tunnels can be up side by side")
    func allowedIPsNarrowToTheNetwork() throws {
        let server = "[Interface]\nPrivateKey = \nAddress = 100.64.0.1/32\n\n[Peer]\nPublicKey = p\nAllowedIPs = 10.0.0.0/8, fd00::/8\nEndpoint = tun.example:51820\n"
        let completed = try VMTunnelManager.completedConfig(server, privateKey: "k", allowedIPs: ["10.16.170.0/24", "fd98:deb9:4c94::/64"])
        #expect(completed.contains("AllowedIPs = 10.16.170.0/24, fd98:deb9:4c94::/64"))
        #expect(!completed.contains("10.0.0.0/8"))
        #expect(completed.contains("PrivateKey = k"))
        // macOS permits duplicate destinations only when each route is scoped
        // to its owning utun.  Without these hooks stock wg-quick's second
        // `route add` fails with EEXIST and tears the new tunnel back down.
        #expect(completed.contains("Table = off"))
        #expect(completed.contains("PostUp = /sbin/route -q -n add -inet '10.16.170.0/24' -interface %i -ifscope %i"))
        #expect(completed.contains("PostUp = /sbin/route -q -n add -inet6 'fd98:deb9:4c94::/64' -interface %i -ifscope %i"))
        #expect(completed.contains("PostDown = /sbin/route -q -n delete -inet -ifscope %i '10.16.170.0/24'"))
        #expect(completed.contains("PostDown = /sbin/route -q -n delete -inet6 -ifscope %i 'fd98:deb9:4c94::/64'"))
        // Nothing known about the network: the server's routes stay.
        let kept = try VMTunnelManager.completedConfig(server, privateKey: "k", allowedIPs: [])
        #expect(kept.contains("AllowedIPs = 10.0.0.0/8, fd00::/8"))
    }

    @Test("Route hooks reject values that could escape the privileged command")
    func routeHooksRejectUnsafeAllowedIPs() {
        let server = "[Interface]\nPrivateKey = \nAddress = 100.64.0.1/32\n\n[Peer]\nPublicKey = p\nAllowedIPs = 10.0.0.0/8\n"
        #expect(throws: VMTunnelManager.TunnelError.self) {
            _ = try VMTunnelManager.completedConfig(
                server,
                privateKey: "k",
                allowedIPs: ["10.16.170.0/24; touch /tmp/cmux-route-pwned"]
            )
        }
    }
}
