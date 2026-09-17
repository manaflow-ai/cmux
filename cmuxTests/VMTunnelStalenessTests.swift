import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The remaining config-scope rules shared by the user-space and Network
/// Extension WireGuard implementations.
@Suite("VM tunnel config scope")
struct VMTunnelStalenessTests {
    @Test("One tunnel per deployment: production keeps `cmux`, other deployments get their own interface")
    func interfaceNamePerEnvironment() {
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://www.cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-staging.vercel.app")!) == "cmux-staging")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "http://localhost:3820")!) == "cmux-local")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-dev-backend-1.tail137216.ts.net:3916")!) == "cmux-dev")
        for name in ["cmux", "cmux-staging", "cmux-local", "cmux-dev"] {
            #expect(name.count <= 15, "WireGuard interface names are at most 15 characters")
        }
        let staging = VMTunnelManager(home: URL(fileURLWithPath: "/tmp/cmux-tunnel-scope", isDirectory: true), interfaceName: "cmux-staging")
        #expect(staging.configURL.lastPathComponent == "cmux-staging.conf")
    }

    @Test("The completed config routes only this network's prefixes, so two tunnels can be up side by side")
    func allowedIPsNarrowToTheNetwork() throws {
        let server = "[Interface]\nPrivateKey = \nAddress = 100.64.0.1/32\n\n[Peer]\nPublicKey = p\nAllowedIPs = 10.0.0.0/8, fd00::/8\nEndpoint = tun.example:51820\n"
        let completed = try VMTunnelManager.completedConfig(server, privateKey: "k", allowedIPs: ["10.16.170.0/24", "fd98:deb9:4c94::/64"])
        #expect(completed.contains("AllowedIPs = 10.16.170.0/24, fd98:deb9:4c94::/64"))
        #expect(!completed.contains("10.0.0.0/8"))
        #expect(completed.contains("PrivateKey = k"))
        // Nothing known about the network: the server's routes stay.
        let kept = try VMTunnelManager.completedConfig(server, privateKey: "k", allowedIPs: [])
        #expect(kept.contains("AllowedIPs = 10.0.0.0/8, fd00::/8"))
    }
}
