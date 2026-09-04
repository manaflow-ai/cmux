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
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")

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
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")
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
        #expect(VMTunnelManager(home: home, interfaceName: "cmux-test").wgQuickInterfaceUp() == false)
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
    func interfaceUpRequiresThePerInterfaceRuntimeMarker() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        // Loopback is always present, but it must not be enough to claim that
        // this deployment's tunnel is up: another build may own the same
        // tunnel-side address. The root-owned wg-quick marker is required.
        try """
        [Interface]
        Address = 127.0.0.1/32

        [Peer]
        PublicKey = Y
        """.write(to: manager.configURL, atomically: true, encoding: .utf8)
        #expect(manager.wgQuickInterfaceUp() == false)
    }

    @Test
    func interfaceNameAndStateHaveALegacyDeploymentFallback() {
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-staging.vercel.app")!) == "cmux-staging")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "http://localhost:9170")!) == "cmux-local")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://dev.example.invalid")!) == "cmux-dev")

        let home = URL(fileURLWithPath: "/tmp/cmux-tunnel-scope-tests", isDirectory: true)
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-staging")
        #expect(manager.configURL.lastPathComponent == "cmux-staging.conf")
        #expect(manager.appliedDigestURL.lastPathComponent == "cmux-staging.applied")
        #expect(manager.runtimeNameFileURL.path == "/var/run/wireguard/cmux-staging.name")
    }

    @Test
    func buildScopesDoNotShareCredentialsOrConfigFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let productionURL = URL(string: "https://cmux.com")!
        let nightly = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )
        let dev = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: productionURL
        )

        #expect(nightly.interfaceName != dev.interfaceName)
        #expect(nightly.configURL != dev.configURL)
        #expect(nightly.privateKeyURL != dev.privateKeyURL)
        #expect(nightly.deviceIDURL != dev.deviceIDURL)

        let nightlyKeys = try nightly.keypair()
        let devKeys = try dev.keypair()
        #expect(nightlyKeys.privateKey != devKeys.privateKey)
        #expect(nightlyKeys.publicKey != devKeys.publicKey)
        let nightlyFingerprint = try nightly.deviceFingerprint()
        let devFingerprint = try dev.deviceFingerprint()
        #expect(nightlyFingerprint != devFingerprint)

        let devRestart = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: URL(string: "http://localhost:9170")!
        )
        #expect(devRestart.interfaceName == dev.interfaceName)
        #expect(try devRestart.keypair().privateKey == devKeys.privateKey)
        #expect(try devRestart.deviceFingerprint() == devFingerprint)
    }

    @Test
    func stableProductionKeepsLegacyCredentialPathsWhileOtherBuildsAreScoped() {
        let home = URL(fileURLWithPath: "/tmp/cmux-tunnel-path-tests", isDirectory: true)
        let productionURL = URL(string: "https://cmux.com")!
        let stable = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app",
            apiBaseURL: productionURL
        )
        let nightly = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )

        #expect(stable.interfaceName == "cmux")
        #expect(stable.privateKeyURL.lastPathComponent == "private.key")
        #expect(stable.deviceIDURL.lastPathComponent == "device-id")
        #expect(stable.configURL.lastPathComponent == "cmux.conf")
        #expect(nightly.interfaceName == "cmux-nightly")
        #expect(nightly.privateKeyURL.lastPathComponent == "cmux-nightly.private.key")
        #expect(nightly.deviceIDURL.lastPathComponent == "cmux-nightly.device-id")
        #expect(nightly.configURL.lastPathComponent == "cmux-nightly.conf")
    }

    @Test
    func taggedBuildIdentityWinsOverItsBackendOrigin() {
        let productionURL = URL(string: "https://cmux.com")!
        let localURL = URL(string: "http://localhost:9170")!
        let taggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: productionURL
        )
        let sameTaggedDevOnLocalAPI = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: localURL
        )
        let anotherTaggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-notify",
            apiBaseURL: localURL
        )
        let nightly = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )

        #expect(taggedDev == sameTaggedDevOnLocalAPI)
        #expect(taggedDev != anotherTaggedDev)
        #expect(taggedDev != nightly)
        for name in [taggedDev, anotherTaggedDev, nightly] {
            #expect(name.utf8.count <= 15)
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        }
    }

    @Test
    func baseDebugBundleUsesItsLaunchTag() {
        let productionURL = URL(string: "https://cmux.com")!
        let first = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "all-agents"],
            apiBaseURL: productionURL
        )
        let second = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "cloud-notify"],
            apiBaseURL: productionURL
        )

        #expect(first != second)
        #expect(first != "cmux-dev")
        #expect(second != "cmux-dev")
    }

    @Test
    func staleConfigIsDetectedByDigest() throws {
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: "same", configDigest: "same"))
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: "old", configDigest: "new"))
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: nil, configDigest: "new"))
        #expect(!VMTunnelManager.isStale(interfaceUp: false, appliedDigest: "old", configDigest: "new"))
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: nil, configDigest: nil))
    }

    @Test
    func appliedDigestRoundTripRejectsAConfigChangedDuringBringUp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        let first = """
        [Interface]
        PrivateKey = key
        Address = 100.64.0.1/32

        [Peer]
        Endpoint = first.example:51820
        """
        let second = first.replacingOccurrences(of: "first.example", with: "second.example")
        try first.write(to: manager.configURL, atomically: true, encoding: .utf8)
        let firstDigest = try #require(manager.configDigest())
        try manager.recordApplied(true, expectedDigest: firstDigest)
        #expect(manager.appliedDigest() == firstDigest)
        #expect(!VMTunnelManager.isStale(interfaceUp: true, appliedDigest: manager.appliedDigest(), configDigest: manager.configDigest()))

        try second.write(to: manager.configURL, atomically: true, encoding: .utf8)
        #expect(throws: VMTunnelManager.TunnelError.self) {
            try manager.recordApplied(true, expectedDigest: firstDigest)
        }
        #expect(VMTunnelManager.isStale(interfaceUp: true, appliedDigest: manager.appliedDigest(), configDigest: manager.configDigest()))
        try manager.recordApplied(false)
        #expect(manager.appliedDigest() == nil)
    }

    @Test
    func completedConfigNarrowsRoutesWhenTheNetworkIsKnown() throws {
        let server = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32

        [Peer]
        PublicKey = server-key
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = vpn.example.com:51820
        """
        let completed = try VMTunnelManager.completedConfig(
            server,
            privateKey: "PRIVATE",
            allowedIPs: ["10.16.170.0/24", "fd98:deb9:4c94::/64"]
        )
        #expect(completed.contains("PrivateKey = PRIVATE"))
        #expect(completed.contains("AllowedIPs = 10.16.170.0/24, fd98:deb9:4c94::/64"))
        #expect(!completed.contains("10.0.0.0/8"))
    }
}
