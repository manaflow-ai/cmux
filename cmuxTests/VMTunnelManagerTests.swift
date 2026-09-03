import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The local half of Cloud VM private networking: keys and device identity are
/// minted once and stay stable, and the server-issued config (blank
/// `PrivateKey`) is completed on this Mac without ever sending the key out.
@Suite
struct VMTunnelManagerTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tunnel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func keypairIsMintedOnceAndStable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)

        let first = try manager.keypair()
        let second = try manager.keypair()
        #expect(first.privateKey == second.privateKey)
        #expect(first.publicKey == second.publicKey)

        // The public half must be the X25519 derivation of the private half —
        // a mismatch would enroll a key the Mac cannot handshake with.
        let raw = try #require(Data(base64Encoded: first.privateKey))
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == first.publicKey)

        // 0600: the private key is a credential.
        let attrs = try FileManager.default.attributesOfItem(atPath: manager.privateKeyURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test
    func deviceFingerprintIsStablePerInstallation() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        let first = try manager.deviceFingerprint()
        #expect(first.hasPrefix("mac-"))
        #expect(try manager.deviceFingerprint() == first)
    }

    @Test
    func completedConfigFillsTheBlankPrivateKeyLine() throws {
        let config = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32
        MTU = 1200

        [Peer]
        PublicKey = server-key
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = vpn.example.com:51820
        """
        let completed = try VMTunnelManager.completedConfig(config, privateKey: "PRIVATE")
        #expect(completed.contains("PrivateKey = PRIVATE"))
        // Everything else must be byte-identical: the server config is final.
        #expect(completed.contains("Address = 100.64.0.1/32"))
        #expect(completed.contains("Endpoint = vpn.example.com:51820"))
    }

    @Test
    func completedConfigInsertsWhenNoPrivateKeyLineExists() throws {
        let config = """
        [Interface]
        Address = 100.64.0.1/32

        [Peer]
        PublicKey = server-key
        """
        let completed = try VMTunnelManager.completedConfig(config, privateKey: "PRIVATE")
        let lines = completed.components(separatedBy: "\n")
        let interfaceIndex = try #require(lines.firstIndex(of: "[Interface]"))
        #expect(lines[interfaceIndex + 1] == "PrivateKey = PRIVATE")
    }

    @Test
    func completedConfigRejectsAConfigWithoutAnInterfaceSection() {
        #expect(throws: VMTunnelManager.TunnelError.self) {
            _ = try VMTunnelManager.completedConfig("[Peer]\nPublicKey = x", privateKey: "PRIVATE")
        }
    }

    @Test
    func interfaceUpIsFalseWithoutAWrittenConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // No config on disk means nothing to match interfaces against.
        #expect(VMTunnelManager(home: home).wgQuickInterfaceUp() == false)
    }

    @Test
    func interfaceAddressesParseOnlyTheInterfaceSection() {
        let config = """
        [Interface]
        PrivateKey = X
        Address = 100.64.0.9/32
        Address = FD7A:7570:6C6B::9/128, 10.9.9.9/24
        MTU = 1380

        [Peer]
        PublicKey = Y
        AllowedIPs = 10.0.0.0/8, fd00::/8
        """
        // Prefix lengths stripped, IPv6 lowercased, AllowedIPs never included —
        // matching an AllowedIPs range against interface addresses would call
        // any 10.x interface "the tunnel".
        #expect(VMTunnelManager.interfaceAddresses(in: config) == [
            "100.64.0.9", "fd7a:7570:6c6b::9", "10.9.9.9",
        ])
    }

    @Test
    func interfaceUpMatchesALiveInterfaceAddress() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        // Loopback is always present, so a config claiming 127.0.0.1 as the
        // interface address reads as up — proving detection is address-based.
        try """
        [Interface]
        Address = 127.0.0.1/32

        [Peer]
        PublicKey = Y
        """.write(to: manager.configURL, atomically: true, encoding: .utf8)
        #expect(manager.wgQuickInterfaceUp() == true)
    }


    // MARK: Route preflight

    @Test
    func routeHostStripsSchemeBracketsPortAndPath() {
        #expect(VMTunnelManager.routeHost("ws://[fd7a:7570:6c6b::2]:1337/v1/link?t=abc") == "fd7a:7570:6c6b::2")
        #expect(VMTunnelManager.routeHost("ws://[FD7A::2]/v1/link") == "fd7a::2")
        #expect(VMTunnelManager.routeHost("ws://10.4.0.9:1337/v1/link") == "10.4.0.9")
        #expect(VMTunnelManager.routeHost("wss://vm-abc.machines.cmux.com/v1/link?token=x") == "vm-abc.machines.cmux.com")
        #expect(VMTunnelManager.routeHost("wss://user@Host.Example:443/x") == "host.example")
        // Not an authority: no host to judge, so the caller must not block on it.
        #expect(VMTunnelManager.routeHost("ws://fd7a::2:1337/v1/link") == nil)
        #expect(VMTunnelManager.routeHost("") == nil)
        #expect(VMTunnelManager.routeHost("ws://[") == nil)
    }

    @Test
    func privateRoutesAreTheOnesTheTunnelCarries() {
        // The Freestyle VPC hands out unique-local IPv6 and 10/8 addresses.
        #expect(VMTunnelManager.routeRequiresTunnel("ws://[fd7a:7570:6c6b:0:1::2]:1337/v1/link"))
        #expect(VMTunnelManager.routeRequiresTunnel("ws://[fc00::1]:1337/v1/link"))
        #expect(VMTunnelManager.routeRequiresTunnel("ws://10.32.0.28:1337/v1/link"))
        #expect(VMTunnelManager.routeRequiresTunnel("ws://172.20.0.5:1337/v1/link"))
        #expect(VMTunnelManager.routeRequiresTunnel("ws://192.168.1.5:1337/v1/link"))
        #expect(VMTunnelManager.routeRequiresTunnel("ws://100.64.0.1:1337/v1/link"))
        // Public addresses, hostnames and link-local are reachable (or not) without it.
        #expect(!VMTunnelManager.routeRequiresTunnel("ws://[2602:f470:1::28]:1337/v1/link"))
        #expect(!VMTunnelManager.routeRequiresTunnel("ws://[fe80::1]:1337/v1/link"))
        #expect(!VMTunnelManager.routeRequiresTunnel("ws://172.32.0.1:1337/v1/link"))
        #expect(!VMTunnelManager.routeRequiresTunnel("ws://100.128.0.1:1337/v1/link"))
        #expect(!VMTunnelManager.routeRequiresTunnel("wss://vm-abc.machines.cmux.com/v1/link?token=x"))
        #expect(!VMTunnelManager.routeRequiresTunnel("not a route"))
    }

    @Test
    func preflightRefusesAPrivateRouteWhileTheTunnelIsDown() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // No config at all: the tunnel is down, so a private route is unreachable.
        let manager = VMTunnelManager(home: home)
        #expect(throws: VMTunnelManager.TunnelError.self) {
            try manager.preflight(route: "ws://[fd7a:7570:6c6b::2]:1337/v1/link")
        }
        // The error names the fix; it is what the sheet and the CLI print.
        let text = String(describing: VMTunnelManager.TunnelError.tunnelDown)
        #expect(text.contains("cmux vpn up"))
        // A public route never needs the tunnel.
        try manager.preflight(route: "wss://vm-abc.machines.cmux.com/v1/link?token=x")
        try manager.preflight(route: "ws://[2602:f470:1::28]:1337/v1/link")
    }

    @Test
    func preflightPassesAPrivateRouteWhenTheTunnelIsUp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        // Loopback stands in for the live tunnel address (see interfaceUpMatchesALiveInterfaceAddress).
        try """
        [Interface]
        Address = 127.0.0.1/32

        [Peer]
        PublicKey = Y
        """.write(to: manager.configURL, atomically: true, encoding: .utf8)
        try manager.preflight(route: "ws://[fd7a:7570:6c6b::2]:1337/v1/link")
        #expect(manager.isEnrolledButDown == false)
    }

    @Test
    func enrolledButDownNeedsAConfigWhoseAddressNoInterfaceHolds() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        // Never enrolled: nothing to say yet.
        #expect(manager.isEnrolledButDown == false)
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        // A documentation-range address (RFC 5737) is never configured on a real interface.
        try """
        [Interface]
        Address = 192.0.2.77/32

        [Peer]
        PublicKey = Y
        """.write(to: manager.configURL, atomically: true, encoding: .utf8)
        #expect(manager.isEnrolledButDown)
    }
}
