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

    @Test
    func completedConfigAddsPeerKeepaliveOnce() throws {
        let server = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32
        MTU = 1380

        [Peer]
        PublicKey = abc
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = tun.example:51820
        """
        let completed = try VMTunnelManager.completedConfig(server, privateKey: "KEY")
        let lines = completed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.filter { $0.hasPrefix("PersistentKeepalive") }.count == 1)
        let peerIndex = try #require(lines.firstIndex(of: "[Peer]"))
        let keepaliveIndex = try #require(lines.firstIndex(of: "PersistentKeepalive = \(VMTunnelManager.persistentKeepaliveSeconds)"))
        #expect(keepaliveIndex > peerIndex)
        // Re-completing an already-complete config does not duplicate it.
        let again = try VMTunnelManager.completedConfig(completed, privateKey: "KEY")
        #expect(again.components(separatedBy: "PersistentKeepalive").count == 2)
    }

    @Test
    func completedConfigKeepsAServerProvidedKeepalive() throws {
        let server = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32

        [Peer]
        PublicKey = abc
        PersistentKeepalive = 15
        """
        let completed = try VMTunnelManager.completedConfig(server, privateKey: "KEY")
        #expect(completed.contains("PersistentKeepalive = 15"))
        #expect(!completed.contains("PersistentKeepalive = 25"))
    }

    @Test
    func networkMetadataRoundTripsWithRestrictedPermissions() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home)
        #expect(manager.loadNetworkMetadata() == nil)
        let metadata = VMTunnelManager.NetworkMetadata(
            tunnelId: "tun-1",
            addressV4: "10.16.204.2",
            addressV6: "fd53:9585:5690::2",
            networkCidr: "10.16.204.0/24",
            networkCidrV6: "fd53:9585:5690::/64"
        )
        try manager.writeNetworkMetadata(metadata)
        #expect(manager.loadNetworkMetadata() == metadata)
        #expect(metadata.networkCIDRs == ["10.16.204.0/24", "fd53:9585:5690::/64"])
        #expect(metadata.machineFacingAddresses == ["fd53:9585:5690::2", "10.16.204.2"])
        let attributes = try FileManager.default.attributesOfItem(atPath: manager.networkMetadataURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test
    func liveInterfaceAddressesIsEmptyWithoutAConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(VMTunnelManager(home: home).liveInterfaceAddresses().isEmpty)
    }
}
