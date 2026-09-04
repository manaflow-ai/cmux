import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The address arithmetic behind "does this Cloud VM route need the WireGuard hub".
@Suite
struct IPNetworkPrefixTests {
    @Test
    func parsesAndMatchesIPv4Prefixes() throws {
        let net = try #require(IPNetworkPrefix(cidr: "10.0.0.0/8"))
        #expect(net.family == .v4)
        #expect(net.contains("10.100.0.10"))
        #expect(net.contains("10.255.255.255"))
        #expect(!net.contains("11.0.0.1"))
        #expect(!net.contains("fd00::1"))
        let slash12 = try #require(IPNetworkPrefix(cidr: "172.16.0.0/12"))
        #expect(slash12.contains("172.31.255.1"))
        #expect(!slash12.contains("172.32.0.1"))
    }

    @Test
    func parsesAndMatchesIPv6Prefixes() throws {
        let net = try #require(IPNetworkPrefix(cidr: "fd00::/8"))
        #expect(net.family == .v6)
        #expect(net.contains("fd7a:7570:6c6b::10"))
        #expect(net.contains("FD00:0:0:0:0:0:0:1"))
        #expect(!net.contains("fe80::1"))
        #expect(!net.contains("2606:4700::1"))
        // Host bits are cleared at parse time, so a sloppy network address still matches.
        let sloppy = try #require(IPNetworkPrefix(cidr: "fd7a:7570:6c6b::9/64"))
        #expect(sloppy.contains("fd7a:7570:6c6b::ffff"))
    }

    @Test(arguments: ["10.0.0.0/33", "fd00::/129", "not-an-ip/8", "", "10.0.0.0/x"])
    func rejectsMalformedCIDRs(_ cidr: String) {
        #expect(IPNetworkPrefix(cidr: cidr) == nil)
    }

    @Test
    func bareAddressIsAHostRoute() throws {
        let host = try #require(IPNetworkPrefix(cidr: "10.1.2.3"))
        #expect(host.prefixLength == 32)
        #expect(host.contains("10.1.2.3"))
        #expect(!host.contains("10.1.2.4"))
    }

    @Test
    func privateRangesCoverRFC1918AndULAOnly() {
        #expect(IPNetworkPrefix.isPrivateAddress("10.100.0.10"))
        #expect(IPNetworkPrefix.isPrivateAddress("192.168.1.1"))
        #expect(IPNetworkPrefix.isPrivateAddress("172.20.0.1"))
        #expect(IPNetworkPrefix.isPrivateAddress("fd7a:7570:6c6b::10"))
        #expect(!IPNetworkPrefix.isPrivateAddress("100.64.0.1"))
        #expect(!IPNetworkPrefix.isPrivateAddress("2606:4700::1"))
        #expect(!IPNetworkPrefix.isPrivateAddress("m.vm.cmux.sh"))
    }

    @Test
    func routeHostStripsIPv6Brackets() {
        #expect(IPNetworkPrefix.routeHost("ws://[fd7a:7570:6c6b::10]:1337/v1/link?t=1") == "fd7a:7570:6c6b::10")
        #expect(IPNetworkPrefix.routeHost("ws://10.100.0.10:1337/v1/link") == "10.100.0.10")
        #expect(IPNetworkPrefix.routeHost("wss://m.vm.cmux.sh/v1/link") == "m.vm.cmux.sh")
        #expect(IPNetworkPrefix.routeHost("not a route") == nil)
    }

    /// The hub decision: capability present, literal private host. Anything else dials
    /// directly, exactly as before the hub existed.
    @Test
    func hubDecisionNeedsCapabilityAndPrivateHost() {
        let caps = ["direct-ws-user-agent", "wireguard-hub"]
        let vpcRoute = "ws://[fd7a:7570:6c6b::10]:1337/v1/link"
        #expect(CloudMachineLinkManager.usesWireGuardHub(route: vpcRoute, clientCapabilities: caps, enrolledRoutes: []))
        #expect(CloudMachineLinkManager.usesWireGuardHub(route: "ws://10.100.0.10:1337/v1/link", clientCapabilities: caps, enrolledRoutes: []))
        // No capability: the old client cannot take the flag.
        #expect(!CloudMachineLinkManager.usesWireGuardHub(route: vpcRoute, clientCapabilities: ["direct-ws-user-agent"], enrolledRoutes: []))
        // Public hosts never go through the hub.
        #expect(!CloudMachineLinkManager.usesWireGuardHub(route: "wss://m.vm.cmux.sh/v1/link", clientCapabilities: caps, enrolledRoutes: []))
        #expect(!CloudMachineLinkManager.usesWireGuardHub(route: "ws://[2606:4700::1]:1337/v1/link", clientCapabilities: caps, enrolledRoutes: []))
        // Once the tunnel's routes are known they are authoritative: a private host
        // outside them (another network) falls back to a direct dial.
        #expect(CloudMachineLinkManager.usesWireGuardHub(route: vpcRoute, clientCapabilities: caps, enrolledRoutes: ["10.0.0.0/8", "fd00::/8"]))
        #expect(!CloudMachineLinkManager.usesWireGuardHub(route: "ws://192.168.1.5:1337/v1/link", clientCapabilities: caps, enrolledRoutes: ["10.0.0.0/8", "fd00::/8"]))
    }
}
