import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Turning the one wg-quick config this Mac already wrote into what a
/// packet-tunnel provider needs — and keeping the private key out of the
/// dictionary macOS persists in the system VPN preferences.
@Suite
struct VMTunnelConfigurationTests {
    /// The shape the Cloud VM control plane issues, completed by
    /// `VMTunnelManager.completedConfig`.
    private static let privateKey = "aE7hLhWt4YyH1aVQFbF9Kg0aXyq0Yy5Zk9dFxU3nZ0Q="
    private static let sample = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.77.3.4/32, fd77:3::4/128
        DNS = 10.77.0.1, cmux.internal
        MTU = 1380

        [Peer]
        PublicKey = XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=
        PresharedKey = QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ=
        Endpoint = gateway.example.com:51820
        AllowedIPs = 10.77.3.0/24, fd77:3::/64
        PersistentKeepalive = 25
        """

    @Test
    func parsesInterfaceAddressesResolversAndSearchDomains() throws {
        let config = try VMTunnelConfiguration(wgQuickConfig: Self.sample)
        #expect(config.interface.addresses == ["10.77.3.4/32", "fd77:3::4/128"])
        // wg-quick's DNS list mixes resolvers and search domains; the provider
        // needs them apart, since a domain passed as a resolver breaks DNS.
        #expect(config.interface.dnsServers == ["10.77.0.1"])
        #expect(config.interface.searchDomains == ["cmux.internal"])
        #expect(config.interface.mtu == 1380)
    }

    @Test
    func parsesThePeer() throws {
        let config = try VMTunnelConfiguration(wgQuickConfig: Self.sample)
        let peer = try #require(config.peers.first)
        #expect(config.peers.count == 1)
        #expect(peer.publicKey == "XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=")
        #expect(peer.presharedKey == "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ=")
        #expect(peer.endpoint == "gateway.example.com:51820")
        #expect(peer.allowedIPs == ["10.77.3.0/24", "fd77:3::/64"])
        #expect(peer.persistentKeepalive == 25)
    }

    @Test
    func theProviderConfigurationNeverCarriesThePrivateKey() throws {
        // The load-bearing one. `providerConfiguration` is persisted by macOS
        // into the system VPN preferences (root-readable, captured by backups),
        // so the key travels as a keychain `passwordReference` instead. Checks
        // the serialized plist, not just the top-level keys, so a nested leak
        // fails too.
        let config = try VMTunnelConfiguration(wgQuickConfig: Self.sample)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: config.providerConfiguration,
            format: .xml,
            options: 0
        )
        let text = try #require(String(data: plist, encoding: .utf8))
        #expect(!text.contains(Self.privateKey))
        #expect(text.contains("XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y="))
    }

    @Test
    func theProviderConfigurationIsAValidPropertyList() throws {
        // NETunnelProviderProtocol rejects a providerConfiguration that is not
        // plist-representable, and the failure surfaces as an opaque
        // configuration error at save time.
        let config = try VMTunnelConfiguration(wgQuickConfig: Self.sample)
        #expect(PropertyListSerialization.propertyList(
            config.providerConfiguration, isValidFor: .xml
        ))
    }

    @Test
    func theProviderConfigurationCarriesTheRoutesAndResolvers() throws {
        let config = try VMTunnelConfiguration(wgQuickConfig: Self.sample)
        let dict = config.providerConfiguration
        #expect(dict["addresses"] as? [String] == ["10.77.3.4/32", "fd77:3::4/128"])
        #expect(dict["dns_servers"] as? [String] == ["10.77.0.1"])
        #expect(dict["search_domains"] as? [String] == ["cmux.internal"])
        #expect(dict["mtu"] as? Int == 1380)
        let peers = try #require(dict["peers"] as? [[String: Any]])
        #expect(peers.count == 1)
        #expect(peers[0]["allowed_ips"] as? [String] == ["10.77.3.0/24", "fd77:3::/64"])
        #expect(peers[0]["endpoint"] as? String == "gateway.example.com:51820")
    }

    @Test
    func optionalPeerFieldsAreOmittedRatherThanEmpty() throws {
        let minimal = """
            [Interface]
            PrivateKey = \(Self.privateKey)
            Address = 10.77.3.4/32

            [Peer]
            PublicKey = XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=
            AllowedIPs = 10.77.3.0/24
            """
        let config = try VMTunnelConfiguration(wgQuickConfig: minimal)
        let dict = config.providerConfiguration
        #expect(dict["dns_servers"] == nil)
        #expect(dict["search_domains"] == nil)
        #expect(dict["mtu"] == nil)
        let peers = try #require(dict["peers"] as? [[String: Any]])
        #expect(peers[0]["preshared_key"] == nil)
        #expect(peers[0]["endpoint"] == nil)
        #expect(peers[0]["persistent_keepalive"] == nil)
    }

    @Test
    func commentsAndBlankLinesAreIgnored() throws {
        let commented = """
            # this Mac on the cmux network
            [Interface]
            PrivateKey = \(Self.privateKey)
            Address = 10.77.3.4/32   # tunnel-side address

            [Peer]   # the network gateway
            PublicKey = XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=
            AllowedIPs = 10.77.3.0/24
            """
        let config = try VMTunnelConfiguration(wgQuickConfig: commented)
        #expect(config.interface.addresses == ["10.77.3.4/32"])
        #expect(config.peers.count == 1)
    }

    @Test
    func aConfigWithoutTheRequiredSectionsIsRejected() {
        #expect(throws: VMTunnelConfiguration.ParseError.noInterfaceSection) {
            _ = try VMTunnelConfiguration(wgQuickConfig: "[Peer]\nPublicKey = k\nAllowedIPs = 0.0.0.0/0")
        }
        #expect(throws: VMTunnelConfiguration.ParseError.noPeerSection) {
            _ = try VMTunnelConfiguration(wgQuickConfig: "[Interface]\nAddress = 10.77.3.4/32")
        }
        #expect(throws: VMTunnelConfiguration.ParseError.noAddresses) {
            _ = try VMTunnelConfiguration(
                wgQuickConfig: "[Interface]\nPrivateKey = k\n\n[Peer]\nPublicKey = k\nAllowedIPs = 0.0.0.0/0"
            )
        }
        #expect(throws: VMTunnelConfiguration.ParseError.peerWithoutPublicKey) {
            _ = try VMTunnelConfiguration(
                wgQuickConfig: "[Interface]\nAddress = 10.77.3.4/32\n\n[Peer]\nAllowedIPs = 0.0.0.0/0"
            )
        }
    }

    @Test
    func theServerAddressIsWhatSystemSettingsShows() throws {
        #expect(try VMTunnelConfiguration(wgQuickConfig: Self.sample).serverAddress == "gateway.example.com")
        #expect(try Self.configuration(endpoint: "203.0.113.9:51820").serverAddress == "203.0.113.9")
        // A bracketed IPv6 literal keeps its address, and a bare one has no
        // port to strip.
        #expect(try Self.configuration(endpoint: "[2001:db8::1]:51820").serverAddress == "2001:db8::1")
        #expect(try Self.configuration(endpoint: "2001:db8::1").serverAddress == "2001:db8::1")
    }

    @Test
    func aConfigTheAppItselfWroteRoundTrips() throws {
        // Guards the seam between the two backends: whatever
        // `completedConfig` produces has to parse, or the app-managed backend
        // rejects the config wg-quick would have accepted.
        let server = """
            [Interface]
            PrivateKey =
            Address = 10.77.3.4/32
            DNS = 10.77.0.1

            [Peer]
            PublicKey = XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=
            Endpoint = gateway.example.com:51820
            AllowedIPs = 0.0.0.0/0
            """
        let completed = try VMTunnelManager.completedConfig(
            server,
            privateKey: Self.privateKey,
            allowedIPs: ["10.77.3.0/24", "fd77:3::/64"]
        )
        let config = try VMTunnelConfiguration(wgQuickConfig: completed)
        #expect(config.peers.first?.allowedIPs == ["10.77.3.0/24", "fd77:3::/64"])
        #expect(config.interface.addresses == ["10.77.3.4/32"])
        let plist = try PropertyListSerialization.data(
            fromPropertyList: config.providerConfiguration, format: .xml, options: 0
        )
        let text = try #require(String(data: plist, encoding: .utf8))
        #expect(!text.contains(Self.privateKey))
    }

    private static func configuration(endpoint: String) throws -> VMTunnelConfiguration {
        try VMTunnelConfiguration(wgQuickConfig: """
            [Interface]
            PrivateKey = \(privateKey)
            Address = 10.77.3.4/32

            [Peer]
            PublicKey = XmY2Z0aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4Y=
            Endpoint = \(endpoint)
            AllowedIPs = 10.77.3.0/24
            """)
    }
}
